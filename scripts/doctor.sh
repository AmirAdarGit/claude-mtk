#!/usr/bin/env sh
#
# mtk doctor — does mtk really work on this machine?
#
#   doctor.sh [--dir PROJECT]
#
# Checks, each printed as OK / WARN / FAIL with the fix:
#   1. which mtk copy really runs   -- from the heartbeats every hook writes to
#                                      ~/.mtk/beat/<script>-<mode> (content: the
#                                      plugin folder it ran from; file time: when)
#   2. that copy's version against the source folder and the plugin registry
#   3. each hook wired in hooks/hooks.json: did it run, and when
#   4. python3 and git are installed
#   5. the project memory (.mtk/) is there and valid
#   6. another plugin that shows its own session memory (ctk) is not also on
#
# WHY THIS EXISTS
# On 2026-11-22 the plugin registry said mtk 0.2.2 was installed, and the cached
# 0.2.2 copy had no memory.sh -- yet the 0.3.1 memory banner showed. Nothing told
# us which copy ran. Before that, a hook wired in skill frontmatter never ran in a
# real session and nobody noticed. The tests call each hook by hand; they cannot
# prove Claude Code calls it. Only a trace left by the real run can.
#
# Exit: 0 all OK · 1 warnings · 2 failures. Reads only; changes nothing.

set -u
SELF_ROOT="$(cd "${0%/*}/.." && pwd)"
DIR="$PWD"
[ "${1:-}" = "--dir" ] && [ -n "${2:-}" ] && DIR="$2"
export SELF_ROOT DIR

command -v python3 >/dev/null 2>&1 || { echo "FAIL  python3 is not installed -- every mtk hook needs it. Install Python 3."; exit 2; }

python3 <<'PY'
import glob, json, os, subprocess, sys, time

home = os.path.expanduser("~")
mtk_home = os.environ.get("MTK_HOME") or os.path.join(home, ".mtk")
claude = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
self_root = os.environ["SELF_ROOT"]
proj = os.environ["DIR"]
worst = 0
lines = []

def say(level, text, fix=""):
    global worst
    worst = max(worst, {"OK": 0, "INFO": 0, "WARN": 1, "FAIL": 2}[level])
    lines.append(f"{level:<5} {text}" + (f"\n      fix: {fix}" if fix else ""))

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def version(root):
    d = load(os.path.join(root, ".claude-plugin", "plugin.json"))
    return d.get("version") if isinstance(d, dict) else None

def name(key):
    """'verify-gate.sh-base' -> 'verify-gate.sh base'"""
    script, _, mode = key.rpartition("-")
    return f"{script} {mode}".strip()

def ago(t):
    s = int(time.time() - t)
    return f"{s}s" if s < 120 else f"{s // 60} min" if s < 7200 else f"{s // 3600} h" if s < 172800 else f"{s // 86400} days"

# ── 1-2. which copy runs, and which version ─────────────────────────────────
beats = {}
for f in glob.glob(os.path.join(mtk_home, "beat", "*")):
    try:
        with open(f) as fh:
            root = os.path.realpath(fh.read().strip())
        beats[os.path.basename(f)] = (root, os.path.getmtime(f))
    except Exception:
        pass

source = None
km = load(os.path.join(claude, "plugins", "known_marketplaces.json")) or {}
src = (km.get("mtk") or {}).get("source") or {}
if src.get("source") == "directory" and src.get("path"):
    source = os.path.realpath(src["path"])
registry = None
ip = load(os.path.join(claude, "plugins", "installed_plugins.json")) or {}
for entry in (ip.get("plugins") or {}).get("mtk@mtk") or []:
    registry = entry

if beats:
    root, t = max(beats.values(), key=lambda v: v[1])
    v = version(root)
    say("INFO", f"running mtk {v or '?'} from {root} (last hook {ago(t)} ago)")
    others = sorted({r for r, _ in beats.values()} - {root})
    for r in others:
        say("WARN", f"hooks also ran from another copy: {r} (mtk {version(r) or '?'})",
            "old heartbeats are fine if that copy is no longer installed; to clear them: rm ~/.mtk/beat/*")
    if source and v and version(source) and v != version(source):
        say("WARN", f"the running copy is mtk {v}, the source folder has mtk {version(source)}",
            "run /plugin, update mtk, then restart Claude Code")
    elif source and v:
        say("OK", f"the running copy matches the source folder (mtk {v})")
else:
    say("WARN", "no hook has left a heartbeat yet, so it is unknown which mtk copy runs",
        "update the plugin to a version with heartbeats (0.3.4+), restart Claude Code, then run /mtk:doctor again")

if registry:
    rv = registry.get("version")
    running = version(max(beats.values(), key=lambda v: v[1])[0]) if beats else None
    if running and rv and rv != running:
        say("INFO", f"the plugin registry lists mtk {rv}, but hooks run mtk {running} -- "
                    "with a directory marketplace the registry number can lag; the heartbeat is what really ran")

# ── 3. every wired hook: did it run? ────────────────────────────────────────
hooks_root = max(beats.values(), key=lambda v: v[1])[0] if beats else (source or self_root)
hj = load(os.path.join(hooks_root, "hooks", "hooks.json")) or {}
wired = {}
for event, groups in (hj.get("hooks") or {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            parts = h.get("command", "").split("hooks/")[-1].split()
            if parts:
                key = parts[0] + "-" + (parts[1] if len(parts) > 1 else "")
                wired.setdefault(key, event)
for key, event in sorted(wired.items()):
    if key.startswith("send.sh"):
        continue                                  # one line for all of send.sh below
    if key in beats:
        say("OK", f"{name(key)} ran {ago(beats[key][1])} ago ({event})")
    elif event in ("PreCompact", "SessionEnd"):
        say("INFO", f"{name(key)} has not run yet -- it runs only on {event}, which can be rare")
    else:
        say("WARN", f"{name(key)} has not run ({event})",
            "if a session already started after the update, Claude Code is not calling this hook: check /hooks")
sends = [k for k in wired if k.startswith("send.sh")]
if sends:
    seen = [k for k in sends if k in beats]
    say("OK" if seen else "WARN", f"send.sh ran for {len(seen)} of {len(sends)} events")
for agent_hook in ("no-writes.sh-", "strikes.sh-check", "strikes.sh-record"):
    if agent_hook in beats:
        say("OK", f"{name(agent_hook)} ran {ago(beats[agent_hook][1])} ago (inside an mtk agent)")
    else:
        say("INFO", f"{name(agent_hook)} has not run yet -- it runs only inside mtk's agents")

# ── 4. tools ────────────────────────────────────────────────────────────────
try:
    subprocess.run(["git", "--version"], capture_output=True, check=True)
    say("OK", "git and python3 are installed")
except Exception:
    say("FAIL", "git is not installed -- memory.sh and verify-gate.sh need it", "install git")

# ── 5. project memory ───────────────────────────────────────────────────────
r = subprocess.run(["git", "-C", proj, "rev-parse", "--show-toplevel"], capture_output=True)
top = r.stdout.decode().strip() if r.returncode == 0 else proj
now = os.path.join(top, ".mtk", "now.md")
if not os.path.isfile(now):
    say("INFO", f"no project memory in {top}/.mtk/", "run /mtk:handoff to create it")
else:
    with open(now, errors="replace") as f:
        text = f.read()
    if "\nNext:" not in "\n" + text:
        say("WARN", ".mtk/now.md has no 'Next:' line -- a new session will not know what to do",
            "run /mtk:handoff")
    plan = os.path.join(top, ".mtk", "plan.json")
    if os.path.isfile(plan) and load(plan) is None:
        say("FAIL", ".mtk/plan.json is not valid JSON", "fix the file, or run /mtk:handoff")
    else:
        say("OK", f"project memory in {top}/.mtk/ is valid")

# ── 6. a second memory banner ───────────────────────────────────────────────
def enabled(name):
    on = None
    for path in (os.path.join(claude, "settings.json"),
                 os.path.join(top, ".claude", "settings.json"),
                 os.path.join(top, ".claude", "settings.local.json")):
        d = load(path) or {}
        val = (d.get("enabledPlugins") or {}).get(name)
        if val is not None:
            on = bool(val)
    return on
for name in [k for k in ((load(os.path.join(claude, "settings.json")) or {}).get("enabledPlugins") or {})
             if k.startswith("ctk@")]:
    if enabled(name):
        say("WARN", f"{name} is on in this project -- it shows its own session memory next to mtk's",
            f'add "enabledPlugins": {{"{name}": false}} to {top}/.claude/settings.json')

print("\n".join(lines))
print()
print({0: "mtk doctor: all OK", 1: "mtk doctor: warnings", 2: "mtk doctor: failures"}[worst])
sys.exit(worst)
PY
