#!/bin/sh
#
# mtk style hook. Wired in hooks.json on SessionStart and UserPromptSubmit.
#
# Reads the chosen style from ~/.mtk/style (written by scripts/style.sh) and
# prints its rules to stdout. For these two events, Claude Code adds a hook's
# stdout to the session as context.
#
# Prints nothing when:
#   - no style is set, or it is "default"
#   - caveman mode is active (its flag file exists). Two sets of style rules
#     would disagree; caveman wins and mtk stays quiet.
#
# This is a REQUEST, not enforcement. A hook can add text; it cannot make the
# model follow it. It is re-sent on every prompt so the style does not drift
# away in long sessions.
#
# Always exits 0: a style hook must never block a prompt.

# heartbeat for /mtk:doctor: "this hook ran, from this plugin folder" (file time = when)
B="${MTK_HOME:-$HOME/.mtk}/beat"; [ -d "$B" ] || mkdir -p "$B" 2>/dev/null
printf '%s\n' "${0%/*}/.." > "$B/${0##*/}-${1:-}" 2>/dev/null || true

STYLE_FILE="${MTK_HOME:-$HOME/.mtk}/style"
CAVEMAN_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"

[ -f "$STYLE_FILE" ] || exit 0
[ -f "$CAVEMAN_FLAG" ] && exit 0

style=$(head -c 32 "$STYLE_FILE" | tr -d '[:space:]')

case "$style" in
  short)
    echo "mtk style: short. Put the answer in the first line. Write plain, simple English: short sentences, one idea per sentence, common words. No idioms, no metaphors, no fragments. Keep technical words exact (names, paths, errors). No preamble and no closing summary. No tables or headings unless asked. Keep prose to about five sentences; code and exact output do not count."
    ;;
  full)
    echo "mtk style: full. Write plain, simple English: short sentences, one idea per sentence, common words. No idioms, no metaphors. Keep technical words exact (names, paths, errors). Give the reason behind each choice. Name the alternatives you rejected and why. End with a line that starts 'Not checked:' and lists what you did not verify."
    ;;
  *)
    : # default, empty, or unknown: add nothing
    ;;
esac
exit 0
