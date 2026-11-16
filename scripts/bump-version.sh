#!/usr/bin/env bash
# Bumps the pinned CodeMender CLI version across checksums, CM_VERSION, actions, workflows, and docs.
#
# Usage: ./scripts/bump-version.sh 0.21.0
set -euo pipefail

new_version="${1:?usage: bump-version.sh <new-version>}"
if [[ ! "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Invalid version '${new_version}'; expected strict X.Y.Z." >&2
  exit 1
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
version_file="${repo_root}/CM_VERSION"
if [ ! -f "$version_file" ]; then
  echo "::error::Missing ${version_file}." >&2
  exit 1
fi

current=$(tr -d '[:space:]' < "$version_file")
if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Invalid current version '${current}' in ${version_file}." >&2
  exit 1
fi

"${repo_root}/scripts/pin-version.sh" "$new_version"
printf '%s\n' "$new_version" > "$version_file"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

update_file() {
  local file="$1"
  awk -v old="$current" -v new="$new_version" '
    function replace_all(str, needle, repl,    out, pos, nlen) {
      if (needle == "" || needle == repl) {
        return str
      }
      out = ""
      nlen = length(needle)
      while ((pos = index(str, needle)) > 0) {
        out = out substr(str, 1, pos - 1) repl
        str = substr(str, pos + nlen)
      }
      return out str
    }
    {
      line = $0
      line = replace_all(line, "default: \"" old "\"", "default: \"" new "\"")
      line = replace_all(line, "\047" old "\047", "\047" new "\047")
      line = replace_all(line, "\140" old "\140", "\140" new "\140")
      line = replace_all(line, "checksums/" old ".sha256", "checksums/" new ".sha256")
      print line
    }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
}

for rel in \
  action.yml \
  setup/action.yml \
  .github/workflows/codemender.yml \
  .github/workflows/preflight.yml \
  README.md; do
  update_file "${repo_root}/${rel}"
done

echo "Bumped CodeMender CLI default from ${current} to ${new_version}."
