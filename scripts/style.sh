#!/usr/bin/env bash
#
# mtk style — choose how Claude writes its answers.
#
#   style.sh                 show the current style
#   style.sh short           answer first, no preamble, no summary
#   style.sh full            reasons, rejected alternatives, a "Not checked:" line
#   style.sh default         add nothing (Claude's normal style)
#
# The choice is global: one file, ~/.mtk/style. hooks/style.sh reads it on
# every session start and every prompt, so a change applies from the next
# message. When caveman mode is on, mtk adds nothing.

set -uo pipefail

STYLE_FILE="${MTK_HOME:-$HOME/.mtk}/style"
CAVEMAN_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"

current() {
  if [ -f "$STYLE_FILE" ]; then head -c 32 "$STYLE_FILE" | tr -d '[:space:]'; else printf default; fi
}

caveman_note() {
  if [ -f "$CAVEMAN_FLAG" ]; then
    echo "note:  caveman mode is active, so mtk adds nothing until caveman is off."
  fi
}

ARG="${1:-}"
case "$ARG" in
  "")
    echo "style: $(current)"
    caveman_note
    ;;
  short|full)
    mkdir -p "$(dirname "$STYLE_FILE")" && printf '%s\n' "$ARG" > "$STYLE_FILE"
    echo "style: $ARG (from the next message)"
    caveman_note
    ;;
  default)
    rm -f "$STYLE_FILE"
    echo "style: default (mtk adds nothing)"
    ;;
  *)
    echo "style.sh: unknown style '$ARG'. Use: short | full | default" >&2
    exit 1
    ;;
esac
