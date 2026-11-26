-- ForeverQuestMark: a skull on the nameplate of a quest mob when the game
-- hides the mob's identity (World of Warcraft: Forever, mostly inside
-- dungeons).
--
-- Copyright (C) 2026 wow-forever-addons
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, version 3 of the License (see LICENSE.txt).
--
-- Why: nameplate quest icons (Polestar, Questie) find a mob by the npc id in
-- its GUID. Inside Forever's instances the game hands GUIDs out as secret
-- values, so those addons can't tell which mob it is and draw nothing.
-- C_QuestLog.UnitIsRelatedToActiveQuest has no secret flag in Forever's API
-- documentation (1.60.1, QuestLogDocumentation.lua), and it answered on
-- real mobs inside the Stockade (webjhon/addonsWoWForever pull request 7).
--
-- What it does:
--   * Only a plate whose GUID was secret when it appeared is looked at; with
--     a readable GUID the plate is left to Polestar or Questie, so the two
--     never draw on the same plate.
--   * The game is asked whether the unit is related to one of the player's
--     active quests (kill targets and mobs that drop a quest item both count;
--     Stakeout's FOREVER-PROBE.md). A secret answer counts as "no".
--   * Only units the player can attack get the mark.
--   * The game may keep saying "related" after an objective is done
--     (ForeverAddons-Issues issue 1). Inside an instance, when the quest log
--     has a header with the instance's name and every quest under it is
--     complete, no mark is drawn.
--   * The mark is the game's raid skull, the same texture Polestar uses on
--     nameplates, left of the health bar. There is no "3/8": the game only
--     says related or not.

local ADDON = ...
local DB

local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local ICON_SIZE, ICON_MIN, ICON_MAX = 16, 14, 20
local ICON_GAP = 3
local ICON_LIFT = 5

local issecret = issecretvalue or function() return false end
local hasSecrets = issecretvalue ~= nil

local secretAtAdd = {} -- unit -> true when its GUID was secret as the plate appeared
local icons = {}       -- unit -> icon frame
local pool = {}

local function say(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff副本任務怪標記：|r" .. msg)
end

local function plateFor(unit)
	if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
	local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
	if ok and type(plate) == "table" then return plate end
	return nil
end

local function shown(f)
	if type(f) ~= "table" or type(f.IsShown) ~= "function" then return false end
	if f.IsForbidden and f:IsForbidden() then return false end
	return f:IsShown() and true or false
end

-- true / false / nil (nil: could not ask, or the answer was secret).
local function safeCall(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok or v == nil or issecret(v) then return nil end
	return v
end

local function guidIsSecret(unit)
	if not hasSecrets then return false end
	local ok, guid = pcall(UnitGUID, unit)
	if not ok then return false end
	return issecret(guid) and true or false
end

---------------------------------------------------------------------------
-- This instance's quests: the quest log header named like the instance.
---------------------------------------------------------------------------

-- found (number of quests under the header), done (how many are complete).
local function instanceQuests()
	if not (IsInInstance and C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return 0, 0 end
	local inside = safeCall(IsInInstance)
	if not inside then return 0, 0 end
	local name = GetInstanceInfo and safeCall(GetInstanceInfo)
	if type(name) ~= "string" or name == "" then return 0, 0 end
	local n = safeCall(C_QuestLog.GetNumQuestLogEntries) or 0
	local inGroup, found, done = false, 0, 0
	for i = 1, n do
		local ok, info = pcall(C_QuestLog.GetInfo, i)
		if ok and type(info) == "table" and not issecret(info.title) then
			if info.isHeader then
				inGroup = (info.title == name)
			elseif inGroup and not info.isHidden and type(info.questID) == "number" then
				found = found + 1
				local q = info.questID
				if safeCall(C_QuestLog.IsComplete, q) or safeCall(C_QuestLog.ReadyForTurnIn, q) then
					done = done + 1
				end
			end
		end
	end
	return found, done
end

-- Cached per refresh round; cleared when the quest log or the zone changes.
local instanceCache
local function instanceAllDone()
	if not instanceCache then
		local found, done = instanceQuests()
		instanceCache = { found = found, done = done }
	end
	return instanceCache.found > 0 and instanceCache.done >= instanceCache.found
end

---------------------------------------------------------------------------
-- Decision
---------------------------------------------------------------------------

-- want (bool), why (short Chinese reason, for /任務怪 測).
local function wanted(unit)
	if not DB.enabled then return false, "插件關著（/任務怪 打開）" end
	if not secretAtAdd[unit] then return false, "遊戲沒藏這隻怪的編號：交給 Polestar／Questie 畫" end
	if safeCall(UnitIsDead, unit) == true then return false, "這隻已經死了" end
	if safeCall(UnitCanAttack, "player", unit) == false then return false, "這隻不能打" end
	local related = C_QuestLog and safeCall(C_QuestLog.UnitIsRelatedToActiveQuest, unit)
	if related == nil then return false, "遊戲沒回答有沒有關（被藏或不支援）" end
	if not related then return false, "遊戲說跟你的任務沒關" end
	if instanceAllDone() then return false, "這個副本的任務你都做完了" end
	return true, "遊戲說跟你的任務有關"
end

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------

local function place(f, plate)
	local uf = plate.UnitFrame
	local bar = shown(uf) and shown(uf.healthBar) and uf.healthBar or nil
	local ok = pcall(function()
		f:SetParent(plate)
		f:ClearAllPoints()
		if bar then
			local s = math.floor(bar:GetHeight() + 0.5)
			if s < ICON_MIN then s = ICON_MIN elseif s > ICON_MAX then s = ICON_MAX end
			f:SetSize(s, s)
			f:SetPoint("RIGHT", bar, "LEFT", -ICON_GAP, 0)
			f:SetFrameStrata(bar:GetFrameStrata())
			f:SetFrameLevel(bar:GetFrameLevel() + ICON_LIFT)
		else
			f:SetSize(ICON_SIZE, ICON_SIZE)
			f:SetPoint("BOTTOM", plate, "TOP", 0, -2)
		end
	end)
	return ok
end

local function release(unit)
	local f = icons[unit]
	if not f then return end
	icons[unit] = nil
	f:Hide()
	f:ClearAllPoints()
	f:SetParent(nil)
	pool[#pool + 1] = f
end

local function update(unit)
	if not wanted(unit) then
		release(unit)
		return
	end
	if icons[unit] then
		icons[unit]:Show()
		return
	end
	local plate = plateFor(unit)
	if not plate then return end
	local f = pool[#pool]
	if f then
		pool[#pool] = nil
	else
		f = CreateFrame("Frame")
		f.tex = f:CreateTexture(nil, "OVERLAY")
		f.tex:SetAllPoints(f)
		f.tex:SetTexture(SKULL)
	end
	if not place(f, plate) then
		f:Hide()
		pool[#pool + 1] = f
		return
	end
	icons[unit] = f
	f:Show()
end

local function plateUnit(plate)
	if type(plate) ~= "table" then return nil end
	local u = plate.namePlateUnitToken
	if type(u) ~= "string" and type(plate.UnitFrame) == "table" then u = plate.UnitFrame.unit end
	return type(u) == "string" and u or nil
end

-- Plates already up (after a /reload or a loading screen): treated as if
-- they had just appeared.
local function scanPlates()
	if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
	local ok, plates = pcall(C_NamePlate.GetNamePlates)
	if not ok or type(plates) ~= "table" then return end
	for _, plate in ipairs(plates) do
		local u = plateUnit(plate)
		if u and secretAtAdd[u] == nil and guidIsSecret(u) then secretAtAdd[u] = true end
	end
end

local function refreshAll()
	instanceCache = nil
	for unit in pairs(secretAtAdd) do update(unit) end
end

local pending = false
local function refreshSoon()
	if pending then return end
	pending = true
	local function run()
		pending = false
		refreshAll()
	end
	if C_Timer and C_Timer.After then C_Timer.After(0.2, run) else run() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		ForeverQuestMarkDB = type(ForeverQuestMarkDB) == "table" and ForeverQuestMarkDB or {}
		DB = ForeverQuestMarkDB
		if DB.enabled == nil then DB.enabled = true end
		ev:UnregisterEvent("ADDON_LOADED")
		ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
		ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
		ev:RegisterEvent("QUEST_LOG_UPDATE")
		ev:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
		ev:RegisterEvent("PLAYER_ENTERING_WORLD")
		ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		if type(arg1) ~= "string" then return end
		if guidIsSecret(arg1) then
			secretAtAdd[arg1] = true
			update(arg1)
		else
			secretAtAdd[arg1] = nil
			release(arg1)
		end
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		if type(arg1) ~= "string" then return end
		secretAtAdd[arg1] = nil
		release(arg1)
	elseif event == "UNIT_QUEST_LOG_CHANGED" then
		if arg1 == "player" then refreshSoon() end
	elseif event == "PLAYER_ENTERING_WORLD" then
		scanPlates()
		refreshSoon()
	else
		refreshSoon()
	end
end)

---------------------------------------------------------------------------
-- /任務怪
---------------------------------------------------------------------------

local function yn(v) if v == nil then return "不知道" end return v and "是" or "否" end

local function test()
	local u = "target"
	if not (UnitExists and UnitExists(u)) then
		say("先點選一隻怪，再打 /任務怪 測")
		return
	end
	local related = C_QuestLog and C_QuestLog.UnitIsRelatedToActiveQuest
	local okR, r = false, nil
	if type(related) == "function" then okR, r = pcall(related, u) end
	local rText = not okR and "問不到" or issecret(r) and "被藏" or (r and "有關" or "沒關")
	local found, done = instanceQuests()
	say(("編號被藏：%s｜遊戲說：%s｜可以打：%s｜這個副本的任務：%d 個、做完 %d 個"):format(
		yn(guidIsSecret(u)), rText, yn(safeCall(UnitCanAttack, "player", u)), found, done))
	-- The target's own plate decides the mark: its GUID state as it appeared.
	if C_NamePlate and C_NamePlate.GetNamePlates then
		local ok, plates = pcall(C_NamePlate.GetNamePlates)
		if ok and type(plates) == "table" then
			for _, plate in ipairs(plates) do
				local pu = plateUnit(plate)
				if pu and safeCall(UnitIsUnit, pu, u) then
					local want, why = wanted(pu)
					say((want and "名條：有骷髏（" or "名條：沒骷髏（") .. why .. "）")
					return
				end
			end
		end
	end
	say("這隻現在沒有名條（太遠或名條關著）")
end

SLASH_FOREVERQUESTMARK1 = "/任務怪"
SLASH_FOREVERQUESTMARK2 = "/fqm"
SlashCmdList.FOREVERQUESTMARK = function(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "測" or msg == "test" then
		test()
		return
	end
	DB.enabled = not DB.enabled
	refreshAll()
	say(DB.enabled and "打開了（副本裡任務怪名條左邊會有骷髏）。" or "關掉了。再打一次 /任務怪 打開。")
end
