# claude-plugins

Chen Chia Yang 的 Claude Code plugin marketplace。

```
/plugin marketplace add Unayung/claude-plugins
/plugin install doorbell@unayung
```

---

# doorbell

告訴你**誰在等你**。

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

## 用法

**預設完全不作動。** 裝了之後開 session 一行都不跑（實測 0.002 秒——旗標不在就在第一行退出，
連 PATH 都不碰）。

```
/doorbell             列出當下誰在等你（隨時可用，不受開關影響）
/doorbell watch       開啟即時輪詢，60 秒一次
/doorbell watch 15    改成 15 秒一次
/doorbell unwatch     關掉，回到完全不作動
```

`watch` 開一次就好。之後每個新 session 的 SessionStart hook 會看到旗標，
自動把即時輪詢掛回來，間隔也沿用，不用重打。

間隔存在旗標檔內容裡，不是正整數就當 60。

**低於 60 秒多半沒有用。** 2026-09-01 實測 `/notifications` 的回應標頭：

```
X-Poll-Interval: 60
Cache-Control:   private, max-age=60, s-maxage=60   ← 資料宣告 60 秒內 fresh
X-Ratelimit-Remaining 每次 -1                        ← gh api 不送 conditional request
```

15 秒去打的結果是三次拿到同一份快取、延遲沒改善、額度花 4 倍（240 次/小時 vs 60，
上限 5000）。真正的延遲瓶頸在 GitHub 端產生通知那段，不在輪詢間隔。參數留著給你調，
但預設 60 是有根據的。

## 需求

`gh`（GitHub CLI）與 `jq`，且 `gh` 已登入。

```bash
brew install gh              # macOS
sudo pacman -S github-cli    # Arch
sudo apt install gh          # Debian/Ubuntu
# 其他平台：https://cli.github.com

gh auth login
gh auth status               # 確認
```

開啟後若缺任何一項，doorbell 會**明講缺什麼、該跑哪個指令**，不會安靜跳過，
也不會擋住你開 session——所有 `gh` 呼叫都有硬性 timeout，最壞 13 秒。
（沒授權時 `gh` 會等互動輸入，實測能卡滿兩分鐘，所以這個 timeout 是必要的。）

`gh` 裝在非標準路徑（asdf/mise shim 之類）也沒關係，doorbell 已經預先把
`~/.local/bin`、`~/bin`、`/opt/homebrew/bin` 加進 PATH。

## 開多個 session 不會被吵兩次

三層各管各的：

| 情況 | 機制 |
|---|---|
| 同一份 backlog 在多個 session 重複出現 | 內容雜湊——一樣就不講 |
| 多個 session 同時輪詢同一個 API | `flock`——只有一個真的打 API |
| 處理完的通知還一直冒出來 | `gh api -X PATCH /notifications/threads/<id>` |

雜湊用內容而不是「N 分鐘內不重複」，是因為前者不需要調魔術數字，而且隔天早上打開時
backlog 沒變本來也不該再提醒一次。

`flock` 用阻塞版而不是 `-n || exit`：其餘 session 安靜等在鎖上，持鎖那個一關就立刻接手，
沒有空窗。鎖綁在 fd 上，`kill -9` 或當機都自動釋放，不會留 stale lock。

## 狀態

`${XDG_STATE_HOME:-~/.local/state}/doorbell/`

| 檔案 | 用途 |
|---|---|
| `watch-enabled` | 開關旗標。不存在 = 完全不作動；內容 = 輪詢秒數 |
| `last-signature` | 上次講過的清單雜湊。刪掉可強制再看一次 |
| `poller.lock` | flock 用 |

---

## 附錄：寫 SessionStart hook 的兩個坑

做這支的時候各花了好幾輪，都是「看起來像沒安裝」的靜默失敗：

**1. hook 不繼承你互動 shell 的 PATH。**
`gh` 常裝在 `~/.local/bin`，hook 環境裡沒有那段，`command -v gh` 直接找不到。

```bash
export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:$PATH"
```

**2. SessionStart hook 的純 stdout 不會顯示給使用者。**
它只進模型 context。給人看要 `systemMessage`，給模型看要 `hookSpecificOutput.additionalContext`：

```bash
jq -nc --arg m "$msg" --arg c "$ctx" \
  '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
```

兩個坑疊在一起的症狀完全相同——開 session 什麼都沒有——而且跟「plugin 根本沒載入」也長得一樣。

**排查順序**：
1. `claude plugin list` / `claude plugin details <p>` — hook 有沒有被註冊
2. 腳本裡寫一行**無條件的落地 log**（寫檔，不是 stdout）— 有沒有被執行
3. 前兩項都過就是輸出格式問題

另外別寫防禦性的 `|| exit 0`。缺依賴、沒登入、清單為空，每種都給不同訊息——
hook 沒有錯誤回報管道，安靜失敗等於沒有線索。

## License

MIT
