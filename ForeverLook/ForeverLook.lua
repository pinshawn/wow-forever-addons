-- 一鍵推薦外觀（Forever Look）
-- Puts a ready-made look for Polestar and Questie in a profile named "推薦"
-- in each addon, next to the player's own, and switches between them. The
-- player's own profiles are never written to: going back is a switch.
--
-- How it switches (the same path both addons take when they load):
--   Polestar: its public profiles API (Polestar.Profiles: New, Exists,
--             Active, Switch; Polestar/Core/Profiles.lua). The "推薦"
--             profile is a plain settings table, like PolestarDB.settings.
--   Questie:  its AceDB saved table: QuestieConfig.profiles["推薦"] and
--             QuestieConfig.profileKeys[character] = "推薦". AceDB reads
--             profileKeys when Questie loads, so nothing changes live.
--   Then the UI reloads, so both addons start on the chosen profile. The
--   game does not let an addon's own code reload the UI (ADDON_ACTION_BLOCKED
--   'Reload()', seen 11/23), so every button that switches is a secure macro
--   button running "/reload": PreClick (ours) writes the saved tables, then
--   the game's own secure click handler runs the /reload macro.
-- Also: with the recommended look on and Polestar loaded, seven of Polestar's
-- map layers are hidden through Polestar.Pins.SetLayerVisible (spawn areas,
-- other goals' areas, "while you're here" areas, small spot dots, the target
-- pin; since 1.1 also the step's other goals and the "while you're here"
-- pins, round drop-shaped marks Polestar draws in the skin's medallion;
-- Polestar/Nav/Layers.lua). The travel route's stops stay. The game's quest
-- objective areas (CVar questPOI) are turned on,
-- because the recommended Questie leaves objective areas to the game. The
-- player's earlier questPOI value comes back when they switch back.
--
-- Where to switch: the "推" minimap button (OneForAll's minimap button bar
-- collects it), /推薦 (or /flook), and Esc > Options > AddOns > 一鍵推薦外觀.
-- The first time it loads it asks, in a dialog drawn like the game's own.

local ADDON, ns = ...
local REC = "推薦"
local TITLE = "一鍵推薦外觀"
local ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Icon"
local HOW = "之後想換回來或再換過去：\n・點小地圖旁的「推」圓鈕\n・或聊天框打 /推薦\n・或 Esc → 選項 → 插件 → " .. TITLE
local LAYERS = { "nav.areas", "nav.goalAreas", "nav.hereAreas", "nav.spots", "nav.target",
	"nav.goals", "nav.here" }
-- Kept from the player's own copy when the recommended look is written again:
-- where they put things on their screen.
local PS_KEEP = { { "nav", "arrowPos" }, { "ui", "pos" }, { "ui", "shown" } }
local Q_KEEP = { "TrackerLocation", "TrackerHeight", "TrackerWidth", "ldbDisplayText",
	"tutorialRejectInBattlegroundsDone", "tutorialShowRunesDone" }

-- ForeverLookDB: { choice = "rec" | "own", version, prev = { polestar, questie = { [char] = profile }, questPOI },
--                  skip = { [char] = true }, mmAngle }
local db

local function say(msg)
	print("|cff66ccff" .. TITLE .. "|r：" .. msg)
end

local function deepCopy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = deepCopy(x) end
	return out
end

local function clear(t)
	for k in pairs(t) do t[k] = nil end
end

---------------------------------------------------------------------------
-- Which addons are here
---------------------------------------------------------------------------

local function PS()
	local P = Polestar and Polestar.Profiles
	if type(P) == "table" and P.New and P.Exists and P.Active and P.Switch and type(PolestarDB) == "table" then
		return P
	end
end

local function psDB()
	return (Polestar and Polestar.DB and Polestar.DB()) or PolestarDB
end

local function QS()
	if type(Questie) == "table" and type(Questie.db) == "table" and type(Questie.db.keys) == "table"
		and type(QuestieConfig) == "table" and type(QuestieConfig.profiles) == "table"
		and type(QuestieConfig.profileKeys) == "table" then
		return Questie.db.keys.char
	end
end

local function names()
	local P, Q = PS() and "Polestar", QS() and "Questie"
	if P and Q then return P .. " 和 " .. Q end
	return P or Q
end

local function polestarOnRec()
	local P = PS()
	return P and P.Active() == REC
end

local function isRec()
	return db and db.choice == "rec"
end

---------------------------------------------------------------------------
-- Writing the recommended look into the "推薦" profiles
---------------------------------------------------------------------------

-- Where things sit on the screen comes from the recommended copy itself, or,
-- the first time, from the profile the player was using (src).
local function fillPolestar(t, src)
	local keep = {}
	for i, path in ipairs(PS_KEEP) do
		local g, h = t[path[1]], src and src[path[1]]
		local v = type(g) == "table" and g[path[2]] or nil
		if v == nil and type(h) == "table" then v = deepCopy(h[path[2]]) end
		keep[i] = v
	end
	clear(t)
	for k, v in pairs(ns.POLESTAR) do t[k] = deepCopy(v) end
	for i, path in ipairs(PS_KEEP) do
		if keep[i] ~= nil then
			if type(t[path[1]]) ~= "table" then t[path[1]] = {} end
			t[path[1]][path[2]] = keep[i]
		end
	end
end

local function fillQuestie(t, withPolestar, src)
	local keep = {}
	for _, k in ipairs(Q_KEEP) do
		local v = t[k]
		if v == nil and src then v = deepCopy(src[k]) end
		keep[k] = v
	end
	clear(t)
	-- Questie's defaults first: the profile in use holds them (AceDB copies them in), and Questie
	-- reads them until the reload (an empty value there stopped its minimap fade, 11/23).
	local defaults = Questie and Questie.db and Questie.db.defaults and Questie.db.defaults.profile
	if type(defaults) == "table" then
		for k, v in pairs(defaults) do
			if k ~= "*" and k ~= "**" then t[k] = deepCopy(v) end
		end
	end
	for k, v in pairs(ns.QUESTIE) do t[k] = deepCopy(v) end
	for k, v in pairs(keep) do t[k] = v end
	-- Polestar's skull and count on nameplates stand in for Questie's; without Polestar, Questie's stay.
	t.nameplateEnabled = not withPolestar
end

local function inCombat()
	if InCombatLockdown and InCombatLockdown() then
		say("戰鬥中不能切換，打完再切換一次。")
		return true
	end
end

local function applyRec()
	if inCombat() then return false end
	db.prev = db.prev or {}
	db.prev.questie = db.prev.questie or {}
	local P = PS()
	if P then
		if P.Active() == REC then
			fillPolestar(psDB().settings)
		else
			if db.prev.polestar == nil then db.prev.polestar = P.Active() end
			if not P.Exists(REC) then P.New(REC) end
			local store = psDB().profiles
			if type(store) == "table" and type(store[REC]) == "table" then
				fillPolestar(store[REC], psDB().settings)
				P.Switch(REC)
			end
		end
	end
	local char = QS()
	if char then
		if type(QuestieConfig.profiles[REC]) ~= "table" then QuestieConfig.profiles[REC] = {} end
		local current = QuestieConfig.profiles[QuestieConfig.profileKeys[char] or "Default"]
		fillQuestie(QuestieConfig.profiles[REC], P ~= nil, type(current) == "table" and current or nil)
		-- Every character Questie knows on this account; one it meets later is asked at its login.
		QuestieConfig.profileKeys[char] = QuestieConfig.profileKeys[char] or "Default"
		for key, prof in pairs(QuestieConfig.profileKeys) do
			if prof ~= REC then
				db.prev.questie[key] = prof
				QuestieConfig.profileKeys[key] = REC
			end
		end
		-- Questie's first-run "which objectives?" choice would rewrite the recommended profile.
		if type(QuestieConfig.global) ~= "table" then QuestieConfig.global = {} end
		QuestieConfig.global.tutorialObjectiveTypeChosen = true
		if db.prev.questPOI == nil and GetCVar then db.prev.questPOI = GetCVar("questPOI") end
		if SetCVar then SetCVar("questPOI", "1") end
	end
	db.choice = "rec"
	db.version = ns.VERSION
	db.skip = nil
	return true -- the secure button's /reload follows
end

local function applyOwn()
	if inCombat() then return false end
	local prev = db.prev or {}
	local P = PS()
	if P and P.Active() == REC then
		local back = prev.polestar
		if type(back) ~= "string" or back == REC or not P.Exists(back) then back = "Default" end
		P.Switch(back)
	end
	if QS() then
		local qprev = prev.questie or {}
		for key, prof in pairs(QuestieConfig.profileKeys) do
			if prof == REC then
				local back = qprev[key]
				if type(back) ~= "string" or back == REC or type(QuestieConfig.profiles[back]) ~= "table" then back = "Default" end
				QuestieConfig.profileKeys[key] = back
			end
		end
		if prev.questPOI ~= nil and SetCVar then SetCVar("questPOI", prev.questPOI) end
	end
	db.choice = "own"
	db.prev = nil
	db.skip = nil
	return true -- the secure button's /reload follows
end

---------------------------------------------------------------------------
-- Windows drawn like the game's own dialogs (gold border, black, header plate)
---------------------------------------------------------------------------

local BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local function dialogFrame(name, w, h)
	local ok, f = pcall(CreateFrame, "Frame", name, UIParent, "BackdropTemplate")
	if not ok or not f then f = CreateFrame("Frame", name, UIParent) end
	if f.SetBackdrop then pcall(f.SetBackdrop, f, BACKDROP) end
	f:SetSize(w, h)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	local header = f:CreateTexture(nil, "ARTWORK")
	header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	header:SetSize(300, 64)
	header:SetPoint("TOP", f, "TOP", 0, 12)
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOP", header, "TOP", 0, -14)
	f.title:SetText(TITLE)
	local okC, close = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
	if okC and close then close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4) end
	if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, name) end
	f:Hide()
	return f
end

local function wowButton(parent, w)
	local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
	if not ok or not b then b = CreateFrame("Button", nil, parent) end
	b:SetSize(w or 130, 24)
	return b
end

-- A button that reloads the UI the way typing /reload does: the game's secure
-- click handler runs the macro, after our PreClick has written the switch.
local function reloadButton(parent, w)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate,SecureActionButtonTemplate")
	b:SetSize(w or 130, 24)
	b:RegisterForClicks("LeftButtonUp")
	b:SetAttribute("type", "macro")
	b:SetAttribute("macrotext", "/reload")
	b:SetAttribute("useOnKeyDown", false)
	return b
end

-- Windows holding a secure button cannot be shown in combat: wait for it to end.
local afterCombat = {}
local function outOfCombat(fn)
	if InCombatLockdown and InCombatLockdown() then
		afterCombat[#afterCombat + 1] = fn
		return false
	end
	fn()
	return true
end

-- Our windows hold a secure button, so our own code may not hide them in combat:
-- then they close when it ends.
local function hideSafe(frame)
	if InCombatLockdown and InCombatLockdown() then
		afterCombat[#afterCombat + 1] = function() frame:Hide() end
	else
		frame:Hide()
	end
end

-- One dialog for every question: text and one or two buttons. Closing it
-- (the X or Esc) counts as the second button.
local ask
local function showAskNow(kind, text, yes, onYes, no, onNo)
	if not ask then
		ask = dialogFrame("ForeverLookDialog", 440, 240)
		ask.text = ask:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		ask.text:SetPoint("TOP", ask, "TOP", 0, -38)
		ask.text:SetWidth(390)
		ask.text:SetJustifyH("LEFT")
		if ask.text.SetSpacing then ask.text:SetSpacing(3) end
		ask.yes = reloadButton(ask, 130)
		ask.no = wowButton(ask, 130)
		ask:SetScript("OnHide", function(self)
			local cb = self.onClose
			self.onClose = nil
			if cb then cb() end
		end)
	end
	ask.onClose = nil
	ask:Hide()
	ask.kind = kind
	ask.text:SetText(text)
	local th = ask.text.GetStringHeight and tonumber(ask.text:GetStringHeight()) or 0
	ask:SetHeight(math.max(170, th + 100))
	ask.yes:SetText(yes)
	ask.yes:ClearAllPoints()
	ask.yes:SetScript("PreClick", function()
		ask.onClose = nil
		if onYes then onYes() end
	end)
	if no then
		ask.yes:SetPoint("BOTTOMRIGHT", ask, "BOTTOM", -6, 20)
		ask.no:ClearAllPoints()
		ask.no:SetPoint("BOTTOMLEFT", ask, "BOTTOM", 6, 20)
		ask.no:SetText(no)
		ask.no:SetScript("OnClick", function() -- OnHide runs onNo
			if InCombatLockdown and InCombatLockdown() then
				local cb = ask.onClose
				ask.onClose = nil
				if cb then cb() end
			end
			hideSafe(ask)
		end)
		ask.no:Show()
	else
		ask.yes:SetPoint("BOTTOM", ask, "BOTTOM", 0, 20)
		ask.no:Hide()
	end
	ask:Show()
	ask.onClose = onNo
end

local function showAsk(...)
	local args = { ... }
	local n = select("#", ...)
	outOfCombat(function() showAskNow(unpack(args, 1, n)) end)
end

local function askFirst()
	showAsk("first",
		"要把 " .. names() .. " 換成推薦的外觀嗎？\n（你原本自己的設定會留著，隨時可以換回來）\n\n" .. HOW .. "\n\n按「好」會重新載入介面（畫面黑幾秒）。",
		"好", function() applyRec() end,
		"先不要", function()
			if db.choice ~= nil then return end -- seen again with /推薦 第一次: nothing changes
			db.choice = "own"
			say("好，先不換。之後想換：點小地圖旁的「推」圓鈕，或聊天框打 /推薦，或 Esc → 選項 → 插件 → " .. TITLE .. "。")
		end)
end

local function askUpdate()
	showAsk("update",
		"推薦外觀有更新，要換成新的嗎？\n（只改「推薦」那一套，你自己的設定不會動）\n\n按「好」會重新載入介面。",
		"好", function() applyRec() end,
		"先不要", function() db.version = ns.VERSION end)
end

local function askThisCharacter(char)
	showAsk("char",
		"推薦外觀還有一部分沒套到這個角色\n（例如這是新角色，或是剛把 Polestar 打開），要現在套用嗎？\n\n按「好」會重新載入介面。",
		"好", function() applyRec() end,
		"這個角色不要", function()
			db.skip = db.skip or {}
			db.skip[char] = true
			say("這個角色先不換。要換的話點小地圖的「推」圓鈕，或打 /推薦。")
		end)
end

---------------------------------------------------------------------------
-- The map layers (what Polestar Quiet Map did)
---------------------------------------------------------------------------

local mapQuiet = true
local function applyMap()
	local Pins = Polestar and Polestar.Pins
	if not (Pins and Pins.SetLayerVisible) then return end
	local hide = mapQuiet and isRec() and polestarOnRec()
	for _, name in ipairs(LAYERS) do pcall(Pins.SetLayerVisible, name, not hide) end
end

---------------------------------------------------------------------------
-- The switch window (minimap button, /推薦)
---------------------------------------------------------------------------

local main, minimapButton
local function statusText()
	if not names() then return "沒有找到 Polestar 或 Questie（都沒開的話，這個插件不會做任何事）。" end
	if isRec() then return "目前：|cff33ff33推薦外觀|r（" .. names() .. "）" end
	return "目前：|cffffcc00你自己的設定|r（" .. names() .. "）"
end

local function updateButtonLook()
	if minimapButton and minimapButton.icon and minimapButton.icon.SetDesaturated then
		minimapButton.icon:SetDesaturated(not isRec())
	end
end

local function updateMinimapShown()
	if minimapButton then minimapButton:Show() end
end

local function refreshMain()
	if not main then return end
	main.status:SetText(statusText())
	main.switch:SetText(isRec() and "換回我自己的設定" or "換成推薦外觀")
end

local function showMainNow()
	if not main then
		main = dialogFrame("ForeverLookMain", 420, 220)
		main.kind = "main"
		local about = main:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		about:SetPoint("TOP", main, "TOP", 0, -38)
		about:SetWidth(370)
		about:SetJustifyH("LEFT")
		about:SetText("在 Polestar 和 Questie 裡各放一套「推薦」設定，跟你自己的設定互相切換。你自己的設定不會被改。切換時會重新載入介面（畫面黑幾秒）。")
		main.status = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		main.status:SetPoint("TOP", about, "BOTTOM", 0, -14)
		-- A secure button may only be anchored to frames, never to a text or a texture
		-- (11/23: "Cannot anchor protected frames to regions" left it without a place).
		main.switch = reloadButton(main, 170)
		main.switch:SetPoint("BOTTOM", main, "BOTTOM", 0, 24)
		main.switch:SetScript("PreClick", function()
			if not names() then return end
			if isRec() then applyOwn() else applyRec() end
		end)
		-- No 關閉 button: the × at the top right and Esc close it (11/23 22:46).
	end
	refreshMain()
	main:Show()
end

local function showMain()
	if not outOfCombat(showMainNow) then say("戰鬥結束後會打開切換視窗。") end
end

local function toggleMain()
	if main and main:IsShown() then
		if not (InCombatLockdown and InCombatLockdown()) then main:Hide() end
	else
		showMain()
	end
end

-- Minimap button: a named button on the minimap, the same shape as the game's
-- tracking button, so OneForAll's "collect minimap buttons" bar takes it in.
local atan2 = math.atan2 or math.atan

local function placeMinimapButton()
	if not (minimapButton and Minimap) or minimapButton:GetParent() ~= Minimap then return end
	local a = math.rad((db and db.mmAngle) or 235)
	local r = (Minimap:GetWidth() or 140) / 2 + 10
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function createMinimapButton()
	if minimapButton or not Minimap then return end
	local b = CreateFrame("Button", "ForeverLookMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetSize(20, 20)
	bg:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -5)
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(19, 19)
	icon:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -6)
	b.icon = icon
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	b:SetScript("OnClick", function() toggleMain() end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(TITLE, 1, 0.82, 0)
		GameTooltip:AddLine(statusText(), 1, 1, 1)
		GameTooltip:AddLine("點一下：打開切換視窗", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("拖曳：沿著小地圖移動", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:SetScript("OnDragStart", function(self)
		if self:GetParent() ~= Minimap then return end -- in OneForAll's bar it stays put
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			if not (mx and px and scale and scale > 0) then return end
			db.mmAngle = math.deg(atan2(py / scale - my, px / scale - mx)) % 360
			placeMinimapButton()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	minimapButton = b
	placeMinimapButton()
end

-- Made as soon as the file loads (OneForAll looks for minimap buttons 1, 5
-- and 15 seconds after login); placed and shown once the saved settings are in.
createMinimapButton()

function ForeverLook_OnCompartmentClick()
	showMain()
end

---------------------------------------------------------------------------
-- Esc > Options > AddOns
---------------------------------------------------------------------------

local panelStatus
local function refreshPanel()
	if panelStatus then panelStatus:SetText(statusText()) end
end

local function makePanel()
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local f = CreateFrame("Frame")
	f.name = TITLE
	local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(TITLE)
	local about = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	about:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
	about:SetWidth(560)
	about:SetJustifyH("LEFT")
	about:SetText("在 Polestar 和 Questie 裡各放一套「推薦」設定，可以跟你自己的設定互相切換。\n你自己的設定不會被改，換回來就回到原本的樣子。切換時會重新載入介面。\n按下面的按鈕，或點小地圖旁的「推」圓鈕，或聊天框打 /推薦，都會打開切換視窗。")
	panelStatus = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	panelStatus:SetPoint("TOPLEFT", about, "BOTTOMLEFT", 0, -16)
	-- A plain button: secure buttons inside the game's Options window would make it protected.
	local open = wowButton(f, 180)
	open:SetPoint("TOPLEFT", panelStatus, "BOTTOMLEFT", 0, -14)
	open:SetText("打開切換視窗")
	open:SetScript("OnClick", function() if names() then showMain() end end)
	f:SetScript("OnShow", refreshPanel)
	local category = Settings.RegisterCanvasLayoutCategory(f, TITLE)
	Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", function(_, event, arg)
	if event == "PLAYER_REGEN_ENABLED" then
		local list = afterCombat
		afterCombat = {}
		for _, fn in ipairs(list) do fn() end
		return
	end
	if event == "ADDON_LOADED" then
		if arg ~= ADDON then return end
		if type(ForeverLookDB) ~= "table" then ForeverLookDB = {} end
		db = ForeverLookDB
		-- Questie's nameplate icons follow whether Polestar's are there (Polestar turned off later: Questie's come back).
		local char = QS()
		if char and isRec() and QuestieConfig.profileKeys[char] == REC and type(QuestieConfig.profiles[REC]) == "table" then
			QuestieConfig.profiles[REC].nameplateEnabled = not polestarOnRec()
		end
		createMinimapButton()
		placeMinimapButton()
		updateMinimapShown()
		updateButtonLook()
		pcall(makePanel)
		return
	end
	-- PLAYER_LOGIN
	applyMap()
	if not names() then
		if minimapButton then minimapButton:Hide() end
		return
	end
	local char = QS()
	if db.choice == nil then
		C_Timer.After(3, askFirst)
	elseif isRec() then
		if (db.version or 0) < ns.VERSION then
			C_Timer.After(3, askUpdate)
		elseif (char and QuestieConfig.profileKeys[char] ~= REC or (PS() and not polestarOnRec()))
			and not (db.skip and char and db.skip[char]) then
			C_Timer.After(3, function() askThisCharacter(char or "?") end)
		end
	end
end)

SLASH_FOREVERLOOK1 = "/推薦"
SLASH_FOREVERLOOK2 = "/flook"
SlashCmdList.FOREVERLOOK = function(msg)
	if not db then return end
	if msg == "第一次" or msg == "first" then -- the first-login question again (to see it, or to answer it again)
		if names() then askFirst() end
		return
	end
	if msg == "地圖" or msg == "map" then
		mapQuiet = not mapQuiet
		applyMap()
		say(mapQuiet and "地圖上 Polestar 的黃框、黃點、水滴標記藏起來了。" or "地圖上 Polestar 的黃框、黃點、水滴標記顯示中（只到這次登出）。")
		return
	end
	showMain()
end
