#!/usr/bin/env bash
# ponytail: Pi self-edit rebuild loop for Coffee & Pi
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

xcodebuild \
  -project CoffeeAndPi.xcodeproj \
  -scheme CoffeeAndPi \
  -configuration Debug \
  -derivedDataPath build \
  build

APP="$ROOT/build/Build/Products/Debug/Coffee & Pi.app"
# Relaunch — replaces the running app instance
pkill -f "Coffee & Pi.app/Contents/MacOS/Coffee & Pi" 2>/dev/null || true
sleep 0.4
open "$APP"
echo "Rebuilt and relaunched: $APP"
