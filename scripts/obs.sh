#!/usr/bin/env bash
#
# mtk obs — read, shrink, and switch off the observability log.
#
#   obs.sh status            is it on? how big? how many events?
#   obs.sh stats             answer the questions worth asking
#   obs.sh runs              one line per mtk run, with duration
#   obs.sh run <session-id>  everything that happened in one run
#   obs.sh prune [days]      delete events older than N days (default 30)
#   obs.sh clear             delete everything
#   obs.sh off               stop sending mtk events
#   obs.sh on                start sending again
#
# The log is only worth keeping if something reads it. That is what `stats` is
# for. If you are not reading it, `off` is the honest choice -- nothing else
# reads this file, not the agents and not Claude.
#
# The log comes from the observability server at
# https://github.com/disler/claude-code-hooks-multi-agent-observability
# which keeps its SQLite file at apps/server/events.db, relative to wherever the
# server was started.
#
# Env:
#   MTK_OBS_DB   full path to events.db. Set this if the search below misses it.

set -uo pipefail

# Look in a few ordinary places rather than hardcoding one person's layout.
find_db() {
  [ -n "${MTK_OBS_DB:-}" ] && { printf '%s' "$MTK_OBS_DB"; return; }
  for base in "$PWD" "$PWD/.." "$PWD/../.." "$PWD/../../.." \
              "$HOME" "$HOME/Documents" "$HOME/src" "$HOME/code" "$HOME/projects"; do
    for name in obs claude-code-hooks-multi-agent-observability; do
      c="$base/$name/apps/server/events.db"
      [ -f "$c" ] && { printf '%s' "$c"; return; }
    done
  done
  printf '%s' "${MTK_OBS_DB:-events.db}"      # give up; have_db will report it
}
DB="$(find_db)"
FLAG="$HOME/.mtk/obs-on"      # exists = ON. absent = OFF (the default).
CMD="${1:-status}"; shift || true

have_db() { [ -f "$DB" ] || { echo "obs.sh: no database at $DB" >&2; echo "obs.sh: set MTK_OBS_DB to point at it" >&2; return 1; }; }
q() { sqlite3 -column -header "$DB" "$1"; }

command -v sqlite3 >/dev/null 2>&1 || { echo "obs.sh: sqlite3 not installed" >&2; exit 1; }

case "$CMD" in

  status)
    if [ -f "$FLAG" ]; then echo "mtk events:  ON    (obs.sh off to stop)"
    else                    echo "mtk events:  OFF   (obs.sh on to start -- this is the default)"; fi
    if [ -f "$DB" ]; then
      sz=$(du -ch "$DB" "$DB-wal" 2>/dev/null | tail -1 | cut -f1)
      n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;" 2>/dev/null)
      old=$(sqlite3 "$DB" "SELECT datetime(MIN(timestamp)/1000,'unixepoch','localtime') FROM events;" 2>/dev/null)
      echo "database:    $DB"
      echo "size:        ${sz:-?}   events: ${n:-0}   oldest: ${old:-none}"
      # ~3.5 KB per event measured on real data; warn before it becomes a surprise
      if [ "${n:-0}" -gt 50000 ]; then echo "note:        large. consider: obs.sh prune 30"; fi
    else
      echo "database:    not found at $DB"
    fi
    echo
    echo "Claude Code hooks are separate. To stop those too:"
    echo "  <observability-repo>/install-into.sh --remove <project-dir>"
    ;;

  stats)
    have_db || exit 1
    echo "── runs ────────────────────────────────────────────────"
    q "SELECT session_id AS run,
              COUNT(*) AS events,
              (MAX(timestamp)-MIN(timestamp))/1000 AS seconds,
              datetime(MIN(timestamp)/1000,'unixepoch','localtime') AS started
       FROM events WHERE source_app='mtk'
       GROUP BY session_id ORDER BY MIN(timestamp) DESC LIMIT 15;"
    echo
    echo "── gates: what you were asked, and what you said ────────"
    q "SELECT json_extract(payload,'\$.gate') AS gate,
              hook_event_type AS kind,
              COALESCE(json_extract(payload,'\$.question'), json_extract(payload,'\$.answer')) AS text
       FROM events
       WHERE hook_event_type IN ('gate_ask','gate_answer')
       ORDER BY id DESC LIMIT 20;"
    echo
    echo "── verify results over time ────────────────────────────"
    q "SELECT datetime(timestamp/1000,'unixepoch','localtime') AS at,
              json_extract(payload,'\$.level') AS level,
              json_extract(payload,'\$.rules') AS rules
       FROM events WHERE hook_event_type='verify_done'
       ORDER BY id DESC LIMIT 15;"
    echo
    echo "── agents: how often, how long ─────────────────────────"
    q "SELECT json_extract(payload,'\$.agent') AS agent, COUNT(*) AS runs
       FROM events WHERE hook_event_type='agent_start'
       GROUP BY agent ORDER BY runs DESC;"
    echo
    echo "── tool use, all apps ──────────────────────────────────"
    q "SELECT json_extract(payload,'\$.tool_name') AS tool, COUNT(*) AS calls
       FROM events WHERE hook_event_type='PreToolUse'
       GROUP BY tool ORDER BY calls DESC LIMIT 10;"
    ;;

  runs)
    have_db || exit 1
    q "SELECT session_id AS run, COUNT(*) AS events,
              (MAX(timestamp)-MIN(timestamp))/1000 AS seconds,
              datetime(MIN(timestamp)/1000,'unixepoch','localtime') AS started
       FROM events WHERE source_app='mtk'
       GROUP BY session_id ORDER BY MIN(timestamp) DESC;"
    ;;

  run)
    have_db || exit 1
    ID="${1:-}"; [ -n "$ID" ] || { echo "obs.sh: usage: obs.sh run <session-id>" >&2; exit 1; }
    q "SELECT datetime(timestamp/1000,'unixepoch','localtime') AS at,
              hook_event_type AS event, payload
       FROM events WHERE session_id='$ID' ORDER BY id;"
    ;;

  prune)
    have_db || exit 1
    DAYS="${1:-30}"
    before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")
    sqlite3 "$DB" "DELETE FROM events WHERE timestamp < (strftime('%s','now','-$DAYS days') * 1000);"
    sqlite3 "$DB" "VACUUM;"                       # actually give the disk space back
    after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")
    echo "obs.sh: removed $((before-after)) events older than $DAYS days ($after left)"
    ;;

  clear)
    have_db || exit 1
    n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")
    printf "obs.sh: delete all %s events? [y/N] " "$n"; read -r ans
    case "$ans" in
      y|Y) sqlite3 "$DB" "DELETE FROM events;"; sqlite3 "$DB" "VACUUM;"; echo "obs.sh: cleared" ;;
      *)   echo "obs.sh: cancelled" ;;
    esac
    ;;

  off)
    rm -f "$FLAG"
    echo "obs.sh: OFF. Neither mtk's own events nor its hooks will record anything."
    ;;

  on)
    mkdir -p "$(dirname "$FLAG")" && touch "$FLAG"
    echo "obs.sh: ON. Needs the server running -- see README."
    ;;

  *)
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
