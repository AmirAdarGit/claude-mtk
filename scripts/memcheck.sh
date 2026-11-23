#!/usr/bin/env sh
#
# mtk memcheck — check the hard facts in the .mtk/ draft against git.
#
#   memcheck.sh                  added lines of `git diff HEAD -- .mtk/` (plus new untracked .mtk files)
#   memcheck.sh --all            the whole .mtk/ files
#   memcheck.sh --dir <path>     which repo (default: the current folder)
#
# Four kinds of fact are checked:
#   hash    7-40 hex characters with a digit   OK if the commit exists, else WRONG
#   branch  mtk/*                              OK if it exists, OLD if only in git history, else WRONG
#   path    a repo file or folder              OK if it exists, OLD if only in git history, else WRONG
#   plan    "step 19", "steps 2-4", "[19]"     OK if plan.json has that id, else WRONG
#
# Output, one line per fact:  <LABEL> <kind> <token> — <reason> | <file>: <line start>
# WRONG first, then OLD, then OK. At most 4000 characters. It always exits 0.

command -v python3 >/dev/null 2>&1 || { echo "memcheck: python3 not found"; exit 0; }

python3 - "$@" <<'PY'
import json
import os
import re
import subprocess
import sys

CAP = 4000
MEMORY_FILES = (".mtk/now.md", ".mtk/log.md", ".mtk/plan.json")

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def main():
    args = sys.argv[1:]
    whole = "--all" in args
    start = os.getcwd()
    if "--dir" in args:
        i = args.index("--dir")
        if i + 1 < len(args):
            start = args[i + 1]

    def git(*a, cwd):
        try:
            r = subprocess.run(["git", "-c", "core.quotepath=off", "-C", cwd, *a],
                               capture_output=True, timeout=10)
        except Exception:
            return None
        return r.stdout.decode("utf-8", errors="replace") if r.returncode == 0 else None

    # The main folder, as hooks/memory.sh finds it (right even from a linked worktree).
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=start)
    if common is None:
        print("memcheck: not a git repo")
        return
    common = common.strip()
    if os.path.basename(common) == ".git":
        root = os.path.dirname(common)
    else:
        root = (git("rev-parse", "--show-toplevel", cwd=start) or start).strip()

    # -- the lines to read: (file, text) ------------------------------------
    def read_whole(rel):
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
                return [(rel, l) for l in f.read().splitlines()]
        except Exception:
            return []

    lines = []
    if whole:
        for rel in MEMORY_FILES:
            lines += read_whole(rel)
    else:
        diff = git("diff", "HEAD", "-U0", "--no-color", "--no-ext-diff", "--no-renames", "--", ".mtk/", cwd=root)
        if diff is None:                       # no commit yet: every file is new
            for rel in MEMORY_FILES:
                lines += read_whole(rel)
        else:
            current, in_hunk = None, False
            for l in diff.splitlines():
                if l.startswith("diff --git"):
                    current, in_hunk = None, False
                elif l.startswith("@@"):
                    in_hunk = True
                elif not in_hunk:
                    if l.startswith("+++ b/"):
                        current = l[6:].split("\t")[0]
                elif l.startswith("+") and current:
                    lines.append((current, l[1:]))
            untracked = git("ls-files", "--others", "--exclude-standard", "--", ".mtk/", cwd=root) or ""
            for rel in untracked.splitlines():
                if rel in MEMORY_FILES:
                    lines += read_whole(rel)

    # -- find the facts -----------------------------------------------------
    facts = {}     # (kind, token) -> (file, line), first one seen wins

    def add(kind, token, file, line):
        facts.setdefault((kind, token), (file, line))

    HASH = re.compile(r"(?<![\w/])[0-9a-f]{7,40}(?![\w/]|\.\w)")
    BRANCH = re.compile(r"(?<![\w/.-])mtk/[A-Za-z0-9._-]+(?![A-Za-z0-9._/-])")
    STEP = re.compile(r"\bsteps?\s+#?(\d+)(?:\s*[-–]\s*(\d+))?")
    BRACKET = re.compile(r"(?<![\w\]])\[(\d+)\](?!\()")
    TICKS = re.compile(r"`([^`\n]+)`")
    SPLIT = re.compile(r"""[\s()\[\]{}"',;|]+""")
    EXT = re.compile(r"\.[A-Za-z0-9]{1,5}$")
    VERSION = re.compile(r"^v?\d+(\.\d+)+$")

    def path_candidate(tok, backticked):
        tok = tok.strip()
        tok = re.sub(r":\d+(-\d+)?$", "", tok)
        tok = tok.rstrip(".,:;!?")
        if tok.startswith("./"):
            tok = tok[2:]
        if not tok or " " in tok:
            return None
        if not ("/" in tok or EXT.search(tok)):
            return None
        if tok[0] in "~/$" or any(c in tok for c in ("<", "*")) or "://" in tok:
            return None
        if tok.startswith("mtk/") or VERSION.match(tok) or tok.isdigit():
            return None
        tok = tok.rstrip("/")
        if not tok:
            return None
        return tok, (backticked or "/" in tok)      # (path, may it be WRONG?)

    path_seen = {}  # path -> (file, line, may_be_wrong)

    for file, line in lines:
        for m in HASH.finditer(line):
            if any(c.isdigit() for c in m.group(0)):
                add("hash", m.group(0), file, line)
        for m in BRANCH.finditer(line):
            add("branch", m.group(0).rstrip(".-"), file, line)
        for m in STEP.finditer(line):
            a = int(m.group(1))
            b = int(m.group(2)) if m.group(2) else a
            if a <= b <= a + 50:
                for n in range(a, b + 1):
                    add("plan", f"step {n}", file, line)
        for m in BRACKET.finditer(line):
            add("plan", f"step {int(m.group(1))}", file, line)
        spans = [(t, True) for t in TICKS.findall(line)]
        rest = TICKS.sub(" ", line)
        spans += [(t, False) for t in SPLIT.split(rest) if t]
        for tok, ticked in spans:
            c = path_candidate(tok, ticked)
            if c:
                p, may_be_wrong = c
                old = path_seen.get(p)
                if old is None:
                    path_seen[p] = (file, line, may_be_wrong)
                elif may_be_wrong and not old[2]:
                    path_seen[p] = (file, line, True)

    # -- check them, batching the git calls ---------------------------------
    results = {}   # (kind, token) -> (label, reason)

    hashes = [t for (k, t) in facts if k == "hash"]
    if hashes:
        try:
            r = subprocess.run(["git", "-C", root, "cat-file", "--batch-check"],
                               input="".join(f"{h}^{{commit}}\n" for h in hashes).encode(),
                               capture_output=True, timeout=10)
            verdicts = r.stdout.decode(errors="replace").splitlines()
        except Exception:
            verdicts = []
        if len(verdicts) == len(hashes):
            for h, v in zip(hashes, verdicts):
                if v.endswith(" missing"):
                    results[("hash", h)] = ("WRONG", "git has no such commit")
                else:
                    results[("hash", h)] = ("OK", "commit exists")

    branches = [t for (k, t) in facts if k == "branch"]
    if branches:
        heads = set((git("for-each-ref", "--format=%(refname)", "refs/heads/", cwd=root) or "").split())
        missing = [b for b in branches if "refs/heads/" + b not in heads]
        history = set()
        if missing:
            msgs = git("log", "--all", "--format=%B", cwd=root) or ""
            history = {m.group(0).rstrip(".-") for m in BRANCH.finditer(msgs)}
        for b in branches:
            if "refs/heads/" + b in heads:
                results[("branch", b)] = ("OK", "branch exists")
            elif b in history:
                results[("branch", b)] = ("OLD", "only in git history, branch is gone")
            else:
                results[("branch", b)] = ("WRONG", "no such branch, no trace in git")

    gone = [p for p in path_seen if not os.path.exists(os.path.join(root, p))]
    names = set()
    if gone:
        log = git("log", "--all", "--format=", "--name-only", "--no-renames", cwd=root) or ""
        for n in log.splitlines():
            if n:
                names.add(n)
                while "/" in n:
                    n = n.rsplit("/", 1)[0]
                    names.add(n)
    for p, (file, line, may_be_wrong) in path_seen.items():
        if os.path.exists(os.path.join(root, p)):
            results[("path", p)] = ("OK", "exists")
        elif p in names:
            results[("path", p)] = ("OLD", "only in git history, not on disk now")
        elif may_be_wrong:
            results[("path", p)] = ("WRONG", "not on disk, no trace in git")
        # a bare word that is not found is skipped, not WRONG
    for p, (file, line, _) in path_seen.items():
        if ("path", p) in results:
            facts.setdefault(("path", p), (file, line))

    plan_ids = None
    try:
        with open(os.path.join(root, ".mtk", "plan.json"), encoding="utf-8") as f:
            plan_ids = {int(s["id"]) for s in json.load(f).get("steps", [])}
    except Exception:
        plan_ids = None
    if plan_ids is not None:
        for (k, t) in facts:
            if k == "plan":
                if int(t.split()[1]) in plan_ids:
                    results[(k, t)] = ("OK", "id is in plan.json")
                else:
                    results[(k, t)] = ("WRONG", "no such id in plan.json")

    # -- print --------------------------------------------------------------
    rows = []
    for order, label in enumerate(("WRONG", "OLD", "OK")):
        for key, (lab, reason) in results.items():
            if lab != label:
                continue
            file, line = facts[key]
            kind, token = key
            if len(token) > 80:
                token = token[:77] + "..."
            text = " ".join(line.split())[:60]
            rows.append(f"{label} {kind} {token} — {reason} | {file}: {text}")

    if not rows:
        print("memcheck: no facts to check")
        return

    counts = {l: sum(1 for r in results.values() if r[0] == l) for l in ("WRONG", "OLD", "OK")}
    summary = f"memcheck: {counts['WRONG']} wrong, {counts['OLD']} old, {counts['OK']} ok"
    room = CAP - len(summary) - 1 - 24            # keep space for the "... N more" line
    shown, used = [], 0
    for r in rows:
        if used + len(r) + 1 > room:
            break
        shown.append(r)
        used += len(r) + 1
    out = shown[:]
    if len(shown) < len(rows):
        out.append(f"... {len(rows) - len(shown)} more")
    out.append(summary)
    print("\n".join(out))


try:
    main()
except Exception as e:          # never fail: this is a check, not a gate
    print(f"memcheck: error ({type(e).__name__}), nothing checked")
PY
exit 0
