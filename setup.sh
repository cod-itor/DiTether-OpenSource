#!/usr/bin/env bash
# One-shot setup for macOS:  ./setup.sh [bundle-prefix] [team-id]
# Example:                   ./setup.sh com.sokha ABCDE12345
set -euo pipefail
cd "$(dirname "$0")"

PREFIX="${1:-}"
TEAM="${2:-}"

if [[ -n "$PREFIX" ]]; then
  sed -i '' "s|^BUNDLE_PREFIX *=.*|BUNDLE_PREFIX = ${PREFIX}|" Config/Local.xcconfig
fi
if [[ -n "$TEAM" ]]; then
  sed -i '' "s|^DEVELOPMENT_TEAM *=.*|DEVELOPMENT_TEAM = ${TEAM}|" Config/Local.xcconfig
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen with Homebrew..."
    brew install xcodegen
  else
    echo "XcodeGen is missing and Homebrew is not installed."
    echo "Install Homebrew from https://brew.sh, then run this script again."
    exit 1
  fi
fi

echo "Generating Tether.xcodeproj ..."
xcodegen generate

echo
echo "Done. Current settings:"
grep -E '^(BUNDLE_PREFIX|DEVELOPMENT_TEAM)' Config/Local.xcconfig
echo
echo "Next: open Tether.xcodeproj, then follow README.md > 'Run it on your devices'."
open Tether.xcodeproj 2>/dev/null || true
