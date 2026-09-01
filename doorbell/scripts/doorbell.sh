#!/usr/bin/env bash
# doorbell — 誰按過門鈴。SessionStart 時列出 GitHub 上真的有人在等你的事。
#
# 兩個「靜默失敗」的坑，別再踩：
#   1. hook 不繼承登入 shell 的 PATH，gh 常在 ~/.local/bin → 下面補 PATH
#   2. SessionStart hook 的純 stdout 只進模型 context，使用者看不到
#      → 必須輸出 JSON 帶 systemMessage
# ponytail: 只做 pull。要即時推播用 /doorbell watch，而且只在一個 session 掛。

export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:$PATH"

# 沒授權時 gh 會等互動輸入；hook 卡住 = 每次開 session 都要等 timeout
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
# 最壞情況 10+3=13s，壓在 hooks.json 的 20s 預算內
GH() { timeout 10 gh "$@"; }
GH_QUICK() { timeout 3 gh "$@"; }

emit() { jq -nc --arg m "$1" '{systemMessage:$m}'; }

if ! command -v jq >/dev/null; then
  echo "🔔 doorbell 需要 jq：brew install jq ／ sudo pacman -S jq ／ sudo apt install jq"
  exit 0
fi

if ! command -v gh >/dev/null; then
  emit "$(cat <<'MSG'
🔔 doorbell 需要 GitHub CLI，目前 PATH 裡找不到。

  安裝    macOS   brew install gh
          Arch    sudo pacman -S github-cli
          Debian  sudo apt install gh
          其他    https://cli.github.com

  登入    gh auth login

裝在非標準路徑的話（例如 asdf/mise shim），把它加進 PATH 再重開 session。
MSG
)"
  exit 0
fi

REASONS='["review_requested","assign","mention","team_mention","author"]'

if ! out=$(GH api "/notifications?all=false&per_page=100" --paginate --jq \
  ".[]|select(.reason|IN(${REASONS}[]))
   |\"- [\(.reason)] \(.repository.full_name) — \(.subject.title)\"" 2>&1); then

  # 只有在失敗時才多跑一次 auth 檢查，區分「沒登入」和「其他錯誤」
  if ! GH_QUICK auth status >/dev/null 2>&1; then
    emit "🔔 doorbell：gh 尚未登入。跑 \`gh auth login\` 授權後重開 session。"
  else
    emit "$(printf '🔔 doorbell：讀取 GitHub 通知失敗（已登入，可能是網路或權限）。\n\n%s\n\n手動確認：gh api /notifications' "$out")"
  fi
  exit 0
fi

[ -n "$out" ] && emit "$(printf '有人在等你\n%s' "$out")"
exit 0
