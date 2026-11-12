# 魔獸世界：永恆（WoW Forever）自製小插件

給「插件自動更新」程式讀的插件來源：更新程式會讀這裡每個插件 `.toc` 的 `## Version:`，比你電腦裡的新就下載這個專案、換上新版（舊版會先備份）。

| 資料夾 | 插件 | 做什麼 |
|---|---|---|
| `AAA_NowarSansSwitch` | 有愛黑體切換 | 整個遊戲（包含插件）的字換成有愛黑體；插件裡的簡體字轉繁體（台灣用字）；小地圖「字」圓鈕開關 |
| `OneForAll_zhTW` | OneForAll 繁體中文包 | 把 OneForAll 的介面、地城、任務、物品名稱換成繁體中文（要先裝 OneForAll） |
| `QuestieZoneOnly` | Questie 只顯示這一區 | Questie 任務追蹤只列你所在區域的任務，標題旁 [只看這區] 切換（要先裝 Questie） |
| `!Details_zhTW` | Details! 繁體中文 | Details!（傷害統計）的介面翻成繁體中文，我們自己翻的；不改 Details! 本體（要先裝 Details!） |

## 線上清單 `addons_list.json`

「插件自動更新」（v1.3 起）每次執行都會先讀這份清單：

- 清單上新加的插件會自動加進每個人的更新清單；標 `autoInstall` 的（這裡自製的小插件）沒裝也會幫忙裝。
- 跟使用者本機 `addons.json` 同一個主資料夾的，以這份清單的寫法為準（作者改了下載位置時，改這裡一次就好）。
- `needs`：要先有哪個插件才裝（例如「Questie 只顯示這一區」要先有 Questie）。
- `optional`：給要的人用的別人的插件：沒裝的不會自己裝，自己先放一次，之後才幫你更新。
- 換新版後，更新程式會列出各插件資料夾裡 `讀我.txt` 的「改版紀錄」中比本機新的那幾版。

## 手動安裝

把要的資料夾整個放進 `World of Warcraft\_forever_\Interface\AddOns\`，整個重開遊戲。

## 授權

- 有愛黑體切換：字型是 Nowar Sans（有愛黑體）1.0.1 改成 TrueType 外框的版本，依 SIL Open Font License 1.1（`AAA_NowarSansSwitch/Fonts/LICENSE.txt`）散布；依授權，字型名稱改成「WCHei TW TT」，不使用原本的保留名稱。簡轉繁資料取自 OpenCC，Apache License 2.0（`AAA_NowarSansSwitch/OpenCC-LICENSE.txt`）。
- OneForAll 繁體中文包、Questie 只顯示這一區：GPL-3.0（各資料夾的 `LICENSE.txt`）。
- Details! 繁體中文：中文翻譯是我們自己翻的，可以自由分享；檔案裡只有 Details! 字串的代號和我們的中文，沒有 Details! 的程式碼和英文原文（Details! 本體是作者 Tercioo 的作品，保留所有權利）。內附的 LibStub、AceLocale-3.0 來自 Ace3（BSD 式授權，`!Details_zhTW/Libs/Ace3-LICENSE.txt`）。
- 免費分享，不得販售。
