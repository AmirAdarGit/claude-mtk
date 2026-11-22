#!/usr/bin/env sh
#
# mtk secret guard — Claude must not print a secret into the session.
#
#   secret-guard.sh       PreToolUse (Bash), every session and every agent
#
# Denies a Bash command that would show a secret in the tool output:
#   - a reader on a .env file: cat, head, tail, sed, awk, cut, grep (without
#     -c/-q/-l), ... and `< .env` into a loop
#   - echo / printf of a variable with a secret-looking name ($MONGODB_URI, ${API_KEY})
#   - printenv or env with no arguments (they print every variable)
#   - a python/node/ruby/perl one-liner that reads .env, or reads a secret-looking
#     variable, and prints
#
# Allowed, because they print no value: grep -c / -q / -l on .env, test -f .env,
# ls, cp, ln, source, `node --env-file=.env script.js`, and any .env.example,
# .env.sample or .env.template file.
#
# WHY THIS EXISTS
# 2026-11-23, Dev Brain: a session checked a .env line with sed/cut. The line had
# no "=", so the "safe" cut printed the whole line, and the database password went
# into the session twice. A memory note saying "never print .env" is a request; a
# model can forget it. This hook makes the common cases impossible.
#
# NOT COVERED: a script file that prints secrets (node print-env.js), base64 or
# other encodings, secrets in files not named .env. It is a guard for the common
# mistakes, not a sandbox.
#
# MTK_SECRET_GUARD=off turns it off. Any error means "allow": a broken hook must
# not break the session.

# heartbeat for /mtk:doctor: "this hook ran, from this plugin folder" (file time = when)
B="${MTK_HOME:-$HOME/.mtk}/beat"; [ -d "$B" ] || mkdir -p "$B" 2>/dev/null
printf '%s\n' "${0%/*}/.." > "$B/${0##*/}-${1:-}" 2>/dev/null || true

[ "${MTK_SECRET_GUARD:-on}" = "off" ] && exit 0
PAYLOAD=$(cat)

# Fast exit for most commands: no .env, no variable, no env dump -> no python.
case "$PAYLOAD" in
  *.env*|*'$'*|*printenv*|*'"env'*|*' env'*|*'&env'*|*';env'*|*'|env'*) ;;
  *) exit 0 ;;
esac

export PAYLOAD
command -v python3 >/dev/null 2>&1 || exit 0   # cannot inspect: do not block

python3 <<'PY'
import json, os, re, shlex, sys

try:
    d = json.loads(os.environ.get("PAYLOAD", "") or "{}")
except Exception:
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command", "") or ""

# a .env file path, but not .env.example / .sample / .template
ENVFILE = re.compile(r"(?:^|.*/)\.env(?:\.(?!example$|sample$|template$|dist$)[\w-]+)?$")
SECRET = r"[A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASS|PWD|URI|URL|DSN|CREDENTIALS?|AUTH)[A-Za-z0-9_]*"
SECRET_VAR = re.compile(r"\$\{?(" + SECRET + r")\b", re.I)
READERS = {"cat", "head", "tail", "less", "more", "bat", "nl", "od", "xxd", "hexdump",
           "strings", "sort", "uniq", "sed", "awk", "gawk", "cut", "tr", "column",
           "diff", "cmp", "paste", "fold", "rev", "tac", "jq", "yq", "base64"}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
GREP_SAFE = re.compile(r"^-(?:[a-zA-Z]*[cqlL][a-zA-Z]*|-count|-quiet|-silent|-files-with(?:out)?-matches)$")
INTERP = re.compile(r"^(?:python\d*(?:\.\d+)?|node|nodejs|bun|deno|ruby|perl|php)$")
PRINTS = re.compile(r"print|console\.(?:log|error|info|dir)|puts|\bsay\b|\becho\b|stdout|write")

def deny(why):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"secret guard: {why}, so a secret would go into the session. Check it "
            f"without printing a value: grep -c '^NAME=' .env, grep -q, test -n \"$NAME\", "
            f"or a script that prints only true/false. Blocked command: {cmd[:160]}"),
    }}))
    sys.exit(0)

def words(seg):
    try:
        return shlex.split(seg, posix=True)
    except ValueError:
        return seg.split()

def head(ws):
    """The program a segment runs: skip VAR=x, env, sudo, command, time, nohup."""
    i = 0
    while i < len(ws):
        w = ws[i]
        if re.match(r"^[A-Za-z_]\w*=", w) or w in ("sudo", "command", "time", "nohup", "exec"):
            i += 1
        elif w == "env" and i + 1 < len(ws):
            i += 1
        else:
            return w.rsplit("/", 1)[-1], ws[i + 1:]
    return "", []

# split into simple commands; keep `<` so input redirection is visible
segments = re.split(r"\|\||&&|[;|&\n]|\$\(|`|\bdo\b|\bthen\b", cmd)

for seg in segments:
    seg = seg.strip().lstrip("({").strip()
    if not seg:
        continue
    ws = words(seg)
    prog, args = head(ws)
    envargs = [a for a in args if ENVFILE.match(a.lstrip("<"))]

    if prog in READERS and envargs:
        deny(f"`{prog}` would print the file {envargs[0]}")
    if prog in GREPS and envargs and not any(GREP_SAFE.match(a) for a in args):
        deny(f"`{prog}` would print matching lines of {envargs[0]}")
    if prog in ("echo", "printf") and SECRET_VAR.search(seg):
        deny(f"`{prog}` would print ${SECRET_VAR.search(seg).group(1)}")
    if prog in ("printenv", "env", "export", "set", "declare") and not args:
        deny(f"`{prog}` with no arguments prints every variable")
    if prog == "printenv" and any(re.fullmatch(SECRET, a, re.I) for a in args):
        deny("`printenv` would print a secret variable")
    if INTERP.match(prog):
        code = " ".join(args)
        if any(a in ("-c", "-e", "-p", "--eval", "--print", "-r") for a in args) and PRINTS.search(code):
            # --env-file=.env only loads the variables; it prints nothing by itself
            if re.search(r"\.env\b(?!\.(?:example|sample|template))", re.sub(r"--env-file=\S+", "", code)):
                deny(f"a `{prog}` one-liner would read .env and print it")
            if re.search(r"(?:process\.env|os\.environ|getenv|ENV\[)\W*" + SECRET, code, re.I):
                deny(f"a `{prog}` one-liner would print a secret variable")

# `while read l; do echo $l; done < .env` and similar
m = re.search(r"<\s*(\S*\.env(?:\.[\w-]+)?)\b", cmd)
if m and ENVFILE.match(m.group(1)) and not re.match(r"^\s*(?:wc|grep\s+-[a-zA-Z]*[cq])\b", cmd):
    deny(f"the file {m.group(1)} is read into a command that can print it")
sys.exit(0)
PY
exit 0
