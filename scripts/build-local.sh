#!/bin/zsh
# 自分用の設定（Config/Local.xcconfig）でビルドする。引数に Debug / Release（既定は Debug）。
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-Debug}
DERIVED=build
[[ $CONFIG == Release ]] && DERIVED=build/release
xcodebuild -project FlowFinder.xcodeproj -scheme FlowFinder -configuration "$CONFIG" \
  -destination "platform=macOS" -derivedDataPath "$DERIVED" -xcconfig Config/Local.xcconfig build 2>&1 \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
echo "$DERIVED/Build/Products/$CONFIG/FlowFinder.app"
