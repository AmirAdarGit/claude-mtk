---
name: verify
description: "Run tests, lint, and typecheck, then report a quality level backed by real command output. Auto-detects the stack (Node, Python, Rust). Use when validating code before a commit or PR, checking CI readiness, or closing the REVIEW phase of the pipeline. Triggers on: verify, run checks, quality check, run tests, does it pass, lint, typecheck, is it green, flaky test."
effort: medium
keep-coding-instructions: true
---

# verify

Run the project's checks and report what actually happened. Standalone, or the last phase of `/mtk:develop`.

> **Note — not forked.** This skill deliberately runs in the main conversation. Evidence you cannot see is evidence you cannot check.

## Step 0 — run the script. Do not hand-run the checks.

```bash
"${CLAUDE_SKILL_DIR}/../../scripts/verify.sh" --json          # this repo
"${CLAUDE_SKILL_DIR}/../../scripts/verify.sh" --dir PATH --json
```

Flags: `--only tests|lint|typecheck`, `--streak N`, `--json`, `--dir PATH`.
Exit codes: `0` all clear · `1` warnings only · `2` failures · `3` blocked.

The script detects the stack, runs each check independently, times them, and
counts lint findings per rule. **Its exit code is the verdict.** You do not get
to disagree with it, summarise around it, or report a level it did not produce.

*Why a script and not instructions: an instruction can be skipped and the skip
can be narrated as a pass. An exit code cannot. Everything below describes what
the script does and how to read it — hand-run a check only if the script is
unavailable, and say so plainly when you do.*

## Step 1 — what it detects

Look for config files. Do not assume; detect.

| File found | Check to run |
|---|---|
| `package.json` with a `test` script | tests (npm) |
| `pytest.ini`, or `pyproject.toml` with pytest | tests (pytest) |
| `tsconfig.json` | TypeScript typecheck |
| `biome.json`, `.eslintrc*` | JS/TS lint |
| `ruff.toml`, or `pyproject.toml` with ruff | Python lint |
| `Cargo.toml` | `cargo test`, `cargo clippy` |

## Step 2 — run every applicable check

```bash
npm test -- --run      # or: pytest      / cargo test
npx tsc --noEmit       # or: mypy .
npx biome check .      # or: npx eslint . / ruff check . / cargo clippy
```

Run each one **independently**. A failure in one must not stop the others — collect all the evidence in a single pass, so one run tells the whole story.

Long runs: use `Bash(run_in_background: true)` and stream with `Monitor` rather than blocking.

### `--streak=N` (flaky-test defense)

A suite that passes once may have passed by luck. With `--streak=N` (N ≥ 2), run the **test** suite N times, fresh each time. No cached or earlier result counts.

- Report green only if **all N** runs pass.
- If any run fails, the verdict is **Failures** — name the run that broke it ("run 2 of 3") and show that output. Passing 2 of 3 is a flaky failure, not a pass.
- Typecheck and lint are deterministic. Run them once; a streak adds nothing.

Default is `--streak=1`.

## Step 3 — record evidence

Per check: the exact command, exit code, duration, pass/fail counts, and the first 10 lines of errors if it failed.

## Step 4 — assign a level

| Level | When | What it means |
|---|---|---|
| **All clear** | every check exit 0 | safe to commit |
| **Warnings only** | all pass, lint warnings exist | read them, then decide |
| **Failures** | one or more checks failed | fix before proceeding |
| **Blocked** | checks cannot run (deps missing, build broken) | clear the blocker first |

### Split failures by severity — always

"33 errors" is a number, not information. The script hands you a **count per rule**;
it deliberately does not judge which rules matter, because a script cannot know
whether 23 hits of one rule are 23 bugs or 23 correct idioms. That judgement is
yours, and it costs a read.

**Before calling any rule blocking, open at least one site and read it.** Classifying
by rule name alone is how a hydration pattern that must be written that way gets
reported as a cascading-render bug.

Sort each rule into one of two buckets:

| Bucket | Contains | What to tell the user |
|---|---|---|
| **blocking** | anything that can change behaviour at runtime — bad state updates, race conditions, unhandled errors, wrong equality, missing awaits, security rules | fix before commit |
| **noise** | anything purely cosmetic or dead — unescaped entities, unused vars, import order, formatting | can ride along |

Report it like this:

```
**Quality Level**: Failures
  ├─ blocking (21) — setState-in-effect ×20, prefer-spread ×1
  └─ noise    (12) — no-unescaped-entities ×7, no-unused-vars ×5
**Recommendation**: fix the 21. the 12 can ride.
```

Rules to follow when splitting:

- **Group by rule name first**, then count. Twenty instances of one rule is one
  problem, not twenty — say so.
- **Name the files**, or at least the shared directory. "Concentrated in
  `src/app/platform/*`" is more useful than a list of 40 line numbers.
- **When unsure which bucket a rule belongs in, call it blocking.** Wrongly
  labelling a real bug as noise is the expensive mistake; the reverse just
  costs a minute.
- A codebase with many accumulated lint errors means nothing has been gating on
  them. Worth saying out loud once — it is the finding, not the individual errors.

## Step 5 — report

```
## Verification Results

| Check     | Status | Duration | Details             |
|-----------|--------|----------|---------------------|
| Tests     | PASS   | 4s       | 268 passed, 0 failed|
| Typecheck | PASS   | 5s       | no errors           |
| Lint      | FAIL   | 15s      | 33 errors, 7 warnings|

**Quality Level**: Failures
  ├─ blocking (21) — setState-in-effect ×20, prefer-spread ×1
  └─ noise    (12) — no-unescaped-entities ×7, no-unused-vars ×5

Concentrated in `src/app/platform/*`.
**Recommendation**: fix the 21. the 12 can ride.
```

If anything failed, show the real error output and suggest a fix.

## Read-only by default

`verify` **reports**. It does not repair. Never edit a file, run `--fix`, or
touch git state unless the user asked for it in this turn — running the tool on
a repo is not permission to change that repo. `/mtk:verify --fix` is the only
exception, and only for the lint auto-fix it names.

## Options

| | |
|---|---|
| `/mtk:verify` | all applicable checks |
| `/mtk:verify tests` | tests only |
| `/mtk:verify lint` | lint only |
| `/mtk:verify typecheck` | typecheck only |
| `/mtk:verify --fix` | lint with auto-fix, then verify |
| `/mtk:verify --streak=N` | require N consecutive green test runs |

## Compliance

### Iron Laws

Violating the letter of these is violating the spirit of them.

**IRON LAW: THE SCRIPT'S EXIT CODE IS THE VERDICT.**
Never report a level the script did not produce. If you did not run
`scripts/verify.sh`, you have no verdict to report — say that instead of
inventing one.

**IRON LAW: NEVER REPORT A CHECK AS PASSING WITHOUT ACTUALLY RUNNING IT.**

**IRON LAW: NEVER SUPPRESS OR SUMMARIZE AWAY FAILING OUTPUT.**

### Red flags

| If you catch yourself thinking… | Do this instead |
|---|---|
| "This check doesn't apply here" | Stop. Look for the config file. Detect, don't assume. |
| "That test is probably just flaky" | Stop. Re-run it, or use `--streak=N`. One failure is a failure. |
| "Lint warnings don't matter" | Stop. Warnings are evidence. Report them; let the human weigh them. |
| "I already know this code is correct" | Stop. Verification exists because **confidence is not evidence**. |
| "23 hits of one rule, that's 23 bugs" | Stop. Open one and read it. It may be 23 correct idioms. |
| "I'll just run the commands myself, same thing" | It is not the same thing. The script's exit code is checkable; your narration is not. |

### Rationalizations, answered

| "But…" | Why it's wrong |
|---|---|
| "The build succeeded, so it's correct." | A build proves there are no syntax errors. It says nothing about behavior. |
| "They're only style warnings." | Style consistency prevents bugs by making code predictable — and noise hides real errors. |
| "Types passed, so tests are redundant." | Types check structure. Tests check behavior. Different bugs. |
