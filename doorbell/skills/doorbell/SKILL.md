---
name: doorbell
description: 查看或持續監看誰在等你 —— GitHub 上 request review / assign / mention / 你自己 PR 的新回覆。用在使用者說「誰在等我」「有什麼要 review」「盯著收件匣」「/doorbell」時。預設列出當下清單；watch [秒數] 開啟即時輪詢並記住設定（預設 60 秒）；unwatch 關掉。
---

# doorbell

doorbell 的 SessionStart hook **預設完全不作動**。要開啟得 opt in，開一次就記住。

狀態目錄：`${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/`
- `watch-enabled` — 旗標檔。存在 = hook 會作動並要求掛輪詢。**內容是輪詢秒數**，
  空的或不是正整數就當 60
- `last-signature` — 上次講過的清單雜湊，用來避免多個 session 重複提示

## 預設：現在列出來

不管旗標開沒開，明確呼叫一律直接查並回答。

```bash
gh api "/notifications?all=false&per_page=100" --paginate --jq \
  '.[]|select(.reason|IN("review_requested","assign","mention","team_mention","author"))
    |"- [\(.reason)] \(.repository.full_name) — \(.subject.title)\n  \(.subject.url)"'
```

`subject.url` 是 API 網址。要給人點的連結把 `api.github.com/repos/X/pulls/N`
轉成 `github.com/X/pull/N`，或用 `gh pr view <n> -R <repo> --web`。

清單空的就直接說沒有，不要編。

## `watch [秒數]`：開啟即時輪詢（會記住）

`/doorbell watch` 用預設 60 秒，`/doorbell watch 15` 就是 15 秒一次。
沒帶數字一律當 60（會覆蓋掉先前設定的值）。

```bash
N=60   # 使用者有給數字就用他的
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/doorbell"
echo "$N" > "${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/watch-enabled"
```

參數不是正整數（打錯字、負數、0）就別寫進去，直接跟使用者說一聲並用 60。

**低於 60 秒要提醒一次**：GitHub 的 `X-Poll-Interval` 對 `/notifications` 的建議下限
就是 60 秒。實務上 conditional request 回 304 不計 rate limit，所以通常沒事，但這是
超出官方建議值的用法，被限流不要意外。低於 10 秒就直接勸退。

然後**立刻**用 Monitor 工具掛上（不要只寫旗標就結束，這個 session 也要生效）：

```
Monitor({
  command: '<下面那段>',
  description: 'doorbell：有人在等你',
  persistent: true
})
```

```bash
# flock：同時只有一個 session 真的在輪詢。其餘的安靜卡在鎖上（kernel wait，
# 不吃 CPU、不發事件），持鎖那個一關就立刻接手，沒有空窗。
# 鎖綁在 fd 上，process 被 kill -9 或當機也會自動釋放，不會留 stale lock。
exec 9>"${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/poller.lock"
flock 9

last=$(date -u +%Y-%m-%dT%H:%M:%SZ)
while true; do
  gh api "/notifications?since=$last&all=false&per_page=50" --jq \
    '.[]|select(.reason|IN("review_requested","assign","mention","team_mention","author"))
      |"[\(.reason)] \(.repository.full_name) — \(.subject.title)"' \
    || echo "⚠️ doorbell: gh notifications 失敗"
  last=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sleep "$N"      # 換成實際秒數
done
```

在幾個 session arm 都無所謂，flock 保證只有一個真的打 API。

**注意**：接手的可能是使用者三天前開著沒關的 session，通知會跑到他沒在看的視窗。
真的困擾就 TaskStop 掉再在想要的 session 重 arm。

之後每個新 session 的 hook 會看到旗標，在 `additionalContext` 裡告訴你間隔幾秒、
要求把輪詢掛回來——所以使用者只需要 opt in 一次，間隔也會沿用。

**改間隔**：再跑一次 `/doorbell watch <新秒數>`。記得先 TaskStop 掉這個 session
舊的那個 Monitor，不然會有兩個（雖然 flock 擋著只有一個真的在打，但舊的拿著鎖
不會放，新間隔不會生效）。

## `unwatch` / `stop`：關掉

```bash
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/watch-enabled"
```

同時用 TaskStop 停掉這個 session 正在跑的 doorbell Monitor（如果有）。
之後的 session 就完全不作動。

## 處理完要標已讀

訊號要從清單消失才不會一直重複出現：

```bash
gh api -X PATCH /notifications/threads/<thread_id>
```

`thread_id` 從上面查詢加 `.id` 取得。**不要**用 `PUT /notifications` 全標已讀——
那會把還沒處理的一起蓋掉。

## 認領任務

```bash
gh issue edit <n> -R <repo> --add-assignee <me> && \
gh issue view <n> -R <repo> --json assignees --jq '.assignees[].login'
```

第二段是 read-back。GitHub 允許多 assignee，兩個人同時認領會兩個都在，
回讀發現不只自己就要按事先講好的規則退讓。
