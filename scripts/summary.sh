#!/usr/bin/env bash
# Writes the CodeMender report to the GitHub job summary.
#
# Environment: BASE_REF, FAIL_ON, STATUS, FINDINGS (informational), GITHUB_STEP_SUMMARY.
set -uo pipefail

GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
{
  echo "## CodeMender scan"
  echo
  echo "Base: \`${BASE_REF:-?}\` | fail-on: \`${FAIL_ON:-none}\` | cm find exit: ${STATUS:-?} | blocking findings: ${FINDINGS:-?}"
  echo
  cm report --status=OPEN --format=md 2>/dev/null || echo "_cm report produced no output._"
  echo
  echo "Findings labelled \`[LEGACY / UNTOUCHED]\` are in code this pull request didn't change; they are reported but don't block."
} >> "$GITHUB_STEP_SUMMARY"
