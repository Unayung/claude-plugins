---
name: doorbell
description: 查看或持續監看誰在等你 —— GitHub 上 request review / assign / mention / 你自己 PR 的新回覆。用在使用者說「誰在等我」「有什麼要 review」「盯著收件匣」「/doorbell」時。預設列出當下清單；watch 在這個 session 掛上即時輪詢；unwatch 關掉。
---

# doorbell

doorbell **只在被呼叫的 session 作動**，不留任何跨 session 狀態：沒有 hook、
沒有旗標檔，也不會自己在新 session 掛回來。要監看就在那個 session 打 `/doorbell watch`。

## 預設：現在列出來

明確呼叫一律直接查並回答。

```bash
gh api "/notifications?all=false&per_page=100" --paginate --jq \
  '.[]|select(.reason|IN("review_requested","assign","mention","team_mention","author"))
    |"- [\(.reason)] \(.repository.full_name) — \(.subject.title)\n  \(.subject.url)"'
```

`subject.url` 是 API 網址。要給人點的連結把 `api.github.com/repos/X/pulls/N`
轉成 `github.com/X/pull/N`，或用 `gh pr view <n> -R <repo> --web`。

清單空的就直接說沒有，不要編。

## `watch`：在這個 session 掛上即時輪詢

只影響當下這個 session。關掉視窗、session 結束，輪詢就跟著沒了——
下次要監看再打一次 `/doorbell watch`。

**間隔固定 60 秒，不要做成可調。** 2026-09-01 實測 `/notifications` 回應標頭：
`Cache-Control: private, max-age=60`（資料宣告 60 秒內 fresh）、`X-Poll-Interval: 60`、
且 `gh api` 不送 conditional request 所以每次實扣額度。調更短只會拿到同一份快取、
延遲不變、額度多花數倍。使用者要求調快就把這段講給他聽。

用 Monitor 工具掛上：

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

export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:$PATH"
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
REASONS='["review_requested","assign","mention","team_mention","author"]'

# 下一輪的 since 用「回應的 Date 標頭」而不是本地 date。用本地時鐘有兩個漏洞：
#   1. 空窗：API 回應產生後、本地取時間前落地的通知，下一輪的 since 會跳過它
#   2. 時鐘偏移：本機比 GitHub 快的話，快多少就漏多少
# 退 1 秒是因為 since 是嚴格大於；代價是邊界上偶爾重複一則，比漏掉好。
since=$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)

while true; do
  resp=$(mktemp)
  if timeout 30 gh api -i "/notifications?since=$since&all=false&per_page=50" > "$resp" 2>&1; then
    awk 'f{print} /^\r?$/{f=1}' "$resp" \
      | jq -r ".[]|select(.reason|IN(${REASONS}[]))
               |\"🔔 [\(.reason)] \(.repository.full_name) — \(.subject.title)\""
    # 只有成功才推進 since。失敗就保留原值，下一輪重查同一個區間，不會漏。
    # 用 sed 不用 grep：某些環境的 grep 對 -im1 這種合併短選項會炸
    # （實測 "unknown option '-G'"），而且是靜默的——d 變空、since 永遠不前進。
    d=$(sed -n 's/^[Dd]ate: *//p' "$resp" | head -1 | tr -d '\r')
    if [ -n "$d" ]; then
      since=$(date -u -d "$d - 1 second" +%Y-%m-%dT%H:%M:%SZ)
    else
      # 抽不到就要吵。靜默不前進 = 每輪重掃同一區間，看起來一切正常但其實壞了。
      echo "⚠️ doorbell: 取不到回應的 Date 標頭，since 未前進（仍為 $since）"
    fi
  else
    echo "⚠️ doorbell: gh notifications 失敗，保留 since=$since 下輪重查"
  fi
  rm -f "$resp"
  sleep 60
done
```


在幾個 session arm 都無所謂，flock 保證只有一個真的打 API。

**注意**：接手的可能是使用者三天前開著沒關的 session，通知會跑到他沒在看的視窗。
真的困擾就 TaskStop 掉再在想要的 session 重 arm。

## `unwatch` / `stop`：關掉

用 TaskStop 停掉這個 session 的 doorbell Monitor。沒有別的狀態要清。

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
