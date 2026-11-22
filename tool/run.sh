#!/bin/sh
# Starts the Sessions tool (tool/sessions-hook, built from src/*.swift). Sessions works on macOS only.
# Elsewhere (Linux, including Cowork, and Windows) the hooks exit at once and quietly, and the commands say so.
if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then
  [ "${1:-}" = "hook" ] || echo "Sessions works only in Claude Code on a Mac."
  exit 0
fi
case "$0" in
  */*) exec "${0%/*}/sessions-hook" "$@" ;;
  *) exec ./sessions-hook "$@" ;;
esac
