#!/usr/bin/env sh
#
# mtk verify-gate — a chore cannot finish until verify.sh has checked the
# files exactly as they are now.
#
#   verify-gate.sh base        PreToolUse (hooks.json): remember the files as they
#                              were when the chore started
#   verify-gate.sh stop        Stop (hooks.json): block if files changed since the
#                              start and verify.sh has not checked this exact state
#   verify-gate.sh mark DIR    called by scripts/verify.sh: "I checked this state"
#
# WHY THIS EXISTS
# The chore skill said "run verify.sh". On real work (Alta, PR #100) the agent
# ran its own smaller checks instead -- 61 tests out of 891, lint on 3 files --
# and reported "lint shows no errors", while verify.sh said "failures". A rule
# in markdown is a request. This hook makes it a condition of finishing.
#
# WHY GIT STATE, NOT TOOL NAMES
# The first version looked for Edit/Write calls in the transcript. Run against
# that same Alta session, it let it through: the agent had changed the files
# with a python script inside Bash. So the gate now compares what is on disk.
# A "state" is a hash of `git diff HEAD` plus the name, size and mtime of every
# untracked file. Any way of changing a file changes the state.
#
# WHAT IT DOES NOT CHECK
# - That the agent reports verify.sh's verdict honestly. That stays a request.
# - Outside a git repo, there is no state to compare, so it allows.
# - verify.sh --only <check> is a partial run and does not count as checked.
#
# SAFETY
# It blocks at most MTK_VERIFY_GATE_LIMIT times (default 3) for one state of the
# files, then lets the stop through, so a project where verify.sh cannot run
# never traps the session in a loop. Any error inside the hook means "allow": a broken gate must
# not break the session.

set -u

MODE="${1:-stop}"
ARG_DIR="${2:-}"
if [ "$MODE" = mark ]; then PAYLOAD='{}'; else PAYLOAD=$(cat); fi
export PAYLOAD MODE ARG_DIR

command -v python3 >/dev/null 2>&1 || exit 0

python3 <<'PY'
import hashlib, json, os, subprocess, sys

def allow():
    sys.exit(0)

mode = os.environ.get("MODE", "stop")
try:
    p = json.loads(os.environ.get("PAYLOAD") or "{}")
except Exception:
    allow()

STATE = os.path.join(os.path.expanduser("~"), ".mtk", "verify-gate")

def git(cwd, *args):
    r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, timeout=20)
    if r.returncode != 0:
        raise RuntimeError("git failed")
    return r.stdout

def repo_and_state(cwd):
    """(repo root, hash of the working tree) -- or (None, None) outside git."""
    try:
        root = git(cwd, "rev-parse", "--show-toplevel").decode().strip()
        h = hashlib.sha1()
        h.update(git(root, "diff", "HEAD", "--binary"))
        for name in sorted(git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")):
            if not name:
                continue
            h.update(name)
            try:
                st = os.stat(os.path.join(root, name.decode(errors="replace")))
                h.update(f"{st.st_size}:{st.st_mtime_ns}".encode())
            except OSError:
                pass
        return root, h.hexdigest()
    except Exception:
        return None, None

def key(*parts):
    return hashlib.sha1("|".join(parts).encode()).hexdigest()[:16]

def chore_start(path):
    """Position of the latest chore start in the transcript (0 if none)."""
    start, pos = 0, 0
    try:
        with open(path, "rb") as f:          # fast path: most sessions never run a chore
            if b"mtk:chore" not in f.read():
                return 0
    except Exception:
        return 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                c = (d.get("message") or {}).get("content")
                for it in (c if isinstance(c, list) else [c]):
                    pos += 1
                    text = it if isinstance(it, str) else (it.get("text") or "") if isinstance(it, dict) else ""
                    if "<command-name>/mtk:chore</command-name>" in text:
                        start = pos
                    if isinstance(it, dict) and it.get("type") == "tool_use" and it.get("name") == "Skill" \
                            and "chore" in str((it.get("input") or {}).get("skill", "")):
                        start = pos
    except Exception:
        pass
    return start

def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return ""

def write(path, text):
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
    except Exception:
        pass

if mode == "mark":
    root, state = repo_and_state(os.environ.get("ARG_DIR") or os.getcwd())
    if root:
        write(os.path.join(STATE, "verified-" + key(root)), state)
    allow()

cwd = p.get("cwd") or os.getcwd()
session = p.get("session_id") or "unknown"
start_pos = chore_start(p.get("transcript_path") or "")
if start_pos == 0:
    allow()                                # no chore in this session: the gate is not active
start = str(start_pos)
if mode == "base" and os.path.exists(os.path.join(STATE, "seen-" + key(session, start))):
    allow()                                # baseline for this chore already taken: skip git
root, state = repo_and_state(cwd)
if not root:
    allow()
base_file = os.path.join(STATE, "base-" + key(session, start, root))

if mode == "base":
    if not os.path.exists(base_file):      # only the FIRST tool call of a chore sets it
        write(base_file, state)
    write(os.path.join(STATE, "seen-" + key(session, start)), "1")
    allow()

# mode == "stop"
base = read(base_file)
if not base or state == base:
    allow()                                # nothing changed, or no baseline to compare
if read(os.path.join(STATE, "verified-" + key(root))) == state:
    allow()                                # verify.sh checked exactly this state

# The cap counts blocks for THIS state of the files. A new change gets a new count,
# so the gate cannot be worn out early and then stay open for the rest of the chore.
count_file = os.path.join(STATE, "blocks-" + key(session, start, root, state))
n = int(read(count_file) or 0)
limit = int(os.environ.get("MTK_VERIFY_GATE_LIMIT", "3") or 3)
if n >= limit:
    allow()
write(count_file, str(n + 1))

reason = (
    "mtk verify-gate: files changed during this chore, and verify.sh has not checked them as they are now. "
    "Run the full check from the project root -- not a smaller check of your own, and not --only: "
    "\"${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh\". "
    "Then report its verdict exactly as it prints it. If it reports failures you did not cause, say which. "
    f"(block {n + 1} of {limit})"
)
print(json.dumps({"decision": "block", "reason": reason}))
PY
exit 0
