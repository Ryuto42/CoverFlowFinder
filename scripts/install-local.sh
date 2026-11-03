#!/bin/zsh
# Release ビルドを作り、/Applications/FlowFinder.app に入れ替える。
set -euo pipefail

cd "$(dirname "$0")/.."
APP=$(./scripts/build-local.sh Release | tail -1)
osascript -e 'tell application id "com.ryuto.FlowFinder" to quit' 2>/dev/null || true
rm -rf /Applications/FlowFinder.app
ditto "$APP" /Applications/FlowFinder.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/FlowFinder.app
# Finder の右クリック「FlowFinder で開く」（Finder Sync 拡張）を有効にする
pluginkit -e use -i com.ryuto.FlowFinder.FinderSync || true
echo "Installed: /Applications/FlowFinder.app"
