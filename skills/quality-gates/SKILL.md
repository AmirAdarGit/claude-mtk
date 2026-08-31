---
name: quality-gates
description: "Score a task 1-5 for complexity, then decide whether work may proceed, must pause for answers, or must escalate. Defines the BLOCKING and WARNING conditions used by every gate in the mtk pipeline. Triggers on: quality gate, complexity assessment, task scoring, escalation, readiness check, how complex is this, should I proceed."
effort: low
keep-coding-instructions: true
---

# quality-gates

A gate is a stopping point between two phases. Its job is to refuse to let bad work move forward.

**Key principle:** stop and clarify *before* proceeding on incomplete information. Asking a question is cheap. Building the wrong thing is not.

> **Note — this skill never runs forked.** A gate that cannot ask a question is not a gate. See [Iron Laws](#iron-laws).

## 1. Score the task, 1–5

| Level | Files | Lines | Time | Unknowns |
|---|---|---|---|---|
| **1 Trivial** | 1 | <50 | <30 min | none |
| **2 Simple** | 1–3 | 50–200 | 30 min–2 h | minimal |
| **3 Moderate** | 3–10 | 200–500 | 2–8 h | some, need research |
| **4 Complex** | 10–25 | 500–1500 | 1–3 days | significant, several decision points |
| **5 Very complex** | 25+ | 1500+ | 3+ days | many; needs prototyping |

Rough markers: level 3 is a feature touching state or schema. Level 4 is auth, payments, real-time, or a data migration. Level 5 is a new service or a whole subsystem — high risk of scope creep.

## 2. BLOCKING conditions — must resolve before proceeding

| # | Condition | Trigger |
|---|---|---|
| 1 | **Incomplete requirements** | more than 3 unanswered critical questions |
| 2 | **Missing dependency** | needs an endpoint, schema, or service that doesn't exist yet |
| 3 | **Stuck** | 3 different approaches tried, all failed |
| 4 | **Evidence failure** | tests or build still failing after 2 fix attempts |
| 5 | **Complexity overflow** | level 4–5 with no breakdown into subtasks |

A *critical* question is one where two reasonable answers produce different code. "What happens when X fails?" is critical. "Should this variable be `i` or `idx`?" is not.

## 3. WARNING conditions — may proceed, carefully

| Condition | What to do |
|---|---|
| Level 3 complexity | state your approach before building; plan checkpoints |
| 1–2 unanswered questions | write down the assumption you're making, out loud |
| 1–2 failed attempts | try a different angle; record what didn't work |

## 4. Gate output — the required format

Every gate emits exactly this, then stops:

```markdown
## Gate: <phase name>

**Complexity**: <1-5> — <one line of why>
**Status**: PASS | WARNING | BLOCKED

**What I know**
- ...

**What I assumed** (because nobody told me)
- ...

**What I need from you**
1. ...
```

Then **ask**, using `AskUserQuestion`, and wait.

- **PASS** — say what's next in one line, and continue.
- **WARNING** — state the assumption, ask if it's right, continue only after an answer.
- **BLOCKED** — do not continue. Present the blocking condition by number and ask.

## Iron Laws

**IRON LAW: A GATE MUST ACTUALLY ASK.**
Never report a gate as passed if no question reached a human. If you cannot call `AskUserQuestion` — for example because you are running in a forked context — the gate is **BLOCKED**, not passed. Say so, and hand the question back up.

*This is the exact failure mode inherited from `etk:development-pipeline`, whose own docs describe it: "a pipeline that reports six passed checkpoints having asked nothing at any of them." That is what this law exists to prevent.*

**IRON LAW: NEVER LOWER A SCORE TO AVOID A GATE.**
If the task is a 4, it is a 4 — even when calling it a 2 would let you start faster.

## Red flags

| If you catch yourself thinking… | Do this instead |
|---|---|
| "I'll just assume they meant X" | One assumption is a WARNING. Three is BLOCKED. Count them. |
| "I can figure out the missing piece while building" | If it changes the design, it's a blocking question. Ask now. |
| "This is basically the same as the last task" | Score it fresh. "Basically the same" hides level 4 work more often than not. |
| "They'll be annoyed if I keep asking" | They will be more annoyed by three days of the wrong thing. |
