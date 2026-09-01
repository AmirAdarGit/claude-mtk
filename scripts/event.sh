#!/usr/bin/env bash
#
# mtk event — send one event to the observability server.
#
#   event.sh <type> [key=value ...]
#
# Examples:
#   event.sh phase_start phase=PLAN
#   event.sh gate_ask gate=1 question="which policy is right?"
#   event.sh gate_answer gate=1 answer="gcal is right"
#   event.sh verify_done level=failures tests=276 errors=33
#
# Groups events into one run via $MTK_RUN. Set it once at the start of a
# pipeline run and every later event lands in the same session:
#
#   export MTK_RUN="calling-hours-$(date +%H%M%S)"
#
# THIS SCRIPT NEVER FAILS THE CALLER. If the server is down, unreachable, or
# slow, it gives up quietly and returns 0. Logging is not allowed to break the
# work it is logging.
#
# Env:
#   MTK_RUN     run/session id      (default: mtk-<date>)
#   MTK_APP     source app name     (default: mtk)
#   MTK_OBS_URL server endpoint     (default: http://localhost:4000/events)
#   MTK_OBS_OFF set to 1 to disable for a single command
#
# OFF BY DEFAULT: nothing is sent unless ~/.mtk/obs-on exists.
# Create it with `scripts/obs.sh on`, remove it with `scripts/obs.sh off`.

set -uo pipefail

# OFF BY DEFAULT. One switch: ~/.mtk/obs-on must exist, and only `obs.sh on`
# creates it. Installing mtk must never start recording without being asked.
[ -f "$HOME/.mtk/obs-on" ] || exit 0
[ "${MTK_OBS_OFF:-0}" = "1" ] && exit 0

TYPE="${1:-}"
[ -n "$TYPE" ] || { echo "event.sh: usage: event.sh <type> [key=value ...]" >&2; exit 0; }
shift

RUN="${MTK_RUN:-mtk-$(date +%Y%m%d-%H%M%S)}"
APP="${MTK_APP:-mtk}"
URL="${MTK_OBS_URL:-http://localhost:4000/events}"

command -v python3 >/dev/null 2>&1 || exit 0
command -v curl    >/dev/null 2>&1 || exit 0

# Build the JSON in python so values with spaces, quotes, or newlines are escaped
# properly. Doing this with printf produces invalid JSON the first time someone
# logs a gate question containing an apostrophe.
BODY=$(python3 - "$APP" "$RUN" "$TYPE" "$@" <<'PY'
import json, sys
app, run, etype, *rest = sys.argv[1:]
payload = {}
for item in rest:
    k, _, v = item.partition("=")
    if not _:
        payload.setdefault("args", []).append(item)
        continue
    if v.isdigit():
        v = int(v)
    payload[k] = v
print(json.dumps({
    "source_app": app,
    "session_id": run,
    "hook_event_type": etype,
    "payload": payload,
}))
PY
) || exit 0

curl -s -m 2 -o /dev/null -X POST "$URL" \
  -H 'Content-Type: application/json' \
  --data-binary "$BODY" 2>/dev/null

exit 0    # always. see the note at the top.
