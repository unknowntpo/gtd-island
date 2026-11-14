# GTD Island POC Spec

## Intent
在不切換 app 的情況下,回答「現在從哪開始」,並跳到對應工作。

## Example
使用者把滑鼠移到膠囊上,或按住 Option 再按 G。面板只列 3 件事。第一件是 Deadline 最近的 Project。
使用者切到自己設定的「工作」分頁,看到這個分頁的 Project 和下一步,等別人的項目在下方。
使用者按 `1`,面板收起,並打開該 Project 的 session 或 Notion 頁面。

## Scope
- 資料來源:Notion 的 `Projects 下一步` view。面板對 GTD 的寫入只有 AC31 的「延後」。
- 不做:agent 通信、卡點欄位、批准工具呼叫、拆小 Action。

## Acceptance
- AC1 可動手的項目排序:14 天內未過期的 Deadline 最優先,再來是 This Week,再依 Priority、Last Worked。
- AC2 「先看這 3 件」最多 3 項,不含等別人的項目。
- AC3 `Next Action` 以「等」開頭,或 `Waiting For` 有值,就算等別人。
- AC4 分頁來自 `~/.gtd-island/config.json` 的 `tabs`,見「分頁設定檔」。
- AC5 跳轉目標依序是:(1) Project 的 `Owner Session`;(2) 開著的子 Action 中,標題等於 Project `Next Action` 的那一個的 `Owner Session`;(3) 該 Action 的 Notion 頁面;(4) Project 的 Notion 頁面。「開著」指 `GTD Status` 不是 Done 或 Dropped。按鈕依目標顯示「打開 session ↗」「打開 Action ↗」或「打開 Notion ↗」。
  Example:Project「發布 1.0」沒有 `Owner Session`,`Next Action` 是「寫發布說明」。它的子 Action「寫發布說明」的 `Owner Session` 是 `claude://claude.ai/epitaxy/local_7`。面板顯示「打開 session ↗」,點擊打開 local_7。子 Action 改名成「寫 changelog」後,面板改顯示「打開 Notion ↗」,點擊打開 Project 頁面。
- AC6 快照超過 5 分鐘算過期,展開時自動更新;更新失敗時保留舊資料並顯示錯誤。
- AC7 真實格式的 view 資料可以解析,多餘欄位不影響。
- AC8 面板懸浮在其他視窗上,打開時不搶走目前 app 的焦點;滑鼠移到膠囊上或點擊就展開,Option+G 切換,`Esc` 或點外面收起,數字鍵跳轉。
- AC28 拖曳膠囊,或拖曳展開面板分頁列的空白處和右端的把手,可以移動面板。移動超過 3 點才算拖曳,否則照常是點擊。放開後位置存起來,重開 app 後保留。
- AC29 位置以膠囊上緣的中點為準:面板展開時,上緣中點對齊這一點,再往下長。面板超出這一點所在螢幕的可見範圍時,往內推到剛好留在範圍內。
- AC30 沒存過位置,或存的點不在任何螢幕上時,用預設位置:主螢幕可見範圍上緣置中、往下 4 點。
  Example:使用者把膠囊拖到螢幕右上角,讓開 Chrome 的網址列。滑鼠移上去,面板向下展開,右緣貼齊螢幕右緣,不會超出。重開 app 後,膠囊還在右上角。外接螢幕拔掉後,膠囊回到主螢幕上緣中央。
- AC31 有「本週」標記的列多一個「延後」按鈕。按下後,面板執行 `refresh.py --postpone <頁面 id>`:它透過 Notion API 把該 Project 的 `This Week` 改成未勾選,再照 AC22 同步快照。成功後該列依 AC1 重新排序;失敗時快照不變,面板顯示錯誤。按「延後」不會打開該列。
- AC32 `--postpone` 只走 Notion API。沒有 token、頁面 id 不是 32 位十六進位、或 API 失敗時,`refresh.py` 不改快照,結束碼不是 0。
  Example:「先看這 3 件」第 2 件是「整理閱讀筆記」,有「本週」標記。使用者按它的「延後」。Notion 上它的 `This Week` 變成未勾選,幾秒後清單重排,原本第 4 件補上第 2 件。
- AC9 macOS Keychain 有 `gtd-island-notion` token 時,`refresh.py` 直接呼叫 Notion API 查 GTD Items:`Item Type` 是 Project 且 `GTD Status` 是 Active,依 `Last Worked` 新到舊,讀完所有分頁。輸出的欄位名稱和格式與原本的 view 資料相同。
- AC10 沒有 token 或 API 失敗時,`refresh.py` 改走原本的 `claude` 路徑。token 不寫進檔案或輸出。
- AC27 有 token 時,`refresh.py` 另外查開著的 Action(`Item Type` 是 Action,`GTD Status` 不是 Done 也不是 Dropped),寫進快照的 `actions`。每筆含標題、頁面、`Owner Session`、`GTD Status` 和 `Parent Project` 的頁面 id。這個查詢失敗時 `actions` 是 null,Project 列照常更新,跳轉只用 AC5 的 (1) 和 (4)。

### 找 session prototype(2026-11-04)
> 2026-11-14:AC11、AC13 由「搜尋框」一節的 AC52–AC58 取代。「找 session」分頁和 Option+J 已移除。AC12 的比對方式和 AC14 的模型程序沿用,改由搜尋框使用。
目的:先看效果,再決定細節。使用者輸入一句話,相關的 session 要列在上方。排名不必精準。
Example:使用者按 Option+J,輸入「上週修到一半的登入錯誤」。清單前 5 列都是登入相關的 session,例如 `修登入錯誤(接手)`、`登入流程重構`。使用者按 ⌘1 打開第 1 列。
- AC11 Option+J 展開面板、切到「找 session」分頁,文字框取得鍵盤焦點。其他方式打開面板時,文字框不自動取得焦點。
- AC12 輸入後列出 5 個最相關的 session。候選排除已封存和排程產生的 session。分數是本機 `multilingual-e5-small` 的標題相似度,加上句子與標題的共同字詞加分。查詢不傳出這台 Mac。
- AC13 Enter 打開第 1 列;⌘1–5 或點擊打開對應的列。在這個分頁,數字鍵輸入文字,不跳轉。
- AC14 模型程序只在這個分頁使用時執行,面板收起時結束。模型無法使用時,面板顯示錯誤,其他分頁不受影響。
- 這個 prototype 不做:語音內建、把原文存進 Inbox、用 Next Action 內容比對。

### GTD 動態長條圖(2026-11-05 改成分鐘數)
目的:使用者看一眼就知道最近 7 天的時間怎麼分配到各 Area。資料是 Notion 的 `Time Log`,不是 GTD Items 的項數。
Example:使用者打開「動態」分頁,看到依 Area 分類的長條,`Side Project` 最長,長條旁只有類別名稱。長條的亮色部分是今天。滑鼠移到 `Side Project`,下方顯示「2 小時 30 分 · 40% · 今天 1 小時」和 `Entry` 標題。
- AC15 動態資料是 `Date` 開始日落在今天和前 6 天、`Minutes` 大於 0 的 `Time Log` 列。一列的分鐘數全部算在開始日。沒有 Area 的列歸到「未分類」。
- AC16 每個 Area 一條長條,依分鐘數由多到少排列。沒 hover 時只顯示類別名稱和長條,不顯示數字。hover 時顯示總時間、占 7 天總時間的比例、今天的時間,和最多 6 個 `Entry` 標題,今天的在前面,同一天分鐘數多的在前面。
- AC17 `refresh.py` 只在 Notion API 路徑抓 `Time Log`,存進同一份快照的 `timeLog`。查詢失敗或沒有 token 時,Project 清單照常更新,「動態」分頁顯示沒有資料的原因。

### 可設定的第 3 格(2026-11-04)
目的:前 3 名都屬於同一個分頁時,另一個分頁仍有位置。第 3 格固定給誰由使用者選。
Example:前 3 名都屬於同一個分頁。使用者在「先看這 3 件」底部選「閱讀」。第 3 格換成排名最高的可動手「閱讀」項目,前 2 格不變。之後使用者選「不固定」,面板回到原本的前 3 名。
- AC18 第 3 格設定為某個分頁時,如果該分頁有可動手的項目,而且前 3 名都不屬於該分頁,第 3 格換成該分頁排名最高的項目。前 2 格不變。
- AC19 設定為「不固定」、該分頁沒有可動手的項目,或前 3 名已有該分頁的項目時,顯示原本的前 3 名。
- AC20 選項是設定檔的分頁、其他、不固定,只顯示在「先看這 3 件」分頁。選擇在重開面板後保留。使用者從未選過時,用設定檔的 `thirdSlot`;沒有這個值就是不固定。儲存的分頁已不在設定檔時,也是不固定。其他分頁和膠囊不受影響。

### 動態自動同步(2026-11-05)
目的:`Time Log` 有新的列後,使用者不用按「重新整理」就看得到。
Example:使用者打開「動態」分頁,面板立刻同步。使用者留在這個分頁,`Time Log` 新增一列 `Side Project` 30 分鐘,1 分鐘內 `Side Project` 的長條變長。使用者切走或收起面板後,面板停止這個同步。
- AC21 切到「動態」分頁時立刻同步一次,留在這個分頁時每 60 秒同步一次。切到其他分頁或收起面板後停止。
- AC22 這個同步只走 Notion API。沒有 token 或 API 失敗時,不呼叫 `claude`、不改快照,面板顯示舊資料和錯誤。「重新整理」按鈕和展開面板時的同步維持 AC9、AC10。

### 分頁設定檔(2026-11-05)
目的:分頁屬於使用者的 GTD 分類,不屬於程式碼。公開程式碼時不會公開使用者的工作分類,別人也能用自己的分類。
Example:`config.json` 有 `"tabs": [{"name": "工作", "areas": ["Client Work"]}, {"name": "閱讀", "areas": ["Reading"], "titlePrefixes": ["讀書會"], "linkContains": ["reading-notes"]}]`。面板的分頁列是「先看這 3 件、動態、工作、閱讀、其他、找 session」。Area 是 `Client Work`、標題以 `讀書會` 開頭的 Project 顯示在「閱讀」。
- AC23 每個分頁有 `name`,以及可省略的 `areas`、`titlePrefixes`、`linkContains`。分頁列依序是:先看這 3 件、等你(AC36)、動態、設定檔的分頁(依檔案順序)、其他。
- AC24 Project 的分頁依序決定:任一分頁的 `titlePrefixes` 符合標題,或 `linkContains` 符合 `Worktree`、`Source URL`;再來是 `areas` 符合 Area;都不符合就是「其他」。同一步有多個分頁符合時,取檔案中較前面的分頁。
- AC25 檔案不存在、無法解析或沒有 `tabs` 時,只顯示固定分頁,所有 Project 在「其他」。`name` 是空字串、與固定分頁同名或與前面分頁同名的分頁會被忽略。
- AC26 面板只在啟動時讀設定檔。改設定檔後要重開面板。

### 等你的 session 和瀏海外觀(2026-11-13)
目的:使用者不用逐個翻 session,就知道哪些 session 在等自己。面板改成貼在螢幕上緣的瀏海,不擋瀏覽器的網址列。這是取代 CodeIsland 的第一階段;在瀏海裡核准權限和回答選項不在這一階段。
Example:使用者同時開 3 個 session。「發布 1.0」問了一個選項題,「整理測試」做完一輪。瀏海左邊顯示「2 等你」。使用者打開「等你」分頁,第 1 列是「發布 1.0 · 有問題要你回答」,第 2 列是「整理測試 · 做完了」。使用者按 `1`,桌面 app 跳到「發布 1.0」。使用者回答後,這一列消失,瀏海顯示「1 等你」。
- AC33 `attention.py` 是 Claude Code 的 hook。它從 stdin 讀一個 hook 事件,寫入或刪除 `~/.gtd-island/attention/<session_id>.json`。檔案內容有 `sessionId`、`cwd`、`state`、`message`、`at`(UTC ISO 8601,精確到毫秒)。
- AC34 事件對應:`PreToolUse` 的工具是 `AskUserQuestion` 時,寫入 `state = "needsYou"`,`message` 是第一個問題。`Notification` 寫入 `needsYou`,`message` 是通知文字;但閒置提醒(`notification_type` 是 `idle_prompt`)在已有紀錄時不改紀錄。`Stop` 寫入 `state = "done"`。`UserPromptSubmit` 和 `SessionEnd` 刪除檔案。`PostToolUse` 在紀錄是 `needsYou` 時刪除檔案,因為工具已經執行,代表使用者已經回應。已知限制:同時執行多個工具時,另一個工具先完成也會刪掉紀錄。
- AC35 `attention.py` 只用 Python 標準函式庫,不依賴 macOS。它永遠以結束碼 0 結束。除了 AC44、AC45 使用者在面板做的決定,它不輸出任何文字,所以不會改變 session。無法解析的輸入、沒有 `session_id`、或 `session_id` 含有英數字和 `-`、`_` 以外的字元時,它什麼都不做。
- AC36 面板的分頁列在「先看這 3 件」後面加上固定分頁「等你」。「等你」列出 attention 資料夾的紀錄:`needsYou` 在前,`done` 在後,同一種依 `at` 新到舊。每列顯示 session 標題、原因(有 `message` 時顯示它;否則 `needsYou` 顯示「等你回覆」,`done` 顯示「做完了」)、資料夾名稱、距今多久。
- AC37 標題和跳轉來自桌面 app 的 session 紀錄:`cliSessionId` 等於 `sessionId` 的那一筆。有這筆時,標題是它的 `title`,點擊或按數字鍵打開 `claude://claude.ai/epitaxy/<它的 sessionId>`。沒有這筆時(終端機的 session),標題是 `cwd` 的資料夾名稱,列上顯示「在終端機」,不能跳轉。
- AC38 以下紀錄不列出:`at` 超過 7 天;桌面 app 紀錄已封存;桌面 app 紀錄的 `lastFocusedAt` 晚於 `at`(使用者已經看過)。
- AC39 收起時,面板貼齊螢幕上緣,畫成黑色、上緣平直、下方圓角的瀏海。有瀏海的螢幕上,內容放在瀏海兩側,不放在瀏海底下。左側顯示「N 等你」(N 是 AC36 的列數,0 時不顯示),右側顯示第一個下一步。面板每 3 秒重讀 attention 資料夾。
- AC40 這一節取代 AC29、AC30 的「可見範圍」:範圍改成可見範圍往上延伸到螢幕上緣(含選單列)。預設位置是主螢幕上緣置中,不留空隙。拖曳和儲存位置照 AC28。
- AC42 滑鼠離開展開的面板 0.4 秒後,面板收起;0.4 秒內移回來就不收。用鍵盤打開、滑鼠還沒進過面板時不收。按著滑鼠(拖曳中)或在「找 session」分頁時不收。
- AC41 `scripts/install.sh` 把 `attention.py` 複製到 `~/.gtd-island/`,並把 AC34 的事件加進 `~/.claude/settings.json`。已經存在的同一個指令不重複加入;其他 hooks 不變;寫入前先備份原檔。

### 在瀏海裡回答(2026-11-13)
目的:取代 CodeIsland 的第二階段。使用者不用切到 session,就能在瀏海核准權限、回答選項題。面板沒在執行或沒人回答時,session 照 Claude 原本的方式詢問,不會卡住。
Example:session「發布 1.0」要執行 `npm publish`,需要權限。瀏海自動展開到「等你」分頁,第 1 列顯示「Bash · npm publish」和「允許」「拒絕」「到 app 處理」。使用者按「允許」,指令執行,這一列消失。另一個 session 問「要用哪個方案?」,選項是 A、B;使用者在瀏海點 B 再按「送出」,Claude 收到答案 B。
- AC43 面板執行時,每 3 秒更新 `~/.gtd-island/island.alive` 的修改時間。hook 只在這個檔案 10 秒內更新過時才在瀏海詢問;否則照 AC33–AC35,不等待。
- AC44 `PermissionRequest` 事件:hook 先照 AC34 寫入 `needsYou`(`message` 是「工具 · 摘要」),再寫入請求檔 `~/.gtd-island/requests/<請求 id>.json`,然後每 0.2 秒檢查回覆檔 `~/.gtd-island/responses/<請求 id>.json`,最多 120 秒。回覆 `allow` 時輸出允許,`deny` 時輸出拒絕和「使用者在 GTD Island 拒絕」。摘要是 `command`、`file_path`、`url` 或 `pattern` 中第一個有值的欄位。
- AC45 `PreToolUse` 的 `AskUserQuestion`:hook 只照 AC34 寫入紀錄,不送請求、不等待,也不輸出文字,讓問題立刻出現在 Claude Code。(2026-11-14 改:原本 hook 會等瀏海回答最多 120 秒,這段時間 Claude Code 不顯示問題,使用者無法在 app 裡回答。在瀏海回答選項題先拿掉,之後再討論。面板裡顯示選項題的程式碼還在,但不會再收到選項題請求。)
- AC46 回覆 `skip`、等待逾時、請求檔被刪除,或回覆檔無法解析時,hook 刪除自己的請求檔和回覆檔,不輸出任何文字,結束碼 0,讓 Claude 照原本的方式詢問。hook 的任何錯誤也是這樣處理。
- AC47 `UserPromptSubmit`、`SessionEnd`、`Stop` 和 `PostToolUse` 刪除該 session 的所有請求檔,讓還在等待的 hook 結束。使用者在 app 裡回答後,瀏海上的請求就消失。
- AC48 「等你」分頁把請求顯示在對應 session 的列上。權限請求有「允許」「拒絕」「到 app 處理」。選項題每題列出選項,單選題點一下就選定,多選題可以點多個;每題都選了才能按「送出」;另有「到 app 處理」。超過 130 秒的請求檔不顯示。
- AC49 出現新的請求時,面板自動展開到「等你」分頁,但不搶鍵盤焦點。滑鼠進入面板後,面板才取得焦點,按鈕第一下點擊就有效。
- AC50 `install.sh` 照 AC41 加上 `PermissionRequest` 事件,並把它的 hook 逾時設為 130 秒;`PreToolUse` 的逾時是 5 秒。已經安裝過的同一個指令只更新逾時。
- AC51 `AskUserQuestion` 的 `PermissionRequest` 事件:hook 不寫紀錄、不送請求,也不輸出文字。在瀏海按「到 app 處理」後,Claude Code 會為同一題再發出這個事件;它若顯示成權限卡,按「允許」會讓問題沒有答案就過關。
- 已知限制:CodeIsland 的 hook 也會回答權限請求。兩者都回答時,Claude Code 採用哪一個沒有文件說明,所以這一階段完成後要移除 CodeIsland 的 hooks。選項題在等待期間,app 不會顯示這個問題,要按「到 app 處理」或等 120 秒。

### 搜尋框(2026-11-14)
目的:使用者不離開鍵盤就能找到任何 session 並跳過去,不依賴 Raycast。瀏海只負責顯示;找和跳轉在搜尋框做。這是控制中樞的第一階段。
Example:使用者在任何 app 按 Option+Space。螢幕中央出現搜尋框,下面先列出 2 個等你的 session。使用者輸入「kafka pm」,清單立刻換成標題含這兩個字的 session,等你的排最前面。使用者按 ↓ 再按 Enter,桌面 app 跳到第 2 列的 session,搜尋框關閉。
- AC52 Option+Space 在滑鼠所在的螢幕中央偏上打開搜尋框,文字框取得鍵盤焦點。再按一次、按 Esc、點擊搜尋框以外的地方,或搜尋框失去鍵盤焦點時,搜尋框關閉,文字清空。Option+Space 被其他 app 佔用時,面板顯示錯誤。
- AC53 沒有輸入文字時,清單是「等你」的 session,順序和「等你」分頁相同(AC37),最多 8 列。
- AC54 有輸入文字時,候選是「等你」的 session,加上桌面 app 的 session(排除已封存、排程產生、沒有標題的)。輸入以空白切成字詞;標題或資料夾名稱包含每一個字詞(不分大小寫)的候選才列出。順序:等你的 session 在前(順序同 AC53),其餘依最後開啟時間由新到舊。
- AC55 AC12 的模型比對結果排在 AC54 的結果後面,已經列出的 session 不重複。合計最多 8 列。模型還沒回覆或無法使用時,AC54 的結果照常顯示;模型無法使用時另外顯示錯誤。
- AC56 ↑ ↓ 移動選取的列,不超出清單;輸入改變,或模型結果讓清單改變時,選取回到第 1 列。Enter 或點擊打開選取的列:桌面 app 跳到該 session,搜尋框關閉。終端機的 session 沒有跳轉連結,標示「在終端機」,Enter 不做任何事。輸入法選字中的 Enter、Esc、↑、↓ 交給輸入法。
- AC59 選取跟著列,不跟著位置:清單因為「等你」更新而重排時,選取的仍是同一個 session;那一列消失時回到第 1 列。等你的 session 還沒有跳轉連結時,借用同一個桌面 app session 的連結,不重複列出。輸入改變後,舊輸入的模型結果不顯示。滑鼠經過瀏海不會搶走搜尋框的鍵盤焦點。
- AC57 AC14 的模型程序在搜尋框打開時啟動,關閉時結束。
- AC58 瀏海面板不再有「找 session」分頁,Option+J 不再註冊。搜尋框開著時,新的請求照 AC49 展開瀏海,不搶搜尋框的鍵盤焦點。
- 第一階段不做:跳到終端機或 herdr 的 session、派發任務、搜尋 GTD 項目、自訂快捷鍵。
