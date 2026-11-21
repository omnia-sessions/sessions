---
name: unpair
description: Disconnect this computer from the Sessions iPhone app and delete its pair key.
disable-model-invocation: true
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}"/tool/sessions-hook unpair)
---

Result of disconnecting this computer from the Sessions app:

!`"${CLAUDE_PLUGIN_ROOT}"/tool/sessions-hook unpair`

Tell the person that result in one short sentence and stop. Do not run anything else.

Only if the result above says shell command execution is disabled: run `"${CLAUDE_PLUGIN_ROOT}"/tool/sessions-hook unpair` once with the Bash tool and report what it printed.
