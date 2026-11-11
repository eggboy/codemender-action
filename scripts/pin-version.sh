#!/usr/bin/env bash
# Records the checksums for a CodeMender CLI release so the action can pin it.
#
# Downloads each platform zip for the given version from Artifact Registry, computes SHA-256,
# and writes checksums/<version>.sha256. Review the result and commit it.
#
# Usage: ./scripts/pin-version.sh 0.21.0
set -euo pipefail

version="${1:?usage: pin-version.sh <version>}"
repo_root=$(cd "$(dirname "$0")/.." && pwd)
out="${repo_root}/checksums/${version}.sha256"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

: > "$out"
for file in cm-linux-amd64.zip cm-linux-arm64.zip cm-darwin-arm64.zip cm-darwin-amd64.zip; do
  url="https://artifactregistry.googleapis.com/download/v1/projects/cmoc-prod/locations/us/repositories/codemender-cli-production/files/cm%3A${version}%3A${file}:download?alt=media"
  echo "Downloading ${file}"
  curl -fsSL --retry 3 -o "${tmp}/${file}" "$url"
  printf '%s  %s\n' "$(sha256_of "${tmp}/${file}")" "$file" >> "$out"
done

echo "Wrote ${out}:"
cat "$out"
