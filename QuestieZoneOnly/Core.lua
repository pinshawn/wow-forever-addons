--===========================================================================
-- Questie 只顯示這一區：右邊的任務追蹤只畫「現在所在區域」的任務
-- 作法：Questie 畫任務那一段（QuestSection.Draw）收到的任務清單先過濾，只留區域名稱跟你現在
-- 所在的區域（大區、小區、地圖名稱任一個）一樣的任務。不改 Questie 的檔案、不動追蹤設定。
--===========================================================================
local ADDON = ...

local function say(msg)
    print("|cff66ccff[只看這區]|r " .. msg)
end

local QL = QuestieLoader
if type(QL) ~= "table" or type(QL.ImportModule) ~= "function" then
    say("找不到 Questie，這個插件不會有作用。")
    return
end

local QuestSection = QL:ImportModule("QuestSection")
local TrackerUtils = QL:ImportModule("TrackerUtils")
local QuestieTracker = QL:ImportModule("QuestieTracker")
local TrackerHeaderFrame = QL:ImportModule("TrackerHeaderFrame")
local QuestieCombatQueue = QL:ImportModule("QuestieCombatQueue")

if type(QuestSection.Draw) ~= "function" then
    say("這一版 Questie 的程式改過了，找不到畫任務的地方；這個插件先不動作。")
    return
end

local function isOn()
    return not (type(QuestieZoneOnlyDB) == "table" and QuestieZoneOnlyDB.on == false)
end

-----------------------------------------------------------------------------
-- 現在在哪：大區、小區、小地圖上的名字、地圖名稱（任一個跟任務的區域一樣就算）
-----------------------------------------------------------------------------
local here, hereKey = {}, nil

local function refreshHere()
    local set, list = {}, {}
    local function add(name)
        if type(name) == "string" and name ~= "" and not set[name] then
            set[name] = true
            list[#list + 1] = name
        end
    end
    if GetRealZoneText then add(GetRealZoneText()) end
    if GetZoneText then add(GetZoneText()) end
    if GetSubZoneText then add(GetSubZoneText()) end
    if GetMinimapZoneText then add(GetMinimapZoneText()) end
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo then
        local mapId = C_Map.GetBestMapForUnit("player")
        local info = mapId and C_Map.GetMapInfo(mapId)
        if info then add(info.name) end
    end
    table.sort(list)
    local key = table.concat(list, "|")
    local changed = key ~= hereKey
    here, hereKey = set, key
    return changed
end

-- 任務屬於哪一區：任務日誌裡的區域標題 → Questie 資料庫的區域 → Questie 分組名稱
local function questZone(detail)
    local quest = detail and detail.quest
    if not quest then return nil end
    if type(quest.zoneName) == "string" and quest.zoneName ~= "" then
        return quest.zoneName
    end
    local zone = quest.zoneOrSort
    if type(zone) == "number" and zone > 0 and type(TrackerUtils.GetZoneNameByID) == "function" then
        local ok, name = pcall(TrackerUtils.GetZoneNameByID, TrackerUtils, zone)
        if ok and type(name) == "string" then return name end
    end
    return detail.zoneName
end

local function filter(sortedQuestIds, questDetails)
    if not isOn() or type(sortedQuestIds) ~= "table" or type(questDetails) ~= "table" then
        return sortedQuestIds
    end
    refreshHere()
    local out = {}
    for _, questId in ipairs(sortedQuestIds) do
        local zone = questZone(questDetails[questId])
        if zone and here[zone] then
            out[#out + 1] = questId
        end
    end
    return out
end

-- 接在 Questie 畫任務之前（Questie 每次都是用 QuestSection.Draw(...) 呼叫，換掉欄位就會用到）
local origDraw = QuestSection.Draw
QuestSection.Draw = function(sortedQuestIds, questDetails, ...)
    return origDraw(filter(sortedQuestIds, questDetails), questDetails, ...)
end
local origHasItems = QuestSection.HasVisibleQuestItems
if type(origHasItems) == "function" then
    QuestSection.HasVisibleQuestItems = function(sortedQuestIds, questDetails, ...)
        return origHasItems(filter(sortedQuestIds, questDetails), questDetails, ...)
    end
end

local function redraw()
    if not (QuestieTracker and QuestieTracker.started and type(QuestieTracker.Update) == "function") then return end
    if type(QuestieCombatQueue) == "table" and type(QuestieCombatQueue.Queue) == "function" then
        QuestieCombatQueue:Queue(function() QuestieTracker:Update() end)
    else
        QuestieTracker:Update()
    end
end

-----------------------------------------------------------------------------
-- 追蹤框標題旁的切換鈕：[只看這區] / [全部區域]
-----------------------------------------------------------------------------
local toggleButton
local setOn

local function styleButton()
    if not toggleButton then return end
    toggleButton.text:SetText(isOn() and "|cffffd100[只看這區]|r" or "|cff9d9d9d[全部區域]|r")
    local w = toggleButton.text:GetStringWidth() or 60
    local _, size = toggleButton.text:GetFont()
    toggleButton:SetSize(w + 4, (size or 12) + 4)
end

local function placeButton()
    local header = TrackerHeaderFrame.headerFrame or _G.Questie_HeaderFrame
    if not (header and header.trackedQuests and header.trackedQuests.label) then return end
    if not toggleButton then
        local b = CreateFrame("Button", "QuestieZoneOnlyToggle", header)
        b.text = b:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        b.text:SetPoint("LEFT", b, "LEFT", 2, 0)
        b:RegisterForClicks("LeftButtonUp")
        b:SetScript("OnClick", function() setOn(nil) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:AddLine("Questie 只顯示這一區", 1, 0.82, 0)
            GameTooltip:AddLine(isOn() and "現在：只顯示你所在區域的任務" or "現在：顯示全部區域的任務", 1, 1, 1)
            GameTooltip:AddLine("點一下切換（也可以打 /這區任務）", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        toggleButton = b
    end
    local label = header.trackedQuests.label
    local font, size, flags = label:GetFont()
    if font then pcall(toggleButton.text.SetFont, toggleButton.text, font, size, flags) end
    toggleButton:ClearAllPoints()
    toggleButton:SetPoint("LEFT", label, "RIGHT", 6, 0)
    styleButton()
    if header:IsShown() then
        toggleButton:Show()
        -- 讓 Questie 算追蹤框寬度時把這個按鈕也算進去：Questie 每次更新都先重設標題寬度、再用它當追蹤框最小寬度，
        -- 不加的話，任務少、追蹤框變窄時，按鈕會超出框外（框靠右放時會被螢幕右邊切掉）。
        local bw = toggleButton:GetWidth() or 0
        local hw = header:GetWidth() or 0
        if bw > 0 and hw > 0 then header:SetWidth(hw + bw + 6) end
    else
        toggleButton:Hide()
    end
end

if type(TrackerHeaderFrame.Update) == "function" then
    hooksecurefunc(TrackerHeaderFrame, "Update", function() pcall(placeButton) end)
end

setOn = function(want)
    QuestieZoneOnlyDB = type(QuestieZoneOnlyDB) == "table" and QuestieZoneOnlyDB or {}
    if want == nil then want = not isOn() end
    QuestieZoneOnlyDB.on = want and true or false
    say(want and "只顯示這一區的任務。" or "顯示全部區域的任務。")
    styleButton()
    redraw()
end

SLASH_QUESTIEZONEONLY1 = "/這區任務"
SLASH_QUESTIEZONEONLY2 = "/qzone"
SlashCmdList.QUESTIEZONEONLY = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "開" or msg == "on" then setOn(true)
    elseif msg == "關" or msg == "off" then setOn(false)
    elseif msg == "這裡" or msg == "here" then
        refreshHere()
        local names = {}
        for name in pairs(here) do names[#names + 1] = name end
        table.sort(names)
        say("現在這裡算：" .. (#names > 0 and table.concat(names, "、") or "（讀不到區域名稱）"))
    else setOn(nil) end
end

-----------------------------------------------------------------------------
-- 換區域時重畫
-----------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON and type(QuestieZoneOnlyDB) ~= "table" then
            QuestieZoneOnlyDB = { on = true }
        end
        return
    end
    C_Timer.After(0.3, function()
        if refreshHere() and isOn() then redraw() end
    end)
end)
