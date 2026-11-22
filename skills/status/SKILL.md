---
name: status
description: Show whether this computer is connected to the Sessions iPhone app. Works only in Claude Code on a Mac.
disable-model-invocation: true
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}"/tool/run.sh status)
---

!`"${CLAUDE_PLUGIN_ROOT}"/tool/run.sh status`

Pass this on to the person as it is, briefly.
If it says Sessions works only in Claude Code on a Mac, tell the person that and stop.
Do not run anything else.

Only if the result above says shell command execution is disabled: run `"${CLAUDE_PLUGIN_ROOT}"/tool/run.sh status` once with the Bash tool and pass on what it printed.

If there is no result above and you cannot run commands here (for example in claude.ai chat), tell the person that Sessions works only in Claude Code on a Mac, and stop.
