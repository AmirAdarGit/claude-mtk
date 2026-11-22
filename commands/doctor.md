---
description: Check that mtk really works here — which copy runs, its version, and whether each hook ran
---

# doctor

Run the check and show its output exactly as it prints it:

```bash
sh ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh --dir "$PWD"
```

Then, in at most three short lines, say what to do about each WARN or FAIL line,
using the `fix:` text the script gives. Do not run the fixes yourself unless the
user asks: the doctor only reads, and so do you here.

A WARN that says a hook "has not run" right after mtk was updated is expected:
the heartbeat appears the first time the hook runs. Say so, and suggest running
`/mtk:doctor` again in a new session.

$ARGUMENTS
