# claude-plugins

Chen Chia Yang 的 Claude Code plugin marketplace。

## 安裝

```
/plugin marketplace add Unayung/claude-plugins
/plugin install doorbell@unayung
```

## doorbell

開 session 時告訴你**誰在等你**。

```
## 有人在等你
- [review_requested] acme/api — feat: add rate limiting to public endpoints
- [mention] acme/web — 這段要不要抽成 hook？
- [author] acme/api — fix: retry on 502 from upstream
```

它讀 GitHub 的未讀通知，只留下真的有人找你的那幾種：
`review_requested`、`assign`、`mention`、`team_mention`、`author`。

**為什麼需要它**：GitHub 通知收件匣預設會被 CI 洗版。實測一台日常開發機累積的未讀裡，
超過 97% 是 `ci_activity`，真正有人在等你的那幾筆完全被埋掉。doorbell 把它們撈出來。

治本建議一併做：GitHub Settings → Notifications → Actions，取消勾選 workflow 通知。

### 需求

`gh`（GitHub CLI）與 `jq`，且 `gh` 已登入。

```bash
# 安裝 gh
brew install gh              # macOS
sudo pacman -S github-cli    # Arch
sudo apt install gh          # Debian/Ubuntu
# 其他平台：https://cli.github.com

# 登入
gh auth login

# 確認
gh auth status
```

缺任何一項，doorbell **會在開 session 時明講缺什麼、該跑哪個指令**，不會安靜跳過，
也不會擋住你開 session（所有 gh 呼叫都有硬性 timeout，最壞 13 秒）。

`gh` 裝在非標準路徑（asdf/mise shim 之類）的話，doorbell 已經預先把
`~/.local/bin`、`~/bin`、`/opt/homebrew/bin` 加進 PATH；還是找不到就自己補。

### 同一份清單只講一次

開第二、第三個 session 不會再重複同一份清單。doorbell 記住上次講過的內容雜湊，
只有清單真的變了（有新的進來、或你標了已讀）才再響。

用內容雜湊而不是「N 分鐘內不重複」，是因為前者不需要調一個魔術數字，
而且隔天早上打開時如果 backlog 沒變，本來也不需要再被提醒一次。

狀態存在 `~/.local/state/doorbell/last-signature`（尊重 `XDG_STATE_HOME`）。
想強制再看一次就刪掉它，或直接用 `/doorbell`——skill 是直接查，不受這個影響。

### `/doorbell` skill

hook 只在開 session 時查一次。session 中途要重查、或要掛即時推播，用 skill：

```
/doorbell           列出當下誰在等你
/doorbell watch     掛一個 Monitor 持續輪詢（只在一個 session 掛）
```

skill 裡也寫了標已讀和認領任務的正確做法（含多人同時認領的 read-back）。

### 想要即時推播？

doorbell 只在開 session 時查一次（pull）。要在工作中被通知，自己 arm 一個 Monitor
輪詢同一個 API——但**只在一個 session arm**，每個 session 都 arm 只會拿到 N 份重複通知。

```bash
last=$(date -u +%Y-%m-%dT%H:%M:%SZ)
while true; do
  gh api "/notifications?since=$last&all=false&per_page=50" --jq \
    '.[]|select(.reason|IN("review_requested","assign","mention","team_mention","author"))
      |"[\(.reason)] \(.repository.full_name) — \(.subject.title)"' \
    || echo "⚠️ gh notifications 失敗"
  last=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sleep 60
done
```

處理完記得標已讀，訊號才會從清單消失：

```bash
gh api -X PATCH /notifications/threads/<thread_id>
```

## License

MIT

## 寫 SessionStart hook 的兩個坑

做這支的時候各花了好幾輪才找到，都是「看起來像沒安裝」的靜默失敗：

**1. hook 不繼承你互動 shell 的 PATH。**
`gh` 常裝在 `~/.local/bin`，hook 環境裡沒有那段，`command -v gh` 直接找不到。
腳本開頭要自己補：

```bash
export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:$PATH"
```

**2. SessionStart hook 的純 stdout 不會顯示給使用者。**
它只進模型 context。要讓人看到必須輸出 JSON 帶 `systemMessage`：

```bash
jq -nc --arg m "$msg" '{systemMessage:$m}'
```

兩個坑疊在一起的症狀完全相同——開 session 什麼都沒有——而且跟「plugin 沒載入」也長得一樣。
排查順序：`claude plugin list` / `details` 確認有註冊 → 腳本裡寫一行無條件的落地 log
確認有沒有被執行 → 都有的話就是輸出格式問題。
