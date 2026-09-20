#!/usr/bin/env bash
#
# usage-statusline.sh - Claude Code statusLine command.
#
# Claude Code pipes a JSON object to the statusLine command on stdin. That
# object is the ONLY place rate_limits is exposed - hooks do not receive it and
# there is no CLI for it - so this script does double duty: it renders the
# status line AND publishes the usage numbers where other tools can read them.
#
# Publishes to $CLAUDE_CONFIG_DIR/usage-state/<session_id>.json.
# One file per session, so writers never contend and no lock is needed
# (macOS has no flock).
#
# This script must never fail in a way that breaks the status line. Every error
# path prints a visible "usage-monitor: <reason>" marker and exits 0.

set -u

: "${CLAUDE_CONFIG_DIR:=${HOME}/.claude}"
: "${USAGE_WARN_PCT:=90}"

STATE_DIR="${CLAUDE_CONFIG_DIR}/usage-state"
PRUNE_MARKER="${STATE_DIR}/.last-prune"
PRUNE_INTERVAL=3600

bail() {
    # Visible in the status line itself - the loudest channel available here.
    printf 'usage-monitor: %s' "$1"
    exit 0
}

input="$(cat)"

command -v jq >/dev/null 2>&1 || bail "jq not installed"

now="$(date '+%s')"

read -r -d '' RENDER_FILTER <<'FILTER' || true
def render($label; $w):
    if $w == null or ($w.used_percentage | type) != "number" then empty
    else ($w.used_percentage) as $p
       | (if $p >= $warn then "\u001b[1;31m" else "" end) as $on
       | (if $p >= $warn then "\u001b[0m"    else "" end) as $off
       | "\($on)\($label):\($p | round)%\($off)"
    end;

. as $in
| (.rate_limits.five_hour) as $five
| (.rate_limits.seven_day) as $week
| ([render("5h"; $five), render("7d"; $week)] | join(" ")) as $display
| (if ($display | length) == 0 then "usage:n/a" else $display end) as $display
| (if ($five == null and $week == null) then ""
   else ({ session_id: ($in.session_id // null)
         , written_at: $now
         , five_hour: $five
         , seven_day: $week
         } | tojson)
   end) as $state
| [$display, $state] | join("\n")
FILTER

rendered="$(printf '%s' "$input" \
    | jq -r --argjson now "$now" --argjson warn "$USAGE_WARN_PCT" "$RENDER_FILTER" 2>/dev/null)" \
    || bail "unparseable statusline input"

display="$(printf '%s' "$rendered" | sed -n '1p')"
state="$(printf '%s' "$rendered" | sed -n '2p')"

# Render first: whatever happens to publishing, the status line still works.
printf '%s' "$display"

# No rate_limits in this payload (API-key user, or before the first API
# response). Publish nothing rather than publishing zeros, and leave any
# existing state untouched.
[ -n "$state" ] || exit 0

session_id="$(printf '%s' "$state" | jq -r '.session_id // empty' 2>/dev/null)"
case "$session_id" in
    ""|*[!A-Za-z0-9._-]*)
        # Cannot key the state file safely. Log rather than write somewhere wrong.
        mkdir -p "$STATE_DIR" 2>/dev/null \
            && printf '%s usage-statusline: unusable session_id %s\n' \
                 "$(date '+%Y-%m-%dT%H:%M:%S')" "${session_id:-<missing>}" \
                 >> "${STATE_DIR}/monitor.log" 2>/dev/null
        exit 0
        ;;
esac

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Atomic publish: the temp name starts with a dot and lacks .json, so a reader
# globbing *.json can never see a partially-written file.
tmp="$(mktemp "${STATE_DIR}/.tmp.XXXXXX" 2>/dev/null)" || exit 0
printf '%s\n' "$state" > "$tmp" 2>/dev/null && mv -f "$tmp" "${STATE_DIR}/${session_id}.json" 2>/dev/null
rm -f "$tmp" 2>/dev/null

# Housekeeping, at most hourly - this runs on every status line render.
prune_due=1
if [ -f "$PRUNE_MARKER" ]; then
    marker_age=$(( now - $(date '+%s' -r "$PRUNE_MARKER" 2>/dev/null || stat -f %m "$PRUNE_MARKER" 2>/dev/null || echo 0) ))
    [ "$marker_age" -lt "$PRUNE_INTERVAL" ] && prune_due=0
fi

if [ "$prune_due" -eq 1 ]; then
    : > "$PRUNE_MARKER" 2>/dev/null
    (
        live="$(jq -r '.sessionId // empty' "${CLAUDE_CONFIG_DIR}"/sessions/*.json 2>/dev/null)"
        if [ -n "$live" ]; then
            for f in "${STATE_DIR}"/*.json; do
                [ -e "$f" ] || continue
                sid="$(basename "$f" .json)"
                printf '%s\n' "$live" | grep -qxF "$sid" || rm -f "$f"
            done
        fi
        find "${STATE_DIR}/warned" -type f -mtime +8 -delete 2>/dev/null
        find "${STATE_DIR}" -maxdepth 1 -name '.tmp.*' -mmin +60 -delete 2>/dev/null
    ) >/dev/null 2>&1 &
fi

exit 0
