#!/bin/zsh
# 本家（upstream/main）の更新を custom ブランチに取り込み、ビルドして /Applications に入れ直す。
# 取り込みはコミットせずに止めるので、内容を確認してから自分でコミットする。
set -euo pipefail

cd "$(dirname "$0")/.."

# 一度解決した競合の解決方法を記録し、次回から自動で再適用する
git config rerere.enabled true
git config rerere.autoUpdate true

if [[ -n "$(git status --porcelain)" ]]; then
  echo "未コミットの変更があります。コミットしてから実行し直してください。"
  exit 1
fi

# フォークでは origin が自分のリポジトリになるので、本家は upstream として参照する
UPSTREAM_URL=https://github.com/elliotttate/CoverFlowFinder.git
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"

git fetch upstream
if git merge-base --is-ancestor upstream/main HEAD; then
  echo "本家の更新はすでに取り込み済みです。"
  exit 0
fi

if ! git merge --no-commit --no-ff upstream/main; then
  echo
  echo "競合が発生しました。次のファイルを解決してから scripts/install-local.sh を実行してください。"
  git diff --name-only --diff-filter=U
  exit 1
fi

./scripts/install-local.sh
echo
echo "取り込みとインストールが終わりました。内容を確認して git commit してください。"
