---
name: verify
description: "Run tests, lint, and typecheck, then report a quality level backed by real command output. Auto-detects the stack (Node, Python, Rust). Use when validating code before a commit or PR, checking CI readiness, or closing the REVIEW phase of the pipeline. Triggers on: verify, run checks, quality check, run tests, does it pass, lint, typecheck, is it green, flaky test."
effort: medium
keep-coding-instructions: true
---

# verify

Run the project's checks and report what actually happened. Standalone, or the last phase of `/mtk:develop`.

> **Note — not forked.** This skill deliberately runs in the main conversation. Evidence you cannot see is evidence you cannot check.

## Step 1 — detect the stack

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

## Step 5 — report

```
## Verification Results

| Check     | Status | Duration | Details             |
|-----------|--------|----------|---------------------|
| Tests     | PASS   | 12.4s    | 24 passed, 0 failed |
| Typecheck | PASS   | 3.2s     | no errors           |
| Lint      | WARN   | 1.1s     | 0 errors, 3 warnings|

**Quality Level**: Warnings only
**Recommendation**: read the 3 warnings, then safe to commit.
```

If anything failed, show the real error output and suggest a fix.

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

**IRON LAW: NEVER REPORT A CHECK AS PASSING WITHOUT ACTUALLY RUNNING IT.**

**IRON LAW: NEVER SUPPRESS OR SUMMARIZE AWAY FAILING OUTPUT.**

### Red flags

| If you catch yourself thinking… | Do this instead |
|---|---|
| "This check doesn't apply here" | Stop. Look for the config file. Detect, don't assume. |
| "That test is probably just flaky" | Stop. Re-run it, or use `--streak=N`. One failure is a failure. |
| "Lint warnings don't matter" | Stop. Warnings are evidence. Report them; let the human weigh them. |
| "I already know this code is correct" | Stop. Verification exists because **confidence is not evidence**. |

### Rationalizations, answered

| "But…" | Why it's wrong |
|---|---|
| "The build succeeded, so it's correct." | A build proves there are no syntax errors. It says nothing about behavior. |
| "They're only style warnings." | Style consistency prevents bugs by making code predictable — and noise hides real errors. |
| "Types passed, so tests are redundant." | Types check structure. Tests check behavior. Different bugs. |
