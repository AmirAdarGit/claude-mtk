#!/usr/bin/env bash
#
# mtk verify — run a project's own checks and report what actually happened.
#
# This exists so that "the checks passed" is a fact with an exit code behind it,
# rather than a claim an agent makes about work it may not have done.
#
# It reports facts only: which checks ran, their exit codes, durations, and for
# lint, a count per rule. It does NOT decide which findings matter — that
# judgement belongs to whoever reads the output. See skills/verify/SKILL.md.
#
# Usage:
#   verify.sh [--json] [--only tests|lint|typecheck] [--streak N] [--dir PATH]
#
# Exit codes:
#   0  all clear      every check passed
#   1  warnings only   passed, but lint reported warnings
#   2  failures        at least one check failed
#   3  blocked         nothing could run (no project, no runner)

set -uo pipefail   # deliberately NOT -e: one failing check must not stop the rest

# Resolve this BEFORE any `cd`. $0 is often relative ("./scripts/verify.sh"), so
# resolving it after cd-ing into --dir silently yields a path that does not
# exist, and every emit below becomes a no-op that looks like it worked.
EVENT="$(cd "$(dirname "$0")" && pwd)/event.sh"
emit() { [ -x "$EVENT" ] && "$EVENT" "$@" >/dev/null 2>&1 || true; }

FORMAT=text
ONLY=""
STREAK=1
DIR="$PWD"

while [ $# -gt 0 ]; do
  case "$1" in
    --json)    FORMAT=json ;;
    --only)    ONLY="${2:-}"; shift ;;
    --streak)  STREAK="${2:-1}"; shift ;;
    --dir)     DIR="${2:-$PWD}"; shift ;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "verify.sh: unknown option '$1'" >&2; exit 3 ;;
  esac
  shift
done

cd "$DIR" 2>/dev/null || { echo "verify.sh: cannot enter $DIR" >&2; exit 3; }
emit verify_start dir="$DIR" only="${ONLY:-all}" streak="$STREAK"

# ── results, kept as parallel arrays ─────────────────────────────────────────
NAMES=(); CMDS=(); CODES=(); SECS=(); NOTES=()

record() {           # record <name> <cmd> <exit> <seconds> <note>
  NAMES+=("$1"); CMDS+=("$2"); CODES+=("$3"); SECS+=("$4"); NOTES+=("$5")
}

run() {              # run <name> <command…> ; captures output to $OUT_FILE
  local name="$1"; shift
  local start end code
  OUT_FILE="$(mktemp)"
  start=$(date +%s)
  "$@" >"$OUT_FILE" 2>&1
  code=$?
  end=$(date +%s)
  LAST_SECS=$(( end - start ))
  LAST_CODE=$code
  return 0
}

json_escape() {      # minimal, sufficient for the short strings we emit
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""}{print}'
}

want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# ── detect ───────────────────────────────────────────────────────────────────
HAS_NPM_TEST=0; HAS_TSC=0; HAS_ESLINT=0; HAS_BIOME=0
HAS_PYTEST=0;   HAS_RUFF=0; HAS_CARGO=0

if [ -f package.json ]; then
  grep -q '"test"[[:space:]]*:' package.json && HAS_NPM_TEST=1
  grep -q '"lint"[[:space:]]*:' package.json && HAS_ESLINT=1
fi
[ -f tsconfig.json ]  && HAS_TSC=1
[ -f biome.json ]     && HAS_BIOME=1
ls .eslintrc* eslint.config.* >/dev/null 2>&1 && HAS_ESLINT=1
[ -f pytest.ini ]     && HAS_PYTEST=1
[ -f pyproject.toml ] && { grep -qi pytest pyproject.toml && HAS_PYTEST=1
                           grep -qi ruff   pyproject.toml && HAS_RUFF=1; }
[ -f ruff.toml ]      && HAS_RUFF=1
[ -f Cargo.toml ]     && HAS_CARGO=1

TOTAL=$(( HAS_NPM_TEST + HAS_TSC + HAS_ESLINT + HAS_BIOME + HAS_PYTEST + HAS_RUFF + HAS_CARGO ))
if [ "$TOTAL" -eq 0 ]; then
  if [ "$FORMAT" = json ]; then
    printf '{"level":"blocked","reason":"no recognised project in %s","checks":[]}\n' "$(json_escape "$DIR")"
  else
    echo "Quality Level: Blocked — no recognised project in $DIR"
  fi
  exit 3
fi

# ── tests (with optional streak) ─────────────────────────────────────────────
if want tests; then
  TEST_CMD=""
  [ "$HAS_NPM_TEST" = 1 ] && TEST_CMD="npm test --silent -- --run"
  [ "$HAS_PYTEST"   = 1 ] && TEST_CMD="pytest -q"
  [ "$HAS_CARGO"    = 1 ] && TEST_CMD="cargo test --quiet"

  if [ -n "$TEST_CMD" ]; then
    broke_at=0; worst=0; total_secs=0
    for i in $(seq 1 "$STREAK"); do
      # shellcheck disable=SC2086
      run tests $TEST_CMD
      total_secs=$(( total_secs + LAST_SECS ))
      if [ "$LAST_CODE" -ne 0 ]; then broke_at=$i; worst=$LAST_CODE
        echo "── test failure (run $i of $STREAK) ──" >&2
        tail -30 "$OUT_FILE" >&2
        break
      fi
    done
    if [ "$broke_at" -ne 0 ]; then
      record tests "$TEST_CMD" "$worst" "$total_secs" "broke on run $broke_at of $STREAK"
    else
      summary=$(grep -Eo '[0-9]+ (passed|passing)' "$OUT_FILE" | tail -1)
      [ "$STREAK" -gt 1 ] && summary="$summary · streak $STREAK/$STREAK"
      record tests "$TEST_CMD" 0 "$total_secs" "${summary:-passed}"
    fi
  fi
fi

# ── typecheck ────────────────────────────────────────────────────────────────
if want typecheck && [ "$HAS_TSC" = 1 ]; then
  run typecheck npx tsc --noEmit
  # grep -c prints the count and exits 1 when it is zero — take the number, not the exit
  n=$(grep -c 'error TS' "$OUT_FILE" 2>/dev/null); n=${n:-0}
  [ "$LAST_CODE" -ne 0 ] && tail -20 "$OUT_FILE" >&2
  record typecheck "npx tsc --noEmit" "$LAST_CODE" "$LAST_SECS" "$n type errors"
fi

# ── lint, with a per-rule breakdown when eslint can give us JSON ─────────────
RULES=""
if want lint && [ "$HAS_ESLINT" = 1 ]; then
  run lint npx eslint . --format json
  if [ -s "$OUT_FILE" ] && command -v python3 >/dev/null 2>&1; then
    RULES=$(python3 - "$OUT_FILE" <<'PY' 2>/dev/null
import json,sys,collections
try: data=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
err=collections.Counter(); warn=collections.Counter(); files=collections.Counter()
for f in data:
    for m in f.get("messages",[]):
        rid=m.get("ruleId") or "(parse)"
        (err if m.get("severity")==2 else warn)[rid]+=1
        files[f.get("filePath","")]+=1
out=[]
for rid,c in err.most_common(): out.append(f"{rid}\t{c}\terror")
for rid,c in warn.most_common(): out.append(f"{rid}\t{c}\twarning")
print("\n".join(out))
print("TOTALS\t%d\t%d" % (sum(err.values()), sum(warn.values())))
PY
)
  fi
  E=$(printf '%s' "$RULES" | awk -F'\t' '$1=="TOTALS"{print $2}')
  W=$(printf '%s' "$RULES" | awk -F'\t' '$1=="TOTALS"{print $3}')
  E=${E:-0}; W=${W:-0}
  note="$E errors, $W warnings"
  code=$LAST_CODE
  [ "$E" = 0 ] && [ "$W" != 0 ] && code=0   # warnings alone are not a failure
  record lint "npx eslint ." "$code" "$LAST_SECS" "$note"
  LINT_WARNINGS=$W
elif want lint && [ "$HAS_BIOME" = 1 ]; then
  run lint npx biome check .
  record lint "npx biome check ." "$LAST_CODE" "$LAST_SECS" ""
elif want lint && [ "$HAS_RUFF" = 1 ]; then
  run lint ruff check .
  record lint "ruff check ." "$LAST_CODE" "$LAST_SECS" ""
fi

# ── level ────────────────────────────────────────────────────────────────────
LEVEL="all clear"; EXIT=0
for c in "${CODES[@]}"; do [ "$c" -ne 0 ] && { LEVEL="failures"; EXIT=2; }; done
if [ "$EXIT" -eq 0 ] && [ "${LINT_WARNINGS:-0}" != 0 ]; then LEVEL="warnings only"; EXIT=1; fi
[ "${#NAMES[@]}" -eq 0 ] && { LEVEL="blocked"; EXIT=3; }

# grep -c prints its count AND exits 1 when that count is zero, so `|| echo 0`
# appends a second line and yields "0\n0". Count with awk, which cannot do that.
RULE_COUNT=$(printf '%s' "$RULES" | awk 'NF && $1!="TOTALS"{n++} END{print n+0}')
emit verify_done level="$LEVEL" exit="$EXIT" checks="${#NAMES[@]}" rules="$RULE_COUNT"

# ── report ───────────────────────────────────────────────────────────────────
if [ "$FORMAT" = json ]; then
  printf '{"level":"%s","dir":"%s","checks":[' "$LEVEL" "$(json_escape "$DIR")"
  for i in "${!NAMES[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    printf '{"check":"%s","command":"%s","exit":%s,"seconds":%s,"summary":"%s"}' \
      "${NAMES[$i]}" "$(json_escape "${CMDS[$i]}")" "${CODES[$i]}" "${SECS[$i]}" \
      "$(json_escape "${NOTES[$i]}")"
  done
  printf '],"rules":['
  first=1
  while IFS=$'\t' read -r rid count sev; do
    [ -z "${rid:-}" ] && continue
    [ "$rid" = TOTALS ] && continue
    [ "$first" -eq 0 ] && printf ','
    printf '{"rule":"%s","count":%s,"severity":"%s"}' "$(json_escape "$rid")" "$count" "$sev"
    first=0
  done <<< "$RULES"
  printf ']}\n'
else
  echo
  echo "## Verification Results"
  echo
  printf '| %-10s | %-6s | %5s | %s\n' "Check" "Status" "Time" "Details"
  printf '|------------|--------|-------|------------------\n'
  for i in "${!NAMES[@]}"; do
    st=PASS; [ "${CODES[$i]}" -ne 0 ] && st=FAIL
    printf '| %-10s | %-6s | %4ss | %s\n' "${NAMES[$i]}" "$st" "${SECS[$i]}" "${NOTES[$i]}"
  done
  if [ -n "$RULES" ]; then
    echo
    echo "Findings per rule (counts only — severity of *impact* is not decided here):"
    while IFS=$'\t' read -r rid count sev; do
      [ -z "${rid:-}" ] && continue
      [ "$rid" = TOTALS ] && continue
      printf '  %-45s %3s  %s\n' "$rid" "$count" "$sev"
    done <<< "$RULES"
  fi
  echo
  echo "Quality Level: $LEVEL"
fi

exit "$EXIT"
