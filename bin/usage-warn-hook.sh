#!/usr/bin/env bash
#
# usage-warn-hook.sh - Claude Code PreToolUse hook.
#
# Warns the agent once per window when account usage crosses the threshold, so
# it can wrap up and write down its progress before being force-stopped.
#
# THIS SCRIPT ALWAYS EXITS 0. A PreToolUse hook that exits non-zero blocks the
# tool call; a monitor that can halt every session at once is worse than no
# monitor. Errors are reported loudly through additionalContext and the log,
# never by blocking.

set -u

: "${CLAUDE_CONFIG_DIR:=${HOME}/.claude}"
: "${USAGE_WARN_PCT:=90}"

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
    local input session_id state rc five_pct week_pct

    input="$(cat)"

    command -v jq >/dev/null 2>&1 || { log "jq is not installed"; return 0; }

    session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
    case "$session_id" in
        ""|*[!A-Za-z0-9._-]*) log "hook input carried no usable session_id"; return 0 ;;
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

    warn_window "$session_id" "five_hour" "5-hour" "$five_pct" \
        "$(printf '%s' "$state" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)"
    warn_window "$session_id" "seven_day" "7-day" "$week_pct" \
        "$(printf '%s' "$state" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)"

    return 0
}

warn_window() {
    local session_id="$1" key="$2" label="$3" pct="$4" resets="$5"
    local latch mins

    [ -n "$pct" ] && [ -n "$resets" ] || return 0
    awk -v a="$pct" -v b="$USAGE_WARN_PCT" 'BEGIN { exit !(a >= b) }' || return 0

    # Latched per session, per window, per reset time. Without this the hook
    # would inject on every single tool call and flood the context. Because the
    # key includes resets_at, a new window re-arms the warning by itself.
    mkdir -p "$WARNED_DIR" 2>/dev/null || return 0
    latch="${WARNED_DIR}/${session_id}__${key}__${resets}"
    [ -e "$latch" ] && return 0
    : > "$latch" 2>/dev/null || return 0

    mins=$(( (resets - $(date '+%s')) / 60 ))
    [ "$mins" -lt 0 ] && mins=0

    emit "$(printf 'Claude Code usage is at %.0f%% of the %s limit, which resets in %d minutes. Sessions that hit the limit are force-stopped and lose unsaved progress. Consider wrapping up soon: record what is done, what is in flight, and the next concrete step somewhere durable, so a fresh session can pick this up.' \
        "$pct" "$label" "$mins")"

    log "warned session ${session_id} at ${pct}% of ${label} window"
}

breakage() {
    local session_id="$1" reason="$2" latch age

    log "broken: ${reason}"

    mkdir -p "$WARNED_DIR" 2>/dev/null || return 0
    latch="${WARNED_DIR}/${session_id}__broken"
    if [ -e "$latch" ]; then
        age=$(( $(date '+%s') - $(file_mtime "$latch") ))
        [ "$age" -lt "$BREAKAGE_QUIET_SECONDS" ] && return 0
    fi
    : > "$latch" 2>/dev/null || return 0

    emit "The Claude Code usage monitor is not working: ${reason} - so you will NOT be warned before hitting the account usage limit. Mention this to the user."
}

main
exit 0
