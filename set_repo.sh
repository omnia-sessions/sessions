#!/bin/sh
# Writes the GitHub repository into every text file of this folder: in place of the placeholder, and in place of
# the repository named now in .claude-plugin/plugin.json ("repository"), so the plugin can move again later.
#   ./set_repo.sh <owner/repo>        for example: ./set_repo.sh omnia-sessions/sessions
set -eu
cd "$(dirname "$0")"
repo="${1:-}"
case "$repo" in
  */*/*|/*|*/|"") echo "usage: ./set_repo.sh <owner/repo>" >&2; exit 2 ;;
esac
if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$'; then
  echo "Not a GitHub owner/repo: $repo" >&2
  exit 2
fi
placeholder="OWNER""/REPO"   # split so this script never matches itself
# The repository written now, from plugin.json's "repository": "https://github.com/<owner/repo>".
old=$(sed -n 's|.*"repository": *"https://github.com/\([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]*\)".*|\1|p' .claude-plugin/plugin.json 2>/dev/null | head -n 1)
old="${old%.git}"
[ "$old" = "$repo" ] && old=""

# Only a whole owner/repo is replaced: not one inside a longer name, and not the plugin's install folder
# (plugins/cache/<marketplace>/<plugin>/, which can read like an owner/repo). The same pattern in both perl lines.
holding() {
  grep -rlI --exclude-dir=.git --exclude-dir=build -F "$1" . 2>/dev/null | while IFS= read -r f; do
    FROM="$1" perl -ne 'if (/(?<![A-Za-z0-9-])(?<!cache\/)\Q$ENV{FROM}\E(?![A-Za-z0-9_-])/) { print "$ARGV\n"; exit }' "$f"
  done
}

changed=0
for from in "$placeholder" $old; do
  files=$(holding "$from")
  [ -z "$files" ] && continue
  changed=1
  printf '%s\n' "$files" | while IFS= read -r f; do
    FROM="$from" REPO="$repo" perl -pi -e 's/(?<![A-Za-z0-9-])(?<!cache\/)\Q$ENV{FROM}\E(?![A-Za-z0-9_-])/$ENV{REPO}/g' "$f"
    echo "updated $f ($from -> $repo)"
  done
done
if [ "$changed" = 0 ]; then
  echo "Already $repo everywhere; nothing changed."
  exit 0
fi
left=$(holding "$placeholder")
[ -n "$old" ] && left="$left$(holding "$old")"
if [ -n "$left" ]; then
  echo "Still written the old way in: $left" >&2
  exit 1
fi
echo "Done: every repository reference now reads $repo."
