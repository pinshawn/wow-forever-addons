--===========================================================================
-- 有愛黑體切換（AAA_NowarSansSwitch；字型檔已附在 Fonts\ 裡）
-- 不動遊戲的 Fonts 資料夾：把遊戲和各插件用到的「遊戲字型檔」在遊戲裡改指到
-- 這個插件 Fonts\ 裡的有愛黑體（Nowar Sans）。插件自己指定字型的（例如
-- GearInsight 的提示框）也會換到。/字型 開關、/字型 狀態、/字型 測試。
--
-- 實測（v1.3.0 測試視窗）：這個用戶端第一次用到插件字型時 SetFont 會先回 false，
-- 過一下才讀好；讀好之後再設就馬上成功。直接設給 FontString 的會自己換上，
-- 但「字型物件」在還沒讀好時設下去，用它的字不會跟著換。
-- 所以：一載入就先把 5 個字型檔讀進來 → 等讀好 → 才去改字型物件和全域設定。
--===========================================================================
local ADDON, ns = ...
local FONTS = "Interface\\AddOns\\" .. ADDON .. "\\Fonts\\"

local type, pairs, ipairs, pcall, tostring = type, pairs, ipairs, pcall, tostring
local strlower, strgsub, strmatch, strfind = string.lower, string.gsub, string.match, string.find

local function say(msg)
    print("|cff66ccff[有愛黑體切換]|r " .. tostring(msg))
end

local function norm(path)
    return type(path) == "string" and strlower((strgsub(path, "/", "\\"))) or nil
end

-----------------------------------------------------------------------------
-- 1. 字型檔
-----------------------------------------------------------------------------
local TW_FILES = { "blei00d", "bHEI00M", "bHEI01B", "bKAI00M", "arheiuhk_bd" }
local ROLE_NAME = { blei00d = "主要介面", bHEI00M = "提示框", bHEI01B = "聊天", bKAI00M = "傷害數字", arheiuhk_bd = "聊天、頭像" }

-- 遊戲字型檔名（小寫、不含副檔名）→ 換成哪一個有愛黑體檔
local ROLE = {
    blei00d = "blei00d", bhei00m = "bHEI00M", bhei01b = "bHEI01B", bkai00m = "bKAI00M", arheiuhk_bd = "arheiuhk_bd",
    -- 英文、俄文、簡中、韓文用戶端的檔名：插件常寫死這些，一樣換成台版那幾個
    frizqt__ = "blei00d", frizqt___cyr = "blei00d", morpheus = "blei00d", morpheus_cyr = "blei00d",
    arialn = "arheiuhk_bd", arhei = "arheiuhk_bd", skurri = "bKAI00M", skurri_cyr = "bKAI00M",
    arkai_t = "blei00d", arkai_c = "bKAI00M",
    ["2002"] = "blei00d", ["2002b"] = "blei00d", k_pagetext = "blei00d", k_damage = "bKAI00M",
}
local DEFAULT_ROLE = "blei00d"

local REAL = {}            -- 角色 → 有愛黑體路徑（找不到的角色用 blei00d）
local ready = false        -- 至少 blei00d 找得到
local loaded = false       -- 遊戲讀好了
local loadedAt             -- 幾秒讀好（從載入開始算）
local gaveUp = false       -- 15 分鐘還沒讀好就不等了
local busy = false         -- 自己在換字的時候，掛勾不要再插手
local OWN = setmetatable({}, { __mode = "k" })   -- 自己做的字、字型物件：不改指

local BASELINE = STANDARD_TEXT_FONT
local T0 = GetTime and GetTime() or 0

-- 先把 5 個字型檔讀進來：每個檔一個看得見（幾乎透明）的字，設好就不再動它
local preHost = CreateFrame("Frame", nil, UIParent)
preHost:SetSize(4, 4)
preHost:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
preHost:SetAlpha(0.01)
preHost:Show()
local PRE = {}             -- 角色 → { fs, path, exists, res }

for _, name in ipairs(TW_FILES) do
    local path = FONTS .. name .. ".ttf"
    local fs = preHost:CreateFontString(nil, "OVERLAY")
    OWN[fs] = true
    busy = true
    pcall(fs.SetFont, fs, BASELINE, 12, "")
    fs:SetText("測A")
    local ok, res = pcall(fs.SetFont, fs, path, 12, "")   -- 找不到檔案會丟錯誤
    busy = false
    PRE[name] = { fs = fs, path = path, exists = ok, res = res }
end
ready = PRE.blei00d.exists
for _, name in ipairs(TW_FILES) do
    REAL[name] = PRE[name].exists and PRE[name].path or PRE.blei00d.path
end

local function isPreLoaded(name)
    local rec = PRE[name]
    return rec.exists and norm(rec.fs:GetFont()) == norm(rec.path)
end

local function allLoaded()
    for _, name in ipairs(TW_FILES) do
        if PRE[name].exists and not isPreLoaded(name) then return false end
    end
    return ready
end

-- 路徑 → 有愛黑體路徑；不是遊戲 Fonts\ 裡的檔就回 nil（不動）
local function target(path)
    local p = norm(path)
    if not p then return nil end
    local base = strmatch(p, "^fonts\\([^\\]+)%.[ot]tf$")
    if not base then return nil end
    return REAL[ROLE[base] or DEFAULT_ROLE]
end

-----------------------------------------------------------------------------
-- 2. 改指
-----------------------------------------------------------------------------
local enabled = ready
local original = setmetatable({}, { __mode = "k" })   -- [字或字型物件] = 原本的路徑
local count = { objects = 0, strings = 0 }

local function isChatPart(region)   -- 聊天視窗相關的不碰（密語視窗的處理中途跑插件程式會出問題）
    local ok, name = pcall(region.GetName, region)
    return ok and type(name) == "string" and strfind(name, "^ChatFrame") ~= nil
end

local function forbidden(region)
    if not region.IsForbidden then return false end
    local ok, result = pcall(region.IsForbidden, region)
    return not ok or result
end

-- 字型物件只在讀好之後才改（還沒讀好就改，用它的字不會跟著換）；還沒讀好先記下來
local discovered = setmetatable({}, { __mode = "k" })   -- 不在遊戲字型清單裡的字型物件（插件自己做的）
local function redirect(region, isObject)
    if busy or not enabled or OWN[region] then return end
    if isObject then discovered[region] = true end
    if isObject and not loaded then return end
    if forbidden(region) then return end
    local ok, path, size, flags = pcall(region.GetFont, region)
    if not ok then return end
    local new = target(path)
    if not new then return end
    if not isObject and isChatPart(region) then return end
    busy = true
    if original[region] == nil then
        original[region] = path
        if isObject then count.objects = count.objects + 1 else count.strings = count.strings + 1 end
    end
    pcall(region.SetFont, region, new, size or 12, flags or "")
    busy = false
end

local function hookType(widget, isObject)
    local mt = getmetatable(widget)
    local index = mt and mt.__index
    if type(index) == "table" and type(index.SetFont) == "function" then
        hooksecurefunc(index, "SetFont", function(self) redirect(self, isObject) end)
    end
end

-- 用字型物件（SetFontObject、樣板）拿字型的字不會呼叫 SetFont。
-- 這種字在「設文字」時檢查一次（每個字只檢查一次，之後直接跳過，不拖慢遊戲）；
-- 換字型物件時再檢查一次。v1.4.1 GearInsight 的分頁、主畫面就是這種。
local seen = setmetatable({}, { __mode = "k" })

-- 簡體轉繁體：字（或按鈕）設好文字後，裡面有簡體字就換成繁體（台灣用字）
local s2tOn = false   -- 存檔讀到之前先不轉（那時候只有遊戲自己的繁體字）
local hasSimplified = ns.S2T_HasSimplified or function() return false end
local convert = ns.ConvertS2T or function(s) return s end
local function convertRegion(region, txt)   -- txt：SetText 傳進來的字（有就不用再讀一次）
    if not s2tOn or busy or OWN[region] then return end
    if txt == nil then
        local ok, got = pcall(region.GetText, region)
        if not ok then return end
        txt = got
    end
    if issecretvalue and issecretvalue(txt) then return end   -- 遊戲保護的文字不碰
    if type(txt) ~= "string" or not hasSimplified(txt) then return end
    if isChatPart(region) then return end
    local new = convert(txt)
    if new ~= txt then
        busy = true
        pcall(region.SetText, region, new)
        busy = false
    end
end

local function onText(self)   -- SetFormattedText：要讀出組好的字
    if busy then return end
    if enabled and not seen[self] then
        seen[self] = true
        redirect(self, false)
    end
    convertRegion(self)
end
local function onSetText(self, text)   -- SetText：直接看傳進來的字（數字、英文很快就跳過）
    if busy then return end
    if enabled and not seen[self] then
        seen[self] = true
        redirect(self, false)
    end
    if text ~= nil then convertRegion(self, text) end
end
local function onFontObject(self, fontObject)
    if busy or not enabled then return end
    seen[self] = true
    if type(fontObject) == "table" and fontObject.GetFont then redirect(fontObject, true) end
    redirect(self, false)
end

-- 按鈕：字跟著按鈕的「一般／滑過／不能按」三種字型樣式走，按鈕設文字時也不會經過 FontString 的 SetText
local BUTTON_GETTERS = { "GetNormalFontObject", "GetHighlightFontObject", "GetDisabledFontObject" }
local seenButton = setmetatable({}, { __mode = "k" })
local function fixButton(btn)
    if busy or not enabled or OWN[btn] or forbidden(btn) then return end
    for _, getter in ipairs(BUTTON_GETTERS) do
        if type(btn[getter]) == "function" then
            local ok, fo = pcall(btn[getter], btn)
            if ok and type(fo) == "table" and fo.GetFont then redirect(fo, true) end
        end
    end
    if type(btn.GetFontString) == "function" then
        local ok, fs = pcall(btn.GetFontString, btn)
        if ok and fs then seen[fs] = true; redirect(fs, false) end
    end
end
local function onButtonText(btn, text)
    if busy then return end
    if enabled and not seenButton[btn] then
        seenButton[btn] = true
        fixButton(btn)
    end
    if type(text) == "string" and not (issecretvalue and issecretvalue(text)) and not hasSimplified(text) then return end
    convertRegion(btn)
end

-- 提示框：一行一行的字是遊戲直接寫進去的（不經過 SetText），顯示或加一行之後再轉
local function tipLines(tip, from, to)
    local okN, name = pcall(tip.GetName, tip)
    if not okN or type(name) ~= "string" then return end
    for i = from, to do
        local left, right = _G[name .. "TextLeft" .. i], _G[name .. "TextRight" .. i]
        if left then convertRegion(left) end
        if right then convertRegion(right) end
    end
end
local function onTipShow(tip)
    if not s2tOn or busy or forbidden(tip) then return end
    local ok, n = pcall(tip.NumLines, tip)
    if ok and type(n) == "number" and n > 0 then tipLines(tip, 1, n) end
end
local function onTipAdd(tip)
    if not s2tOn or busy or forbidden(tip) then return end
    local ok, n = pcall(tip.NumLines, tip)
    if ok and type(n) == "number" and n > 0 then tipLines(tip, n, n) end
end
local function hookTooltipType(tip)
    local mt = tip and getmetatable(tip)
    local index = mt and mt.__index
    if type(index) ~= "table" then return end
    if type(index.Show) == "function" then hooksecurefunc(index, "Show", onTipShow) end
    for _, method in ipairs({ "AddLine", "AddDoubleLine", "SetText" }) do
        if type(index[method]) == "function" then hooksecurefunc(index, method, onTipAdd) end
    end
end
local function onButtonFontObject(btn, fontObject)
    if busy or not enabled then return end
    if type(fontObject) == "table" and fontObject.GetFont then redirect(fontObject, true) end
    fixButton(btn)
end

local function hookButtonType(btn)
    local mt = getmetatable(btn)
    local index = mt and mt.__index
    if type(index) ~= "table" then return end
    if type(index.SetText) == "function" then hooksecurefunc(index, "SetText", onButtonText) end
    if type(index.SetFormattedText) == "function" then
        hooksecurefunc(index, "SetFormattedText", function(btn) onButtonText(btn, nil) end)
    end
    for _, method in ipairs({ "SetNormalFontObject", "SetHighlightFontObject", "SetDisabledFontObject" }) do
        if type(index[method]) == "function" then hooksecurefunc(index, method, onButtonFontObject) end
    end
end

local function hookFontStringText(fs)
    local mt = getmetatable(fs)
    local index = mt and mt.__index
    if type(index) ~= "table" then return end
    if type(index.SetText) == "function" then hooksecurefunc(index, "SetText", onSetText) end
    if type(index.SetFormattedText) == "function" then hooksecurefunc(index, "SetFormattedText", onText) end
    if type(index.SetFontObject) == "function" then hooksecurefunc(index, "SetFontObject", onFontObject) end
end

local function remapDiscovered()   -- 插件自己做的字型物件（不在遊戲清單裡）
    local list = {}
    for obj in pairs(discovered) do list[#list + 1] = obj end
    for _, obj in ipairs(list) do redirect(obj, true) end
end
local function remapFontObjects()
    remapDiscovered()
    local names = GetFonts and GetFonts()
    if type(names) == "table" then
        for _, name in ipairs(names) do
            local object = name
            if type(name) == "string" then object = _G[name] end
            if type(object) == "table" and object.GetFont and object.SetFont then redirect(object, true) end
        end
    else
        for name, object in pairs(_G) do
            if type(name) == "string" and type(object) == "table" and object.GetObjectType and object.SetFont then
                local ok, kind = pcall(object.GetObjectType, object)
                if ok and kind == "Font" then redirect(object, true) end
            end
        end
    end
end

local function packRegions(f) return { f:GetRegions() } end
local function isFontString(region) return region.GetObjectType and region:GetObjectType() == "FontString" end

local function sweepFontStrings()   -- 用 XML 直接寫死字型檔的 FontString 不會呼叫 SetFont，掃一遍補上
    if not EnumerateFrames then return end
    local frame = EnumerateFrames()
    while frame do
        if not forbidden(frame) and not isChatPart(frame) then
            local ok, regions = pcall(packRegions, frame)
            if ok then
                for _, region in ipairs(regions) do
                    local okType, isFS = pcall(isFontString, region)
                    if okType and isFS then redirect(region, false) end
                end
            end
        end
        frame = EnumerateFrames(frame)
    end
end

local function chatFrames()
    local list, seen = {}, {}
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local f = _G["ChatFrame" .. i]
        if f and not seen[f] then seen[f] = true; list[#list + 1] = f end
    end
    for _, name in ipairs(CHAT_FRAMES or {}) do
        local f = _G[name]
        if f and not seen[f] then seen[f] = true; list[#list + 1] = f end
    end
    return list
end

local function applyChat()   -- 聊天視窗：不掛勾在聊天程式裡，等它做完再從自己的計時器換
    if not (enabled and loaded) then return end
    local function set(region)
        if not (region and region.GetFont and region.SetFont) then return end
        local ok, path, size, flags = pcall(region.GetFont, region)
        local new = ok and target(path)
        if new then
            if original[region] == nil then original[region] = path end
            pcall(region.SetFont, region, new, size or 14, flags or "")
        end
    end
    for _, f in ipairs(chatFrames()) do set(f) end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do set(_G["ChatFrame" .. i .. "EditBox"]) end   -- 密語視窗的輸入框不碰
end

-- 頭上名字、傷害數字、預設字型：讀好之後才改（之後新建的字會直接用）
local GLOBALS = { "STANDARD_TEXT_FONT", "UNIT_NAME_FONT", "DAMAGE_TEXT_FONT", "NAMEPLATE_FONT", "NAMEPLATE_SPELLCAST_FONT" }
local originalGlobals = {}

local function applyGlobals()
    if not (enabled and loaded) then return end
    for _, name in ipairs(GLOBALS) do
        local value = _G[name]
        local new = target(value)
        if new then
            if originalGlobals[name] == nil then originalGlobals[name] = value end
            _G[name] = new
        end
    end
end

local function restoreAll()
    busy = true
    for name, value in pairs(originalGlobals) do _G[name] = value end
    for region, path in pairs(original) do
        local ok, _, size, flags = pcall(region.GetFont, region)
        if ok then pcall(region.SetFont, region, path, size or 12, flags or "") end
    end
    busy = false
    wipe(original)
    wipe(originalGlobals)
end

local loggedIn = false
local function fullPass()
    if not (enabled and loaded) then return end
    remapFontObjects()
    sweepFontStrings()
    applyChat()
end

-----------------------------------------------------------------------------
-- 3. 等字型讀好
-----------------------------------------------------------------------------
local probe = preHost:CreateFontString(nil, "OVERLAY")   -- 只拿來找 FontString 的共用方法表
OWN[probe] = true
-- 勾子一律掛上（字型、簡轉繁各自看自己的開關）
hookType(probe, false)
hookType(CreateFont("NowarSansSwitchProbeFont"), true)
hookFontStringText(probe)
for _, kind in ipairs({ "Button", "CheckButton" }) do
    local okB, btn = pcall(CreateFrame, kind, nil, preHost)
    if okB and btn then
        OWN[btn] = true
        if btn.Hide then btn:Hide() end
        hookButtonType(btn)
    end
end
if GameTooltip then hookTooltipType(GameTooltip) end

-- 簡轉繁：登入後把畫面上已經有的字掃一遍（之前設好、之後不再改的字）
local function sweepConvert()
    if not s2tOn or not EnumerateFrames then return end
    local frame = EnumerateFrames()
    while frame do
        if not forbidden(frame) and not isChatPart(frame) then
            local okT, kind = pcall(frame.GetObjectType, frame)
            if okT and (kind == "Button" or kind == "CheckButton") then convertRegion(frame) end
            local ok, regions = pcall(packRegions, frame)
            if ok then
                for _, region in ipairs(regions) do
                    local okR, isFS = pcall(isFontString, region)
                    if okR and isFS then convertRegion(region) end
                end
            end
        end
        frame = EnumerateFrames(frame)
    end
end

local function onLoaded()
    if loaded then return end
    loaded = true
    loadedAt = (GetTime and GetTime() or 0) - T0
    -- 還沒讀好的檔先用主要介面那個代替（直接設給字的，那個檔讀好後會自己換上）
    for _, name in ipairs(TW_FILES) do
        if name ~= "blei00d" and not isPreLoaded(name) then REAL[name] = REAL.blei00d end
    end
    if not enabled then return end
    applyGlobals()
    remapFontObjects()
    if loggedIn then
        fullPass()
        C_Timer.After(3, fullPass)
        if loadedAt > 1 then
            say(("有愛黑體已經換上（遊戲花了 %.1f 秒讀字型）。頭上名字、傷害數字要回角色選擇畫面再登入才會換。"):format(loadedAt))
        end
    end
end

-- 主要介面那個讀好就開始算：5 個都好了，或主要介面好了已經過 5 秒，就換上
local mainAt
local function poll()
    if loaded or not ready then return end
    if allLoaded() then onLoaded(); return end
    if isPreLoaded("blei00d") then
        local now = GetTime and GetTime() or 0
        mainAt = mainAt or now
        if now - mainAt >= 5 then onLoaded() end
    end
end

poll()   -- 這次遊戲裡已經讀過的話（例如 /reload），這裡就讀好了

-- 遊戲第一次讀、或剛重建字型暫存（_forever_\Fonts 裡的 .slug 檔）時，實測要將近 5 分鐘：
-- 前 30 秒每 0.2 秒看一次，之後每秒看一次，最多等 15 分鐘；讀好就換上。
local ticker
local tries, warned = 0, false
local function stopTicker()
    if ticker then ticker:Cancel(); ticker = nil end
end
local function slowTick()
    tries = tries + 1
    poll()
    if loaded then stopTicker(); return end
    if tries >= 870 then   -- 加上前面 30 秒，一共 15 分鐘
        stopTicker()
        gaveUp = true
        if enabled then say("有愛黑體 15 分鐘都沒讀好。請打 /字型 測試，把視窗截圖給我。") end
    end
end
local function fastTick()
    tries = tries + 1
    poll()
    if loaded then stopTicker(); return end
    if tries >= 150 then   -- 30 秒還沒好：說一聲，改成每秒看一次
        stopTicker()
        if enabled and not warned then
            warned = true
            say("有愛黑體還在讀。遊戲第一次讀、或剛重建字型暫存時，可能要好幾分鐘；讀好會自動換上，不用做什麼。")
        end
        tries = 0
        ticker = C_Timer.NewTicker(1, slowTick)
    end
end
if ready and not loaded and C_Timer and C_Timer.NewTicker then
    ticker = C_Timer.NewTicker(0.2, fastTick)
end

-----------------------------------------------------------------------------
-- 4. 事件
-----------------------------------------------------------------------------
local rescanPending = false
local function scheduleRescan(delay)
    if rescanPending or not (enabled and loaded) then return end
    rescanPending = true
    C_Timer.After(delay or 0.5, function()
        rescanPending = false
        if enabled and loaded then remapFontObjects() end
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({ "UPDATE_CHAT_WINDOWS", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
        "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM" }) do
    pcall(events.RegisterEvent, events, e)
end

events:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON then
            if type(NowarSansSwitchDB) ~= "table" then NowarSansSwitchDB = { on = true } end
            if NowarSansSwitchDB.s2t == nil then NowarSansSwitchDB.s2t = true end
            s2tOn = NowarSansSwitchDB.s2t and true or false
            if NowarSansSwitchDB.on == false then
                enabled = false
                restoreAll()
            end
        end
        poll()
        if name ~= ADDON then scheduleRescan(0.3) end
    elseif event == "PLAYER_LOGIN" then
        loggedIn = true
        if s2tOn then
            C_Timer.After(2, sweepConvert)
            C_Timer.After(7, sweepConvert)
        end
        if ready and NowarSansSwitchDB and NowarSansSwitchDB.on == false then
            say("字型目前是關的（遊戲原本的字）。打 /字型 開啟開關視窗。")
        end
        if not ready then
            if not (NowarSansSwitchDB and NowarSansSwitchDB.on == false) then
                say("找不到字型檔（Interface\\AddOns\\" .. ADDON .. "\\Fonts\\blei00d.ttf）。請確認整個資料夾都放進 AddOns，再整個重開遊戲。")
            end
            return
        end
        poll()
        if loaded and enabled then
            C_Timer.After(1, fullPass)
            C_Timer.After(6, fullPass)
        end
    elseif enabled and loaded then
        C_Timer.After(0, applyChat)
    end
end)

-----------------------------------------------------------------------------
-- 5. 測試視窗：同一句話用原本的字和有愛黑體各寫一次
-----------------------------------------------------------------------------
local SAMPLE = "測試 ABC 123 鍵位 键位 主循环 動作條 12345"
local testWin

local function showTestWindow()
    poll()   -- 剛好讀好了就馬上換上
    if not testWin then
        local f = CreateFrame("Frame", "NowarSansSwitchTestWindow", UIParent)
        f:SetSize(760, 300)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.88)

        busy = true
        local function label(text, x, y, size, r, g, b)
            local fs = f:CreateFontString(nil, "OVERLAY")
            OWN[fs] = true
            fs:SetFont(BASELINE, size or 14, "")
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
            fs:SetJustifyH("LEFT")
            fs:SetTextColor(r or 1, g or 1, b or 1)
            fs:SetText(text)
            return fs
        end
        label("有愛黑體切換：字型測試（拖曳可以移動）", 16, -12, 16, 1, 0.82, 0)
        label("第 0 行是遊戲原本的字；第 1～4 行是有愛黑體。字形不一樣、而且沒有方框，就代表讀到了。", 16, -36, 12, 0.8, 0.8, 0.8)

        local rows = { { label = "0. 遊戲原本的字", path = BASELINE } }
        for i, name in ipairs({ "blei00d", "bHEI00M", "bHEI01B", "bKAI00M" }) do
            rows[#rows + 1] = { label = ("%d. 有愛黑體（%s）"):format(i, ROLE_NAME[name]), path = REAL[name] }
        end
        f.rows = {}
        for i, row in ipairs(rows) do
            local y = -64 - (i - 1) * 44
            label(row.label, 16, y + 2, 13, 0.6, 0.85, 1)
            local fs = f:CreateFontString(nil, "OVERLAY")
            OWN[fs] = true
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", 220, y)
            fs:SetJustifyH("LEFT")
            pcall(fs.SetFont, fs, BASELINE, 20, "")
            fs:SetText(SAMPLE)
            if i > 1 then pcall(fs.SetFont, fs, row.path, 20, "") end
            row.fs = fs
            row.note = label("", 16, y - 14, 10, 0.6, 0.6, 0.6)
            f.rows[i] = row
        end
        busy = false

        local close = CreateFrame("Button", nil, f)
        close:SetSize(70, 22)
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
        busy = true
        local ct = close:CreateFontString(nil, "OVERLAY")
        OWN[ct] = true
        ct:SetFont(BASELINE, 14, "")
        busy = false
        ct:SetPoint("CENTER")
        ct:SetText("[ 關閉 ]")
        close:SetScript("OnClick", function() f:Hide() end)

        f.update = function()
            for i, row in ipairs(f.rows) do
                if i > 1 then
                    local ok = norm(row.fs:GetFont()) == norm(row.path)
                    row.note:SetText(ok and "遊戲回報：讀到了" or "遊戲回報：還沒讀到")
                end
            end
        end
        testWin = f
    end
    testWin:Show()
    testWin.update()
    C_Timer.After(1, testWin.update)
    C_Timer.After(3, testWin.update)
end

-----------------------------------------------------------------------------
-- 6. 指令：/字型（開關）、/字型 狀態、/字型 測試
-----------------------------------------------------------------------------
local function setOn(want)   -- want：true 開、false 關、nil 切換
    if InCombatLockdown and InCombatLockdown() then
        say("戰鬥中不能切換，離開戰鬥再試一次。")
        return
    end
    if not ready then
        say("找不到字型檔，沒辦法開。請確認整個資料夾都放進 AddOns，再整個重開遊戲。")
        return
    end
    NowarSansSwitchDB = NowarSansSwitchDB or {}
    local now = NowarSansSwitchDB.on ~= false
    if want == nil then want = not now end
    if want == now then
        say(now and "已經是開的（有愛黑體）。" or "已經是關的（遊戲原本的字）。")
        return
    end
    NowarSansSwitchDB.on = want
    if NowarSansSwitchDB.on then
        say("切換成：有愛黑體。重新載入介面中…（頭上名字、傷害數字要回角色選擇畫面再登入才會換）")
    else
        say("切換成：遊戲原本的字。重新載入介面中…（頭上名字、傷害數字要回角色選擇畫面再登入才會換）")
    end
    ReloadUI()
end

local function setS2T(want)   -- 簡體轉繁體：true 開、false 關、nil 切換
    if InCombatLockdown and InCombatLockdown() then
        say("戰鬥中不能切換，離開戰鬥再試一次。")
        return
    end
    NowarSansSwitchDB = NowarSansSwitchDB or {}
    local now = NowarSansSwitchDB.s2t ~= false
    if want == nil then want = not now end
    if want == now then
        say(now and "簡體轉繁體已經是開的。" or "簡體轉繁體已經是關的。")
        return
    end
    NowarSansSwitchDB.s2t = want
    say(want and "簡體轉繁體：開。重新載入介面中…" or "簡體轉繁體：關。重新載入介面中…")
    ReloadUI()
end

local function status()
    poll()   -- 剛好讀好了就馬上換上
    local state
    if not ready then state = "找不到字型檔"
    elseif loaded then state = ("讀好了（%.1f 秒）"):format(loadedAt or 0)
    elseif gaveUp then state = "15 分鐘內沒讀好"
    else state = ("還在讀（已經 %d 秒）"):format(math.floor((GetTime and GetTime() or 0) - T0)) end
    say(("狀態：%s｜字型：%s｜換了 %d 個字型物件、%d 個文字"):format(
        enabled and "開（有愛黑體）" or "關（遊戲原本的字）", state, count.objects, count.strings))
    local parts = {}
    for _, name in ipairs(TW_FILES) do
        local rec = PRE[name]
        local s = not rec.exists and "找不到" or (isPreLoaded(name) and "好" or "還沒")
        parts[#parts + 1] = ROLE_NAME[name] .. "：" .. s
    end
    say("各檔：" .. table.concat(parts, "｜"))
    say("簡體轉繁體：" .. (s2tOn and "開" or "關"))
    say("指令：/字型（開關視窗）｜/字型 開、關（字型）｜/字型 簡轉繁（切換）｜/字型 測試｜/字型 這裡")
end

-----------------------------------------------------------------------------
-- 7. 開關視窗（魔獸風格）：/字型、小地圖按鈕、小地圖旁的插件選單
-----------------------------------------------------------------------------
local BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

-- 魔獸對話框的外框（金邊黑底）；舊用戶端沒有 BackdropTemplate 就直接 SetBackdrop
local function dialogFrame(name, w, h)
    local ok, f = pcall(CreateFrame, "Frame", name, UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", name, UIParent) end
    if f.SetBackdrop then pcall(f.SetBackdrop, f, BACKDROP) end
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    -- 上面那塊標題牌
    local header = f:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetSize(300, 64)
    header:SetPoint("TOP", f, "TOP", 0, 12)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", header, "TOP", 0, -14)
    local okC, close = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
    if okC and close then
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    end
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, name) end
    return f
end

local function wowButton(parent, text, w)
    local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not b then b = CreateFrame("Button", nil, parent) end
    b:SetSize(w or 110, 24)
    if b.SetText then b:SetText(text) end
    return b
end

-- 魔獸的勾選框＋說明
local function wowCheck(parent, y, title, desc)
    local ok, c = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
    if not ok or not c then c = CreateFrame("CheckButton", nil, parent) end
    c:SetSize(28, 28)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y)
    local t = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("LEFT", c, "RIGHT", 4, 1)
    t:SetText(title)
    local d = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -3)
    d:SetJustifyH("LEFT")
    d:SetText(desc)
    return c
end

local panel
local minimapButton
local function updateMinimapShown()
    if not minimapButton then return end
    local hide = NowarSansSwitchDB and NowarSansSwitchDB.mmHide
    if hide then minimapButton:Hide() else minimapButton:Show() end
end

local function refreshPanel()
    if not panel then return end
    panel.font:SetChecked(NowarSansSwitchDB == nil or NowarSansSwitchDB.on ~= false)
    panel.s2t:SetChecked(s2tOn)
    panel.mm:SetChecked(not (NowarSansSwitchDB and NowarSansSwitchDB.mmHide))
end

local function showPanel()
    if not panel then
        local f = dialogFrame("NowarSansSwitchPanel", 380, 250)
        f.title:SetText("有愛黑體切換")
        f.font = wowCheck(f, -36, "有愛黑體", "整個遊戲（包含插件）的字換成有愛黑體")
        f.s2t = wowCheck(f, -82, "簡體字轉繁體", "插件裡的簡體字自動換成繁體（台灣用字）")
        f.mm = wowCheck(f, -128, "顯示小地圖按鈕", "OneForAll 開了「收集小地圖按鈕」的話會收進它的列裡")
        f.font:SetScript("OnClick", function(self)
            local want = self:GetChecked() and true or false
            refreshPanel()   -- 先照目前狀態畫回來；真的切換會重新載入介面
            setOn(want)
        end)
        f.s2t:SetScript("OnClick", function(self)
            local want = self:GetChecked() and true or false
            refreshPanel()
            setS2T(want)
        end)
        f.mm:SetScript("OnClick", function(self)
            NowarSansSwitchDB = NowarSansSwitchDB or {}
            NowarSansSwitchDB.mmHide = not self:GetChecked()
            updateMinimapShown()
        end)
        local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        note:SetPoint("BOTTOM", f, "BOTTOM", 0, 48)
        note:SetText("前兩項切換後會重新載入介面（幾秒鐘）")
        local test = wowButton(f, "字型測試", 110)
        test:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 18)
        test:SetScript("OnClick", function() showTestWindow() end)
        local close = wowButton(f, "關閉", 110)
        close:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 18)
        close:SetScript("OnClick", function() f:Hide() end)
        panel = f
    end
    refreshPanel()
    panel:Show()
end

-- 小地圖按鈕：OneForAll 的「收集小地圖按鈕」會把它收進那一列
local ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Icon"

local atan2 = math.atan2 or math.atan

local function minimapAngle()
    return (NowarSansSwitchDB and NowarSansSwitchDB.mmAngle) or 215
end

local function placeMinimapButton()
    if not (minimapButton and Minimap) then return end
    local a = math.rad(minimapAngle())
    local r = (Minimap:GetWidth() or 140) / 2 + 10
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function createMinimapButton()
    if minimapButton or not Minimap then return end
    local b = CreateFrame("Button", "NowarSansSwitchMinimapButton", Minimap)
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
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then showTestWindow() else
            if panel and panel:IsShown() then panel:Hide() else showPanel() end
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("有愛黑體切換", 1, 0.82, 0)
        GameTooltip:AddLine(("有愛黑體：%s　簡轉繁：%s"):format(
            (NowarSansSwitchDB == nil or NowarSansSwitchDB.on ~= false) and "開" or "關", s2tOn and "開" or "關"), 1, 1, 1)
        GameTooltip:AddLine("左鍵：開關視窗", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("右鍵：字型測試", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("拖曳：沿著小地圖移動", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnDragStart", function(self)
        if self:GetParent() ~= Minimap then return end   -- 被 OneForAll 收進列裡時不自己移動
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            if not (mx and px and scale and scale > 0) then return end
            local angle = math.deg(atan2(py / scale - my, px / scale - mx)) % 360
            NowarSansSwitchDB = NowarSansSwitchDB or {}
            NowarSansSwitchDB.mmAngle = angle
            placeMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    minimapButton = b
    placeMinimapButton()
    updateMinimapShown()
end

-- 插件一載入就做好按鈕（OneForAll 在登入後 1、5、15 秒找小地圖按鈕）；存檔讀進來後再照存的位置放
createMinimapButton()
local mmEvents = CreateFrame("Frame")
mmEvents:RegisterEvent("ADDON_LOADED")
mmEvents:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    createMinimapButton()
    placeMinimapButton()
    updateMinimapShown()
end)

-- /字型 這裡：滑鼠底下那一塊用的是什麼字型（找哪裡沒換到）
local function shortText(s, n)
    if #s <= n then return s end
    local cut = n
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

local function describe(frame, depth)
    local okN, name = pcall(frame.GetName, frame)
    local lines = {}
    local okR, regions = pcall(packRegions, frame)
    if okR then
        for _, r in ipairs(regions) do
            local okT, isFS = pcall(isFontString, r)
            if okT and isFS and #lines < 4 then
                local okF, path = pcall(r.GetFont, r)
                local okX, txt = pcall(r.GetText, r)
                if issecretvalue and okX and issecretvalue(txt) then txt = "？" end
                if not okX or type(txt) ~= "string" then txt = "" end
                lines[#lines + 1] = ("    「%s」→ %s"):format(shortText(txt, 24), tostring(okF and path))
            end
        end
    end
    say(("%s%s：%d 個字"):format(depth > 0 and "（外層）" or "", tostring(okN and name or "沒名字的框"), #lines))
    for _, l in ipairs(lines) do say(l) end
end

local function inspectMouse()
    local focus
    if GetMouseFoci then
        local list = GetMouseFoci()
        focus = type(list) == "table" and list[1] or nil
    elseif GetMouseFocus then
        focus = GetMouseFocus()
    end
    if not focus or focus == WorldFrame then
        say("滑鼠底下沒有介面。先在聊天框打好 /字型 這裡，把滑鼠移到要查的字上，再按 Enter。")
        return
    end
    describe(focus, 0)
    local okP, parent = pcall(focus.GetParent, focus)
    if okP and parent and parent ~= UIParent then describe(parent, 1) end
end

SLASH_NOWARSANSSWITCH1 = "/字型"
SLASH_NOWARSANSSWITCH2 = "/nowar"
SlashCmdList.NOWARSANSSWITCH = function(msg)
    msg = strlower(strgsub(msg or "", "^%s*(.-)%s*$", "%1"))
    if msg == "" then
        showPanel()
    elseif msg == "簡轉繁" or msg == "繁體" or msg == "s2t" then
        setS2T(nil)
    elseif msg == "狀態" or msg == "status" or msg == "?" then
        status()
    elseif msg == "測試" or msg == "test" then
        showTestWindow()
    elseif msg == "這裡" or msg == "here" then
        inspectMouse()
    elseif msg == "開" or msg == "on" then
        setOn(true)
    elseif msg == "關" or msg == "off" then
        setOn(false)
    elseif msg == "切換" or msg == "toggle" then
        setOn(nil)
    else
        showPanel()
    end
end

function NowarSansSwitch_OnCompartmentClick()
    showPanel()
end
