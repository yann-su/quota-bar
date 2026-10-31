#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
# Only the signed app's own resource directory is used as the CLI workspace.
cd "$(dirname "$0")"
echo "QuotaBar：等待 Claude 用量面板出现后，返回小组件点击刷新。"
echo "此操作使用官方客户端更新登录，不发起模型对话。"
if command -v claude >/dev/null 2>&1; then
    exec claude --safe-mode /usage
fi
echo "未找到 Claude Code。请先安装并使用订阅账号登录。"
read -r -p "按回车关闭…"
