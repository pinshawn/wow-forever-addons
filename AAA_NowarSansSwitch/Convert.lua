--===========================================================================
-- 簡體轉繁體（台灣用字）
-- 句子裡至少有一個「Big5 沒有的簡體字」才轉，台版遊戲本來的繁體字串不會被動到。
-- 轉法（同 OpenCC s2twp 的順序）：簡體詞 → 簡體字 → 台灣用詞 → 台灣字形
-- 資料在 S2T.lua（由 OpenCC 字典產生，Apache-2.0）
--===========================================================================
local _, ns = ...
local strfind, gmatch, concat, min = string.find, string.gmatch, table.concat, math.min

local UTF8 = "[%z\1-\127\194-\244][\128-\191]*"

local function charSet(s)
    local set = {}
    for c in gmatch(s, UTF8) do set[c] = true end
    return set
end

local function pairMap(s)   -- "簡繁簡繁…" → { 簡 = 繁 }
    local map, prev = {}, nil
    for c in gmatch(s, UTF8) do
        if prev then map[prev] = c; prev = nil else prev = c end
    end
    return map
end

local TRIG = charSet(ns.S2T_TRIGGER or "")
local CH = pairMap(ns.S2T_CHARS or "")
local TWV = pairMap(ns.S2T_TWV or "")
local PHR = ns.S2T_PHRASES or {}
local TWP = ns.S2T_TWP or {}

local function starters(tbl)
    local set, maxLen = {}, 1
    for k in pairs(tbl) do
        local n, first = 0, nil
        for c in gmatch(k, UTF8) do
            n = n + 1
            if n == 1 then first = c end
        end
        if first then set[first] = true end
        if n > maxLen then maxLen = n end
    end
    return set, maxLen
end
local PSTART, PMAX = starters(PHR)
local TSTART, TMAX = starters(TWP)

local function split(s)
    local t = {}
    for c in gmatch(s, UTF8) do t[#t + 1] = c end
    return t
end

local function longest(t, tbl, start, maxLen, minLen, fallback)
    local out, i, n = {}, 1, #t
    while i <= n do
        local hit = false
        if start[t[i]] then
            for L = min(maxLen, n - i + 1), minLen, -1 do
                local v = tbl[concat(t, "", i, i + L - 1)]
                if v then
                    out[#out + 1] = v
                    i = i + L
                    hit = true
                    break
                end
            end
        end
        if not hit then
            local c = t[i]
            out[#out + 1] = fallback and fallback[c] or c
            i = i + 1
        end
    end
    return concat(out)
end

-- 有沒有簡體字：先看有沒有中文字（UTF-8 開頭 E4～E9），有才逐字查
local function hasTrigger(s)
    if not strfind(s, "[\228-\233]") then return false end
    for c in gmatch(s, "[\228-\233][\128-\191][\128-\191]") do
        if TRIG[c] then return true end
    end
    return false
end
ns.S2T_HasSimplified = hasTrigger

local cache, cacheN = {}, 0
function ns.ConvertS2T(s)
    if type(s) ~= "string" or s == "" then return s end
    local hit = cache[s]
    if hit ~= nil then return hit end
    local r = s
    if hasTrigger(s) then
        r = longest(split(s), PHR, PSTART, PMAX, 2, CH)
        r = longest(split(r), TWP, TSTART, TMAX, 1, nil)
        r = (r:gsub(UTF8, TWV))
    end
    if cacheN >= 4000 then cache, cacheN = {}, 0 end
    cache[s] = r
    cacheN = cacheN + 1
    return r
end
