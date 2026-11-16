#!/usr/bin/env bash
# Build Coffee & Pi, zip the .app, and publish a GitHub Release.
# Usage:
#   Scripts/release.sh              # uses MARKETING_VERSION from project.yml
#   Scripts/release.sh 1.0.1        # bump version, commit not included — just tag/release
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI required" >&2
  exit 1
fi

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(python3 - <<'PY'
import re
text=open("project.yml").read()
m=re.search(r'MARKETING_VERSION:\s*"([^"]+)"', text)
print(m.group(1) if m else "1.0.0")
PY
)"
else
  # Bump project.yml version for this release.
  VERSION="$VERSION" python3 - <<'PY'
import os, re
from pathlib import Path
version = os.environ["VERSION"]
p = Path("project.yml")
text = p.read_text()
text = re.sub(r'(MARKETING_VERSION:\s*")[^"]+(")', rf'\g<1>{version}\g<2>', text, count=1)
m = re.search(r'CURRENT_PROJECT_VERSION:\s*"(\d+)"', text)
if m:
    n = int(m.group(1)) + 1
    text = re.sub(r'(CURRENT_PROJECT_VERSION:\s*")\d+(")', rf'\g<1>{n}\g<2>', text, count=1)
p.write_text(text)
print(f"project.yml → MARKETING_VERSION={version}")
PY
fi

TAG="v${VERSION}"
ASSET="Coffee-and-Pi-${VERSION}-macos.zip"

echo "==> Building ${TAG}"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

xcodebuild \
  -project CoffeeAndPi.xcodeproj \
  -scheme CoffeeAndPi \
  -configuration Release \
  -derivedDataPath build \
  build

APP="$ROOT/build/Build/Products/Release/Coffee & Pi.app"
if [[ ! -d "$APP" ]]; then
  echo "Missing app at $APP" >&2
  exit 1
fi

# Strip quarantine from local build; clients also strip after download.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

DIST="$ROOT/build/dist"
mkdir -p "$DIST"
ZIP="$DIST/$ASSET"
rm -f "$ZIP"
# KeepParent so unzip yields "Coffee & Pi.app"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> Zip $(du -h "$ZIP" | awk '{print $1}') → $ZIP"

# Ensure git remote exists
if ! git remote get-url origin >/dev/null 2>&1; then
  echo "No git remote 'origin'. Create the GitHub repo first." >&2
  exit 1
fi

# Push tag if needed
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists locally"
else
  git tag -a "$TAG" -m "Coffee & Pi $VERSION"
fi
git push -u origin HEAD
git push origin "$TAG"

NOTES="Coffee & Pi ${VERSION}

Install: unzip and open **Coffee & Pi.app** (or use in-app Check for Updates).

Built from \`$(git rev-parse --short HEAD)\`."

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Updating existing release $TAG"
  gh release upload "$TAG" "$ZIP" --clobber
else
  echo "==> Creating release $TAG"
  gh release create "$TAG" "$ZIP" --title "Coffee & Pi $VERSION" --notes "$NOTES"
fi

echo "Published: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$TAG"
