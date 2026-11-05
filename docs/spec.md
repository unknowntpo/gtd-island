# GTD Island POC Spec

## Intent
在不切換 app 的情況下,回答「現在從哪開始」,並跳到對應工作。

## Example
使用者把滑鼠移到膠囊上,或按住 Option 再按 G。面板只列 3 件事。第一件是 Deadline 最近的 Project。
使用者切到自己設定的「工作」分頁,看到這個分頁的 Project 和下一步,等別人的項目在下方。
使用者按 `1`,面板收起,並打開該 Project 的 session 或 Notion 頁面。

## Scope
- 資料來源:Notion 的 `Projects 下一步` view。POC 只讀,不寫 GTD。
- 不做:agent 通信、卡點欄位、批准工具呼叫、拆小 Action。

## Acceptance
- AC1 可動手的項目排序:14 天內未過期的 Deadline 最優先,再來是 This Week,再依 Priority、Last Worked。
- AC2 「先看這 3 件」最多 3 項,不含等別人的項目。
- AC3 `Next Action` 以「等」開頭,或 `Waiting For` 有值,就算等別人。
- AC4 分頁來自 `~/.gtd-island/config.json` 的 `tabs`,見「分頁設定檔」。
- AC5 跳轉目標:`Owner Session` 優先,其次 Notion 頁面。
- AC6 快照超過 5 分鐘算過期,展開時自動更新;更新失敗時保留舊資料並顯示錯誤。
- AC7 真實格式的 view 資料可以解析,多餘欄位不影響。
- AC8 面板懸浮在其他視窗上,打開時不搶走目前 app 的焦點;滑鼠移到膠囊上或點擊就展開,Option+G 切換,`Esc` 或點外面收起,數字鍵跳轉。
- AC9 macOS Keychain 有 `gtd-island-notion` token 時,`refresh.py` 直接呼叫 Notion API 查 GTD Items:`Item Type` 是 Project 且 `GTD Status` 是 Active,依 `Last Worked` 新到舊,讀完所有分頁。輸出的欄位名稱和格式與原本的 view 資料相同。
- AC10 沒有 token 或 API 失敗時,`refresh.py` 改走原本的 `claude` 路徑。token 不寫進檔案或輸出。

### 找 session prototype(2026-11-04)
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
- AC23 每個分頁有 `name`,以及可省略的 `areas`、`titlePrefixes`、`linkContains`。分頁列依序是:先看這 3 件、動態、設定檔的分頁(依檔案順序)、其他、找 session。
- AC24 Project 的分頁依序決定:任一分頁的 `titlePrefixes` 符合標題,或 `linkContains` 符合 `Worktree`、`Source URL`;再來是 `areas` 符合 Area;都不符合就是「其他」。同一步有多個分頁符合時,取檔案中較前面的分頁。
- AC25 檔案不存在、無法解析或沒有 `tabs` 時,只顯示固定分頁,所有 Project 在「其他」。`name` 是空字串、與固定分頁同名或與前面分頁同名的分頁會被忽略。
- AC26 面板只在啟動時讀設定檔。改設定檔後要重開面板。
