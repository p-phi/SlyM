#!/usr/bin/env bash
# release.sh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: ./release.sh <version>"
  echo "example: ./release.sh 0.1.0"
  exit 1
fi

VERSION="$1"

# Validate semver format
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: version must be in semver format (e.g., 0.1.0)"
  exit 1
fi

# Update version in all relevant files
sed -i "s/^VERSION=\".*\"/VERSION=\"$VERSION\"/" slym.sh
sed -i "s/^VERSION=\".*\"/VERSION=\"$VERSION\"/" slym-show.sh

# Create git tag
git add slym.sh slym-show.sh slymsh.sh
git commit -m "Release v$VERSION"
git tag -a "v$VERSION" -m "Release v$VERSION"
git push && git push --tags

# Github release
gh release create v"$VERSION" \
  --title "v$VERSION" \
  --notes "See CHANGELOG.md for details" \
  slym.sh slym-show.sh slymsh.sh

echo "Released v$VERSION"
