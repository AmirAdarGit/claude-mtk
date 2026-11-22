#!/usr/bin/env sh
#
# mtk memory — the project's plan survives sessions and compaction.
#
#   memory.sh start       SessionStart (startup, resume, clear, compact):
#                         print .mtk/now.md, the open steps of .mtk/plan.json and
#                         the last entries of .mtk/log.md, with STALE on top when
#                         they are older than the code
#   memory.sh precompact  PreCompact: tell the compaction summary to keep them
#   memory.sh stop        Stop: block once when commits are newer than now.md,
#                         block when a plan step was removed or renamed, and
#                         block once when the context window is MTK_HANDOFF_AT %
#                         full (default 70) -- each block asks for /mtk:handoff
#
# Without .mtk/now.md only the context check runs; /mtk:handoff creates the files.
#
# CONTEXT SIZE: read from the session transcript -- the token usage of the last
# main-thread answer (input + cache read + cache creation). The transcript does not
# name the window size, so: MTK_CONTEXT_WINDOW if set; else 1M for Opus models or
# when a session already went past 200k; else 200k. A guess, with an override.
#
# WHY THIS EXISTS
# On 2026-11-22 a new session got "continue" and did not know the plan. ctk's
# ledger was 3 months old, and its automatic handoff had empty next_steps --
# by design: only manual commands write goals there, and nothing checks age.
# Writing good memory cannot be forced. What can be forced is that the memory
# is always SHOWN, that staleness is SAID out loud, and that the session is
# stopped once when the code moved on and the memory did not. See specs/memory.md.
#
# ENFORCED: shown at every start and after every compaction; STALE detection;
#           one stop per new commit; one stop at 70% context; plan steps cannot be removed or renamed
#           (checked against git HEAD, so it does not matter how the file was edited).
# REQUESTED: that what is written in the files is good and true.
#
# Any error means "allow" and print nothing: a broken memory hook must not
# break the session.

set -u

MODE="${1:-start}"
PAYLOAD=$(cat)
export PAYLOAD MODE

command -v python3 >/dev/null 2>&1 || exit 0

python3 <<'PY'
import hashlib, json, os, subprocess, sys, time

def done():
    sys.exit(0)

mode = os.environ.get("MODE", "start")
try:
    p = json.loads(os.environ.get("PAYLOAD") or "{}")
except Exception:
    p = {}
cwd = p.get("cwd") or os.getcwd()

def git(*args, cwd=cwd):
    r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, timeout=10)
    return r.stdout.decode(errors="replace").strip() if r.returncode == 0 else None

root = git("rev-parse", "--show-toplevel") or cwd
NOW = os.path.join(root, ".mtk", "now.md")
PLAN = os.path.join(root, ".mtk", "plan.json")
LOG = os.path.join(root, ".mtk", "log.md")
has_memory = os.path.isfile(NOW)
if not has_memory and mode != "stop":
    done()

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return ""

def staleness():
    """(is_stale, commits_since). The memory is stale when code was committed after any .mtk/ file last changed."""
    head_time = git("log", "-1", "--format=%ct", cwd=root)
    if not head_time:
        return False, 0                                   # no commits yet
    # Any of the three files counts: a handoff may change only log.md or plan.json.
    rel = ".mtk/"
    dirty = git("status", "--porcelain", "--", rel, cwd=root)
    if dirty:                                             # edited, not committed yet
        newest = max((os.path.getmtime(f) for f in (NOW, PLAN, LOG) if os.path.isfile(f)), default=0)
        return newest < int(head_time), 0
    last = git("log", "-1", "--format=%H", "--", rel, cwd=root)
    if not last:
        return True, 0
    n = int(git("rev-list", "--count", f"{last}..HEAD", cwd=root) or 0)
    return n > 0, n

def plan_steps(text):
    try:
        steps = json.loads(text).get("steps", [])
        return [s for s in steps if isinstance(s, dict)]
    except Exception:
        return None

def age(path):
    try:
        mins = int((time.time() - os.path.getmtime(path)) / 60)
    except Exception:
        return "unknown"
    return f"{mins} min" if mins < 120 else f"{mins // 60} h" if mins < 2880 else f"{mins // 1440} days"

if mode == "start":
    stale, n = staleness()
    out = []
    if stale:
        since = f"{n} commit(s) were made since it last changed" if n else "code was committed after it last changed"
        out.append(f"** mtk memory is STALE: {since}. Check it against `git log` before trusting it, "
                   "and update it with /mtk:handoff. **\n")
    out.append(f"=== mtk memory: .mtk/now.md (changed {age(NOW)} ago) ===")
    out.append(read(NOW).strip()[:6000])
    steps = plan_steps(read(PLAN)) if os.path.isfile(PLAN) else None
    if steps is not None:
        open_steps = [s for s in steps if not s.get("done")]
        out.append(f"\n=== mtk plan: {len(steps) - len(open_steps)} of {len(steps)} steps done. Open: ===")
        for s in open_steps[:15]:
            out.append(f"- [{s.get('id', '?')}] {s.get('step', '')}")
        if len(open_steps) > 15:
            out.append(f"- ... and {len(open_steps) - 15} more in .mtk/plan.json")
    elif os.path.isfile(PLAN):
        out.append("\n** .mtk/plan.json is not valid JSON. Fix it. **")
    log = read(LOG)
    if log.strip():
        entries = ["## " + e for e in log.split("\n## ")[1:]]
        if entries:
            out.append(f"\n=== mtk log: last {min(5, len(entries))} of {len(entries)} episodes (.mtk/log.md) ===")
            out.append("\n".join(e.strip() for e in entries[-5:])[:3000])

    # Short banner for the USER (systemMessage is shown in the terminal);
    # the full memory goes to CLAUDE as additionalContext.
    def line(prefix):
        for l in read(NOW).splitlines():
            if l.startswith(prefix):
                return l[len(prefix):].strip()
        return ""
    banner = ["=== mtk memory ==="]
    if stale:
        banner.append("STALE: code changed after the memory. Run /mtk:handoff.")
    if line("Goal:"):
        banner.append("Goal: " + line("Goal:")[:200])
    if line("Next:"):
        banner.append("Next: " + line("Next:")[:200])
    if steps is not None:
        banner.append(f"Plan: {len(steps) - len(open_steps)} of {len(steps)} steps done (.mtk/plan.json)")
    banner.append("Claude already has this memory. Write \"continue\" to start the next step.")
    print(json.dumps({
        "systemMessage": "\n".join(banner),
        "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "\n".join(out)},
    }))
    done()

if mode == "precompact":
    print("mtk memory: this project keeps its plan in .mtk/now.md, .mtk/plan.json and .mtk/log.md. "
          "In the summary, keep: the Goal, the open plan steps by id, the one Next step, "
          "and every feature, fix and decision of this session that is not yet written in .mtk/log.md, "
          "so /mtk:handoff can still record them. The files are shown again automatically after compaction.")
    done()

if mode != "stop":
    done()

STATE = os.path.join(os.path.expanduser("~"), ".mtk", "memory")
session = p.get("session_id") or "unknown"

def once(tag, limit):
    """True if this block may fire: counts blocks per tag, up to limit."""
    try:
        os.makedirs(STATE, exist_ok=True)
        f = os.path.join(STATE, hashlib.sha1(f"{session}|{tag}".encode()).hexdigest()[:16])
        n = int(read(f).strip() or 0)
        if n >= limit:
            return False
        with open(f, "w") as fh:
            fh.write(str(n + 1))
        return True
    except Exception:
        return False

reasons = []

def context_pct(path):
    """Percent of the context window used by the last main-thread answer, or None."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 3_000_000))
            lines = f.read().decode(errors="replace").splitlines()
    except Exception:
        return None
    for line in reversed(lines):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") != "assistant" or d.get("isSidechain"):
            continue
        msg = d.get("message") or {}
        u = msg.get("usage") or {}
        used = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
        if used:
            window = int(os.environ.get("MTK_CONTEXT_WINDOW") or 0)
            if not window:
                # The transcript names the model, not the window. Observed on this setup:
                # Opus showed 79.6k tokens as 8% -> a 1M window. Anything past 200k is 1M too.
                model = str(msg.get("model") or "")
                window = 1_000_000 if ("opus" in model or "[1m]" in model or used > 200_000) else 200_000
            return round(100 * used / window)
    return None

# 0. Context window nearly full: hand off once per session.
pct = context_pct(p.get("transcript_path") or "")
limit_pct = int(os.environ.get("MTK_HANDOFF_AT") or 70)
if pct is not None and pct >= limit_pct and once("context", 1):
    reasons.append(f"the context window is about {pct}% full. Run /mtk:handoff now to save the memory "
                   "(goal, next step, plan, and a log entry for this episode), and then tell the user to run /clear. "
                   "The next session shows the memory automatically. (This stop happens once per session.)")

# 1. Plan steps may be marked done, never removed or renamed. Compared with git HEAD.
if has_memory and os.path.isfile(PLAN):
    now_steps = plan_steps(read(PLAN))
    head_text = git("show", "HEAD:.mtk/plan.json", cwd=root)
    head_steps = plan_steps(head_text) if head_text else None
    if now_steps is None:
        if once("badjson|" + hashlib.sha1(read(PLAN).encode()).hexdigest(), 3):
            reasons.append(".mtk/plan.json is not valid JSON. Fix it.")
    elif head_steps:
        current = {str(s.get("id")): s.get("step") for s in now_steps}
        broken = [s for s in head_steps
                  if str(s.get("id")) not in current or current[str(s.get("id"))] != s.get("step")]
        if broken and once("plan|" + hashlib.sha1(read(PLAN).encode()).hexdigest(), 3):
            ids = ", ".join(str(s.get("id")) for s in broken)
            reasons.append(f".mtk/plan.json removed or renamed step(s) {ids} compared with git HEAD. "
                           "Steps may only be marked done. Put them back as they were; "
                           "add a new step at the end if the plan changed.")

# 2. Code moved on, memory did not: stop once per new HEAD.
stale, n = staleness() if has_memory else (False, 0)
if stale and once("stale|" + (git("rev-parse", "HEAD", cwd=root) or ""), 1):
    reasons.append("commits were made after the .mtk/ memory last changed. Run /mtk:handoff to record them: "
                   "mark finished plan steps done, add a log entry, and write the one Next step. "
                   "(This stop happens once per new commit.)")

if reasons:
    print(json.dumps({"decision": "block", "reason": "mtk memory: " + " ".join(reasons)}))
done()
PY
exit 0
