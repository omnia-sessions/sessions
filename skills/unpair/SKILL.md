---
name: unpair
description: Disconnect this computer from the Sessions iPhone app and delete its pair key and local data. Works only in Claude Code on a Mac.
disable-model-invocation: true
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}"/tool/run.sh unpair)
---

Result of disconnecting this computer from the Sessions app:

!`"${CLAUDE_PLUGIN_ROOT}"/tool/run.sh unpair`

Tell the person that result in one short sentence and stop.
If the result says Sessions works only in Claude Code on a Mac, tell the person that and stop.
Do not run anything else.

Only if the result above says shell command execution is disabled: run `"${CLAUDE_PLUGIN_ROOT}"/tool/run.sh unpair` once with the Bash tool and report what it printed.

If there is no result above and you cannot run commands here (for example in claude.ai chat), tell the person that Sessions works only in Claude Code on a Mac, and stop.
