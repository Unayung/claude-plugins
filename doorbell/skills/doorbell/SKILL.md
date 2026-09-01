---
name: doorbell
description: 查看或持續監看誰在等你 —— GitHub 上 request review / assign / mention / 你自己 PR 的新回覆。用在使用者說「誰在等我」「有什麼要 review」「盯著收件匣」「/doorbell」時。預設列出當下清單；帶 watch 會掛一個持續輪詢的 Monitor。
---

# doorbell

doorbell 的 SessionStart hook 只在開 session 時查一次。這個 skill 補兩件 hook 做不到的事：
session 中途重查，以及即時推播。

## 預設：現在列出來

```bash
gh api "/notifications?all=false&per_page=100" --paginate --jq \
  '.[]|select(.reason|IN("review_requested","assign","mention","team_mention","author"))
    |"- [\(.reason)] \(.repository.full_name) — \(.subject.title)\n  \(.subject.url)"'
```

`subject.url` 是 API 網址，要給使用者點的連結用 `gh pr view <n> -R <repo> --web` 或把
`api.github.com/repos/X/pulls/N` 轉成 `github.com/X/pull/N`。

清單空的就直接說沒有，不要編。

## `watch`：掛即時推播

使用者說「盯著」「watch」「有人找我就告訴我」時，用 Monitor 工具：

```
Monitor({
  command: '<下面那段輪詢迴圈>',
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
  sleep 60
done
```

arm 之前先建目錄：`mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/doorbell"`。

上面的 `flock` 讓「只在一個 session arm」變成強制而不是建議——在幾個 session 裡
arm 都無所謂，只有一個會真的輪詢。GitHub 的 `X-Poll-Interval` 下限是 60 秒，別調更短。

**注意**：接手的可能是你三天前開著沒關的 session，通知會跑到你沒在看的視窗。
真的困擾就 TaskStop 掉再在想要的 session 重 arm。

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
