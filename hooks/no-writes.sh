#!/usr/bin/env sh
#
# mtk no-writes — the read-only agents (two reviewers and memory-checker) really are read-only.
#
#   no-writes.sh          PreToolUse (Bash): deny a known writing command; else
#                         remember the files as they are now
#   no-writes.sh after    PostToolUse / PostToolUseFailure (Bash): if any file
#                         changed during the command, block and name the files
#
# Wired in hooks/hooks.json for every Bash call. It acts only when the call comes
# from a read-only agent: the hook input's "agent_type" is one of MTK_READONLY_AGENTS
# (default: mtk:quality-reviewer mtk:adversarial-verifier mtk:memory-checker). Your own commands and
# tdd-implementer's are never touched.
#
# WHY THIS EXISTS
# `disallowedTools: [Write, Edit, MultiEdit]` blocks tools by NAME. Bash is not
# named Write, so `echo x > file` wrote anyway.
#
# WHY TWO CHECKS
# 1. The deny-list stops the common writes BEFORE they happen: redirects, rm, mv,
#    sed -i, git commit/checkout/reset, package installs.
# 2. A list cannot see a write inside another program: python3 -c "open('f','w')",
#    node -e "fs.writeFileSync(...)". So after every command the hook compares the
#    files git can see (changed + untracked, by mtime and size) with before. Any
#    change is a write, whatever made it. It cannot undo the write -- that could
#    destroy your own work -- so it blocks the agent with the list of changed files,
#    and the agent must report them.
#
# WHY HOOKS.JSON, NOT THE AGENT FILE
# Until 0.3.5 this hook was wired in the agents' own frontmatter. On 2026-11-22 the
# /mtk:doctor heartbeat showed it never ran: Claude Code ignores `hooks:` in the
# frontmatter of an agent that comes from a plugin. The read-only rule was not
# enforced at all. hooks.json does run, and its input carries agent_type.
#
# NOT COVERED: files git ignores (.gitignore) and files outside the repo.
# Any error means "allow": a broken hook must not break the session.

# heartbeat for /mtk:doctor: "this hook ran, from this plugin folder" (file time = when)
B="${MTK_HOME:-$HOME/.mtk}/beat"; [ -d "$B" ] || mkdir -p "$B" 2>/dev/null
printf '%s\n' "${0%/*}/.." > "$B/${0##*/}-${1:-}" 2>/dev/null || true

set -u

MODE="${1:-check}"
PAYLOAD=$(cat)
AGENTS="${MTK_READONLY_AGENTS:-mtk:quality-reviewer mtk:adversarial-verifier mtk:memory-checker}"

# Fast exit for every Bash call that is not from a read-only agent: no python.
hit=0
for a in $AGENTS; do
  case "$PAYLOAD" in *"$a"*) hit=1 ;; esac
done
[ "$hit" = 1 ] || exit 0

export PAYLOAD MODE AGENTS
command -v python3 >/dev/null 2>&1 || exit 0   # cannot inspect: do not block

python3 <<'PY'
import hashlib, json, os, re, subprocess, sys

try:
    d = json.loads(os.environ.get("PAYLOAD", "") or "{}")
except Exception:
    sys.exit(0)
if d.get("agent_type") not in os.environ.get("AGENTS", "").split():
    sys.exit(0)                      # the name appeared somewhere else in the payload
cmd = (d.get("tool_input") or {}).get("command", "")
mode = os.environ.get("MODE", "check")
cwd = d.get("cwd") or os.getcwd()
state_dir = os.path.join(os.environ.get("MTK_HOME") or os.path.expanduser("~/.mtk"), "no-writes")
state_file = os.path.join(state_dir, hashlib.sha1(
    f"{d.get('session_id')}|{d.get('agent_id')}".encode()).hexdigest()[:16])

def files():
    """{path: "mtime:size"} for every file git sees as changed or untracked."""
    r = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True, timeout=10)
    if r.returncode != 0:
        return None
    root = r.stdout.decode().strip()
    r = subprocess.run(["git", "-C", root, "status", "--porcelain", "-z", "--untracked-files=all"],
                       capture_output=True, timeout=20)
    if r.returncode != 0:
        return None
    out = {}
    entries = r.stdout.split(b"\0")
    i = 0
    while i < len(entries):
        e = entries[i]
        i += 1
        if len(e) < 4:
            continue
        if e[:1] in (b"R", b"C"):
            i += 1                       # a rename has the old name next; skip it
        path = e[3:].decode(errors="replace")
        try:
            st = os.stat(os.path.join(root, path))
            out[path] = f"{st.st_mtime_ns}:{st.st_size}"
        except OSError:
            out[path] = "deleted"
    return out

def save(state):
    try:
        os.makedirs(state_dir, exist_ok=True)
        with open(state_file, "w") as f:
            json.dump(state, f)
    except Exception:
        pass

if mode == "after":
    try:
        with open(state_file) as f:
            before = json.load(f)
    except Exception:
        sys.exit(0)                      # no "before": nothing to compare
    now = files()
    if now is None:
        sys.exit(0)
    changed = sorted(p for p in set(before) | set(now) if before.get(p) != now.get(p))
    save(now)                            # report each change once
    if changed:
        shown = ", ".join(changed[:10]) + (f" and {len(changed) - 10} more" if len(changed) > 10 else "")
        print(json.dumps({"decision": "block", "reason": (
            f"read-only agent: the last command changed files: {shown}. This agent must not change "
            f"files. Do not try to undo it. Stop, and report these files and the command to the user. "
            f"Command: {cmd[:160]}")}))
    sys.exit(0)

# ── check (PreToolUse): known writing commands are denied up front ──────────
if not cmd:
    sys.exit(0)

RULES = [
    (r'\bgit\s+reset\s+--hard\b',            "git reset --hard destroys work"),
    (r'\bgit\s+(checkout|restore)\b(?!.*\b(-b|--)\s*$)', "git checkout/restore discards changes"),
    (r'\bgit\s+clean\b',                     "git clean deletes untracked files"),
    (r'\bgit\s+(commit|push|merge|rebase|stash)\b', "changes repository state"),
    (r'(^|[;&|]|\s)\s*rm\b',                 "rm deletes files"),
    (r'(^|[;&|]|\s)\s*(mv|cp)\b',            "mv/cp changes files"),
    (r'\bsed\b[^|]*\s-i\b',                  "sed -i edits in place"),
    (r'\bperl\b[^|]*\s-i\b',                 "perl -i edits in place"),
    (r'\btee\b',                             "tee writes to a file"),
    (r'\btruncate\b|\bdd\b',                 "writes to a file"),
    (r'\b(npm|pnpm|yarn|pip|pip3|uv|brew)\s+(i|install|add|remove|uninstall|upgrade)\b',
                                             "package install/remove changes the project"),
    (r'\bchmod\b|\bchown\b',                 "changes file permissions"),
    (r'>>?(?!&)',                            "> redirects output into a file"),
]

# A heredoc body is data fed to stdin, not shell syntax: `cat <<'EOF' | node` with
# `(a)=>a>=1` inside is not a redirect. Drop the body lines; keep the line that
# opens the heredoc, so `cat <<EOF > out.txt` is still seen. Done before the quote
# scrub, because a body can hold an odd quote (Hebrew צ'אט) that would break it.
def strip_heredocs(s):
    out, pending = [], []
    for line in s.split("\n"):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        out.append(line)
        pending += [m.group(2) for m in
                    re.finditer(r"(?<!<)<<(?!<)-?\s*(['\"]?)(\w+)\1", line)]
    return "\n".join(out)

# Quoted strings are data, not shell syntax: grep "a > b" is not a redirect.
scrubbed = re.sub(r'"[^"]*"', '""', strip_heredocs(cmd))
scrubbed = re.sub(r"'[^']*'", "''", scrubbed)
# /dev/null is not a real write and shows up constantly in read-only commands.
scrubbed = scrubbed.replace(">/dev/null", "").replace("> /dev/null", "")
scrubbed = scrubbed.replace("2>&1", "")

for pattern, why in RULES:
    if re.search(pattern, scrubbed):
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    f"read-only agent: {why}. This agent reports findings; it does not "
                    f"change files or repository state. Blocked command: {cmd[:160]}"
                ),
            }
        }))
        sys.exit(0)

state = files()                          # allowed: remember the files for "after"
if state is not None:
    save(state)
sys.exit(0)
PY
exit 0
