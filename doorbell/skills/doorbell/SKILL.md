---
name: doorbell
description: 查看或持續監看誰在等你 —— GitHub 上 request review / assign / mention / 你自己 PR 的新回覆。用在使用者說「誰在等我」「有什麼要 review」「盯著收件匣」「/doorbell」時。預設列出當下清單；watch 在這個 session 掛上即時輪詢（全機只准一個）；unwatch 關掉。
---

# doorbell

doorbell **只在被呼叫的 session 作動**，不留任何跨 session 狀態：沒有 hook、
沒有旗標檔，也不會自己在新 session 掛回來。要監看就在那個 session 打 `/doorbell watch`。

**全機同時只准一個輪詢在跑。** 見下方 singleton 一節。

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

**這裡刻意不套 `watch` 的 author 過濾。** watch 是推播、重精確（不吵人）；
這裡是使用者主動問、重召回（不漏）。兩條路不對稱是設計，不是遺漏——
watch 那道過濾在「留言之後緊接著有 push」時會蓋掉那則留言，用這個指令補得回來。

## `watch`：在這個 session 掛上即時輪詢

只影響當下這個 session。關掉視窗、session 結束，輪詢就跟著沒了——
下次要監看再打一次 `/doorbell watch`。

### 先檢查有沒有別的在跑

arm 之前先探一次，這樣能直接告訴使用者狀況，而不是掛一個馬上自己退出的 Monitor：

```bash
LOCK="${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/poller.lock"
mkdir -p "${LOCK%/*}"
if ( exec 9>"$LOCK"; flock -n 9 ); then
  echo "沒有其他 doorbell 在跑，可以 arm"
else
  echo "已有 doorbell 在別的 session 跑"
fi
```

**已經有的話就不要 arm**，把狀況講給使用者聽，並告訴他接管的方式（見下方 singleton）。

### 間隔固定 60 秒，不要做成可調

2026-09-01 實測 `/notifications` 回應標頭：`Cache-Control: private, max-age=60`
（資料宣告 60 秒內 fresh）、`X-Poll-Interval: 60`，且 `gh api` 不送 conditional
request 所以每次實扣額度。調更短只會拿到同一份快取、延遲不變、額度多花數倍。
使用者要求調快就把這段講給他聽。

### arm

```
Monitor({
  command: '<下面那段>',
  description: 'doorbell：有人在等你',
  persistent: true
})
```

```bash
LOCK="${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/poller.lock"
mkdir -p "${LOCK%/*}"
exec 9>"$LOCK"

# singleton：拿不到鎖就直接退出，不排隊。
# 用 -n 而不是阻塞版是刻意的——阻塞會讓多餘的 poller 埋伏著，前一個死掉就
# 無聲接管，使用者無從知道現在是哪個 session 在收通知。
flock -n 9 || {
  echo "🔔 doorbell 已在另一個 session 執行，這裡不啟動。"
  echo "   要把它接管過來：fuser -k \"$LOCK\" 之後在這裡重打 /doorbell watch"
  exit 0
}

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
    # author 這一類要多一道：`latest_comment_url` 等於 subject.url 代表最後動作
    # 不是留言（merge / push / CI 狀態），純噪音。實測未讀 24 筆裡 22 筆是這種。
    #
    # ⚠️ 不要再加「跳過 bot 帳號」那一層。codex-review / post-review 都是
    # github-actions[bot]，而它們貼的是 P1 findings —— 2026-09-02 差點把兩個
    # P1（清空工具綁定、缺 confirm 的破壞性頻道解綁）濾掉。降噪要看內容不看來源。
    awk 'f{print} /^\r?$/{f=1}' "$resp" \
      | jq -r ".[]|select(.reason|IN(${REASONS}[]))
               |select(.reason != \"author\"
                       or (.subject.latest_comment_url != null
                           and .subject.latest_comment_url != .subject.url))
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

## singleton：全機只准一個

鎖是 `${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/poller.lock`，綁在 fd 上，
所以 process 被 `kill -9`、當機、斷電都會自動釋放，不會留 stale lock。

- 第二個 session 打 `/doorbell watch` → **拒絕啟動並說明**，不排隊、不埋伏
- 想換到別的 session 收通知 → 明確接管，兩步：

```bash
fuser -k "${XDG_STATE_HOME:-$HOME/.local/state}/doorbell/poller.lock"
# 然後在想要的 session 打 /doorbell watch
```

沒有 hook、沒有旗標檔，所以開再多 session 都不會有 doorbell 自己冒出來。

## `unwatch` / `stop`：關掉

用 TaskStop 停掉這個 session 的 doorbell Monitor。沒有別的狀態要清。

不在這個 session 的話用 `fuser -k` 那行。

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
