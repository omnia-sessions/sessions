#!/bin/sh
# Replaces the GitHub placeholder with the real repository in every text file of this folder.
#   ./set_repo.sh <owner/repo>        for example: ./set_repo.sh omnia-studio/sessions
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
files=$(grep -rlI --exclude-dir=.git --exclude-dir=build -F "$placeholder" . || true)
if [ -z "$files" ]; then
  echo "No placeholders left; nothing changed."
  exit 0
fi
printf '%s\n' "$files" | while IFS= read -r f; do
  FROM="$placeholder" REPO="$repo" perl -pi -e 's{\Q$ENV{FROM}\E}{$ENV{REPO}}g' "$f"
  echo "updated $f"
done
if grep -rqI --exclude-dir=.git --exclude-dir=build -F "$placeholder" .; then
  echo "Some placeholders are still there." >&2
  exit 1
fi
echo "Done: every placeholder now reads $repo."
