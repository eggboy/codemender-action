#!/usr/bin/env bash
# Runs cm fix for each finding in FINDINGS_FILE and commits each successful fix separately.
#
# Adapted from Google's CodeMender CI/CD guide. Commits only changes to files that are already
# tracked; files the fix agent creates (test output, scratch files) are discarded.
#
# Environment:
#   FINDINGS_FILE  required  JSON list of findings produced by scan.sh
#   GITHUB_OUTPUT  optional  receives fixed=<count>
set -uo pipefail

: "${FINDINGS_FILE:?FINDINGS_FILE is required}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

cm init || exit 1
# Fix in the repository root instead of each file's directory.
printf 'project_paths:\n  - "%s"\n' "${GITHUB_WORKSPACE:-$PWD}" >> ~/.codemender/config.yaml
cm report import -f "$FINDINGS_FILE" || exit 1

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

list=$(mktemp)
cm report --format=json --status=OPEN | jq -r '.[] | [.finding_id, .title] | @tsv' > "$list"

fixed=0
while IFS=$'\t' read -r id title; do
  # cm fix may stage edits with git add; unstage first so git diff sees tracked changes.
  if cm fix "$id" --sandbox=false --yes --bypass-warning < /dev/null && git reset -q && ! git diff --quiet; then
    git commit -q -a -m "Fix ${title}" -m "CodeMender finding ${id}"
    fixed=$((fixed + 1))
    echo "Fixed \"${title}\" (${id})."
  else
    echo "::warning::CodeMender didn't fix \"${title}\" (${id})."
  fi
  # Discard files the fix agent created, such as test output.
  git reset -q --hard
  git clean -q -fd
done < "$list"

echo "fixed=${fixed}" >> "$GITHUB_OUTPUT"
echo "CodeMender fixed ${fixed} finding(s)."
