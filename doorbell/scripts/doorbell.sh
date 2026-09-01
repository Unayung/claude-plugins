#!/usr/bin/env bash
# doorbell — 誰按過門鈴。SessionStart 時列出 GitHub 上真的有人在等你的事。
#
# 兩個「靜默失敗」的坑，別再踩：
#   1. hook 不繼承登入 shell 的 PATH，gh 常在 ~/.local/bin → 下面補 PATH
#   2. SessionStart hook 的純 stdout 只進模型 context，使用者看不到
#      → 必須輸出 JSON 帶 systemMessage
# ponytail: 只做 pull。要即時推播就自己 arm 一個 Monitor，而且只在一個 session arm。

export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:$PATH"

# 只給使用者看，不佔模型 context（想讓 Claude 也知道就加 hookSpecificOutput）
emit() { jq -nc --arg m "$1" '{systemMessage:$m}'; }

command -v gh >/dev/null || { emit "🔔 doorbell: PATH 裡找不到 gh"; exit 0; }
command -v jq >/dev/null || { echo "🔔 doorbell: 需要 jq"; exit 0; }

REASONS='["review_requested","assign","mention","team_mention","author"]'

out=$(gh api "/notifications?all=false&per_page=100" --paginate --jq \
  ".[]|select(.reason|IN(${REASONS}[]))
   |\"- [\(.reason)] \(.repository.full_name) — \(.subject.title)\"" 2>&1) \
  || { emit "🔔 doorbell: 讀不到 GitHub 通知（gh 沒登入？）"; exit 0; }

[ -n "$out" ] && emit "$(printf '有人在等你\n%s' "$out")"
exit 0
