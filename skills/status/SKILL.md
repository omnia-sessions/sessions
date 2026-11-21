---
name: status
description: Show whether this computer is connected to the Sessions iPhone app.
disable-model-invocation: true
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}"/tool/sessions-hook status)
---

!`"${CLAUDE_PLUGIN_ROOT}"/tool/sessions-hook status`

Pass this on to the person as it is, briefly. Do not run anything else.
