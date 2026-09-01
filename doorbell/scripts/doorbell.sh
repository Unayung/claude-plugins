#!/usr/bin/env bash
# doorbell — 誰按過門鈴。
#
# 預設完全不作動。要開：/doorbell watch（寫旗標，之後每個 session 自動生效）。
#
# 兩個「靜默失敗」的坑，別再踩：
#   1. hook 不繼承登入 shell 的 PATH，gh 常在 ~/.local/bin → 下面補 PATH
#   2. SessionStart hook 的純 stdout 只進模型 context，使用者看不到
#      → 給人看要 systemMessage，給模型看要 hookSpecificOutput.additionalContext

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/doorbell"

# ── opt-in 閘門：沒開就零成本退出，連 PATH 都不用碰 ──────────────────
[ -e "$STATE_DIR/watch-enabled" ] || exit 0

export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:$PATH"
# 沒授權時 gh 會等互動輸入；hook 卡住 = 每次開 session 都要等 timeout
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
# 最壞情況 10+3=13s，壓在 hooks.json 的 20s 預算內
GH() { timeout 10 gh "$@"; }
GH_QUICK() { timeout 3 gh "$@"; }

emit() { jq -nc --arg m "$1" '{systemMessage:$m}'; }

command -v jq >/dev/null || {
  echo "🔔 doorbell 需要 jq：brew install jq ／ sudo pacman -S jq ／ sudo apt install jq"; exit 0; }

command -v gh >/dev/null || { emit "$(cat <<'MSG'
🔔 doorbell 需要 GitHub CLI，目前 PATH 裡找不到。

  安裝    macOS   brew install gh
          Arch    sudo pacman -S github-cli
          Debian  sudo apt install gh
          其他    https://cli.github.com

  登入    gh auth login

裝在非標準路徑的話（例如 asdf/mise shim），把它加進 PATH 再重開 session。
MSG
)"; exit 0; }

REASONS='["review_requested","assign","mention","team_mention","author"]'

if ! out=$(GH api "/notifications?all=false&per_page=100" --paginate --jq \
  ".[]|select(.reason|IN(${REASONS}[]))
   |\"- [\(.reason)] \(.repository.full_name) — \(.subject.title)\"" 2>&1); then
  if ! GH_QUICK auth status >/dev/null 2>&1; then
    emit "🔔 doorbell：gh 尚未登入。跑 \`gh auth login\` 授權後重開 session。"
  else
    emit "$(printf '🔔 doorbell：讀取 GitHub 通知失敗（已登入，可能是網路或權限）。\n\n%s\n\n手動確認：gh api /notifications' "$out")"
  fi
  exit 0
fi

# 輪詢間隔存在旗標檔裡。內容不是正整數就退回 60，免得 `sleep abc` 空轉。
INTERVAL=$(cat "$STATE_DIR/watch-enabled" 2>/dev/null | tr -dc '0-9')
case "$INTERVAL" in ''|0) INTERVAL=60 ;; esac

# 告訴模型把即時輪詢掛起來——這是 watch 能跨 session 持續的關鍵
ARM_HINT="doorbell watch 已啟用，輪詢間隔 ${INTERVAL} 秒。請立刻用 Monitor 工具掛上
（persistent: true，description \"doorbell：有人在等你\"），command 用 doorbell skill 裡
\`watch\` 那段，sleep 改成 ${INTERVAL}（含 flock，多 session 同時掛也只有一個會真的打 API）。
已經掛著就不要重複掛。"

# 同一份清單只講一次：第二個以後的 session 保持安靜，清單有變才再響。
# ponytail: 兩個 session 同時開有極小機率各響一次。加鎖不值得，最壞多看一遍。
if [ -n "$out" ]; then
  sig=$(printf '%s' "$out" | sha256sum | cut -d' ' -f1)
  if [ -r "$STATE_DIR/last-signature" ] && [ "$(cat "$STATE_DIR/last-signature")" = "$sig" ]; then
    msg=""
  else
    mkdir -p "$STATE_DIR" && printf '%s' "$sig" > "$STATE_DIR/last-signature"
    msg=$(printf '有人在等你\n%s' "$out")
  fi
else
  msg=""
fi

jq -nc --arg m "$msg" --arg c "$ARM_HINT" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}
   + (if $m == "" then {} else {systemMessage:$m} end)'
exit 0
