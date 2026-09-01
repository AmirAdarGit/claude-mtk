#!/usr/bin/env sh
#
# mtk no-writes — block writing Bash commands for a read-only agent.
#
# Wired into an agent's own frontmatter:
#
#   hooks:
#     PreToolUse:
#       - matcher: "Bash"
#         hooks:
#           - type: command
#             command: "${CLAUDE_PLUGIN_ROOT}/hooks/no-writes.sh"
#
# WHY THIS EXISTS
# `disallowedTools: [Write, Edit, MultiEdit]` blocks tools by NAME. Bash is not
# named Write, so it passes -- and `echo x > file` writes anyway. The read-only
# label was documentation, not enforcement. This is the enforcement.
#
# WHAT IT IS NOT
# A deny-list is a fence, not a vault. `python3 -c "open('f','w').write('x')"`
# has no > and gets through. Closing that needs an allow-list of exact commands,
# which breaks the agent the first time it needs something unlisted. This side
# of the trade-off keeps the reviewers working; be honest that it is a fence.
#
# Reads the hook payload on stdin. Prints deny JSON to block, or exits 0 to let
# the normal permission flow continue.

set -u

PAYLOAD=$(cat)
export PAYLOAD

command -v python3 >/dev/null 2>&1 || exit 0   # cannot inspect: do not block

python3 <<'PY'
import json, os, re, sys

try:
    d = json.loads(os.environ.get("PAYLOAD", "") or "{}")
except Exception:
    sys.exit(0)                      # unparseable: do not block

cmd = (d.get("tool_input") or {}).get("command", "")
if not cmd:
    sys.exit(0)

# Each rule is (regex, what to tell the agent). Ordered most-destructive first
# so the reason names the worst thing in a compound command.
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

# Strip quoted strings before matching, so `grep "a > b" file` is not mistaken
# for a redirect. Crude, and deliberately so: it errs toward allowing reads.
scrubbed = re.sub(r'"[^"]*"', '""', cmd)
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

sys.exit(0)     # nothing matched: no decision, normal flow continues
PY
