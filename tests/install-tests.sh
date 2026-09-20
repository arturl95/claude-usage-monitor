#!/usr/bin/env bash
#
# Tests for install.sh / uninstall.sh. Every test runs against a throwaway
# CLAUDE_CONFIG_DIR - nothing touches the real Claude configuration.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
t(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
     else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$3" "$2"; fi; }

echo; echo "install.sh / uninstall.sh"

T=$(mktemp -d); CLAUDE_CONFIG_DIR=$T "$REPO/install.sh" >/dev/null 2>&1
t "creates settings.json"         "$(jq -r '.statusLine.command' "$T/settings.json" | grep -c usage-statusline)" "1"
t "adds PreToolUse hook"          "$(jq -r '[.hooks.PreToolUse[].hooks[].command]|length' "$T/settings.json")" "1"
t "adds permission"               "$(jq -r '.permissions.allow|index("Bash(claude-usage:*)")' "$T/settings.json")" "0"
t "installs 3 scripts"            "$(ls "$T/scripts" | wc -l | tr -d ' ')" "3"
t "installs skill"                "$(test -f "$T/skills/usage-broadcast/SKILL.md" && echo yes)" "yes"
t "scripts are executable"        "$(test -x "$T/scripts/claude-usage" && echo yes)" "yes"

CLAUDE_CONFIG_DIR=$T "$REPO/install.sh" >/dev/null 2>&1
t "re-install: no duplicate hook"  "$(jq -r '[.hooks.PreToolUse[].hooks[].command]|length' "$T/settings.json")" "1"
t "re-install: no dup permission"  "$(jq -r '[.permissions.allow[]|select(.=="Bash(claude-usage:*)")]|length' "$T/settings.json")" "1"

CLAUDE_CONFIG_DIR=$T "$REPO/uninstall.sh" >/dev/null 2>&1
t "uninstall: statusLine gone"    "$(jq -r '.statusLine // "gone"' "$T/settings.json")" "gone"
t "uninstall: hooks gone"         "$(jq -r '.hooks // "gone"' "$T/settings.json")" "gone"
t "uninstall: permission gone"    "$(jq -r '[.permissions.allow[]?|select(.=="Bash(claude-usage:*)")]|length' "$T/settings.json")" "0"
t "uninstall: scripts gone"       "$(ls "$T/scripts" 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -rf "$T"

T=$(mktemp -d)
echo '{"statusLine":{"type":"command","command":"/my/own/line.sh"}}' > "$T/settings.json"
out=$(CLAUDE_CONFIG_DIR=$T "$REPO/install.sh" 2>&1); rc=$?
t "foreign statusLine: exits 1"          "$rc" "1"
t "foreign statusLine: not replaced"     "$(jq -r '.statusLine.command' "$T/settings.json")" "/my/own/line.sh"
t "foreign statusLine: installs nothing" "$(ls "$T/scripts" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "foreign statusLine: shows merge help" "$(echo "$out" | grep -c 'Merge by hand')" "1"
CLAUDE_CONFIG_DIR=$T "$REPO/install.sh" --replace-statusline >/dev/null 2>&1
t "--replace-statusline: takes over"     "$(jq -r '.statusLine.command' "$T/settings.json" | grep -c usage-statusline)" "1"
rm -rf "$T"

T=$(mktemp -d)
cat > "$T/settings.json" <<'J'
{"model":"opus","permissions":{"allow":["WebFetch"],"deny":["Bash(rm:*)"]},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/other/hook.sh"}]}],
          "Stop":[{"matcher":"*","hooks":[{"type":"command","command":"/stop.sh"}]}]},
 "enabledPlugins":{"x":true}}
J
CLAUDE_CONFIG_DIR=$T "$REPO/install.sh" >/dev/null 2>&1
t "preserves model"               "$(jq -r '.model' "$T/settings.json")" "opus"
t "preserves enabledPlugins"      "$(jq -r '.enabledPlugins.x' "$T/settings.json")" "true"
t "preserves deny list"           "$(jq -r '.permissions.deny[0]' "$T/settings.json")" "Bash(rm:*)"
t "preserves existing allow"      "$(jq -r '.permissions.allow[0]' "$T/settings.json")" "WebFetch"
t "keeps foreign PreToolUse hook" "$(jq -r '[.hooks.PreToolUse[].hooks[].command]|map(select(.=="/other/hook.sh"))|length' "$T/settings.json")" "1"
t "keeps Stop hook"               "$(jq -r '.hooks.Stop[0].hooks[0].command' "$T/settings.json")" "/stop.sh"
t "creates a backup"              "$(ls "$T"/settings.json.bak.* 2>/dev/null | wc -l | tr -d ' ')" "1"
CLAUDE_CONFIG_DIR=$T "$REPO/uninstall.sh" >/dev/null 2>&1
t "uninstall keeps foreign hook"  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$T/settings.json")" "/other/hook.sh"
t "uninstall keeps Stop hook"     "$(jq -r '.hooks.Stop[0].hooks[0].command' "$T/settings.json")" "/stop.sh"
t "uninstall keeps allow list"    "$(jq -r '.permissions.allow[0]' "$T/settings.json")" "WebFetch"
rm -rf "$T"

T=$(mktemp -d); echo 'not json' > "$T/settings.json"
CLAUDE_CONFIG_DIR=$T "$REPO/install.sh" >/dev/null 2>&1
t "invalid settings.json: refuses" "$?" "1"
rm -rf "$T"

echo; printf 'passed %d, failed %d\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
