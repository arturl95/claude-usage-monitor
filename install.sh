#!/usr/bin/env bash
#
# install.sh - install claude-usage-monitor into your Claude Code config.
#
# Copies the scripts and the broadcast skill into place and patches
# settings.json. It will NOT replace an existing statusLine unless you pass
# --replace-statusline; your status line is yours.

set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CLAUDE_CONFIG_DIR:=${HOME}/.claude}"

SCRIPTS_DIR="${CLAUDE_CONFIG_DIR}/scripts"
SKILLS_DIR="${CLAUDE_CONFIG_DIR}/skills"
SETTINGS="${CLAUDE_CONFIG_DIR}/settings.json"

STATUSLINE_CMD="${SCRIPTS_DIR}/usage-statusline.sh"
HOOK_CMD="${SCRIPTS_DIR}/usage-warn-hook.sh"
PERMISSION="Bash(claude-usage:*)"

replace_statusline=0
[ "${1:-}" = "--replace-statusline" ] && replace_statusline=1

die() { printf 'install: %s\n' "$1" >&2; exit 1; }
say() { printf '  %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || die "jq is required. Install it first (brew install jq)."

printf '\nInstalling claude-usage-monitor into %s\n\n' "$CLAUDE_CONFIG_DIR"

mkdir -p "$SCRIPTS_DIR" "$SKILLS_DIR"
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"

jq -e . "$SETTINGS" >/dev/null 2>&1 || die "${SETTINGS} is not valid JSON. Fix it before installing."

# --- refuse to clobber an existing, foreign status line -----------------------
existing_statusline="$(jq -r '.statusLine.command // empty' "$SETTINGS")"
if [ -n "$existing_statusline" ] \
   && [ "$existing_statusline" != "$STATUSLINE_CMD" ] \
   && [ "$replace_statusline" -eq 0 ]; then
    cat >&2 <<MSG

You already have a status line configured:

    $existing_statusline

This tool needs the statusLine slot, because that is the only place Claude Code
exposes rate_limits. Two ways forward:

  1. Merge by hand. Have your script call ours and append its output:

       "$STATUSLINE_CMD" <<< "\$input"

     (ours reads the statusLine JSON on stdin and prints "5h:62% 7d:41%")

  2. Let us take the slot:

       ./install.sh --replace-statusline

Nothing has been changed.
MSG
    exit 1
fi

# --- copy files --------------------------------------------------------------
for f in claude-usage usage-statusline.sh usage-warn-hook.sh; do
    cp "${REPO_DIR}/bin/${f}" "${SCRIPTS_DIR}/${f}"
    chmod +x "${SCRIPTS_DIR}/${f}"
    say "installed ${SCRIPTS_DIR}/${f}"
done

rm -rf "${SKILLS_DIR}/usage-broadcast"
cp -R "${REPO_DIR}/skills/usage-broadcast" "${SKILLS_DIR}/usage-broadcast"
say "installed ${SKILLS_DIR}/usage-broadcast"

# --- back up settings --------------------------------------------------------
BACKUP="${SETTINGS}.bak.$(date '+%Y%m%d%H%M%S')"
cp "$SETTINGS" "$BACKUP"
say "backed up settings to ${BACKUP}"

# --- patch settings ----------------------------------------------------------
hook_present=0
jq -e --arg hk "$HOOK_CMD" \
   '[.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | .command] | index($hk) != null' \
   "$SETTINGS" >/dev/null 2>&1 && hook_present=1

tmp="$(mktemp)"
jq --arg sl "$STATUSLINE_CMD" \
   --arg hk "$HOOK_CMD" \
   --arg perm "$PERMISSION" \
   --argjson add_hook "$(( hook_present == 0 ? 1 : 0 ))" '
    .statusLine = { type: "command", command: $sl }
  | .hooks = (.hooks // {})
  | .hooks.PreToolUse = ((.hooks.PreToolUse // [])
      + (if $add_hook == 1
         then [{ matcher: "*", hooks: [{ type: "command", command: $hk }] }]
         else [] end))
  | .permissions = (.permissions // {})
  | .permissions.allow = ((.permissions.allow // [])
      | if index($perm) then . else . + [$perm] end)
' "$SETTINGS" > "$tmp"

jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "produced invalid settings.json; original left untouched"; }
mv "$tmp" "$SETTINGS"

say "set statusLine"
[ "$hook_present" -eq 1 ] && say "PreToolUse hook already present, left as is" || say "added PreToolUse hook"
say "allowed ${PERMISSION}"

cat <<MSG

Done.

  Check usage:      ${SCRIPTS_DIR}/claude-usage
  Broadcast a wrap-up to all sessions:  /usage-broadcast

Restart your Claude Code sessions so they pick up the new settings. The status
line will show "usage:n/a" until the first API response of each session, which
is when Claude Code starts reporting rate_limits.

Configure with environment variables (defaults shown):
  USAGE_WARN_PCT=90          warn at this percentage
  USAGE_FRESH_SECONDS=300    ignore state older than this

MSG
