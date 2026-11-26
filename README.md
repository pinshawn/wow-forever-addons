# 魔獸世界：永恆（WoW Forever）自製小插件

給「插件自動更新」程式讀的插件來源：更新程式會讀這裡每個插件 `.toc` 的 `## Version:`，比你電腦裡的新就下載這個專案、換上新版（舊版會先備份）。

| 資料夾 | 插件 | 做什麼 |
|---|---|---|
| `AAA_NowarSansSwitch` | 有愛黑體切換 | 整個遊戲（包含插件）的字換成有愛黑體；插件裡的簡體字轉繁體（台灣用字）；小地圖「字」圓鈕開關 |
| `OneForAll_zhTW` | OneForAll 繁體中文包 | 把 OneForAll 的介面、地城、任務、物品名稱換成繁體中文（要先裝 OneForAll） |
| `QuestieZoneOnly` | Questie 只顯示這一區 | Questie 任務追蹤只列你所在區域的任務，標題旁 [只看這區] 切換（要先裝 Questie） |
| `!Details_zhTW` | Details! 繁體中文 | Details!（傷害統計）的介面翻成繁體中文，我們自己翻的；不改 Details! 本體（要先裝 Details!） |
| `ForeverLook` | 一鍵推薦外觀 | 在 Polestar 和 Questie 裡各放一套「推薦」設定，跟自己的設定一鍵切換（小地圖「推」圓鈕、/推薦）；自己的設定不會被改 |
| `!PolestarPlus_zhTW` | Polestar 中文補充 | Polestar（練等指南）繁體中文包還沒翻到的句子先補上中文；作者有翻的一律用作者的，作者翻好後從這裡刪掉。要配兩個共用補丁（`polestar-zhtw-plus-texts`、`polestar-zhtw-plus-ui`，更新程式會自動補）；/pszh 看補了幾句（要先裝 Polestar） |
| `ForeverAHScan` | 拍賣場掃描（配無限副本手冊） | 每次打開拍賣場就掃一次（全場清單 15 分鐘一次，其間用摘要掃描），把每樣東西「在賣幾個、一個最低多少」交給無限副本手冊的專業路線；拍賣場底下多一個「掃描」分頁；滑鼠提示在「售價：」下面顯示「拍賣：」一個的最低價，指著一堆時後面加「這 N 個：」整堆的價錢。不幫你買賣 |
| `ForeverQuestMark` | 副本任務怪標記 | 地城裡要打的任務怪，名條左邊標骷髏（遊戲在地城藏了怪的編號，Polestar／Questie 認不出來時，改問遊戲「這隻跟你的任務有沒有關」）；這個副本的任務都做完就不標。/任務怪 開關、/任務怪 測 看目標為什麼標或不標。不用 Polestar 也能用 |

## 線上清單 `addons_list.json`

「插件自動更新」（v1.3 起）每次執行都會先讀這份清單：

- 清單上新加的插件會自動加進每個人的更新清單；標 `autoInstall` 的（這裡自製的小插件）沒裝也會幫忙裝。
- 跟使用者本機 `addons.json` 同一個主資料夾的，以這份清單的寫法為準（作者改了下載位置時，改這裡一次就好）。
- `needs`：要先有哪個插件才裝（例如「Questie 只顯示這一區」要先有 Questie）。
- `optional`：給要的人用的別人的插件：沒裝的不會自己裝；想要的人在自己的 `addons.json` 寫 `"want": ["主資料夾名"]` 就會幫你裝（v1.3.10 起），或自己先放一次，之後就幫你更新。
- `folderPrefix`：一包很多資料夾、名字同一個開頭的（例：Polestar 的 `Polestar_`）：下載裡這個開頭的資料夾全部一起裝、一起更新；作者拿掉的資料夾搬到「插件備份」；你自己另外放的同開頭資料夾（例：Polestar_Recorder）不會動（v1.3.10 起）。
- 換新版後，更新程式會列出各插件資料夾裡 `讀我.txt` 的「改版紀錄」中比本機新的那幾版。

## 手動安裝

把要的資料夾整個放進 `World of Warcraft\_forever_\Interface\AddOns\`，整個重開遊戲。

## 授權

- 有愛黑體切換：字型是 Nowar Sans（有愛黑體）1.0.1 改成 TrueType 外框的版本，依 SIL Open Font License 1.1（`AAA_NowarSansSwitch/Fonts/LICENSE.txt`）散布；依授權，字型名稱改成「WCHei TW TT」，不使用原本的保留名稱。簡轉繁資料取自 OpenCC，Apache License 2.0（`AAA_NowarSansSwitch/OpenCC-LICENSE.txt`）。
- OneForAll 繁體中文包、Questie 只顯示這一區、一鍵推薦外觀、拍賣場掃描、副本任務怪標記：GPL-3.0（各資料夾的 `LICENSE.txt`）。
- Polestar 中文補充：GPL-3.0（`!PolestarPlus_zhTW/LICENSE.txt`）；裡面是 Polestar（GPL-3.0，fitzforge/polestar）指南和介面句子的英文原句和我們的中文翻譯。
- 拍賣場掃描提供的是無限副本手冊本來就會讀的 `EasyAuctionAPI` 接口（沒裝 EasyAuction 時才提供）；程式全部是我們自己寫的，不含無限副本手冊、EasyAuction、Auctionator 的程式碼。
- Details! 繁體中文：中文翻譯是我們自己翻的，可以自由分享；檔案裡只有 Details! 字串的代號和我們的中文，沒有 Details! 的程式碼和英文原文（Details! 本體是作者 Tercioo 的作品，保留所有權利）。內附的 LibStub、AceLocale-3.0 來自 Ace3（BSD 式授權，`!Details_zhTW/Libs/Ace3-LICENSE.txt`）。
- 免費分享，不得販售。
