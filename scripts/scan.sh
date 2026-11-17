#!/usr/bin/env bash
# Scans a pull request's changes with CodeMender.
#
# Runs cm find --diff against BASE_REF, writes a SARIF report, and saves the findings that
# matched FAIL_ON (excluding "[LEGACY / UNTOUCHED]" findings in code the pull request didn't
# change) to FINDINGS_FILE so an autofix job can pick them up.
#
# Environment:
#   BASE_REF       required  ref to diff against, for example origin/main
#   FAIL_ON        optional  severities that fail the scan (default CRITICAL,HIGH; empty = report only)
#   DIFF_WORKERS   optional  files scanned concurrently, 1-16 (default 16)
#   SARIF_FILE     optional  SARIF output path (default codemender.sarif)
#   FINDINGS_FILE  optional  JSON output path for blocking findings
#   GITHUB_OUTPUT  optional  receives status=, findings=, sarif-file=
#
# Exits 0 when clean or when findings exist (status 0 or 1); exits 2 on setup or scan execution errors.
set -uo pipefail

: "${BASE_REF:?BASE_REF is required}"
FAIL_ON="${FAIL_ON-CRITICAL,HIGH}"
DIFF_WORKERS="${DIFF_WORKERS:-16}"
SARIF_FILE="${SARIF_FILE:-codemender.sarif}"
FINDINGS_FILE="${FINDINGS_FILE:-${RUNNER_TEMP:-/tmp}/codemender-findings.json}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

if [ -z "$BASE_REF" ] || [ "$BASE_REF" = "origin/" ]; then
  echo "::error::base-ref is empty. Run on pull_request events, or pass base-ref explicitly."
  exit 2
fi
if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
  echo "::error::${BASE_REF} is not in the checkout. Use actions/checkout with fetch-depth: 0."
  exit 2
fi
if [ -z "${GOOGLE_CLOUD_PROJECT:-}" ]; then
  echo "::error::GOOGLE_CLOUD_PROJECT is not set. Run google-github-actions/auth with project_id first."
  exit 2
fi

echo "Checking CodeMender connectivity and permissions"
if ! cm health --strict; then
  echo "::error::cm health failed (10 credentials, 20 config, 30 reachability, 40 authorization, 50 timeout)."
  exit 2
fi

cm init || exit 2

status=0
cm find . \
  --diff="$BASE_REF" \
  --diff-workers="$DIFF_WORKERS" \
  --fail-on="$FAIL_ON" \
  --format=sarif \
  --output="$SARIF_FILE" \
  --sandbox=false \
  --yes \
  --bypass-warning || status=$?

# Exit 1 means findings. Anything else is an error; surface the details the CLI logged
# (permission names, HTTP bodies) so the failure can be diagnosed from the job log alone.
if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
  logdir="${CM_HOME:-$HOME/.codemender}/logs"
  echo "::group::CodeMender error details (cm find exit ${status})"
  if [ -d "$logdir" ]; then
    find "$logdir" -type f -mmin -30 \( -name '*.log' -o -name '*.jsonl' \) -print0 2>/dev/null \
      | xargs -0 grep -h -i -E 'permission|denied|forbidden|unauthori|403|401|quota|not found|reason' 2>/dev/null \
      | cut -c1-600 | sort -u | head -20
  else
    echo "no CodeMender log directory at ${logdir}"
  fi
  echo "::endgroup::"
  echo "::error::cm find failed with exit status ${status}."
  exit 2
fi

echo '[]' > "$FINDINGS_FILE"
if [ "$status" -ne 0 ] && [ -n "$FAIL_ON" ]; then
  cm report --format=json --status=OPEN \
    | jq --arg fail_on "$FAIL_ON" '
        ($fail_on | ascii_upcase | split(",")) as $severities
        | [.[]
           | select(.title | startswith("[LEGACY / UNTOUCHED]") | not)
           | select(.severity | ascii_upcase | IN($severities[]))]' \
    > "$FINDINGS_FILE" || echo '[]' > "$FINDINGS_FILE"
fi
findings=$(jq length "$FINDINGS_FILE")

{
  echo "status=${status}"
  echo "findings=${findings}"
  echo "sarif-file=${SARIF_FILE}"
} >> "$GITHUB_OUTPUT"

echo "cm find exited with ${status}; ${findings} finding(s) matched fail-on=${FAIL_ON:-<none>}"
