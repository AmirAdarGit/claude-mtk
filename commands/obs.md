---
description: Read, shrink, or switch off the observability log — runs, gates, verify history, tool use
---

# obs

Run the script directly:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/obs.sh status   # is it on? how big?
${CLAUDE_PLUGIN_ROOT}/scripts/obs.sh stats    # the report
${CLAUDE_PLUGIN_ROOT}/scripts/obs.sh runs     # one line per run
${CLAUDE_PLUGIN_ROOT}/scripts/obs.sh run <id> # everything in one run
${CLAUDE_PLUGIN_ROOT}/scripts/obs.sh prune 30 # delete older than 30 days
${CLAUDE_PLUGIN_ROOT}/scripts/obs.sh off      # stop recording
```

Show the output as-is. Do not summarise away the numbers.

$ARGUMENTS
