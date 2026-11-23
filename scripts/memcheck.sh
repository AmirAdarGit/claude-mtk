#!/usr/bin/env sh
#
# mtk memcheck — check the hard facts in the .mtk/ draft against git.
#
#   memcheck.sh                  added lines of `git diff HEAD -- .mtk/` (plus new untracked .mtk files)
#   memcheck.sh --all            the whole .mtk/ files
#   memcheck.sh --dir <path>     which repo (default: the current folder)
#
# Four kinds of fact are checked:
#   hash    7-12 or 40 hex, digit and a-f      OK if the commit exists, else WRONG
#   branch  mtk/*                              OK if it exists, OLD if only in git history, else NOT FOUND
#   path    a repo file or folder              OK if it exists, OLD if only in git history, else NOT FOUND
#   plan    "step 19", "steps 2-4", "[19]"     OK if plan.json has that id. A missing id is WRONG only
#                                              for "plan step N", else NOT FOUND
#
# Output, one line per fact:  <LABEL> <kind> <token> — <reason> | <file>: <line start>
# Only hash and plan facts can be WRONG. NOT FOUND means: git cannot tell, the reader must judge.
# Order: WRONG, NOT FOUND, OLD, OK. At most 4000 characters. It always exits 0.

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
    plan_strict = set()   # plan ids that were named as "plan step N"

    def add(kind, token, file, line):
        facts.setdefault((kind, token), (file, line))

    # A git hash: 7-12 or exactly 40 hex characters, with a digit AND a letter a-f. That drops
    # dates, ports, timestamps, ObjectIds (24) and MD5 (32), and `abc1234:latest`, `abc1234-dirty`.
    HASH = re.compile(r"(?<![\w/#:])[0-9a-f]{7,40}(?![\w/:-]|\.\w)")
    BRANCH = re.compile(r"(?<![\w/.-])mtk/[A-Za-z0-9._-]+(?![A-Za-z0-9._/-])")
    PLAN_STEP = re.compile(r"\bplan\s+steps?\s+#?(\d+)(?:\s*[-–]\s*(\d+))?", re.I)
    STEP = re.compile(r"\bsteps?\s+#?(\d+)(?:\s*[-–]\s*(\d+))?", re.I)
    BRACKET = re.compile(r"(?<![\w\]])\[(\d+)\](?!\()")
    TICKS = re.compile(r"`([^`\n]+)`")
    SPLIT = re.compile(r"""[\s()\[\]{}"',;|]+""")
    EXT = re.compile(r"\.[A-Za-z0-9]{1,5}$")
    VERSION = re.compile(r"^v?\d+(\.\d+)+$")
    ONLY_EXT = re.compile(r"^\.[A-Za-z0-9]{1,5}$")
    KNOWN_EXT = set("md json py sh ts js tsx jsx yml yaml toml txt csv html css".split())

    def path_candidate(tok, backticked):
        tok = tok.strip()
        tok = re.sub(r":\d+(-\d+)?$", "", tok)
        tok = tok.rstrip(".,:;!?")
        if tok.startswith("./"):
            tok = tok[2:]
        if not tok or " " in tok or any(c in tok for c in "[]()"):
            return None
        if tok[0] in "~/$" or any(c in tok for c in ("<", "*")) or "://" in tok:
            return None
        if tok.startswith("mtk/") or VERSION.match(tok) or tok.isdigit() or ONLY_EXT.match(tok):
            return None
        if "/" in tok:
            # a path only if it has a file extension, or its first folder is real
            first = tok.split("/")[0]
            if not (EXT.search(tok) or os.path.exists(os.path.join(root, first))):
                return None
        else:
            # a bare name only if it is in backticks and has a known file extension
            m = EXT.search(tok)
            if not (backticked and m and m.group(0)[1:].lower() in KNOWN_EXT):
                return None
        tok = tok.rstrip("/")
        return tok or None

    path_seen = {}  # path -> (file, line)

    for file, line in lines:
        for m in HASH.finditer(line):
            h = m.group(0)
            if (len(h) <= 12 or len(h) == 40) and any(c.isdigit() for c in h) and any(c in "abcdef" for c in h):
                add("hash", m.group(0), file, line)
        for m in BRANCH.finditer(line):
            add("branch", m.group(0).rstrip(".-"), file, line)
        for rx, strict_here in ((STEP, False), (PLAN_STEP, True)):
            for m in rx.finditer(line):
                a = int(m.group(1))
                b = int(m.group(2)) if m.group(2) else a
                if a <= b <= a + 50:
                    for n in range(a, b + 1):
                        add("plan", f"step {n}", file, line)
                        if strict_here:
                            plan_strict.add(f"step {n}")
        for m in BRACKET.finditer(line):
            add("plan", f"step {int(m.group(1))}", file, line)
        spans = [(t, True) for t in TICKS.findall(line)]
        rest = TICKS.sub(" ", line)
        spans += [(t, False) for t in SPLIT.split(rest) if t]
        for tok, ticked in spans:
            p = path_candidate(tok, ticked)
            if p:
                path_seen.setdefault(p, (file, line))

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
                elif v.endswith(" ambiguous"):
                    results[("hash", h)] = ("NOT FOUND", "ambiguous short hash")
                else:
                    results[("hash", h)] = ("OK", "commit exists")
        else:
            facts[("hash", "-")] = facts[("hash", hashes[0])]
            results[("hash", "-")] = ("NOT FOUND", "hash check failed")

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
                results[("branch", b)] = ("NOT FOUND", "no branch, no trace in git — agent must judge")

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
    for p, (file, line) in path_seen.items():
        if os.path.exists(os.path.join(root, p)):
            results[("path", p)] = ("OK", "exists")
        elif p in names:
            results[("path", p)] = ("OLD", "only in git history, not on disk now")
        else:
            results[("path", p)] = ("NOT FOUND", "not on disk, no trace in git — agent must judge")
        facts.setdefault(("path", p), (file, line))

    plan_ids = None
    plan_facts = [(k, t) for (k, t) in facts if k == "plan"]
    try:
        with open(os.path.join(root, ".mtk", "plan.json"), encoding="utf-8") as f:
            plan_ids = {int(s["id"]) for s in json.load(f).get("steps", [])}
    except FileNotFoundError:
        plan_ids = None                       # no plan.json: plan ids are skipped
    except Exception:
        if plan_facts:
            facts[("plan", "-")] = facts[plan_facts[0]]
            results[("plan", "-")] = ("NOT FOUND", "plan.json unreadable, plan ids not checked")
    if plan_ids is not None:
        for (k, t) in plan_facts:
            if int(t.split()[1]) in plan_ids:
                results[(k, t)] = ("OK", "id is in plan.json")
            elif t in plan_strict:
                results[(k, t)] = ("WRONG", "no such id in plan.json")
            else:
                results[(k, t)] = ("NOT FOUND", "no such id in plan.json, but it may not mean a plan step")

    # -- print --------------------------------------------------------------
    rows = []
    for label in ("WRONG", "NOT FOUND", "OLD", "OK"):
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

    counts = {l: sum(1 for r in results.values() if r[0] == l) for l in ("WRONG", "NOT FOUND", "OLD", "OK")}
    summary = f"memcheck: {counts['WRONG']} wrong, {counts['NOT FOUND']} not found, {counts['OLD']} old, {counts['OK']} ok"
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
