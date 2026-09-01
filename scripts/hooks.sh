#!/usr/bin/env bash
#
# mtk hooks — show every hook that can run, and where it is defined.
#
#   hooks.sh            list everything
#   hooks.sh --mine     only hooks you wrote (settings files)
#   hooks.sh --plugins  only hooks that came with a plugin
#
# A hook is a command Claude Code runs by itself at a fixed moment. There is no
# on/off switch: a hook is on because an entry exists in a file, and off because
# the entry was deleted. This shows you every file that has one.

set -uo pipefail

MODE="${1:-all}"
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"

count() {   # count hook entries in a settings-shaped json file
  python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(0); sys.exit()
print(sum(len(b.get('hooks',[])) for ev in d.get('hooks',{}).values() for b in ev))
" "$1" 2>/dev/null || echo 0
}

show() {    # print each hook entry as: EVENT  command
  python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit()
for ev, blocks in d.get('hooks',{}).items():
    for b in blocks:
        for h in b.get('hooks',[]):
            cmd = h.get('command','')
            if len(cmd) > 88: cmd = cmd[:85] + '...'
            print(f'      {ev:20} {cmd}')
" "$1" 2>/dev/null
}

if [ "$MODE" != "--plugins" ]; then
  echo "── hooks you control (settings files) ──────────────────────────"
  for f in "$HOME/.claude/settings.json" "$PROJ/.claude/settings.json" "$PROJ/.claude/settings.local.json"; do
    label="$f"
    case "$f" in
      "$HOME/.claude/settings.json") scope="every project" ;;
      *settings.local.json)          scope="this project, not in git" ;;
      *)                             scope="this project" ;;
    esac
    if [ -f "$f" ]; then
      n=$(count "$f")
      printf "  %s\n    %s · %s entries\n" "$label" "$scope" "$n"
      [ "$n" -gt 0 ] && show "$f"
    else
      printf "  %s\n    %s · does not exist\n" "$label" "$scope"
    fi
  done
  echo
fi

if [ "$MODE" != "--mine" ]; then
  echo "── hooks that came with a plugin (you did not write these) ─────"
  found=0
  while IFS= read -r hj; do
    found=1
    n=$(count "$hj")
    short="${hj#"$HOME/.claude/plugins/cache/"}"
    printf "  %-56s %s entries\n" "${short%/hooks.json}" "$n"
  done < <(find "$HOME/.claude/plugins/cache" -name hooks.json -maxdepth 6 2>/dev/null | sort)
  [ "$found" -eq 0 ] && echo "  none"
  echo
fi

echo "── how to turn one off ─────────────────────────────────────────"
echo "  yours:   delete its entry from the settings file above"
echo "  plugin:  disable the plugin (/plugin), or edit its hooks.json"
echo
echo "  mtk's own event log is separate and has a real switch:"
echo "    $(cd "$(dirname "$0")" && pwd)/obs.sh off"
