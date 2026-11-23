-- 拍賣場掃描（配無限副本手冊）— 我們自己寫的，GPL-3.0
--
-- 做什麼：
--   1. 每次打開拍賣場就掃一次，算出每樣東西「有直購價的在賣幾個、一個最低多少錢」，存起來。
--      兩種掃法：
--        全場清單（C_AuctionHouse.ReplicateItems）：每一筆掛單都看到，最準；遊戲規定 15 分鐘只能要一次。
--        摘要掃描（空白搜尋 SendBrowseQuery）：每樣東西的最低價和總數量；隨時可以，15 分鐘內再開拍賣場就用這個。
--      摘要掃描第一次會跟剛掃的全場清單比對價錢（看是不是「一個」的價錢），對得上才拿來用。
--   2. 用無限副本手冊（DungeonsForever 專業模組）本來就會讀的接口交給它：它在永恆版會讀 EasyAuctionAPI
--      （原本是 EasyAuction 插件的）。沒裝 EasyAuction 才由我們提供；有裝的話不搶。
--      所以無限副本手冊畫面上寫「EasyAuction 行情」，其實是這裡掃的。
--   3. 拍賣場下面多一個「掃描」分頁：狀態、按鈕、設定都在那裡。
--   4. 滑鼠指到物品時，在遊戲「售價：」那行下面顯示「拍賣：」一個的最低價（一樣靠左，數字對齊）。
-- 不做什麼：不幫你買、不幫你賣、不自動出價（遊戲規定這些都要自己按）。

local ADDON = ...
local COOLDOWN = 15 * 60          -- 遊戲規定：全場清單 15 分鐘只能要一次
local WAIT_LIMIT = 90             -- 要了全場清單 90 秒沒回 → 這次沒拿到
local BROWSE_LIMIT = 30           -- 摘要掃描 30 秒沒有進度 → 這次沒拿到
local OLD = 2 * 24 * 3600         -- 無限副本手冊預設超過 2 天就當作過期

local DB                          -- 存檔（ForeverAHScanDB），ADDON_LOADED 後才有
local S = { state = "idle" }      -- idle／waiting（等全場清單）／reading（讀全場清單）／browsing（摘要掃描）
local ahOpen = false
local page, tabButton             -- 拍賣場下面的「掃描」分頁
local refreshPage                 -- 下面才定義

local function now() return time() end
local function say(msg) print("|cff66ccff拍賣場掃描|r：" .. msg) end

-- 哪個市場：伺服器＋陣營（永恆的用戶端有時不給伺服器名稱，那就只分陣營）
local function scopeKey()
	local realm = (GetRealmName and GetRealmName()) or ""
	if realm == "" and GetNormalizedRealmName then realm = GetNormalizedRealmName() or "" end
	local faction = (UnitFactionGroup and UnitFactionGroup("player")) or ""
	return (realm ~= "" and realm or "?") .. "-" .. (faction ~= "" and faction or "?")
end

local function currentScan()
	return DB and DB.scans and DB.scans[scopeKey()] or nil
end

local function ago(t)
	local s = now() - (t or 0)
	if s < 0 then s = 0 end
	if s < 60 then return "剛剛" end
	if s < 3600 then return ("%d 分鐘前"):format(math.floor(s / 60)) end
	if s < 2 * 86400 then return ("%d 小時前"):format(math.floor(s / 3600)) end
	return ("%d 天前"):format(math.floor(s / 86400))
end

local function commas(n)
	n = tostring(math.floor(n or 0))
	local out = n:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- 錢：數字後面直接接金銀銅小圖示，中間不留空白（0.2 留了空白，數字分太開）
-- 永恆的用戶端沒有 GetCoinTextureString，自己組
local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0|t"
local function money(c)
	c = math.floor((c or 0) + 0.5)
	local g, s, cu = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
	if g > 0 then return ("%s%s%02d%s%02d%s"):format(commas(g), GOLD, s, SILVER, cu, COPPER) end
	if s > 0 then return ("%d%s%02d%s"):format(s, SILVER, cu, COPPER) end
	return ("%d%s"):format(cu, COPPER)
end

local function auctionatorLoaded()
	local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	return f and f("Auctionator") and true or false
end

local function fullWait()          -- 全場清單還要等幾秒才能再要
	return DB and math.max(0, COOLDOWN - (now() - (DB.lastRequest or 0))) or 0
end

----------------------------------------------------------------------
-- 共用：存一次掃描的結果
----------------------------------------------------------------------
local events = CreateFrame("Frame")
local reader = CreateFrame("Frame")

local function setIdle()
	reader:SetScript("OnUpdate", nil)
	S.state, S.acc, S.token, S.needSend, S.waitThrottle = "idle", nil, nil, false, false
end

local function fail(why)
	setIdle()
	say(why .. (currentScan() and "（上一次的資料還在）" or ""))
	if refreshPage then refreshPage() end
end

-- items：[物品編號] = { 在賣幾個（只算有直購價的）, 一個最低多少銅 }
local function store(items, count, rows, method, seenAt)
	DB.scans = DB.scans or {}
	DB.scans[scopeKey()] = { t = seenAt, done = now(), rows = rows, count = count, items = items, method = method }
end

----------------------------------------------------------------------
-- 全場清單（15 分鐘一次）
----------------------------------------------------------------------
local function finishFull()
	reader:SetScript("OnUpdate", nil)
	local items, count = {}, 0
	for id, a in pairs(S.acc) do
		if a.q > 0 and a.min then items[id] = { a.q, math.floor(a.min + 0.5) } else items[id] = { 0 } end
		count = count + 1
	end
	store(items, count, S.rows, "full", S.seenAt)
	local rows = S.rows
	setIdle()
	say(("掃好了（全場清單）：%s 樣東西、%s 筆掛單。無限副本手冊的專業路線可以重新計算了。"):format(commas(count), commas(rows)))
	if refreshPage then refreshPage() end
end

local function stepFull()
	local t0 = debugprofilestop and debugprofilestop() or 0
	local get = C_AuctionHouse.GetReplicateItemInfo
	while S.i < S.total do
		local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = get(S.i)
		S.i = S.i + 1
		if type(itemID) == "number" and itemID > 0 and type(count) == "number" and count > 0 then
			S.rows = S.rows + 1
			local a = S.acc[itemID]
			if not a then a = { q = 0 }; S.acc[itemID] = a end
			if type(buyout) == "number" and buyout > 0 then   -- 只能競標的不算「買得到」
				local unit = buyout / count
				a.q = a.q + count
				if not a.min or unit < a.min then a.min = unit end
			end
		end
		if S.i % 250 == 0 and debugprofilestop and debugprofilestop() - t0 > 12 then break end
	end
	if S.i % 2000 < 250 and refreshPage then refreshPage() end
	if S.i >= S.total then finishFull() end
end

local function startReading()
	local total = C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
	if not total or total <= 0 then fail("拍賣場回了 0 筆，這次沒存"); return end
	S.state, S.total, S.i, S.rows, S.acc, S.seenAt, S.method = "reading", total, 0, 0, {}, now(), "full"
	DB.lastRead = now()
	reader:SetScript("OnUpdate", stepFull)
	if refreshPage then refreshPage() end
end

local function requestFull()
	DB.lastRequest = now()
	S.state, S.method = "waiting", "full"
	local token = {}
	S.token = token
	C_AuctionHouse.ReplicateItems()
	if refreshPage then refreshPage() end
	if C_Timer and C_Timer.After then
		-- 20 秒還沒回：可能 15 分鐘內別的插件已經要過，遊戲手上已經有那份清單 → 直接讀
		C_Timer.After(20, function()
			if S.token == token and S.state == "waiting"
				and (C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0) > 0 then
				startReading()
			end
		end)
		C_Timer.After(WAIT_LIMIT, function()
			if S.token == token and S.state == "waiting" then fail("拍賣場這次沒回全場清單") end
		end)
	end
end

----------------------------------------------------------------------
-- 摘要掃描（隨時可以）：空白搜尋，一頁一頁拿到全部
----------------------------------------------------------------------
local function browseQuery()
	local sorts = {}
	if Enum and Enum.AuctionHouseSortOrder then
		sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
	end
	return { searchString = "", sorts = sorts, filters = {}, itemClassFilters = {} }
end

local function readBrowse()
	local list = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
	local acc, rows = {}, 0
	for _, r in ipairs(list) do
		local id = r and r.itemKey and r.itemKey.itemID
		if type(id) == "number" and id > 0 then
			rows = rows + 1
			local a = acc[id]
			if not a then a = { q = 0 }; acc[id] = a end
			local q, p = tonumber(r.totalQuantity) or 0, tonumber(r.minPrice) or 0
			if q > 0 and p > 0 then
				a.q = a.q + q
				if not a.min or p < a.min then a.min = p end
			end
		end
	end
	return acc, rows
end

-- 摘要的價錢是不是「一個」的價錢：拿剛掃的全場清單比，同一樣東西最低價要差不多
local function checkAgainstFull(acc)
	local full = currentScan()
	if not (full and full.method == "full" and full.items and now() - (full.t or 0) < 3 * 3600) then return nil end
	local n, same = 0, 0
	for id, a in pairs(acc) do
		local f = full.items[id]
		if a.min and f and f[2] and f[2] > 0 then
			n = n + 1
			local r = a.min / f[2]
			if r > 0.95 and r < 1.05 then same = same + 1 end
		end
	end
	if n < 20 then return nil end
	return same / n >= 0.6, n, same
end

local function finishBrowse()
	local acc, rows = readBrowse()
	local seenAt = S.seenAt
	setIdle()
	if rows == 0 then fail("摘要掃描沒拿到東西，這次沒存"); return end
	local ok, n, same = checkAgainstFull(acc)
	if ok ~= nil then DB.summaryCheck = { ok = ok, n = n, same = same, t = now() } end
	local trust = DB.summaryCheck and DB.summaryCheck.ok
	if not trust then
		if refreshPage then refreshPage() end
		if DB.summaryCheck then
			say(("摘要掃描的價錢跟全場清單對不上（%d 樣裡只有 %d 樣一樣，可能是整疊的價錢），這次不用；無限副本手冊照用全場清單的資料。"):format(DB.summaryCheck.n, DB.summaryCheck.same))
		else
			say("摘要掃描還沒跟全場清單比對過，這次先不用（等下次有新的全場清單再比）。")
		end
		return
	end
	local items, count = {}, 0
	for id, a in pairs(acc) do
		if a.q > 0 and a.min then items[id] = { a.q, math.floor(a.min + 0.5) } else items[id] = { 0 } end
		count = count + 1
	end
	store(items, count, rows, "summary", seenAt)
	say(("掃好了（摘要）：%s 樣東西。無限副本手冊的專業路線可以重新計算了。"):format(commas(count)))
	if refreshPage then refreshPage() end
end

local function continueBrowse()
	if S.state ~= "browsing" then return end
	S.lastProgress = now()
	if C_AuctionHouse.HasFullBrowseResults and C_AuctionHouse.HasFullBrowseResults() then
		finishBrowse()
		return
	end
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		S.waitThrottle = true      -- 等 AUCTION_HOUSE_THROTTLED_SYSTEM_READY
		return
	end
	S.waitThrottle = false
	S.mine = true
	C_AuctionHouse.RequestMoreBrowseResults()
	S.mine = false
	if refreshPage then refreshPage() end
end

local function sendFirst()
	S.needSend = false
	S.mine = true
	C_AuctionHouse.SendBrowseQuery(browseQuery())
	S.mine = false
end

local function startBrowse()
	if not (C_AuctionHouse.SendBrowseQuery and C_AuctionHouse.GetBrowseResults) then
		fail("這個遊戲版本不能做摘要掃描"); return
	end
	S.state, S.method, S.seenAt, S.lastProgress = "browsing", "summary", now(), now()
	local token = {}
	S.token = token
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		S.needSend = true        -- 拍賣場正忙（遊戲自己開場的搜尋），等它好了再送
	else
		sendFirst()
	end
	if refreshPage then refreshPage() end
	local function watchdog()
		if S.token ~= token or S.state ~= "browsing" then return end
		if now() - (S.lastProgress or 0) > BROWSE_LIMIT then fail("摘要掃描卡住了，這次沒存"); return end
		C_Timer.After(5, watchdog)
	end
	if C_Timer and C_Timer.After then C_Timer.After(5, watchdog) end
end

-- 別人（你自己在「購買」搜尋、或別的插件）送了搜尋：我們的摘要掃描會被蓋掉 → 這次停掉
local function someoneElseSearched()
	if S.state == "browsing" and not S.mine then
		setIdle()
		say("你在拍賣場搜尋東西，這次摘要掃描先停（下次開拍賣場或按「現在掃描」再掃）")
		if refreshPage then refreshPage() end
	end
end
if C_AuctionHouse and hooksecurefunc then
	-- 會把「購買」那頁的結果換掉的三種搜尋
	for _, name in ipairs({ "SendBrowseQuery", "SearchForFavorites", "SearchForItemKeys" }) do
		if type(C_AuctionHouse[name]) == "function" then hooksecurefunc(C_AuctionHouse, name, someoneElseSearched) end
	end
end

----------------------------------------------------------------------
-- 要掃：全場清單能要就要，不能（15 分鐘內）就做摘要
----------------------------------------------------------------------
local function scan(manual)
	if not ahOpen then
		if manual then say("要先打開拍賣場") end
		return
	end
	if not C_AuctionHouse then return end
	if S.state ~= "idle" then
		if manual then say("正在掃，請等一下") end
		return
	end
	if C_AuctionHouse.ReplicateItems and fullWait() == 0 then
		requestFull()
	else
		startBrowse()
	end
end

----------------------------------------------------------------------
-- 拍賣場下面的「掃描」分頁
----------------------------------------------------------------------
local function stateLine()
	if S.state == "waiting" then return "|cffffd100正在跟拍賣場要全場清單…|r" end
	if S.state == "reading" then
		return ("|cffffd100正在讀全場清單 %d%%（%s / %s）|r"):format(math.floor(S.i / math.max(1, S.total) * 100), commas(S.i), commas(S.total))
	end
	if S.state == "browsing" then
		local n = C_AuctionHouse and C_AuctionHouse.GetBrowseResults and #C_AuctionHouse.GetBrowseResults() or 0
		return ("|cffffd100正在做摘要掃描…（已拿到 %s 樣）|r"):format(commas(n))
	end
	return nil
end

local function statusText()
	local lines = {}
	local busy = stateLine()
	if busy then lines[#lines + 1] = busy end
	local scan_ = currentScan()
	if scan_ then
		local how = scan_.method == "summary" and "摘要掃描" or "全場清單"
		local old = (now() - (scan_.t or 0)) > OLD
		lines[#lines + 1] = ("上次掃描：%s（%s）%s"):format(ago(scan_.t), how, old and "　|cffff6060已超過 2 天，無限副本手冊會當作過期|r" or "")
		if scan_.method == "summary" then
			lines[#lines + 1] = ("拍賣場在賣的東西：%s 樣"):format(commas(scan_.count or 0))
		else
			lines[#lines + 1] = ("拍賣場在賣的東西：%s 樣，%s 筆掛單"):format(commas(scan_.count or 0), commas(scan_.rows or 0))
		end
	else
		lines[#lines + 1] = "還沒掃過"
	end
	local w = fullWait()
	if w > 0 then
		lines[#lines + 1] = ("全場清單：%d 分鐘後可以再要；在那之前掃描會用摘要掃描"):format(math.ceil(w / 60))
	else
		lines[#lines + 1] = "全場清單：現在可以要（下次掃描會用全場清單）"
	end
	local c = DB and DB.summaryCheck
	if c then
		lines[#lines + 1] = c.ok and ("摘要掃描的價錢：跟全場清單對過，對得上（%d 樣裡 %d 樣一樣）"):format(c.n, c.same)
			or ("|cffff6060摘要掃描的價錢：跟全場清單對不上（%d 樣裡只有 %d 樣一樣），不拿來用|r"):format(c.n, c.same)
	end
	lines[#lines + 1] = ForeverAHScan and ForeverAHScan.providesAPI and "無限副本手冊：讀得到（它畫面上寫的「EasyAuction 行情」就是這裡掃的）"
		or "無限副本手冊：你有裝 EasyAuction，它讀的是 EasyAuction 的"
	return table.concat(lines, "\n")
end

local function blizzTabs()
	local host = AuctionHouseFrame
	local list = {}
	if host and type(host.Tabs) == "table" then
		for _, t in ipairs(host.Tabs) do if t ~= tabButton then list[#list + 1] = t end end
	end
	if #list == 0 and host then
		for _, k in ipairs({ "BuyTab", "SellTab", "AuctionsTab" }) do if host[k] then list[#list + 1] = host[k] end end
	end
	return list
end

local function showPage(show)
	if not page then return end
	if show then
		page:Show()
		if PanelTemplates_SelectTab and tabButton then pcall(PanelTemplates_SelectTab, tabButton) end
		if PanelTemplates_DeselectTab then for _, t in ipairs(blizzTabs()) do pcall(PanelTemplates_DeselectTab, t) end end
		refreshPage()
	else
		page:Hide()
		if PanelTemplates_DeselectTab and tabButton then pcall(PanelTemplates_DeselectTab, tabButton) end
	end
end

local function makeTab()
	local host = AuctionHouseFrame
	if tabButton or not host then return end
	-- 分頁按鈕：放在最後一個分頁（拍賣）右邊；用遊戲的分頁樣子，做不出來就用一般按鈕
	local last = blizzTabs()
	last = last[#last]
	local ok, b = pcall(CreateFrame, "Button", "ForeverAHScanTab", host, "PanelTabButtonTemplate")
	if not ok or not b then ok, b = pcall(CreateFrame, "Button", "ForeverAHScanTab", host, "UIPanelButtonTemplate") end
	if not ok or not b then return end
	tabButton = b
	b:SetText("掃描")
	if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, b, 0) end
	if last then b:SetPoint("LEFT", last, "RIGHT", 3, 0) else b:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 280, 2) end
	b:SetScript("OnClick", function() showPage(not page:IsShown()) end)
	for _, t in ipairs(blizzTabs()) do
		if t.HookScript then t:HookScript("OnClick", function() showPage(false) end) end
	end
	if hooksecurefunc and type(host.SetDisplayMode) == "function" then
		hooksecurefunc(host, "SetDisplayMode", function() showPage(false) end)
	end

	-- 分頁內容：蓋在拍賣場內容上面
	page = CreateFrame("Frame", "ForeverAHScanPage", host, BackdropTemplateMixin and "BackdropTemplate" or nil)
	page:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -26)
	page:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -4, 4)
	page:SetFrameLevel((host:GetFrameLevel() or 1) + 200)
	page:EnableMouse(true)
	if page.CreateTexture then
		local bg = page:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.07, 0.06, 0.05, 0.97)
	elseif page.SetBackdrop then
		page:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", tile = true, tileSize = 32 })
	end
	page:Hide()
	local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 24, -24)
	title:SetText("拍賣場掃描（給無限副本手冊用）")
	page.button = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
	page.button:SetSize(160, 28)
	page.button:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
	page.button:SetText("現在掃描")
	page.button:SetScript("OnClick", function() scan(true) end)
	page.status = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	page.status:SetPoint("TOPLEFT", page.button, "BOTTOMLEFT", 0, -16)
	page.status:SetPoint("RIGHT", page, "RIGHT", -24, 0)
	page.status:SetJustifyH("LEFT")
	page.status:SetSpacing(6)
	page.auto = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
	page.auto:SetSize(24, 24)
	page.auto:SetPoint("TOPLEFT", page.status, "BOTTOMLEFT", -4, -16)
	page.auto:SetScript("OnClick", function(self) DB.auto = self:GetChecked() and true or false end)
	local autoText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	autoText:SetPoint("LEFT", page.auto, "RIGHT", 4, 0)
	autoText:SetText("每次打開拍賣場就自動掃一次")
	page.help = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	page.help:SetPoint("TOPLEFT", page.auto, "BOTTOMLEFT", 4, -16)
	page.help:SetPoint("RIGHT", page, "RIGHT", -24, 0)
	page.help:SetJustifyH("LEFT")
	page.help:SetSpacing(4)
	page.help:SetText("兩種掃法：\n"
		.. "・全場清單：每一筆掛單都看，最準。遊戲規定 15 分鐘只能要一次。\n"
		.. "・摘要掃描：每樣東西的最低價和總數量，隨時可以；15 分鐘內再開拍賣場就用這個。\n"
		.. "　（摘要掃描會在「購買」那頁列出全部東西，那是掃描的結果，不影響你買賣；你一搜尋，摘要掃描就會停。）\n"
		.. "滑鼠指到物品會顯示「拍賣」一個的最低價。打 /拍賣掃描 提示 可以開關。")
	page.elapsed = 0
	page:SetScript("OnUpdate", function(self, dt)
		self.elapsed = self.elapsed + dt
		if self.elapsed > 1 then self.elapsed = 0; refreshPage() end
	end)
end

refreshPage = function()
	if not (page and page:IsShown()) then return end
	page.status:SetText(statusText())
	if S.state == "idle" then page.button:Enable() else page.button:Disable() end
	page.auto:SetChecked(DB and DB.auto ~= false)
end

----------------------------------------------------------------------
-- 事件
----------------------------------------------------------------------
local AH_EVENTS = { "REPLICATE_ITEM_LIST_UPDATE", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
	"AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		ForeverAHScanDB = ForeverAHScanDB or {}
		DB = ForeverAHScanDB
		DB.v = 1
		DB.scans = DB.scans or {}
		DB.lastRequest = DB.lastRequest or 0
		if DB.auto == nil then DB.auto = true end
		if DB.lastRead == nil then   -- 0.1 版沒記：用存著的掃描完成時間補上
			local last = 0
			for _, sc in pairs(DB.scans) do if type(sc) == "table" and (sc.done or 0) > last then last = sc.done end end
			DB.lastRead = last
		end
	elseif event == "AUCTION_HOUSE_SHOW" then
		ahOpen = true
		for _, e in ipairs(AH_EVENTS) do pcall(events.RegisterEvent, events, e) end
		if not tabButton then pcall(makeTab) end
		if page then page:Hide() end
		if DB.auto ~= false then
			-- 等拍賣場畫面自己的第一次載入做完，再開始掃（免得跟它搶）
			if C_Timer and C_Timer.After then C_Timer.After(1, function() if ahOpen then scan(false) end end) else scan(false) end
		end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ahOpen = false
		for _, e in ipairs(AH_EVENTS) do pcall(events.UnregisterEvent, events, e) end
		if S.state == "reading" or S.state == "waiting" then
			fail("拍賣場在掃描的時候關掉了，這次沒存")
		elseif S.state == "browsing" then
			setIdle()   -- 摘要掃描被關掉：安靜地停（下次開拍賣場再掃）
		end
		if page then page:Hide() end
	elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
		-- 這個事件同一份清單會來很多次 → 每份只讀一次。自己要的：讀；別的插件要的新清單：順便讀。
		if S.state == "reading" or S.state == "browsing" then return end
		if S.state == "waiting" then startReading(); return end
		if now() - (DB.lastRead or 0) < COOLDOWN then return end
		DB.lastRequest = now()
		startReading()
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
		if S.state == "browsing" then continueBrowse() end
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		if S.state == "browsing" and S.needSend then S.lastProgress = now(); sendFirst()
		elseif S.state == "browsing" and S.waitThrottle then continueBrowse() end
	elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
		if S.state == "browsing" then fail("摘要掃描失敗（拍賣場忙），這次沒存") end
	end
end)

----------------------------------------------------------------------
-- 交給無限副本手冊的接口（它在永恆版讀 EasyAuctionAPI）
----------------------------------------------------------------------
local API = {}
function API.IsReady() return DB ~= nil end
function API.GetMarketInfo()
	local sc = currentScan()
	if not sc then return { scope = "ForeverAHScan:" .. scopeKey(), itemCount = 0 } end
	return { scope = "ForeverAHScan:" .. scopeKey(), itemCount = sc.count or 0,
		scanObservedAt = sc.t, updatedAt = sc.t, source = "ForeverAHScan" }
end
-- 一樣東西：在賣幾個（只算有直購價的）、一個最低多少（銅）；整場掃描時沒看到＝沒人在賣
function API.GetRecord(key)
	local id = tonumber(key)
	if not id or id <= 0 or id ~= math.floor(id) then return nil end
	local sc = currentScan()
	if not sc then return nil end
	local it = sc.items[id]
	if it and (it[1] or 0) > 0 then
		return { bookStatus = "fresh", bookUpdated = sc.t, seen = sc.t, updated = sc.t,
			bookQuantity = it[1], quantity = it[1], min = it[2] }
	end
	return { bookStatus = "empty", bookUpdated = sc.t, seen = sc.t, updated = sc.t, bookQuantity = 0, quantity = 0 }
end

ForeverAHScan = { API = API, Scan = scan, Status = function() return statusText() end }
if EasyAuctionAPI == nil then
	EasyAuctionAPI = API          -- 沒裝 EasyAuction：由我們提供
	ForeverAHScan.providesAPI = true
end

----------------------------------------------------------------------
-- 滑鼠提示：跟遊戲的「售價：」同一個樣子（靠左）
----------------------------------------------------------------------
local function tooltipOn()
	if not DB then return false end
	if DB.tooltip == nil then return not auctionatorLoaded() end   -- 預設：沒裝 Auctionator 才顯示
	return DB.tooltip
end

local function addLine(tt, itemID)
	if not (tt and itemID and tooltipOn()) then return end
	local sc = currentScan()
	if not sc then return end
	local it = sc.items[itemID]
	if it and (it[1] or 0) > 0 then
		-- 跟遊戲的「售價：19●」一樣靠左：「拍賣：」也是兩個字＋冒號，數字會跟售價的數字對齊
		tt:AddLine("|cffffd100拍賣：|r" .. money(it[2]), 1, 1, 1)
	else
		tt:AddLine("|cffffd100拍賣：|r沒人在賣", 0.6, 0.6, 0.6)
	end
	tt:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
		if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
		local id = data and data.id
		if not id and tt.GetItem then
			local _, link = tt:GetItem()
			id = link and tonumber(link:match("item:(%d+)"))
		end
		addLine(tt, id)
	end)
elseif GameTooltip and GameTooltip.HookScript then
	GameTooltip:HookScript("OnTooltipSetItem", function(tt)
		local _, link = tt:GetItem()
		addLine(tt, link and tonumber(link:match("item:(%d+)")))
	end)
end

----------------------------------------------------------------------
-- 指令
----------------------------------------------------------------------
SLASH_FOREVERAHSCAN1 = "/拍賣掃描"
SLASH_FOREVERAHSCAN2 = "/ahscan"
SlashCmdList.FOREVERAHSCAN = function(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "掃" or msg == "scan" then
		scan(true)
	elseif msg == "自動" or msg == "auto" then
		DB.auto = not (DB.auto ~= false)
		say("每次打開拍賣場就自動掃：" .. (DB.auto and "開" or "關"))
		if refreshPage then refreshPage() end
	elseif msg == "提示" or msg == "tooltip" then
		DB.tooltip = not tooltipOn()
		say("滑鼠提示顯示拍賣場價錢：" .. (DB.tooltip and "開" or "關"))
	else
		say((statusText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\n", "；")))
		say("指令：/拍賣掃描 掃｜/拍賣掃描 自動（開關自動掃）｜/拍賣掃描 提示（開關滑鼠提示的價錢）；拍賣場下面的「掃描」分頁也看得到")
	end
end
