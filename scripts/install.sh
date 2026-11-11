#!/usr/bin/env bash
# Installs a pinned CodeMender CLI (cm) release from Artifact Registry and verifies its SHA-256.
#
# Environment:
#   CM_VERSION   required  package version, for example 0.20.0 (not "stable")
#   CM_SHA256    optional  expected SHA-256 of the zip; overrides checksums/<version>.sha256
#   ACTION_PATH  optional  directory that contains checksums/ (defaults to this repository)
#   RUNNER_TEMP  optional  where to unpack (GitHub Actions sets it)
#   GITHUB_PATH  optional  if set, the install directory is appended so later steps find cm
set -euo pipefail

: "${CM_VERSION:?CM_VERSION is required}"
ACTION_PATH="${ACTION_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "::error::Unsupported operating system: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "::error::Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
file="cm-${os}-${arch}.zip"

expected="${CM_SHA256:-}"
if [ -z "$expected" ]; then
  sums="${ACTION_PATH}/checksums/${CM_VERSION}.sha256"
  if [ ! -f "$sums" ]; then
    echo "::error::No checksum file for cm ${CM_VERSION} (${sums}). Pass the sha256 input or add the file."
    exit 1
  fi
  expected=$(awk -v f="$file" '$2 == f { print $1 }' "$sums")
  if [ -z "$expected" ]; then
    echo "::error::No checksum for ${file} in ${sums}."
    exit 1
  fi
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

url="https://artifactregistry.googleapis.com/download/v1/projects/cmoc-prod/locations/us/repositories/codemender-cli-production/files/cm%3A${CM_VERSION}%3A${file}:download?alt=media"
dest="${RUNNER_TEMP}/cm-cli"
mkdir -p "$dest"

echo "Downloading cm ${CM_VERSION} (${file})"
curl -fsSL --retry 3 --retry-delay 2 -o "${dest}/${file}" "$url"

actual=$(sha256_of "${dest}/${file}")
if [ "$actual" != "$expected" ]; then
  echo "::error::Checksum mismatch for ${file}: expected ${expected}, got ${actual}"
  exit 1
fi
echo "Checksum verified: ${actual}"

unzip -q -o "${dest}/${file}" -d "$dest"
chmod +x "${dest}/cm"
rm -f "${dest}/${file}"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$dest" >> "$GITHUB_PATH"
fi
echo "Installed $("${dest}/cm" --version) in ${dest}"
