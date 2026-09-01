#!/usr/bin/env sh
#
# mtk strikes — stop an agent that is repeating the same failure.
#
#   strikes.sh record    PostToolUse / PostToolUseFailure: remember what happened
#   strikes.sh check     PreToolUse: deny a command that has already failed 3x identically
#
# WHY THIS EXISTS
# development-pipeline says "three failed attempts at the same step = STOP". That
# rule lived in a markdown file and the agent counted its own failures, which is
# the same mistake as asking an agent to run its own checks: a counter that lives
# inside the thing it counts is a suggestion, not a limit. This moves it into
# code that Claude Code runs.
#
# WHY COMMAND + RESULT, NOT JUST COMMAND
# In TDD a failing test IS the goal -- the RED step. Blocking a command merely
# because it failed three times would break tdd-implementer on its own first
# step. What actually signals stuck is the same command producing the SAME
# result over and over: no progress. So the fingerprint is
# command + exit code + a normalised slice of the output. Once the output
# changes, the count starts over, because something moved.
#
# State: $HOME/.mtk/strikes/<session>.tsv   one line per fingerprint
# Never fails, never blocks longer than it must. Exits 0 on every path except a
# deliberate deny, which is printed as JSON.

set -u

MODE="${1:-check}"
LIMIT="${MTK_STRIKE_LIMIT:-3}"

PAYLOAD=$(cat)
export PAYLOAD MODE LIMIT

command -v python3 >/dev/null 2>&1 || exit 0

python3 <<'PY'
import json, os, hashlib, re, sys, time, glob

mode  = os.environ.get("MODE", "check")
limit = int(os.environ.get("LIMIT", "3") or 3)

try:
    d = json.loads(os.environ.get("PAYLOAD", "") or "{}")
except Exception:
    sys.exit(0)

cmd = (d.get("tool_input") or {}).get("command", "")
if not cmd.strip():
    sys.exit(0)

session = d.get("session_id") or "nosession"
home    = os.path.expanduser("~/.mtk/strikes")
store   = os.path.join(home, re.sub(r"[^A-Za-z0-9_.-]", "_", session) + ".tsv")

def norm(s):
    """Squash the parts of output that change every run but mean nothing:
    timings, dates, temp paths, hex ids. Without this, two identical failures
    look different and the counter never reaches the limit."""
    s = s[:4000]
    s = re.sub(r"\d+(\.\d+)?\s*(ms|s|sec|seconds|m)\b", "T", s)
    s = re.sub(r"\d{4}-\d{2}-\d{2}[T ][\d:.]+", "D", s)
    s = re.sub(r"/(tmp|var/folders)/\S+", "TMP", s)
    s = re.sub(r"\b[0-9a-f]{7,40}\b", "HEX", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip()

cmd_key = re.sub(r"\s+", " ", cmd.strip())

def fingerprint(exit_code, out):
    raw = f"{cmd_key}\x00{exit_code}\x00{norm(out)}"
    return hashlib.sha256(raw.encode("utf-8", "replace")).hexdigest()[:20]

def read():
    rows = {}
    try:
        with open(store) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    rows[parts[0]] = (int(parts[1]), parts[2])
    except FileNotFoundError:
        pass
    except Exception:
        pass
    return rows

# ---------------------------------------------------------------- record ----
if mode == "record":
    resp = d.get("tool_response") or {}
    exit_code = resp.get("exit_code")
    is_error  = bool(resp.get("is_error")) or (exit_code not in (0, None))
    if not is_error:
        # A success means progress. Forget every strike for this command, so a
        # command that failed twice then worked does not carry a grudge.
        rows = read()
        rows = {k: v for k, v in rows.items() if v[1] != cmd_key}
        try:
            os.makedirs(home, exist_ok=True)
            with open(store, "w") as fh:
                for k, (n, c) in rows.items():
                    fh.write(f"{k}\t{n}\t{c}\n")
        except Exception:
            pass
        sys.exit(0)

    out = (resp.get("stderr") or "") + (resp.get("stdout") or "")
    fp  = fingerprint(exit_code, out)
    rows = read()
    n = rows.get(fp, (0, cmd_key))[0] + 1
    rows[fp] = (n, cmd_key)
    try:
        os.makedirs(home, exist_ok=True)
        with open(store, "w") as fh:
            for k, (cnt, c) in rows.items():
                fh.write(f"{k}\t{cnt}\t{c}\n")
        # tidy: drop strike files older than a day
        for old in glob.glob(os.path.join(home, "*.tsv")):
            if time.time() - os.path.getmtime(old) > 86400:
                os.remove(old)
    except Exception:
        pass
    sys.exit(0)

# ----------------------------------------------------------------- check ----
rows = read()
worst = 0
for fp, (n, c) in rows.items():
    if c == cmd_key and n > worst:
        worst = n

if worst >= limit:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"stuck: this command has already failed {worst} times with the same result. "
                f"Trying again will produce the same failure. Stop, report what you tried, "
                f"what the error was, and hand it back. Command: {cmd_key[:140]}"
            ),
        }
    }))
sys.exit(0)
PY
