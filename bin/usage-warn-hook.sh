#!/usr/bin/env bash
#
# usage-warn-hook.sh - Claude Code PreToolUse hook.
#
# Warns the agent when account usage crosses the threshold, so it can wrap up
# and write down its progress before being force-stopped. Two tiers: a warning
# at USAGE_WARN_PCT and a final one at USAGE_CRITICAL_PCT, each once per window.
#
# Subagents run under their parent's session_id, so they are told apart by the
# agent_id the hook input carries for them. Each subagent and the main thread
# latch separately - otherwise the first subagent to make a tool call swallows
# the one warning meant for the main thread, which then never hears of it.
#
# THIS SCRIPT ALWAYS EXITS 0. A PreToolUse hook that exits non-zero blocks the
# tool call; a monitor that can halt every session at once is worse than no
# monitor. Errors are reported loudly through additionalContext and the log,
# never by blocking.

set -u

: "${CLAUDE_CONFIG_DIR:=${HOME}/.claude}"
: "${USAGE_WARN_PCT:=90}"
: "${USAGE_CRITICAL_PCT:=97}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_USAGE="${SELF_DIR}/claude-usage"

STATE_DIR="${CLAUDE_CONFIG_DIR}/usage-state"
WARNED_DIR="${STATE_DIR}/warned"
LOG="${STATE_DIR}/monitor.log"
BREAKAGE_QUIET_SECONDS=3600

log() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s usage-warn-hook: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >> "$LOG" 2>/dev/null || true
}

emit() {
    # Requires jq. install.sh hard-requires it, so its absence is a real fault.
    jq -cn --arg c "$1" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null \
        || log "could not emit additionalContext: jq unavailable"
}

file_mtime() {
    date '+%s' -r "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

main() {
    local input session_id agent_id scope state rc five_pct week_pct

    input="$(cat)"

    command -v jq >/dev/null 2>&1 || { log "jq is not installed"; return 0; }

    session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
    case "$session_id" in
        ""|*[!A-Za-z0-9._-]*) log "hook input carried no usable session_id"; return 0 ;;
    esac

    # Absent on main-thread calls, present on every subagent call.
    agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)"
    case "$agent_id" in
        "") scope="main" ;;
        *[!A-Za-z0-9._-]*) log "hook input carried an unusable agent_id (session ${session_id})"; return 0 ;;
        *) scope="agent-${agent_id}" ;;
    esac

    [ -x "$CLAUDE_USAGE" ] || { log "claude-usage not found or not executable at ${CLAUDE_USAGE}"; return 0; }

    state="$("$CLAUDE_USAGE" --json 2>&1)"
    rc=$?

    case "$rc" in
        0)  ;;
        6)  # Nothing published yet. Normal during the first seconds of a
            # session, before the status line has seen an API response.
            log "no usage state published yet (session ${session_id})"
            return 0
            ;;
        *)  breakage "$session_id" "$state"
            return 0
            ;;
    esac

    five_pct="$(printf '%s' "$state" | jq -r '.five_hour.used_percentage // empty' 2>/dev/null)"
    week_pct="$(printf '%s' "$state" | jq -r '.seven_day.used_percentage // empty' 2>/dev/null)"

    warn_window "$session_id" "$scope" "five_hour" "5-hour" "$five_pct" \
        "$(printf '%s' "$state" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)" \
        "$(printf '%s' "$state" | jq -r '.five_hour.age_seconds // empty' 2>/dev/null)"
    warn_window "$session_id" "$scope" "seven_day" "7-day" "$week_pct" \
        "$(printf '%s' "$state" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)" \
        "$(printf '%s' "$state" | jq -r '.seven_day.age_seconds // empty' 2>/dev/null)"

    return 0
}

warn_window() {
    local session_id="$1" scope="$2" key="$3" label="$4" pct="$5" resets="$6" age="$7"
    local tier latch mins as_of headline

    [ -n "$pct" ] && [ -n "$resets" ] && [ -n "$age" ] || return 0
    if awk -v a="$pct" -v b="$USAGE_CRITICAL_PCT" 'BEGIN { exit !(a >= b) }'; then
        tier="critical"
    elif awk -v a="$pct" -v b="$USAGE_WARN_PCT" 'BEGIN { exit !(a >= b) }'; then
        tier="warn"
    else
        return 0
    fi

    # Latched per session, per agent, per window, per tier, per reset time.
    # Without this the hook would inject on every single tool call and flood the
    # context. Because the key includes resets_at, a new window re-arms it.
    mkdir -p "$WARNED_DIR" 2>/dev/null || return 0
    latch="${WARNED_DIR}/${session_id}__${scope}__${key}__${tier}__${resets}"
    [ -e "$latch" ] && return 0
    : > "$latch" 2>/dev/null || return 0
    # Reaching critical first makes the ordinary warning redundant.
    [ "$tier" = "critical" ] && : > "${WARNED_DIR}/${session_id}__${scope}__${key}__warn__${resets}" 2>/dev/null

    mins=$(( (resets - $(date '+%s')) / 60 ))
    [ "$mins" -lt 0 ] && mins=0

    # Readings go unrefreshed while the main thread waits on a subagent. Usage
    # only rises within a window, so an old reading understates the truth.
    as_of=""
    [ "$age" -ge 60 ] && as_of="$(printf ' (as of %d minutes ago - it may be higher now)' $(( age / 60 )))"

    headline="USAGE LIMIT WARNING"
    [ "$tier" = "critical" ] && headline="FINAL USAGE LIMIT WARNING"

    # Worded as an instruction, not advice: agents read "consider wrapping up"
    # as optional background and carried on without telling anyone.
    if [ "$scope" = "main" ]; then
        emit "$(printf '%s - act on this before your next step. Claude Code account usage is at %.0f%%%s of the %s limit, which resets in %d minutes. At 100%% this session is force-stopped mid-task and everything not written to disk is lost. Do this now: (1) write a progress note somewhere durable (the plan or spec you are working from, or PROGRESS.md in the working directory) covering what is done, what is in flight, and the next concrete step, so a fresh session can resume; (2) in your next message, tell the user the usage figure and where the note is. Then you may continue working.' \
            "$headline" "$pct" "$as_of" "$label" "$mins")"
    else
        emit "$(printf '%s - act on this before your next step. Claude Code account usage is at %.0f%%%s of the %s limit, which resets in %d minutes. At 100%% every session is force-stopped mid-task. You are a subagent: bring your current step to a safe stopping point quickly and end your final report with the usage figure, what is done, what remains, and the next concrete step, so your parent can record it.' \
            "$headline" "$pct" "$as_of" "$label" "$mins")"
    fi

    log "warned session ${session_id} (${scope}, ${tier}) at ${pct}% of ${label} window"
}

breakage() {
    local session_id="$1" reason="$2" latch age

    # Logged under the same latch as the agent notice. Logging on every tool
    # call wrote thousands of identical lines per broken episode.
    mkdir -p "$WARNED_DIR" 2>/dev/null || { log "broken: ${reason}"; return 0; }
    latch="${WARNED_DIR}/${session_id}__broken"
    if [ -e "$latch" ]; then
        age=$(( $(date '+%s') - $(file_mtime "$latch") ))
        [ "$age" -lt "$BREAKAGE_QUIET_SECONDS" ] && return 0
    fi
    log "broken (session ${session_id}): ${reason}"
    : > "$latch" 2>/dev/null || return 0

    emit "The Claude Code usage monitor is not working: ${reason} - so you will NOT be warned before hitting the account usage limit. Mention this to the user."
}

main
exit 0
