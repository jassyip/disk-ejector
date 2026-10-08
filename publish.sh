#!/bin/bash
# 一键发布脚本：创建公开仓库并推送代码
#
# 前置条件：在你自己的终端里完成一次 gh 登录（或设置 GITHUB_TOKEN）
#
# 用法：
#   ./publish.sh              # 用 gh 登录态发布
#   GITHUB_TOKEN=xxx ./publish.sh   # 用 token 发布

set -euo pipefail

cd "$(dirname "$0")"

REPO_NAME="${REPO_NAME:-disk-ejector}"
REPO_DESC="${REPO_DESC:-macOS 菜单栏外接硬盘弹出工具，一键弹出，无需指纹验证}"

if ! gh auth status >/dev/null 2>&1; then
  echo "❌ 尚未登录 GitHub"
  echo ""
  echo "请先执行："
  echo "  gh auth login --hostname github.com --git-protocol https --web"
  exit 1
fi

if gh repo view "$REPO_NAME" >/dev/null 2>&1; then
  echo "ℹ️  仓库 $REPO_NAME 已存在，改为直接推送"
else
  echo "==> 创建公开仓库 $REPO_NAME"
  gh repo create "$REPO_NAME" \
    --public \
    --description "$REPO_DESC" \
    --source=. \
    --push
  echo "✅ 创建并推送完成"
  exit 0
fi

echo "==> 推送到已有仓库"
git push -u origin "HEAD:$(gh repo view "$REPO_NAME" --json defaultBranchRef -q .defaultBranchRef.name)"
echo "✅ 推送完成"
