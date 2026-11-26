-- Polestar 中文補充（我們自己做的，GPL-3.0）
-- Polestar 作者附的繁體中文包（Polestar_zhTW）是機器翻的，作者改了英文句子以後，
-- 新句子要等作者下一批翻譯才會有中文，這段時間遊戲裡會顯示英文。這個插件把那些句子先補上。
--
-- 規矩：作者有翻的一律用作者的。這裡只補「作者那邊沒有、或是空白」的句子；
--       作者之後翻好的句子，我們整理時會從這個插件刪掉。
-- 接法：Polestar_zhTW 的 Texts.lua、Interface.lua 各有一行我們的共用補丁，
--       Polestar 載入中文包時會呼叫這裡的 MergeGuides／MergeUI。
--       資料夾名字開頭是「!」，所以這個插件會比 Polestar 先載入。

PolestarPlusZhTW = {
	version = "0.2",
	basedOn = "0.4.3",    -- 這一版的句子是照 Polestar 哪一版整理的
	guides = {},            -- [指南代號] = { [英文原句] = 中文 }
	ui = {},                -- [英文介面字] = 中文
	merged = { guides = false, ui = false },
	added = { guides = 0, ui = 0 },
}
local P = PolestarPlusZhTW

-- 指南句子：在 Texts.lua 把整包交給 Polestar 之前呼叫（t 是作者的整包翻譯）
function P.MergeGuides(t)
	if type(t) ~= "table" then return end
	if type(t.guides) ~= "table" then t.guides = {} end
	local n = 0
	for id, list in pairs(P.guides) do
		local g = t.guides[id]
		if type(g) ~= "table" then g = {}; t.guides[id] = g end
		for en, zh in pairs(list) do
			if g[en] == nil or g[en] == "" then
				g[en] = zh
				n = n + 1
			end
		end
	end
	P.merged.guides = true
	P.added.guides = n
end

-- 介面字：在 Interface.lua 開頭呼叫；作者後面那幾行會再蓋過去，所以作者有翻的還是用作者的
function P.MergeUI(L)
	if type(L) ~= "table" then return end
	for en, zh in pairs(P.ui) do
		if rawget(L, en) == nil then L[en] = zh end
	end
	P.merged.ui = L
end

local function countUI()
	local L = P.merged.ui
	if type(L) ~= "table" then return 0 end
	local n = 0
	for en, zh in pairs(P.ui) do
		if rawget(L, en) == zh then n = n + 1 end
	end
	return n
end

local function report()
	local function total(t) local n = 0; for _, l in pairs(t) do for _ in pairs(l) do n = n + 1 end end; return n end
	local ui = 0; for _ in pairs(P.ui) do ui = ui + 1 end
	local msg
	if not P.merged.guides and not P.merged.ui then
		msg = "還沒接上：Polestar 的中文包沒有呼叫這裡（共用補丁還沒補上，或 Polestar 中文包沒載入）。雙擊「更新插件」補一次再重開遊戲。"
	else
		msg = ("指南補了 %d 句（這個插件帶了 %d 句）、介面補了 %d 句（帶了 %d 句）；其他的作者已經有翻，用作者的。")
			:format(P.added.guides, total(P.guides), countUI(), ui)
	end
	print("|cff66ccffPolestar 中文補充 " .. P.version .. "|r（照 Polestar " .. P.basedOn .. " 整理）：" .. msg)
end

SLASH_POLESTARPLUSZHTW1 = "/pszh"
SLASH_POLESTARPLUSZHTW2 = "/polestar中文"
SlashCmdList.POLESTARPLUSZHTW = report
