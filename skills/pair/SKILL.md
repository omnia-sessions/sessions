---
name: pair
description: Connect this computer to the Sessions iPhone app with the six-digit code the app shows.
argument-hint: "[six-digit code from the phone]"
disable-model-invocation: true
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}"/tool/sessions-hook pair *)
---

Result of connecting this computer to the Sessions app:

!`"${CLAUDE_PLUGIN_ROOT}"/tool/sessions-hook pair --session=${CLAUDE_SESSION_ID} $ARGUMENTS`

Tell the person that result in one short sentence and stop. Do not run anything else.

Only if the result above says shell command execution is disabled: run `"${CLAUDE_PLUGIN_ROOT}"/tool/sessions-hook pair $ARGUMENTS` once with the Bash tool and report what it printed.
