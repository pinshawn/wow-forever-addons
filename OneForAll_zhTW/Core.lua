-- OneForAll 繁體中文包（OneForAll_zhTW）
-- 不改 OneForAll 本體：在畫面顯示的那一刻把英文換成中文。
--   1. OneForAll 建立的文字（FLT.NewFS）→ 換掉那個文字物件的 SetText
--   2. 滑鼠提示框（GameTooltip / ItemRefTooltip）→ 加完一行後換掉那一行
--   3. 聊天框裡 OneForAll 自己的訊息（開頭是「OneForAll:」）
--   5. 「精簡綠色屬性」在繁中用戶端也能用（認官方繁中的「裝備：」句子）
-- 官方名稱（地城、首領、NPC、任務、物品、地名）來自遊戲用戶端資料與 Wowhead 繁中；其餘由譯者翻譯。
local ADDON, ns = ...

local N = ns.N or {}
local T = ns.T or {}
local F = ns.F or {}

local type, pcall, tostring, tonumber, select = type, pcall, tostring, tonumber, select
local strfind, strsub, strgsub, strmatch, strformat, strlower, strupper = string.find, string.sub, string.gsub, string.match, string.format, string.lower, string.upper
local tconcat, tsort = table.concat, table.sort

local issecret = issecretvalue or function() return false end

-- 小寫索引：給「Sort by name」這種被程式轉成小寫的字用
local LC = {}
local function addLC(tbl)
  for k, v in pairs(tbl) do
    if #k <= 40 then
      local l = strlower(k)
      if LC[l] == nil then LC[l] = v end
    end
  end
end

---------------------------------------------------------------------------
-- 句型（範本）：英文裡的 {1}{2} 或 %s %d 會變成擷取，中文用 {1}{2} 放回去
---------------------------------------------------------------------------
local TPL = {}
local function escapeChar(c)
  if strfind(c, "^[%^%$%(%)%%%.%[%]%*%+%-%?]$") then return "%" .. c end
  return c
end
local function compile(en, tw)
  local pat, n, i, len = { "^" }, 0, 1, #en
  local lits, cur = {}, {}
  while i <= len do
    local a, b = strfind(en, "^{%d+}", i)
    if a then
      n = n + 1; pat[#pat + 1] = "(.-)"; i = b + 1
      lits[#lits + 1] = tconcat(cur); cur = {}
    else
      local a2, b2, spec = strfind(en, "^%%([%-%d%.]*[sdfgx])", i)
      if a2 then
        n = n + 1
        local conv = strsub(spec, -1)
        if conv == "d" then pat[#pat + 1] = "(%-?%d+)"
        elseif conv == "f" or conv == "g" then pat[#pat + 1] = "(%-?[%d%.]+)"
        else pat[#pat + 1] = "(.-)" end
        i = b2 + 1
        lits[#lits + 1] = tconcat(cur); cur = {}
      elseif strsub(en, i, i + 1) == "%%" then
        pat[#pat + 1] = "%%"; cur[#cur + 1] = "%"; i = i + 2
      else
        local c = strsub(en, i, i)
        pat[#pat + 1] = escapeChar(c); cur[#cur + 1] = c; i = i + 1
      end
    end
  end
  lits[#lits + 1] = tconcat(cur)
  -- 最長的一段固定文字，用來快速篩選
  local best, total = "", 0
  for k = 1, #lits do
    total = total + #lits[k]
    if #lits[k] > #best then best = lits[k] end
  end
  if n == 0 or total < 3 then return nil end
  pat[#pat + 1] = "$"
  -- 中文裡的 %s %d 改成 {1}{2}
  local k = 0
  tw = strgsub(tw, "%%[%-%d%.]*[sdfgx]", function() k = k + 1; return "{" .. k .. "}" end)
  tw = strgsub(tw, "%%%%", "%%")
  return { pat = tconcat(pat), tw = tw, first = best, weight = total }
end
for i = 1, #F do
  local t = compile(F[i][1], F[i][2])
  if t then TPL[#TPL + 1] = t end
end
tsort(TPL, function(a, b) return a.weight > b.weight end)

---------------------------------------------------------------------------
-- 翻譯
---------------------------------------------------------------------------
local cache, cacheN = {}, 0
local MAXDEPTH = 8
local trCore -- 前置宣告

local function hasCJK(s) return strfind(s, "[\227-\239][\128-\191][\128-\191]") ~= nil end

local function lookup(s)
  local v = T[s] or N[s]
  if v then return v end
  local lead, core, trail = strmatch(s, "^(%s*)(.-)(%s*)$")
  if core ~= "" and core ~= s then
    v = T[core] or N[core]
    if v then return lead .. v .. trail end
  end
  if core ~= "" and #core <= 40 then
    v = LC[strlower(core)]
    if v then return lead .. v .. trail end
  end
end

local function applyTemplates(s, depth)
  for i = 1, #TPL do
    local t = TPL[i]
    if t.first == "" or strfind(s, t.first, 1, true) then
      local caps = { strmatch(s, t.pat) }
      if caps[1] ~= nil then
        return (strgsub(t.tw, "{(%d+)}", function(k)
          local c = caps[tonumber(k)]
          if c == nil then return "" end
          return trCore(c, depth + 1)
        end))
      end
    end
  end
end

-- 只在括號外面切
local function splitTop(s, sep)
  local parts, depth, last, i, n, sl = nil, 0, 1, 1, #s, #sep
  while i <= n do
    local c = strsub(s, i, i)
    if c == "(" then depth = depth + 1; i = i + 1
    elseif c == ")" then if depth > 0 then depth = depth - 1 end; i = i + 1
    elseif depth == 0 and strsub(s, i, i + sl - 1) == sep then
      parts = parts or {}
      parts[#parts + 1] = strsub(s, last, i - 1)
      i = i + sl; last = i
    else
      i = i + 1
    end
  end
  if not parts then return nil end
  parts[#parts + 1] = strsub(s, last)
  return parts
end

local L1 = { "\n", " — ", " – ", " | ", " · " }
local L2 = { " - ", "; ", ", ", ": ", " / " }

local function sentenceLike(s)
  local words = select(2, strgsub(s, "%S+", ""))
  if words < 6 then return false end
  return strfind(s, "[%.!%?][\"')]?%s") ~= nil or strfind(s, "[%.!%?][\"')]?$") ~= nil
end

-- 顏色碼、圖示、連結不動，只翻中間的文字
local function trEscapes(s, depth)
  local out, buf, i, n, found = {}, {}, 1, #s, false
  while i <= n do
    local a = strfind(s, "|", i, true)
    if not a then buf[#buf + 1] = strsub(s, i); break end
    buf[#buf + 1] = strsub(s, i, a - 1)
    local nx, tok = strsub(s, a + 1, a + 1), nil
    if nx == "c" then tok = strmatch(s, "^|c%x%x%x%x%x%x%x%x", a)
    elseif nx == "r" or nx == "n" then tok = strsub(s, a, a + 1)
    elseif nx == "T" then tok = strmatch(s, "^|T.-|t", a)
    elseif nx == "A" then tok = strmatch(s, "^|A.-|a", a)
    elseif nx == "H" then tok = strmatch(s, "^|H.-|h.-|h", a)
    elseif nx == "K" then tok = strmatch(s, "^|K.-|k", a)
    end
    if tok then
      found = true
      local text = tconcat(buf); buf = {}
      if text ~= "" then out[#out + 1] = trCore(text, depth + 1) end
      out[#out + 1] = tok
      i = a + #tok
    else
      buf[#buf + 1] = "|"; i = a + 1
    end
  end
  if not found then return nil end
  local text = tconcat(buf)
  if text ~= "" then out[#out + 1] = trCore(text, depth + 1) end
  return tconcat(out)
end

local function trText(s, depth)
  local lead, core, trail = strmatch(s, "^(%s*)(.-)(%s*)$")
  if core == "" then return s end
  if core ~= s then
    local v = lookup(core) or applyTemplates(core, depth)
    if v then return lead .. v .. trail end
  end
  -- 開頭的方括號標籤：地圖任務圖示的「[15] 任務名稱」、「[D] …」
  local tag, rest0 = strmatch(core, "^(%[[^%]]*%]%s*)(.+)$")
  if tag then
    local r = trCore(rest0, depth + 1)
    if r ~= rest0 then return lead .. tag .. r .. trail end
  end
  for k = 1, #L1 do
    local parts = splitTop(core, L1[k])
    if parts then
      for p = 1, #parts do parts[p] = trCore(parts[p], depth + 1) end
      return lead .. tconcat(parts, L1[k]) .. trail
    end
  end
  if sentenceLike(core) then return s end
  local x, y, z = strmatch(core, "^(.-)%s*%(([^()]*)%)%s*(.*)$")
  if x and (x ~= "" or z ~= "") then
    local tx = (x ~= "") and trCore(x, depth + 1) or ""
    local ty = trCore(y, depth + 1)
    local tz = (z ~= "") and trCore(z, depth + 1) or ""
    local out
    if hasCJK(ty) or hasCJK(tx) then out = tx .. "（" .. ty .. "）"
    else out = tx .. ((x ~= "") and " (" or "(") .. ty .. ")" end
    if tz ~= "" then out = out .. " " .. tz end
    return lead .. out .. trail
  end
  for k = 1, #L2 do
    local sep = L2[k]
    local parts = splitTop(core, sep)
    if parts then
      local any = false
      for p = 1, #parts do
        parts[p] = trCore(parts[p], depth + 1)
        if hasCJK(parts[p]) then any = true end
      end
      local joiner = sep
      if any and sep == ", " then joiner = "，" elseif any and sep == ": " then joiner = "：" end
      return lead .. tconcat(parts, joiner) .. trail
    end
  end
  local ra, rb = strmatch(core, "^([%d%.]+) to ([%d%.]+)$")
  if ra then return lead .. ra .. "到" .. rb .. trail end
  local pa, pb = strmatch(core, "^(.-) and (.-)$")
  if pa and pa ~= "" and pb ~= "" and not strfind(pa, " and ", 1, true) then
    local ta, tb = trCore(pa, depth + 1), trCore(pb, depth + 1)
    if hasCJK(ta) and hasCJK(tb) then return lead .. ta .. "和" .. tb .. trail end
  end
  local cnt, item = strmatch(core, "^(%d+x)%s+(.+)$")
  if cnt then
    local r = trCore(item, depth + 1)
    if r ~= item then return lead .. cnt .. " " .. r .. trail end
  end
  item, cnt = strmatch(core, "^(.-)%s*(x%d+)$")
  if item and item ~= "" then
    local r = trCore(item, depth + 1)
    if r ~= item then return lead .. r .. " " .. cnt .. trail end
  end
  local num, rest = strmatch(core, "^([%+%-]?%d[%d,%.]*%%?)%s+(.+)$")
  if num then
    local r = trCore(rest, depth + 1)
    if r ~= rest then return lead .. num .. " " .. r .. trail end
  end
  rest, num = strmatch(core, "^(.-)%s+([%+%-]?%d[%d,%.]*%%?)$")
  if rest and rest ~= "" then
    local r = trCore(rest, depth + 1)
    if r ~= rest then return lead .. r .. " " .. num .. trail end
  end
  return s
end

trCore = function(s, depth)
  if depth > MAXDEPTH or s == "" or not strfind(s, "%a") then return s end
  local v = lookup(s)
  if v then return v end
  v = applyTemplates(s, depth)
  if v then return v end
  if strfind(s, "|", 1, true) then
    v = trEscapes(s, depth)
    if v then return v end
  end
  return trText(s, depth)
end

local function Tr(s)
  if type(s) ~= "string" or issecret(s) then return s end
  if s == "" or not strfind(s, "%a") then return s end
  local c = cache[s]
  if c then return c end
  local ok, r = pcall(trCore, s, 0)
  if not ok or type(r) ~= "string" then r = s end
  cacheN = cacheN + 1
  if cacheN > 20000 then cache = {}; cacheN = 0 end
  cache[s] = r
  -- 記下沒翻到的英文（給作者補翻譯用；/ofazh log 可以關）
  if r == s and ns.logMissing and strfind(s, "%a%a%a") then
    local db = OneForAll_zhTW_DB
    if type(db) == "table" then
      db.missing = db.missing or {}
      if db.missing[s] == nil and (db.missingN or 0) < 400 then
        db.missing[s] = true
        db.missingN = (db.missingN or 0) + 1
      end
    end
  end
  return r
end
ns.Tr = Tr
_G.OneForAll_zhTW_Tr = Tr -- 方便除錯：/run print(OneForAll_zhTW_Tr("Dungeons"))

---------------------------------------------------------------------------
-- 掛上去
---------------------------------------------------------------------------
-- 中文字比英文寬：固定大小的框裡「置中」的那行字，放不下就把字縮小一點（不換行，不動其他排版）
-- 只處理：只有一個錨點、錨在自己父框正中央的文字（例如小地圖按鈕收集列的「沒有找到…」）
local fitList = setmetatable({}, { __mode = "k" })
local function refit(fs)
  local font = fitList[fs]
  if not font then return end
  local parent = fs.GetParent and fs:GetParent()
  local pw = parent and parent.GetWidth and parent:GetWidth()
  if not pw or pw < 40 then return end
  fs:SetFont(font[1], font[2], font[3])
  local sw = fs:GetStringWidth()
  local avail = pw - 16
  if sw and sw > avail then
    local size = math.floor(font[2] * avail / sw)
    if size < 8 then size = 8 end
    fs:SetFont(font[1], size, font[3])
  end
end
local function maybeFit(fs, text)
  if type(text) ~= "string" or issecret(text) or not hasCJK(text) then return end
  if not (fs.GetNumPoints and fs.GetPoint and fs.GetFont and fs.SetFont and fs.GetStringWidth) then return end
  if fs:GetNumPoints() ~= 1 then return end
  local point, rel = fs:GetPoint(1)
  local parent = fs:GetParent()
  if point ~= "CENTER" or not parent or (rel ~= nil and rel ~= parent) then return end
  if not fitList[fs] then
    local path, size, flags = fs:GetFont()
    if not path or not size then return end
    fitList[fs] = { path, size, flags }
    if parent.HookScript and not parent.__ofazhFit then
      parent.__ofazhFit = true
      parent:HookScript("OnSizeChanged", function(self)
        for f in pairs(fitList) do
          if f:GetParent() == self then pcall(refit, f) end
        end
      end)
    end
  end
  refit(fs)
end
local function wrapFS(fs)
  if type(fs) ~= "table" or fs.__ofazh then return fs end
  local set = fs.SetText
  if type(set) ~= "function" then return fs end
  fs.__ofazh = true
  fs.SetText = function(self, t, ...)
    local tr = Tr(t)
    local r = set(self, tr, ...)
    if tr ~= t then pcall(maybeFit, self, tr) end
    return r
  end
  local setf = fs.SetFormattedText
  if type(setf) == "function" then
    fs.SetFormattedText = function(self, fmt, ...)
      local ok, s = pcall(strformat, fmt, ...)
      if ok then
        local tr = Tr(s)
        local r = set(self, tr)
        if tr ~= s then pcall(maybeFit, self, tr) end
        return r
      end
      return setf(self, fmt, ...)
    end
  end
  local ok, cur = pcall(fs.GetText, fs)
  if ok and type(cur) == "string" and not issecret(cur) then
    local tr = Tr(cur)
    if tr ~= cur then set(fs, tr); pcall(maybeFit, fs, tr) end
  end
  return fs
end
ns.wrapFS = wrapFS

local FLT = _G.OneForAll
local hooked = false
local function hookOneForAll()
  if hooked then return end
  FLT = _G.OneForAll
  if type(FLT) ~= "table" then return end
  hooked = true
  addLC(T); addLC(N)

  -- 1. 文字物件
  if type(FLT.NewFS) == "function" then
    local orig = FLT.NewFS
    FLT.NewFS = function(owner, ...) return wrapFS(orig(owner, ...)) end
  end

  -- 標題用的「小型大寫字」：中文不能拆字母，改成一般文字
  local UI = FLT.UI
  if type(UI) == "table" and type(UI.SmallCaps) == "function" then
    local orig = UI.SmallCaps
    UI.SmallCaps = function(parent, text, big, small, color, template)
      local en = tostring(text or "")
      local tr = Tr(en)
      if tr ~= en and hasCJK(tr) then
        local holder = CreateFrame("Frame", nil, parent)
        local fs = holder:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
        local font, _, flags = fs:GetFont()
        if font then fs:SetFont(font, big or 14, flags) end
        fs:SetText(tr)
        if type(color) == "table" then
          if FLT.SkinC then fs:SetTextColor(FLT.SkinC(unpack(color))) else fs:SetTextColor(unpack(color)) end
        end
        fs:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
        holder:SetSize(math.max(1, fs:GetStringWidth() or 1), (big or 14) + 2)
        return holder
      end
      return orig(parent, text, big, small, color, template)
    end
  end
end

-- 2. 滑鼠提示框
local function fixLine(tt, idx, side)
  local name = tt.GetName and tt:GetName()
  if not name or not idx or idx < 1 then return end
  local fs = _G[name .. "Text" .. side .. idx]
  if not fs then return end
  local ok, cur = pcall(fs.GetText, fs)
  if ok and type(cur) == "string" and not issecret(cur) and strfind(cur, "%a") then
    local tr = Tr(cur)
    if tr ~= cur then fs:SetText(tr) end
  end
end
local function hookTooltip(tt)
  if type(tt) ~= "table" or tt.__ofazh then return end
  tt.__ofazh = true
  hooksecurefunc(tt, "AddLine", function(self) fixLine(self, self:NumLines(), "Left") end)
  hooksecurefunc(tt, "AddDoubleLine", function(self)
    local n = self:NumLines(); fixLine(self, n, "Left"); fixLine(self, n, "Right")
  end)
  hooksecurefunc(tt, "SetText", function(self) fixLine(self, 1, "Left") end)
end

-- 3. 聊天框：只動 OneForAll 自己的訊息
local PREFIX = "|cff66ccff"
local function wrapChat(cf)
  if type(cf) ~= "table" or cf.__ofazh or type(cf.AddMessage) ~= "function" then return end
  cf.__ofazh = true
  local orig = cf.AddMessage
  cf.AddMessage = function(self, text, ...)
    if type(text) == "string" and not issecret(text) and strsub(text, 1, 10) == PREFIX then
      local a, b = strfind(text, ":|r ", 11, true)
      if a and a < 60 then
        text = strsub(text, 1, b) .. Tr(strsub(text, b + 1))
      end
    end
    return orig(self, text, ...)
  end
end

-- 4. 很早就建立、沒經過 NewFS 的文字：登入後掃一次 OneForAll 的視窗
local NAMED = { "OneForAllFrame", "OneForAllCraftList", "OneForAllWelcome", "OneForAllPreviewFrame", "OneForAllQuestChain",
  "OneForAllWeightEditor", "OneForAllDungeonMapKey", "OneForAllProfilePopup", "OneForAllQuestSharePopup", "OneForAllWorldMapMenu",
  "OneForAllWorldMapButton", "OneForAllConfirm", "OneForAllConfirmSecure", "OneForAllBugReport", "OneForAllChatHideButton",
  "OneForAllLibraryInfoPopup", "OneForAllTrainerSpells" }
local seen = setmetatable({}, { __mode = "k" })
local function scan(frame, depth)
  if type(frame) ~= "table" or seen[frame] or depth > 14 then return end
  seen[frame] = true
  if frame.GetRegions then
    local regions = { frame:GetRegions() }
    for i = 1, #regions do
      local r = regions[i]
      if r and r.GetObjectType and r:GetObjectType() == "FontString" then wrapFS(r) end
    end
  end
  if frame.GetChildren then
    local kids = { frame:GetChildren() }
    for i = 1, #kids do scan(kids[i], depth + 1) end
  end
end
local function scanNamed()
  for i = 1, #NAMED do
    local f = _G[NAMED[i]]
    if f then
      scan(f, 0)
      if not f.__ofazhShow and f.HookScript then
        f.__ofazhShow = true
        f:HookScript("OnShow", function(self) seen[self] = nil; scan(self, 0) end)
      end
    end
  end
end

-- 5. 精簡綠色屬性：OneForAll 只認英文用戶端的「Equip:」行；繁中用戶端改認官方繁中說明
--    （句子取自永恆用戶端 1.60.1 的 Spell 表 zhTW，wago.tools；同一種屬性有幾種官方寫法就都列）
local SHORT_TW = {
  { "^使所有魔法法術和效果造成的治療效果提高最多(%d+)點，傷害提高最多(%d+)點。$", "+%2 法術傷害\n+%1 法術治療" },
  { "^使所有魔法法術和效果造成的治療效果最多提高(%d+)點，傷害最多提高(%d+)點。$", "+%2 法術傷害\n+%1 法術治療" },
  { "^使法術和魔法效果所造成的治療效果提高最多(%d+)點，法術傷害提高最多(%d+)點。$", "+%2 法術傷害\n+%1 法術治療" },
  { "^提高魔法法術和效果所造成的傷害和治療效果，最多(%d+)點。$", "+%1 法術傷害和治療" },
  { "^使所有魔法法術和效果造成的傷害和治療效果提高最多(%d+)點。$", "+%1 法術傷害和治療" },
  { "^使所有魔法法術和效果造成的傷害和治療效果最多提高(%d+)點。$", "+%1 法術傷害和治療" },
  { "^魔法法術和效果造成的傷害和治療效果最多提高(%d+)點。$", "+%1 法術傷害和治療" },
  { "^使魔法法術和效果造成的傷害和治療效果最多提高(%d+)點。$", "+%1 法術傷害和治療" },
  { "^使魔法法術和效果所造成的傷害和治療效果提高最多(%d+)點。$", "+%1 法術傷害和治療" },
  { "^提高法術和魔法效果所造成的治療效果，最多(%d+)點。$", "+%1 法術治療" },
  { "^法術和效果造成的治療效果最多提高(%d+)點。$", "+%1 法術治療" },
  { "^提高魔法法術和效果對(.-)所造成的傷害，最多(%d+)點。$", "+%2 法術傷害（對%1）" },
  { "^提高所有魔法法術和效果對(.-)所造成的傷害，最多(%d+)點。$", "+%2 法術傷害（對%1）" },
  { "^提高(.-)法術和效果所造成的傷害，最多(%d+)點。$", "+%2 %1法術傷害" },
  { "^(.-)法術和效果造成的傷害提高最多(%d+)點。$", "+%2 %1法術傷害" },
  { "^使你的法術造成致命一擊的機率提高([%d%.]+)%%。$", "+%1%% 法術致命一擊" },
  { "^使你造成致命一擊的機率提高([%d%.]+)%%。$", "+%1%% 致命一擊" },
  { "^使你的法術命中率提高([%d%.]+)%%。$", "+%1%% 法術命中" },
  { "^使你的命中機率提高([%d%.]+)%%。$", "+%1%% 命中" },
  { "^%+(%d+)遠程攻擊強度。$", "+%1 遠程攻擊強度" },
  { "^%+(%d+)點遠程攻擊強度。$", "+%1 遠程攻擊強度" },
  { "^對(.-)的攻擊強度提高(%d+)點。$", "+%2 攻擊強度（對%1）" },
  { "^%+(%d+)攻擊強度。$", "+%1 攻擊強度" },
  { "^%+(%d+)點攻擊強度。$", "+%1 攻擊強度" },
  { "^提高(%d+)點攻擊強度。$", "+%1 攻擊強度" },
  { "^每5秒恢復(%d+)點法力。$", "+%1 每5秒法力" },
  { "^每5秒恢復(%d+)點生命力。$", "+%1 每5秒生命力" },
  { "^防禦技能提高(%d+)點。$", "+%1 防禦" },
  { "^使你閃躲攻擊的機率提高([%d%.]+)%%。$", "+%1%% 閃躲" },
  { "^使你招架攻擊的機率提高([%d%.]+)%%。$", "+%1%% 招架" },
  { "^使你用盾牌格擋攻擊的機率提高([%d%.]+)%%。$", "+%1%% 格擋" },
  { "^使你的盾牌格擋值提高(%d+)點。$", "+%1 格擋值" },
  { "^使你法術目標的魔法抗性降低(%d+)點。$", "+%1 法術穿透" },
  { "^降低施法目標的魔法抗性(%d+)點。$", "+%1 法術穿透" },
  { "^你的攻擊速度提高([%d%.]+)%%。$", "+%1%% 攻擊速度" },
  { "^(.-)技能提高(%d+)點。$", "+%2 %1技能", 24 }, -- 武器技能：「劍類武器技能提高7點。」（第 3 欄＝第一個擷取最多幾個位元組）
}
local function shortTW(text)
  local body = strmatch(text, "^裝備：%s*(.+)$")
  if not body then return end
  for i = 1, #SHORT_TW do
    local e = SHORT_TW[i]
    local cap = e[3] and strmatch(body, e[1])
    local out, n = body, 0
    if not e[3] or (cap and #cap <= e[3]) then out, n = strgsub(body, e[1], e[2]) end
    if n > 0 then return (strgsub(out, "(%d)%.0%%", "%1%%")) end
  end
end
ns.ShortTW = shortTW
local function shortenTW(tt)
  local q = OneForAll and OneForAll.QoL
  if type(q) ~= "table" or type(q.Get) ~= "function" then return end
  local okq, on = pcall(q.Get, "shortStats")
  if not (okq and on) then return end
  if type(tt) ~= "table" or not tt.GetName or not tt.NumLines then return end
  local name = tt:GetName()
  if not name then return end
  local changed
  for i = 2, tt:NumLines() do
    local line = _G[name .. "TextLeft" .. i]
    if line then
      local ok, text = pcall(line.GetText, line)
      if ok and type(text) == "string" and not issecret(text) and strfind(text, "^裝備：") then
        local out = shortTW(text)
        if out then line:SetText(out); changed = true end
      end
    end
  end
  if changed then tt:Show() end
end
local function hookShortStats()
  if ns.shortHooked then return end
  ns.shortHooked = true
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt) pcall(shortenTW, tt) end)
  else
    local tips = { GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }
    for i = 1, #tips do
      local tt = tips[i]
      if type(tt) == "table" and tt.HookScript then pcall(tt.HookScript, tt, "OnTooltipSetItem", function(self) pcall(shortenTW, self) end) end
    end
  end
end

hookOneForAll()

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, name)
  if event == "ADDON_LOADED" then
    if name == "OneForAll" then hookOneForAll() end
    if name == ADDON then
      if type(OneForAll_zhTW_DB) ~= "table" then OneForAll_zhTW_DB = {} end
      ns.logMissing = OneForAll_zhTW_DB.log ~= false
    end
    return
  end
  hookOneForAll()
  hookTooltip(GameTooltip)
  hookTooltip(ItemRefTooltip)
  hookShortStats()
  wrapChat(DEFAULT_CHAT_FRAME)
  if C_Timer and C_Timer.After then
    C_Timer.After(3, scanNamed)
    C_Timer.After(15, scanNamed)
  else
    scanNamed()
  end
end)

SLASH_OFAZH1 = "/ofazh"
SlashCmdList.OFAZH = function(msg)
  msg = msg and strmatch(msg, "^%s*(.-)%s*$") or ""
  if msg == "log" or msg == "log on" or msg == "log off" then
    local on = msg ~= "log off"
    if msg == "log" then on = not ns.logMissing end
    ns.logMissing = on
    if type(OneForAll_zhTW_DB) == "table" then OneForAll_zhTW_DB.log = on end
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffOneForAll 繁中包|r 記錄沒翻到的句子：" .. (on and "開" or "關"))
    return
  end
  if msg == "clear" then
    if type(OneForAll_zhTW_DB) == "table" then OneForAll_zhTW_DB.missing = {}; OneForAll_zhTW_DB.missingN = 0 end
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffOneForAll 繁中包|r 已清空沒翻到的紀錄。")
    return
  end
  if msg == "" then
    local nN, nT = 0, 0
    for _ in pairs(N) do nN = nN + 1 end
    for _ in pairs(T) do nT = nT + 1 end
    DEFAULT_CHAT_FRAME:AddMessage(strformat("|cff66ccffOneForAll 繁中包|r 官方名稱 %d、翻譯 %d、句型 %d。輸入 /ofazh <英文> 試翻一句；/ofazh log 開關「記錄沒翻到的句子」（目前 %s，已記 %d 句）。", nN, nT, #TPL, ns.logMissing and "開" or "關", (type(OneForAll_zhTW_DB) == "table" and OneForAll_zhTW_DB.missingN) or 0))
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffOneForAll 繁中包|r " .. msg .. " → " .. Tr(msg))
  end
end
