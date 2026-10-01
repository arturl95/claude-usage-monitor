#!/usr/bin/env bash
#
# Test suite for claude-usage-monitor.
# Every test runs against a throwaway CLAUDE_CONFIG_DIR - nothing touches the
# real Claude configuration.

set -u

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
PASS=0
FAIL=0

setup() {
    TMP="$(mktemp -d)"
    export CLAUDE_CONFIG_DIR="$TMP"
    export USAGE_WARN_PCT=90
    NOW="$(date '+%s')"
}

teardown() { rm -rf "$TMP"; }

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output containing '$3'" "$2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "output without '$3'" "$2" ;; *) ok "$1" ;; esac; }

# Write a state file. $1=session $2=age_secs $3=5h pct $4=5h resets $5=7d pct $6=7d resets
# Use "-" for a window to omit it.
state() {
    local sid="$1" age="$2" fp="$3" fr="$4" wp="$5" wr="$6" five week
    mkdir -p "$CLAUDE_CONFIG_DIR/usage-state"
    if [ "$fp" = "-" ]; then five=null; else five="{\"used_percentage\":$fp,\"resets_at\":$fr}"; fi
    if [ "$wp" = "-" ]; then week=null; else week="{\"used_percentage\":$wp,\"resets_at\":$wr}"; fi
    cat > "$CLAUDE_CONFIG_DIR/usage-state/${sid}.json" <<JSON
{"session_id":"$sid","written_at":$(( NOW - age )),"five_hour":$five,"seven_day":$week}
JSON
}

hook_input() { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash"}' "$1"; }
# Subagent tool calls carry the parent's session_id plus their own agent_id.
sub_input()  { printf '{"session_id":"%s","agent_id":"%s","agent_type":"general-purpose","hook_event_name":"PreToolUse","tool_name":"Bash"}' "$1" "$2"; }

echo
echo "claude-usage"

setup
out="$("$BIN/claude-usage" --json 2>&1)"; rc=$?
is "no state dir -> exit 6" "$rc" 6
has "no state dir -> explains why" "$out" "Is the status line installed?"
teardown

setup
mkdir -p "$CLAUDE_CONFIG_DIR/usage-state"
"$BIN/claude-usage" --json >/dev/null 2>&1; is "empty state dir -> exit 6" "$?" 6
teardown

setup
state s1 5 62.4 $((NOW+3600)) 41 $((NOW+400000))
out="$("$BIN/claude-usage" --json)"
is "fresh state -> five_hour pct"  "$(printf '%s' "$out" | jq -r '.five_hour.used_percentage')" "62.4"
is "fresh state -> seven_day pct"  "$(printf '%s' "$out" | jq -r '.seven_day.used_percentage')" "41"
is "fresh state -> source count"   "$(printf '%s' "$out" | jq -r '.sources')" "1"
teardown

setup
state s1 5  40 $((NOW+3600)) - 0
state s2 5  91 $((NOW+3600)) - 0
state s3 10 55 $((NOW+3600)) - 0
out="$("$BIN/claude-usage" --json)"
is "sessions disagree -> highest wins" "$(printf '%s' "$out" | jq -r '.five_hour.used_percentage')" "91"
is "sessions disagree -> counts all"   "$(printf '%s' "$out" | jq -r '.sources')" "3"
teardown

setup
# Window rolled over: s_old still reports the spent old window, s_new the fresh one.
state s_old 5 95 $((NOW+100))  - 0
state s_new 5 12 $((NOW+9999)) - 0
out="$("$BIN/claude-usage" --json)"
is "rollover -> newest window wins"      "$(printf '%s' "$out" | jq -r '.five_hour.used_percentage')" "12"
is "rollover -> newest resets_at kept"   "$(printf '%s' "$out" | jq -r '.five_hour.resets_at')" "$((NOW+9999))"
teardown

setup
state s1 5 62 $((NOW-60)) - 0   # window already reset
out="$("$BIN/claude-usage" --json 2>&1)"; rc=$?
is  "all windows reset -> exit 4" "$rc" 4
has "all windows reset -> says so" "$out" "stale"
teardown

setup
state s1 9999 62 $((NOW+3600)) - 0   # old reading, window still open
out="$("$BIN/claude-usage" --json 2>&1)"; rc=$?
is  "old reading, open window -> exit 0" "$rc" 0
is  "old reading, open window -> reports age" "$(printf '%s' "$out" | jq -r '.five_hour.age_seconds')" "9999"
teardown

setup
state good 5 62 $((NOW+3600)) - 0
printf '{"broken' > "$CLAUDE_CONFIG_DIR/usage-state/bad.json"
out="$("$BIN/claude-usage" --json 2>&1)"; rc=$?
is  "corrupt file -> exit 7"        "$rc" 7
has "corrupt file -> names the file" "$out" "bad.json"
teardown

setup
state s1 5 62 $((NOW+3600)) - 0
"$BIN/claude-usage" --check >/dev/null 2>&1; is "--check below threshold -> exit 0" "$?" 0
teardown

setup
state s1 5 91 $((NOW+3600)) - 0
"$BIN/claude-usage" --check >/dev/null 2>&1; is "--check at threshold -> exit 3" "$?" 3
teardown

setup
state s1 5 90 $((NOW+3600)) - 0
"$BIN/claude-usage" --check >/dev/null 2>&1; is "--check exactly at threshold -> exit 3" "$?" 3
teardown

setup
state s1 5 62 $((NOW+3600)) 41 $((NOW+400000))
out="$("$BIN/claude-usage")"
has "human output shows 5h" "$out" "5h:"
has "human output shows 7d" "$out" "7d:"
teardown

setup
"$BIN/claude-usage" --nonsense >/dev/null 2>&1; is "bad argument -> exit 2" "$?" 2
teardown

echo
echo "usage-statusline.sh"

setup
five="{\"used_percentage\":62.4,\"resets_at\":$((NOW+3600))}"
week="{\"used_percentage\":41,\"resets_at\":$((NOW+400000))}"
disp="$(printf '{"session_id":"sess-1","rate_limits":{"five_hour":%s,"seven_day":%s}}' "$five" "$week" \
    | "$BIN/usage-statusline.sh")"
has "renders 5h" "$disp" "5h:62%"
has "renders 7d" "$disp" "7d:41%"
is  "publishes state file" "$(ls "$CLAUDE_CONFIG_DIR/usage-state/" | grep -c 'sess-1.json')" "1"
is  "state carries pct" "$(jq -r '.five_hour.used_percentage' "$CLAUDE_CONFIG_DIR/usage-state/sess-1.json")" "62.4"
teardown

setup
disp="$(printf '{"session_id":"sess-1","rate_limits":{"five_hour":{"used_percentage":94,"resets_at":%d}}}' $((NOW+600)) \
    | "$BIN/usage-statusline.sh")"
has   "above threshold -> red ansi" "$disp" $'\033[1;31m'
is    "only five_hour -> seven_day null" "$(jq -r '.seven_day' "$CLAUDE_CONFIG_DIR/usage-state/sess-1.json")" "null"
teardown

setup
disp="$(printf '{"session_id":"sess-1","model":{"id":"x"}}' | "$BIN/usage-statusline.sh")"
is     "no rate_limits -> n/a marker" "$disp" "usage:n/a"
is     "no rate_limits -> writes nothing" "$(ls "$CLAUDE_CONFIG_DIR/usage-state/" 2>/dev/null | wc -l | tr -d ' ')" "0"
teardown

setup
state sess-1 5 62 $((NOW+3600)) - 0
before="$(cat "$CLAUDE_CONFIG_DIR/usage-state/sess-1.json")"
printf '{"session_id":"sess-1"}' | "$BIN/usage-statusline.sh" >/dev/null
is "no rate_limits -> leaves existing state untouched" "$(cat "$CLAUDE_CONFIG_DIR/usage-state/sess-1.json")" "$before"
teardown

setup
disp="$(printf 'not json at all' | "$BIN/usage-statusline.sh")"; rc=$?
has "malformed input -> visible marker" "$disp" "usage-monitor:"
is  "malformed input -> still exit 0" "$rc" 0
teardown

setup
printf '{"session_id":"../../etc/passwd","rate_limits":{"five_hour":{"used_percentage":50,"resets_at":%d}}}' $((NOW+60)) \
    | "$BIN/usage-statusline.sh" >/dev/null
is  "unsafe session_id -> writes no state" "$(ls "$CLAUDE_CONFIG_DIR/usage-state"/*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
has "unsafe session_id -> logged" "$(cat "$CLAUDE_CONFIG_DIR/usage-state/monitor.log" 2>/dev/null)" "unusable session_id"
teardown

echo
echo "usage-warn-hook.sh"

setup
state s1 5 91 $((NOW+3600)) - 0
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"; rc=$?
is  "above threshold -> exit 0" "$rc" 0
has "above threshold -> injects context" "$out" "additionalContext"
has "above threshold -> names the window" "$out" "5-hour"
has "above threshold -> advises recording progress" "$out" "next concrete step"
out2="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
is  "latched -> silent on second call" "$out2" ""
teardown

setup
state s1 5 91 $((NOW+3600)) - 0
hook_input sess-a | "$BIN/usage-warn-hook.sh" >/dev/null
rm -f "$CLAUDE_CONFIG_DIR/usage-state/s1.json"
state s1 5 12 $((NOW+99999)) - 0   # new window
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
is "new window below threshold -> silent" "$out" ""
rm -f "$CLAUDE_CONFIG_DIR/usage-state/s1.json"
state s1 5 93 $((NOW+99999)) - 0   # new window, now hot
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
has "new window above threshold -> re-arms" "$out" "additionalContext"
teardown

setup
state s1 5 91 $((NOW+3600)) - 0
out_a="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
out_b="$(hook_input sess-b | "$BIN/usage-warn-hook.sh")"
has "latch is per-session -> other session still warned" "$out_b" "additionalContext"
teardown

setup
state s1 5 91 $((NOW+3600)) - 0
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
has "main thread -> told to act now" "$out" "before your next step"
has "main thread -> told to tell the user" "$out" "tell the user"
teardown

setup
state s1 5 91 $((NOW+3600)) - 0
out_sub="$(sub_input sess-a agent1 | "$BIN/usage-warn-hook.sh")"
has "subagent -> warned" "$out_sub" "additionalContext"
has "subagent -> told to report to its parent" "$out_sub" "final report"
out_main="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
has "subagent warning does not consume the main thread's" "$out_main" "before your next step"
is  "subagent -> latched per agent" "$(sub_input sess-a agent1 | "$BIN/usage-warn-hook.sh")" ""
has "other subagent -> still warned" "$(sub_input sess-a agent2 | "$BIN/usage-warn-hook.sh")" "final report"
is  "main thread -> latched" "$(hook_input sess-a | "$BIN/usage-warn-hook.sh")" ""
teardown

setup
state s1 5 91 $((NOW+3600)) - 0
hook_input sess-a | "$BIN/usage-warn-hook.sh" >/dev/null
rm -f "$CLAUDE_CONFIG_DIR/usage-state/s1.json"
state s1 5 97 $((NOW+3600)) - 0   # same window, now critical
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
has "critical tier -> warns again in the same window" "$out" "FINAL"
is  "critical tier -> latched" "$(hook_input sess-a | "$BIN/usage-warn-hook.sh")" ""
teardown

setup
state s1 5 98 $((NOW+3600)) - 0
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
has "first reading already critical -> critical wording" "$out" "FINAL"
is  "first reading already critical -> one warning only" "$(hook_input sess-a | "$BIN/usage-warn-hook.sh")" ""
teardown

setup
state s1 5 91 $((NOW+3600)) - 0
out="$(sub_input sess-a 'bad/../id' | "$BIN/usage-warn-hook.sh")"; rc=$?
is  "unsafe agent_id -> exit 0" "$rc" 0
has "unsafe agent_id -> logged" "$(cat "$CLAUDE_CONFIG_DIR/usage-state/monitor.log" 2>/dev/null)" "unusable agent_id"
teardown

setup
state s1 5 62 $((NOW+3600)) - 0
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"; rc=$?
is "below threshold -> silent" "$out" ""
is "below threshold -> exit 0" "$rc" 0
teardown

setup
state s1 5 - 0 94 $((NOW+400000))
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
has "seven_day above threshold -> warns" "$out" "7-day"
teardown

setup
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"; rc=$?
is "no state yet -> silent" "$out" ""
is "no state yet -> exit 0" "$rc" 0
has "no state yet -> logged" "$(cat "$CLAUDE_CONFIG_DIR/usage-state/monitor.log" 2>/dev/null)" "no usage state published yet"
teardown

setup
state s1 5 91 $((NOW-60)) - 0
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"; rc=$?
has "stale state -> reports breakage" "$out" "usage monitor is not working"
is  "stale state -> exit 0" "$rc" 0
out2="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"
is  "breakage is latched" "$out2" ""
teardown

setup
state good 5 91 $((NOW+3600)) - 0
printf 'garbage' > "$CLAUDE_CONFIG_DIR/usage-state/bad.json"
out="$(hook_input sess-a | "$BIN/usage-warn-hook.sh")"; rc=$?
has "corrupt state -> reports breakage" "$out" "usage monitor is not working"
is  "corrupt state -> exit 0" "$rc" 0
teardown

setup
out="$(printf 'not json' | "$BIN/usage-warn-hook.sh")"; rc=$?
is "malformed hook input -> exit 0" "$rc" 0
is "malformed hook input -> silent" "$out" ""
teardown

echo
printf 'passed %d, failed %d\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
