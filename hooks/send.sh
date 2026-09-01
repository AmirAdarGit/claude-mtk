#!/usr/bin/env sh
#
# mtk hook sender — record one Claude Code lifecycle event.
#
#   send.sh <EventName>        reads the hook payload as JSON on stdin
#
# OFF BY DEFAULT. Nothing is recorded unless ~/.mtk/obs-on exists, which only
# `mtk/scripts/obs.sh on` creates. Installing mtk must never start recording
# anything on someone's machine without them asking.
#
# This never fails and never blocks. A hook that errors or hangs interrupts the
# session it is supposed to be quietly watching, so every path here exits 0.

EVENT="${1:-Unknown}"

# --- the switch: absent flag means off ---------------------------------------
[ -f "$HOME/.mtk/obs-on" ] || exit 0
[ "${MTK_OBS_OFF:-0}" = "1" ] && exit 0

URL="${MTK_OBS_URL:-http://localhost:4000/events}"
APP="${MTK_APP:-mtk}"

command -v curl    >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Claude Code sends the payload on stdin. Read it into a variable FIRST: the
# heredoc below becomes stdin for python, so sys.stdin there would return the
# script itself, and every event would record an empty payload while looking
# like it worked.
MTK_PAYLOAD=$(cat)
export MTK_PAYLOAD

# Keep only small, useful fields -- never the whole thing, which can carry file
# contents and long command text.
BODY=$(python3 - "$APP" "$EVENT" <<'PY' 2>/dev/null
import json, sys, os
app, event = sys.argv[1], sys.argv[2]
try:
    raw = os.environ.get("MTK_PAYLOAD", "")
    d = json.loads(raw) if raw.strip() else {}
except Exception:
    d = {}

keep = {}
for k in ("tool_name", "hook_event_name", "permission_mode", "agent_type", "agent_name"):
    if d.get(k):
        keep[k] = d[k]

# a short label only -- not the command body, not file contents
ti = d.get("tool_input") or {}
if isinstance(ti, dict):
    for k in ("description", "file_path", "subagent_type"):
        if ti.get(k):
            keep[k] = str(ti[k])[:120]

cwd = d.get("cwd") or os.getcwd()
keep["project"] = os.path.basename(cwd)

print(json.dumps({
    "source_app": app,
    "session_id": d.get("session_id") or os.environ.get("MTK_RUN") or "mtk",
    "hook_event_type": event,
    "payload": keep,
}))
PY
) || exit 0

[ -n "$BODY" ] || exit 0

curl -s -m 2 -o /dev/null -X POST "$URL" \
  -H 'Content-Type: application/json' \
  --data-binary "$BODY" 2>/dev/null

exit 0
