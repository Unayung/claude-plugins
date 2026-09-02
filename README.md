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
🔔 [review_requested] acme/api — feat: add rate limiting to public endpoints
🔔 [mention] acme/web — 這段要不要抽成 hook？
🔔 [author] acme/api — fix: retry on 502 from upstream
```

它讀 GitHub 的未讀通知，只留下真的有人找你的那幾種：
`review_requested`、`assign`、`mention`、`team_mention`、`author`。

**為什麼需要它**：GitHub 通知收件匣預設會被 CI 洗版。實測一台日常開發機累積的未讀裡，
超過 97% 是 `ci_activity`，真正有人在等你的那幾筆完全被埋掉。doorbell 把它們撈出來。

治本建議一併做：GitHub Settings → Notifications → Actions，取消勾選 workflow 通知。

## 用法

```
/doorbell           列出當下誰在等你
/doorbell watch     在這個 session 掛上即時輪詢（60 秒一次）
/doorbell unwatch   關掉
```

**doorbell 只在你叫它的那個 session 作動。** 沒有 hook、沒有旗標檔、沒有任何跨 session
狀態，所以開再多 Claude Code 也不會有 doorbell 自己冒出來。session 關掉輪詢就沒了，
下次要監看再打一次。

## singleton：全機只准一個在輪詢

第二個 session 打 `/doorbell watch` 會**被拒絕並說明**，不會偷偷排隊。

鎖在 `${XDG_STATE_HOME:-~/.local/state}/doorbell/poller.lock`，綁在 fd 上，
`kill -9`、當機、斷電都自動釋放，不會留 stale lock。

想換一個 session 收通知，明確接管：

```bash
fuser -k "${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/poller.lock"
# 然後在想要的 session 打 /doorbell watch
```

早期版本用阻塞式 `flock`，多餘的 poller 會排隊等著。那是假的 singleton——同時
只有一個在打 API，但前一個死掉時會**無聲接管**，你不知道現在是哪個視窗在收。
改成 `flock -n` 直接拒絕，寧可要明確也不要方便。

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

`gh` 裝在非標準路徑（asdf/mise shim 之類）也沒關係，doorbell 已經預先把
`~/.local/bin`、`~/bin`、`/opt/homebrew/bin` 加進 PATH。

## 間隔為什麼固定 60 秒

曾經做成可調，量完之後拿掉了。2026-09-01 實測 `/notifications` 回應標頭：

```
X-Poll-Interval: 60
Cache-Control:   private, max-age=60, s-maxage=60   ← 資料宣告 60 秒內 fresh
X-Ratelimit-Remaining 每次 -1                        ← gh api 不送 conditional request
```

調成 15 秒的實際效果是三次拿到同一份快取、延遲沒改善、額度花 4 倍。真正的延遲
瓶頸在 GitHub 端產生通知那段，不在輪詢間隔。一個量不出差別的旋鈕留著只會誤導人。

真要更低延遲得換機制——GitHub webhook 是 push 的，沒有輪詢週期，但那需要一個
GitHub 打得到的端點。60 秒輪詢就是不架 server 的代價。

## 處理完記得標已讀

訊號要從清單消失才不會一直重複出現：

```bash
gh api -X PATCH /notifications/threads/<thread_id>
```

**不要**用 `PUT /notifications` 全標已讀，那會把還沒處理的一起蓋掉。

---

## 附錄：曾經用 SessionStart hook，這是當時踩到的兩個坑

doorbell 早期版本有一個 SessionStart hook，會在開 session 時自動列出 backlog。
後來為了 singleton 與「不要有東西自己冒出來」把它移除了（見 `ee9d014`）。
但當時踩的兩個坑對任何要寫 hook 的人都還適用，留在這裡：

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
hook 沒有錯誤回報管道，安靜失敗等於沒有線索。同理 `[ -n "$x" ] && do_thing`：
條件不成立時什麼都不會發生，而「什麼都沒發生」看起來跟成功一樣。

## License

MIT
