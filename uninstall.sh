#!/usr/bin/env bash
#
# uninstall.sh - remove claude-usage-monitor.
#
# Only removes what this tool installed. A statusLine that is not ours is left
# alone, and other PreToolUse hooks are preserved.

set -eu

: "${CLAUDE_CONFIG_DIR:=${HOME}/.claude}"

SCRIPTS_DIR="${CLAUDE_CONFIG_DIR}/scripts"
SKILLS_DIR="${CLAUDE_CONFIG_DIR}/skills"
SETTINGS="${CLAUDE_CONFIG_DIR}/settings.json"
STATE_DIR="${CLAUDE_CONFIG_DIR}/usage-state"

STATUSLINE_CMD="${SCRIPTS_DIR}/usage-statusline.sh"
HOOK_CMD="${SCRIPTS_DIR}/usage-warn-hook.sh"
PERMISSION="Bash(claude-usage:*)"

die() { printf 'uninstall: %s\n' "$1" >&2; exit 1; }
say() { printf '  %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || die "jq is required."

printf '\nRemoving claude-usage-monitor from %s\n\n' "$CLAUDE_CONFIG_DIR"

if [ -f "$SETTINGS" ]; then
    jq -e . "$SETTINGS" >/dev/null 2>&1 || die "${SETTINGS} is not valid JSON."

    BACKUP="${SETTINGS}.bak.$(date '+%Y%m%d%H%M%S')"
    cp "$SETTINGS" "$BACKUP"
    say "backed up settings to ${BACKUP}"

    tmp="$(mktemp)"
    jq --arg sl "$STATUSLINE_CMD" --arg hk "$HOOK_CMD" --arg perm "$PERMISSION" '
        (if (.statusLine.command // "") == $sl then del(.statusLine) else . end)
      | (if .hooks.PreToolUse then
            .hooks.PreToolUse = (.hooks.PreToolUse
              | map(.hooks = ((.hooks // []) | map(select(.command != $hk))))
              | map(select((.hooks | length) > 0)))
         else . end)
      | (if (.hooks.PreToolUse // []) == [] then del(.hooks.PreToolUse) else . end)
      | (if (.hooks // {}) == {} then del(.hooks) else . end)
      | (if .permissions.allow then
            .permissions.allow = (.permissions.allow | map(select(. != $perm)))
         else . end)
    ' "$SETTINGS" > "$tmp"

    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "produced invalid settings.json; original left untouched"; }
    mv "$tmp" "$SETTINGS"
    say "cleaned settings.json"
fi

for f in claude-usage usage-statusline.sh usage-warn-hook.sh; do
    [ -e "${SCRIPTS_DIR}/${f}" ] && rm -f "${SCRIPTS_DIR}/${f}" && say "removed ${SCRIPTS_DIR}/${f}"
done
[ -d "${SKILLS_DIR}/usage-broadcast" ] && rm -rf "${SKILLS_DIR}/usage-broadcast" && say "removed usage-broadcast skill"

if [ -d "$STATE_DIR" ]; then
    printf '\n  Published state remains at %s\n  Remove it with: rm -rf %s\n' "$STATE_DIR" "$STATE_DIR"
fi

printf '\nDone. Restart your Claude Code sessions.\n\n'
