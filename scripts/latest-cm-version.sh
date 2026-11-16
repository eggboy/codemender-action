#!/usr/bin/env bash
# Prints the highest semantic version of the CodeMender CLI (cm) in Artifact Registry.
#
# Queries the public Artifact Registry REST API across all pages, keeps strict X.Y.Z releases
# (excluding floating tags such as "stable" and pre-release suffixes), and sorts numerically.
set -euo pipefail

base_url="https://artifactregistry.googleapis.com/v1/projects/cmoc-prod/locations/us/repositories/codemender-cli-production/packages/cm/versions?pageSize=200"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

page_token=""
while :; do
  if [ -n "$page_token" ]; then
    response=$(curl -fsSL --retry 3 --retry-delay 2 --get --data-urlencode "pageToken=${page_token}" "$base_url")
  else
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$base_url")
  fi

  printf '%s\n' "$response" | jq -r '(.versions // [])[].name | split("/") | last' >> "$tmp"
  page_token=$(printf '%s\n' "$response" | jq -r '.nextPageToken // empty')
  if [ -z "$page_token" ]; then
    break
  fi
done

latest=$(
  awk -F. '/^[0-9]+\.[0-9]+\.[0-9]+$/ { print $1 + 0, $2 + 0, $3 + 0, $0 }' "$tmp" \
    | LC_ALL=C sort -k1,1n -k2,2n -k3,3n \
    | tail -n 1 \
    | awk '{ print $4 }'
)

if [ -z "$latest" ]; then
  echo "::error::No semantic versions found for cm in Artifact Registry." >&2
  exit 1
fi

printf '%s\n' "$latest"
