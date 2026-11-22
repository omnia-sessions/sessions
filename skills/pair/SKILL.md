---
name: pair
description: Connect this computer to the Sessions iPhone app with the six-digit code the app shows. Works only in Claude Code on a Mac.
argument-hint: "[six-digit code from the phone]"
disable-model-invocation: true
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}"/tool/run.sh pair *)
---

Result of connecting this computer to the Sessions app:

!`"${CLAUDE_PLUGIN_ROOT}"/tool/run.sh pair --session=${CLAUDE_SESSION_ID} $ARGUMENTS`

Tell the person that result in one short sentence and stop.
If the result says Sessions works only in Claude Code on a Mac, tell the person that and stop.
Do not run anything else.

Only if the result above says shell command execution is disabled: run `"${CLAUDE_PLUGIN_ROOT}"/tool/run.sh pair $ARGUMENTS` once with the Bash tool and report what it printed.

If there is no result above and you cannot run commands here (for example in claude.ai chat), tell the person that Sessions works only in Claude Code on a Mac, and stop.
