# 魔獸世界：永恆 插件自動更新（不用 CurseForge）
# 雙擊「更新插件.bat」執行。要更新哪些插件寫在 addons.json。
# 換新版前，舊版整個搬到 <遊戲資料夾>\插件備份\<日期時間>\，不刪；確定沒問題再自己刪。
# 只用 Windows 內建的 PowerShell 5.1，不用另外裝東西。
# v1.3：會先讀「線上清單」（addons.json 的 lists），清單上新加的插件自己加進來；
#       換新版後列出「改了什麼」（作者的更新說明），完整的存在 最近更新說明.txt。
# v1.3.3：addons.json 寫了 localPatches 才做「本機補丁」：更新完檢查一次，被新版蓋掉就再補上；
#       作者改到那段、補不上就不動檔案，畫面寫「補丁套不上」。
# v1.3.4：新版 .toc 寫的必要前置插件（## Dependencies），下載裡有就一起裝（Shortest Path 1.29 起要 ForeverCore）；
#       版本一樣但前置插件沒裝，就同一版重裝一次補上；最後檢查每個插件的前置插件，缺了就用紅字說。
# v1.3.5：更新程式自己更新：線上清單的 updater 寫了比較新的版本，就下載新的 update_addons.ps1
#       （檢查碼要對、讀得懂、版本號要對才換），舊的留在 舊版_v<版本>\，換好用新的從頭跑一次。
# v1.3.6：共用補丁：線上清單的 patches 列的補丁大家都會補（不放原作者程式碼的 format 2）；
#       addons.json 可以寫 sharedPatches: false 或 skipPatches 不要。
# v1.3.7：curseforge-assist：只在 CurseForge 的插件（例：Details），看作者 GitHub 的版本號，有新版就幫你打開
#       CurseForge 下載頁（下載會自己開始），等下載好就裝。
#       github-source：作者 GitHub 只有原始碼的（例：Details），自己組裝（搬附加、填版本號），完全不經過 CurseForge。
# v1.3.8：github-tag：作者每一版在 GitHub 打一個「版本標籤」（例：ProcDoc 的 v4.18.0），照標籤下載、填版本號。
#       optional：清單上標了的插件，就算 addons.json 寫 installMissing 也不會自己裝；要的人自己先放一次，之後才幫他更新。

$UpdaterVersion = '1.3.8'
$SelfPath = $MyInvocation.MyCommand.Path
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # 不顯示下載進度條（PowerShell 5.1 顯示進度條會慢很多）
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$UA = @{ 'User-Agent' = 'WoW-Forever-Addon-Updater' }
$Results = New-Object System.Collections.ArrayList
$script:BranchCache = @{}

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }

function Add-Result($name, $local, $remote, $status, $color, $notes = $null) {
    [void]$Results.Add([pscustomobject]@{ Name = $name; Local = $local; Remote = $remote; Status = $status; Color = $color; Notes = @($notes | Where-Object { $_ }) })
}

# ---------------------------------------------------------------------------
# 版本號：從字串抓出「數字.數字.數字」比大小（v1.22.45、bundle/v12.6.3+v1.0.12 → 12.6.3）
# ---------------------------------------------------------------------------
function Get-Ver([string]$s) {
    if (-not $s) { return $null }
    $m = [regex]::Match($s, '\d+(\.\d+)*')
    if (-not $m.Success) { return $null }
    $parts = New-Object System.Collections.ArrayList
    foreach ($p in $m.Value.Split('.')) {
        if ($parts.Count -ge 4) { break }
        $n = 0
        if (-not [int]::TryParse($p, [ref]$n)) { return $null }
        [void]$parts.Add($n)
    }
    while ($parts.Count -lt 2) { [void]$parts.Add(0) }
    return New-Object Version (($parts | ForEach-Object { $_.ToString() }) -join '.')
}

function Read-TocVersionFromText([string]$text) {
    if (-not $text) { return $null }
    $m = [regex]::Match($text, '(?m)^\s*##\s*Version\s*:\s*(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# 本機插件資料夾的版本（同一個資料夾可能有好幾個 .toc：先看同名的，再看 _Forever 的）
function Get-LocalVersion([string]$folder) {
    return (Get-DirVersion (Join-Path $script:AddOns $folder) $folder)
}
function Get-DirVersion([string]$dir, [string]$folder) {
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $tocs = @(Get-ChildItem -LiteralPath $dir -Filter '*.toc' -File -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { if ($_.BaseName -eq $folder) { 0 } elseif ($_.BaseName -like '*_Forever') { 1 } else { 2 } } }, Length)
    foreach ($t in $tocs) {
        $hit = Select-String -LiteralPath $t.FullName -Pattern '^\s*##\s*Version\s*:\s*(.+?)\s*$' -List -ErrorAction SilentlyContinue
        if ($hit) { return $hit.Matches[0].Groups[1].Value }
    }
    return $null
}

# .toc 寫的「必要前置插件」（## Dependencies／## RequiredDeps／## Dep…）：沒裝的話這個插件整個開不起來；暴雪自己的不算
# 一個資料夾有好幾個 .toc 時：有 _Forever 的看 _Forever 的，沒有就看同名的，都沒有才全部看
function Get-TocDeps([string]$dir) {
    $all = @(Get-ChildItem -LiteralPath $dir -Filter '*.toc' -File -ErrorAction SilentlyContinue)
    $leaf = Split-Path -Leaf $dir
    $use = @($all | Where-Object { $_.BaseName -like '*_Forever' })
    if ($use.Count -eq 0) { $use = @($all | Where-Object { $_.BaseName -ieq $leaf }) }
    if ($use.Count -eq 0) { $use = $all }
    $out = New-Object System.Collections.ArrayList
    foreach ($t in $use) {
        foreach ($line in @(Get-Content -LiteralPath $t.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match([string]$line, '^\s*##\s*(Dependencies|RequiredDeps|Dep\d*)\s*:\s*(.*)$', 'IgnoreCase')
            if (-not $m.Success) { continue }
            foreach ($d in ($m.Groups[2].Value -split '[,\s]+')) {
                $d = $d.Trim()
                if ($d -and -not $d.StartsWith('Blizzard_') -and -not ($out -contains $d)) { [void]$out.Add($d) }
            }
        }
    }
    return $out.ToArray()
}
# 本機這個插件要的前置插件，哪幾個沒裝
function Get-MissingDeps([string]$folder) {
    $dir = Join-Path $script:AddOns $folder
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($d in @(Get-TocDeps $dir)) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:AddOns $d))) { $d }
    }
}

# ---------------------------------------------------------------------------
# 找遊戲資料夾（裡面要有 Interface\AddOns）
# ---------------------------------------------------------------------------
# 路徑怪怪的（例如從安裝紀錄抓到的亂碼）就當作不存在，不要讓整個程式停掉
function Test-PathSafe([string]$p) {
    try { return [bool](Test-Path -LiteralPath $p) } catch { return $false }
}

function Find-GameDir($config) {
    $cands = @()
    if ($config.gameDir) { $cands += [string]$config.gameDir }
    $cands += (Split-Path -Parent $Here)
    # Battle.net 裝魔獸時寫在登錄檔的位置（找不到就算了）
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft', 'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft') {
        try {
            $ip = [string](Get-ItemProperty -LiteralPath $k -ErrorAction Stop).InstallPath
            if ($ip) {
                $ip = $ip.TrimEnd('\')
                $cands += [IO.Path]::Combine($ip, '_forever_')
                $cands += [IO.Path]::Combine([IO.Path]::GetDirectoryName($ip), '_forever_')
            }
        } catch { }
    }
    # Battle.net 自己的安裝紀錄（product.db 裡有每個遊戲裝在哪；讀不到就算了）
    try {
        if ($env:ProgramData) {
            $pdb = [IO.Path]::Combine($env:ProgramData, 'Battle.net', 'Agent', 'product.db')
            if (Test-Path -LiteralPath $pdb) {
                $txt = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($pdb))
                foreach ($m in [regex]::Matches($txt, '[A-Za-z]:[\\/][^\x00-\x1f"<>|*?]{0,200}')) {
                    $pth = $m.Value.TrimEnd('\', '/')
                    if ($pth -match '[\\/]_forever_$') { $cands += $pth } else { $cands += [IO.Path]::Combine($pth, '_forever_') }
                }
            }
        }
    } catch { }
    foreach ($d in 'C', 'D', 'E', 'F', 'G') {
        $cands += "${d}:\World of Warcraft\_forever_", "${d}:\Program Files (x86)\World of Warcraft\_forever_", "${d}:\Games\World of Warcraft\_forever_"
    }
    foreach ($c in $cands) {
        if (-not $c) { continue }
        try { $ad = [IO.Path]::Combine($c, 'Interface', 'AddOns') } catch { continue }
        if (Test-PathSafe $ad) { return (Resolve-Path -LiteralPath $c).Path }
    }
    # 還沒裝過任何插件（沒有 Interface\AddOns）：有遊戲本體就自己建 AddOns
    foreach ($c in $cands) {
        if (-not $c) { continue }
        try { $exe = [IO.Path]::Combine($c, 'Wow.exe'); $fl = [IO.Path]::Combine($c, '.flavor.info') } catch { continue }
        if ((Test-PathSafe $exe) -or (Test-PathSafe $fl)) {
            New-Item -ItemType Directory -Path ([IO.Path]::Combine($c, 'Interface', 'AddOns')) -Force | Out-Null
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

# 「已更新」或「新裝好」（本來沒裝的）
function Get-DoneWord([string]$localStr) {
    if ($localStr) { return '已更新' }
    return '新裝好'
}

function Test-GameRunning([string]$gameDir) {
    $prefix = $gameDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        $path = $null
        try { $path = $p.Path } catch { }
        if ($path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 下載、解壓、找資料夾
# ---------------------------------------------------------------------------
function Get-Json([string]$url) {
    return Invoke-RestMethod -Uri $url -Headers ($UA + @{ 'Accept' = 'application/vnd.github+json' }) -UseBasicParsing -TimeoutSec 30
}

# 作者網站的清單：自己用 UTF-8 解（網站沒寫字元編碼時，Windows PowerShell 會把中文解成亂碼）
function Get-JsonUrl([string]$url) {
    return ((Get-Text $url) | ConvertFrom-Json)
}

# 一律當 UTF-8 讀（中文的清單、說明才不會變亂碼）
function Get-Text([string]$url) {
    $r = Invoke-WebRequest -Uri $url -Headers $UA -UseBasicParsing -TimeoutSec 30
    try {
        $bytes = $r.RawContentStream.ToArray()
        if ($bytes -and $bytes.Length -gt 0) { return [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) }
    } catch { }
    if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content).TrimStart([char]0xFEFF) }
    return ([string]$r.Content).TrimStart([char]0xFEFF)
}

function Save-Download([string]$url, [string]$file) {
    Invoke-WebRequest -Uri $url -Headers $UA -OutFile $file -UseBasicParsing -TimeoutSec 900
}

function New-TempDir {
    $d = Join-Path $script:TmpRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

# 解壓後找「名字一樣、裡面有 .toc」的資料夾，挑最淺的那個
function Find-AddonDir([string]$root, [string]$name) {
    $hits = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq $name -and (Get-ChildItem -LiteralPath $_.FullName -Filter '*.toc' -File -ErrorAction SilentlyContinue | Select-Object -First 1) } |
        Sort-Object { $_.FullName.Length })
    if ($hits.Count -gt 0) { return $hits[0].FullName }
    return $null
}

# 換新版：先把舊的全部搬到備份，再把新的搬進去；中途出錯就把舊的搬回來
function Install-Folders($entry, [string]$extracted) {
    $plan = @()
    $missing = @()
    foreach ($f in $entry.folders) {
        $src = Find-AddonDir $extracted $f
        if ($src) { $plan += [pscustomobject]@{ Name = $f; Src = $src } }
        else { $missing += $f }
    }
    if ($plan.Count -eq 0) { throw "下載的檔案裡找不到 $($entry.folders -join '、')" }
    if ($plan[0].Name -ne $entry.folders[0]) { throw "下載的檔案裡找不到主資料夾 $($entry.folders[0])" }

    # 新版 .toc 寫的必要前置插件，下載裡也有的就一起裝（例：Shortest Path v1.29 起要 ForeverCore，作者放在同一個 zip）
    # 本機已經有、而且比下載裡的新，就不換成舊的
    $extra = @()
    $names = @($plan | ForEach-Object { $_.Name })
    foreach ($pp in @($plan)) {
        foreach ($d in @(Get-TocDeps $pp.Src)) {
            if ($names -contains $d) { continue }
            $ds = Find-AddonDir $extracted $d
            if (-not $ds) { continue }
            $inside = $false
            foreach ($q in $plan) { if ($ds.StartsWith($q.Src + [IO.Path]::DirectorySeparatorChar)) { $inside = $true } }
            if ($inside) { continue }
            $lv = Get-Ver (Get-LocalVersion $d)
            $zv = Get-Ver (Get-DirVersion $ds $d)
            if ($lv -and $zv -and $zv -lt $lv) { continue }
            $plan += [pscustomobject]@{ Name = $d; Src = $ds }
            $names += $d
            $extra += $d
        }
    }

    $backup = Join-Path (Join-Path $script:BackupRoot $script:Stamp) $entry.folders[0]
    $moved = @()      # 已經搬去備份的舊資料夾
    $placed = @()     # 已經放進去的新資料夾
    try {
        foreach ($p in $plan) {
            $dst = Join-Path $script:AddOns $p.Name
            if (Test-Path -LiteralPath $dst) {
                New-Item -ItemType Directory -Path $backup -Force | Out-Null
                Move-Item -LiteralPath $dst -Destination (Join-Path $backup $p.Name)
                $moved += $p.Name
            }
        }
        foreach ($p in $plan) {
            Move-Item -LiteralPath $p.Src -Destination (Join-Path $script:AddOns $p.Name)
            $placed += $p.Name
        }
    } catch {
        $err = $_.Exception.Message
        foreach ($n in $placed) {
            try { Remove-Item -LiteralPath (Join-Path $script:AddOns $n) -Recurse -Force } catch { }
        }
        foreach ($n in $moved) {
            try { Move-Item -LiteralPath (Join-Path $backup $n) -Destination (Join-Path $script:AddOns $n) } catch { }
        }
        throw "換的時候出錯，已經把舊版放回去：$err"
    }
    $note = ''
    if ($extra.Count -gt 0) { $note = "（一起裝了 $($extra -join '、')：$($entry.folders[0]) 要它才開得起來）" }
    if ($missing.Count -gt 0) { $note += "（下載裡沒有：$($missing -join '、')，原本的留著沒動）" }
    if ($moved.Count -gt 0) { $note += "　舊版備份在 插件備份\$($script:Stamp)\$($entry.folders[0])" }
    return $note
}

# 檔名沒標 UTF-8 的 zip 也當 UTF-8 讀（不然中文檔名會變亂碼）
function Expand-Zip([string]$zip, [string]$dest) {
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest, [Text.Encoding]::UTF8)
}

# ---------------------------------------------------------------------------
# 「改了什麼」：作者寫的更新說明（拿不到就算了，不影響更新）
# ---------------------------------------------------------------------------
$script:TradOk = $null
# 簡體字轉繁體：用 Windows 內建的 LCMapStringEx（直接在 Unicode 上換字、不換詞；轉不了就照原文）
# （v1.3 用的 StrConv 會先轉成 Big5，Big5 沒有的簡體字變成「?」，所以換掉）
function Convert-ToTrad([string]$s) {
    if (-not $s -or $s -notmatch '[一-鿿]') { return $s }
    if ($null -eq $script:TradOk) {
        try {
            Add-Type -Namespace AddonUpdater -Name Lcm -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int LCMapStringEx(string lpLocaleName, uint dwMapFlags, string lpSrcStr, int cchSrc, [Out] char[] lpDestStr, int cchDest, IntPtr lpVersionInformation, IntPtr lpReserved, IntPtr sortHandle);
'@
            $script:TradOk = $true
        } catch { $script:TradOk = $false }
    }
    if (-not $script:TradOk) { return $s }
    try {
        $buf = New-Object char[] ($s.Length * 2 + 16)
        $n = [AddonUpdater.Lcm]::LCMapStringEx('zh-TW', 0x04000000, $s, $s.Length, $buf, $buf.Length, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
        if ($n -gt 0) { return [string]::new($buf, 0, $n) }
    } catch { }
    return $s
}

# 把 GitHub 的 Markdown 整理成好讀的一行一行
function Format-NoteLine([string]$l) {
    if ($null -eq $l) { return $null }
    if ($l -match '^\s*Build:\s') { return $null }
    $l = [regex]::Replace($l, '\s*\((\s*\[[^\]]*\]\([^)]*\)\s*,?)+\)', '')       # （[作者](網址)）
    $l = [regex]::Replace($l, '!\[[^\]]*\]\([^)]*\)', '')                          # 圖片
    $l = [regex]::Replace($l, '\[([^\]]+)\]\([^)]*\)', '$1')                       # [字](網址) → 字
    $l = [regex]::Replace($l, '<[^>]+>', '')
    $l = [regex]::Replace($l, '\*\*([^*]+)\*\*', '$1')
    $l = [regex]::Replace($l, '__([^_]+)__', '$1')
    $l = [regex]::Replace($l, '`([^`]+)`', '$1')
    $l = [regex]::Replace($l, '\\([\\`*_{}\[\]()#+\-.!>|"])', '$1')               # \[Forever\] → [Forever]
    if ($l -match '^\s*#{1,6}\s*(.+?)\s*#*\s*$') { $l = '〔' + $Matches[1].Trim() + '〕' }
    $l = [regex]::Replace($l, '^\s*[-*+]\s+', '・')
    $l = $l.Trim()
    if (-not $l -or $l -match '^[=\-_*]{3,}$') { return $null }
    return $l
}

function Format-NoteBlock([string]$text) {
    $out = @()
    foreach ($l in ($text -split "`r?`n")) { $f = Format-NoteLine $l; if ($f) { $out += $f } }
    return $out
}

# 這個版本要不要列：比本機新、不比網路上的新（第一次裝就只列最新那一版）
function Test-NoteVer($v, $localVer, $remoteVer) {
    if (-not $v) { return $false }
    if ($remoteVer -and $v -gt $remoteVer) { return $false }
    if ($localVer -and $v -le $localVer) { return $false }
    return $true
}

# 從插件資料夾裡的說明檔找改版紀錄（讀我.txt、README、CHANGELOG）
# 認得兩種寫法：「  v1.6.1  說明…」（我們的讀我.txt）、「6.2.1 - 標題」底下一條一條（OneForAll 的 README）
function Get-NotesFromText([string]$text, $localVer, $remoteVer) {
    $lines = $text -split "`r?`n"
    $start = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '(改版紀錄|更新紀錄|版本紀錄|更新日誌|更新日志|Change\s?log|Version history|Release notes|What.s new)') { $start = $i + 1; break }
    }
    $out = New-Object System.Collections.ArrayList
    $sections = 0; $take = $false; $inSec = $false; $blank = $false; $headIndent = 0
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*[=\-]{3,}\s*$') { continue }
        $m = [regex]::Match($l, '^(\s*)[vV]?(\d+\.\d+(?:\.\d+){0,2})(?:\s*[-–—:：]\s*|\s{2,}|\s*$)(.*)$')
        if ($m.Success) {
            $v = Get-Ver $m.Groups[2].Value
            $take = (Test-NoteVer $v $localVer $remoteVer) -and ($localVer -or $sections -eq 0) -and ($sections -lt 6)
            if ($take) {
                $sections++
                [void]$out.Add("【$($m.Groups[2].Value)】")
                $rest = $m.Groups[3].Value.Trim()
                if ($rest) { [void]$out.Add($rest) }
            }
            $inSec = $true; $blank = $false; $headIndent = $m.Groups[1].Value.Length
            continue
        }
        if (-not $inSec) { continue }
        if (-not $l.Trim()) { $blank = $true; continue }
        # 標題有縮排的檔（我們的讀我.txt）：空一行後碰到沒縮排的字＝下一段（例如「授權」），改版紀錄結束
        if ($blank -and $headIndent -gt 0 -and $l -notmatch '^\s' -and $l -notmatch '^[-*•・]') { break }
        $blank = $false
        if (-not $take) { continue }
        $f = Format-NoteLine $l
        if (-not $f) { continue }
        # 接續上一行的字（沒有「・」開頭、縮排比較多）接到上一行後面
        $isCont = ($l -match '^\s+') -and ($l -notmatch '^\s*[-*+•・]\s') -and $out.Count -gt 0 -and -not $out[$out.Count - 1].StartsWith('【')
        if ($isCont) {
            $prev = $out[$out.Count - 1]
            $sep = ''
            if ($prev -match '[A-Za-z0-9,.;:)]$' -and $f -match '^[A-Za-z0-9(]') { $sep = ' ' }
            $out[$out.Count - 1] = $prev + $sep + $f
        } else { [void]$out.Add($f) }
    }
    return @($out)
}

function Get-NotesFromFolder([string]$dir, $localVer, $remoteVer) {
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(讀我|更新說明|更新紀錄|改版紀錄|changelog|change_log|changes|history|readme)(\.(txt|md))?$' -and $_.Length -lt 2MB } |
        Sort-Object @{ Expression = { if ($_.Name -match '^(更新說明|更新紀錄|改版紀錄|changelog|change_log|changes|history)') { 0 } else { 1 } } })
    foreach ($f in $files) {
        try {
            $txt = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
            $n = @(Get-NotesFromText $txt $localVer $remoteVer)
            if ($n.Count -gt 0) { return $n }
        } catch { }
    }
    return @()
}

# GitHub 發布版：每一版的說明（中間跳過好幾版就每一版都列）
function Get-ReleaseNotes($entry, $localVer, $remoteVer, $latest) {
    $out = @(); $n = 0
    try {
        # Windows PowerShell 5.1 會把整個陣列當成一個東西傳回來，先拆開
        $raw = Get-Json "https://api.github.com/repos/$($entry.repo)/releases?per_page=20"
        $rels = @($raw | ForEach-Object { $_ })
        foreach ($r in $rels) {
            if ($r.draft -or $r.prerelease) { continue }
            $v = Get-Ver ([string]$r.tag_name)
            if (-not (Test-NoteVer $v $localVer $remoteVer)) { continue }
            $out += "【$($r.tag_name)】"
            $out += @(Format-NoteBlock ([string]$r.body))
            $n++
            if ((-not $localVer) -or $n -ge 6) { break }
        }
    } catch { }
    if ($out.Count -eq 0 -and $latest -and $latest.body) {
        $out = @("【$($latest.tag_name)】") + @(Format-NoteBlock ([string]$latest.body))
    }
    return $out
}

# 作者沒寫說明檔：列 GitHub 上的修改紀錄（commit 訊息），列到本機那一版為止
function Get-CommitNotes($entry, [string]$branch, [string]$localStr) {
    $out = @()
    try {
        $raw = Get-Json "https://api.github.com/repos/$($entry.repo)/commits?sha=$branch&per_page=30"
        $cs = @($raw | ForEach-Object { $_ })
        $num = $null
        if ($localStr) { $mm = [regex]::Match($localStr, '\d+(\.\d+)+'); if ($mm.Success) { $num = $mm.Value } }
        $found = $false
        foreach ($c in $cs) {
            $msg = (([string]$c.commit.message) -split "`r?`n")[0].Trim()
            if (-not $msg) { continue }
            if ($num -and $msg -match ('(?<![\d.])' + [regex]::Escape($num) + '(?![\d.])')) { $found = $true; break }
            if ($msg -match '^Merge (pull request|branch|remote)') { continue }
            $out += '・' + (Convert-ToTrad $msg)
            if ($out.Count -ge 8) { break }
        }
        if ($num -and -not $found -and $out.Count -gt 5) { $out = @($out[0..4]) + '（只列最近 5 筆）' }
        elseif (-not $num -and $out.Count -gt 3) { $out = @($out[0..2]) }
    } catch { }
    return $out
}

# 作者網站的版本清單（GearInsight）：history 裡每一版的重點
function Get-ManifestNotes($info, $localVer, $remoteVer) {
    $out = @(); $n = 0
    foreach ($h in @($info.history)) {
        if (-not $h) { continue }
        $v = Get-Ver ([string]$h.version)
        if (-not (Test-NoteVer $v $localVer $remoteVer)) { continue }
        $hl = $h.highlights
        $arr = $null; $simp = $false
        if ($hl) {
            if ($hl.'zh-TW') { $arr = $hl.'zh-TW' }
            elseif ($hl.'zh-CN') { $arr = $hl.'zh-CN'; $simp = $true }
            elseif ($hl.en) { $arr = $hl.en }
        }
        $out += "【$($h.version)】"
        foreach ($it in @($arr)) {
            $s = ([string]$it).Trim()
            if (-not $s) { continue }
            if ($s.Length -lt 40 -and $s -match [regex]::Escape([string]$h.version)) { continue }   # 「GearInsight 無限 0.8.9」這種標題行
            if ($simp) { $s = Convert-ToTrad $s }
            $out += $s
        }
        $n++
        if ((-not $localVer) -or $n -ge 6) { break }
    }
    return $out
}

# 拿說明不准讓更新失敗
function Get-NotesSafe([scriptblock]$sb) {
    try { return @(& $sb) } catch { return @() }
}

# ---------------------------------------------------------------------------
# 三種來源
# ---------------------------------------------------------------------------
function Update-GitHubRelease($entry, $state) {
    $name = $entry.name
    $localStr = Get-LocalVersion $entry.folders[0]
    $rel = Get-Json "https://api.github.com/repos/$($entry.repo)/releases/latest"
    $tag = [string]$rel.tag_name
    $remoteVer = Get-Ver $tag
    $localVer = Get-Ver $localStr
    $asset = @($rel.assets | Where-Object { $_.name -match $entry.asset }) | Select-Object -First 1
    if (-not $asset) { Add-Result $name $localStr $tag '找不到下載檔（作者改了檔名？）' 'Yellow'; return }

    $saved = $state.($entry.repo)
    $need = $false
    if (-not $localStr) { $need = $true }
    elseif ($saved -and $saved.tag) {
        $need = ($saved.tag -ne $tag) -and ((-not $remoteVer) -or (-not $localVer) -or ($remoteVer -ge $localVer))
    } elseif ($remoteVer -and $localVer) {
        $need = $remoteVer -gt $localVer
    } else {
        Add-Result $name $localStr $tag '看不懂版本號，略過' 'Yellow'; return
    }
    # 版本一樣、但它要的前置插件沒裝（例：舊版更新程式只裝了主資料夾）→ 同一版重裝一次補上；同一版只試一次
    $lack = @(Get-MissingDeps $entry.folders[0])
    $depKey = 'deps|' + $entry.repo
    if (-not $need -and $localStr -and $lack.Count -gt 0 -and [string]$state.$depKey -ne $tag) {
        $need = $true
        $state | Add-Member -NotePropertyName $depKey -NotePropertyValue $tag -Force
        Say "  $name 少了它要的 $($lack -join '、')（沒有就開不起來），重新裝一次 $tag 補上…" 'Yellow'
    }
    if (-not $need) {
        $state | Add-Member -NotePropertyName $entry.repo -NotePropertyValue @{ tag = $tag } -Force
        Add-Result $name $localStr $tag '已經是最新' 'DarkGray'; return
    }

    Say "  下載 $name $tag（$([math]::Round($asset.size / 1MB, 1)) MB）…"
    $tmp = New-TempDir
    $zip = Join-Path $tmp 'download.zip'
    Save-Download $asset.browser_download_url $zip
    $ex = Join-Path $tmp 'x'
    Expand-Zip $zip $ex
    $note = Install-Folders $entry $ex
    $state | Add-Member -NotePropertyName $entry.repo -NotePropertyValue @{ tag = $tag; updated = (Get-Date -Format 'yyyy-MM-dd HH:mm') } -Force
    $notes = Get-NotesSafe { Get-ReleaseNotes $entry $localVer $remoteVer $rel }
    Add-Result $name $localStr $tag ((Get-DoneWord $localStr) + $note) 'Green' $notes
}

function Update-GitHubBranch($entry, $state) {
    $name = $entry.name
    $localStr = Get-LocalVersion $entry.folders[0]
    # 先試清單寫的分支，讀不到再試 main、master（有的作者主分支叫 master）
    $branches = @()
    if ($entry.branch) { $branches += [string]$entry.branch }
    foreach ($b in 'main', 'master') { if ($branches -notcontains $b) { $branches += $b } }
    $remoteToc = $null; $branch = $null; $lastErr = $null
    foreach ($b in $branches) {
        try { $remoteToc = Get-Text "https://raw.githubusercontent.com/$($entry.repo)/$b/$($entry.toc)"; $branch = $b; break }
        catch { $lastErr = $_.Exception }
    }
    if (-not $branch) { throw $lastErr }
    $remoteStr = Read-TocVersionFromText $remoteToc
    $remoteVer = Get-Ver $remoteStr
    $localVer = Get-Ver $localStr
    if (-not $remoteVer) { Add-Result $name $localStr $remoteStr '看不懂 GitHub 上的版本號，略過' 'Yellow'; return }
    if ($localStr -and -not $localVer) { Add-Result $name $localStr $remoteStr '看不懂本機的版本號，略過' 'Yellow'; return }
    $lack = @(Get-MissingDeps $entry.folders[0])
    $depKey = 'deps|' + $entry.repo + '/' + $entry.folders[0]
    if ($localVer -and $remoteVer -le $localVer) {
        if ($lack.Count -gt 0 -and [string]$state.$depKey -ne $remoteStr) {
            $state | Add-Member -NotePropertyName $depKey -NotePropertyValue $remoteStr -Force
            Say "  $name 少了它要的 $($lack -join '、')（沒有就開不起來），重新裝一次 $remoteStr 補上…" 'Yellow'
        } else {
            Add-Result $name $localStr $remoteStr '已經是最新' 'DarkGray'; return
        }
    }

    # 同一個專案這次已經下載過（一個專案放好幾個插件時）就直接用，不再下載一次
    $cacheKey = "$($entry.repo)|$branch"
    $ex = $script:BranchCache[$cacheKey]
    if (-not $ex) {
        Say "  下載 $name $remoteStr…"
        $tmp = New-TempDir
        $zip = Join-Path $tmp 'download.zip'
        Save-Download "https://github.com/$($entry.repo)/archive/refs/heads/$branch.zip" $zip
        $ex = Join-Path $tmp 'x'
        Expand-Zip $zip $ex
        $script:BranchCache[$cacheKey] = $ex
    } else {
        Say "  裝 $name $remoteStr（同一個專案剛下載過）…"
    }
    $note = Install-Folders $entry $ex
    $state | Add-Member -NotePropertyName ($entry.repo + '/' + $entry.folders[0]) -NotePropertyValue @{ version = $remoteStr; updated = (Get-Date -Format 'yyyy-MM-dd HH:mm') } -Force
    # 改了什麼：先看插件裡的說明檔，沒有再看 GitHub 的修改紀錄
    $notes = Get-NotesSafe { Get-NotesFromFolder (Join-Path $script:AddOns $entry.folders[0]) $localVer $remoteVer }
    if ($notes.Count -eq 0) { $notes = Get-NotesSafe { Get-CommitNotes $entry $branch $localStr } }
    Add-Result $name $localStr $remoteStr ((Get-DoneWord $localStr) + $note) 'Green' $notes
}

# 作者自己網站的版本清單（例：GearInsight 的 releases.json：版本號、下載網址、SHA256 檢查碼）
# 清單網址可以給好幾個（主站、鏡像），前一個連不上就換下一個
function Update-JsonManifest($entry, $state) {
    $name = $entry.name
    $localStr = Get-LocalVersion $entry.folders[0]
    $info = $null; $base = $null; $errs = @()
    foreach ($u in @($entry.manifest)) {
        try {
            $m = Get-JsonUrl $u
            $obj = $m.($entry.key)
            if ($obj -and $obj.version -and $obj.download) { $info = $obj; $base = ([Uri]$u).GetLeftPart([UriPartial]::Authority); break }
            $errs += "$u 裡沒有 $($entry.key)"
        } catch { $errs += "$u：$($_.Exception.Message)" }
    }
    if (-not $info) { throw ("讀不到版本清單：" + ($errs -join '；')) }
    if ($info.enabled -eq $false) { Add-Result $name $localStr ([string]$info.version) '作者暫時關掉下載，略過' 'Yellow'; return }
    $remoteStr = [string]$info.version
    $remoteVer = Get-Ver $remoteStr
    $localVer = Get-Ver $localStr
    if (-not $remoteVer) { Add-Result $name $localStr $remoteStr '看不懂網站上的版本號，略過' 'Yellow'; return }
    if ($localStr -and -not $localVer) { Add-Result $name $localStr $remoteStr '看不懂本機的版本號，略過' 'Yellow'; return }
    if ($localVer -and $remoteVer -le $localVer) { Add-Result $name $localStr $remoteStr '已經是最新' 'DarkGray'; return }

    $url = [string]$info.download
    if ($url -notmatch '^https?://') { $url = $base + '/' + $url.TrimStart('/') }
    Say "  下載 $name $remoteStr…"
    $tmp = New-TempDir
    $zip = Join-Path $tmp 'download.zip'
    Save-Download $url $zip
    if ($info.sha256) {
        $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($got -ne ([string]$info.sha256).ToLower()) { throw '下載的檔案跟網站公布的檢查碼對不上（可能沒下載完整），這次不換' }
    }
    $ex = Join-Path $tmp 'x'
    Expand-Zip $zip $ex
    $note = Install-Folders $entry $ex
    $state | Add-Member -NotePropertyName $entry.name -NotePropertyValue @{ version = $remoteStr; updated = (Get-Date -Format 'yyyy-MM-dd HH:mm') } -Force
    $notes = Get-NotesSafe { Get-ManifestNotes $info $localVer $remoteVer }
    if ($notes.Count -eq 0) { $notes = Get-NotesSafe { Get-NotesFromFolder (Join-Path $script:AddOns $entry.folders[0]) $localVer $remoteVer } }
    Add-Result $name $localStr $remoteStr ((Get-DoneWord $localStr) + "（檢查碼對過）" + $note) 'Green' $notes
}

# 跟更新程式一起附的插件（放在 插件更新\自己做的插件\）：沒裝就裝，附的版本比較新就換
function Update-Bundled($entry, $state) {
    $name = $entry.name
    $src = Join-Path $Here $entry.path
    if (-not (Test-Path -LiteralPath $src)) { Add-Result $name '' '' "找不到附的檔案：$($entry.path)" 'Yellow'; return }
    $localStr = Get-LocalVersion $entry.folders[0]
    $bundStr = $null
    $toc = @(Get-ChildItem -LiteralPath $src -Filter '*.toc' -File -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($toc) {
        $hit = Select-String -LiteralPath $toc.FullName -Pattern '^\s*##\s*Version\s*:\s*(.+?)\s*$' -List -ErrorAction SilentlyContinue
        if ($hit) { $bundStr = $hit.Matches[0].Groups[1].Value }
    }
    $localVer = Get-Ver $localStr
    $bundVer = Get-Ver $bundStr
    if ($localStr -and ((-not $bundVer) -or ($localVer -and $bundVer -le $localVer))) { Add-Result $name $localStr $bundStr '已經是最新' 'DarkGray'; return }
    Say "  裝 $name $bundStr（附在更新程式裡的）…"
    $tmp = New-TempDir
    Copy-Item -LiteralPath $src -Destination (Join-Path $tmp (Split-Path -Leaf $src)) -Recurse
    $note = Install-Folders $entry $tmp
    $notes = Get-NotesSafe { Get-NotesFromFolder (Join-Path $script:AddOns $entry.folders[0]) $localVer $bundVer }
    Add-Result $name $localStr $bundStr ((Get-DoneWord $localStr) + $note) 'Green' $notes
}

# 下載資料夾的位置（使用者可能改過，問系統）
function Get-DownloadsDir {
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

# 只看 zip 的目錄、不解壓：裡面有沒有「主資料夾\主資料夾*.toc」，有就讀版本號
function Get-ZipAddonVersion([string]$zipPath, [string]$folder) {
    $z = $null
    try {
        $z = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Read, [Text.Encoding]::UTF8)
        $best = $null
        foreach ($e in $z.Entries) {
            $parts = $e.FullName.Replace('\', '/').Split('/')
            if ($parts.Count -ge 2 -and $parts[$parts.Count - 2] -ieq $folder -and $parts[$parts.Count - 1] -like '*.toc') {
                $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
                $head = $sr.ReadToEnd(); $sr.Close()
                $v = Read-TocVersionFromText $head
                if ($v) {
                    if ($parts[$parts.Count - 1] -ieq "$folder.toc") { return $v }
                    if (-not $best) { $best = $v }
                }
            }
        }
        return $best
    } catch { return $null }
    finally { if ($z) { $z.Dispose() } }
}

function Update-Manual($entry, $state) {
    $name = $entry.name
    $localStr = Get-LocalVersion $entry.folders[0]
    $localVer = Get-Ver $localStr
    $dl = Get-DownloadsDir
    $bestZip = $null; $bestStr = $null; $bestVer = $null
    $zips = @(Get-ChildItem -LiteralPath $dl -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-60) -and $_.Length -lt 300MB })
    foreach ($zf in $zips) {
        $v = Get-ZipAddonVersion $zf.FullName $entry.folders[0]
        $vv = Get-Ver $v
        if ($vv -and ((-not $bestVer) -or $vv -gt $bestVer)) { $bestZip = $zf; $bestStr = $v; $bestVer = $vv }
    }
    if ($bestVer -and ((-not $localVer) -or $bestVer -gt $localVer)) {
        Say "  從下載資料夾裝 $name $bestStr（$($bestZip.Name)）…"
        $tmp = New-TempDir
        $ex = Join-Path $tmp 'x'
        Expand-Zip $bestZip.FullName $ex
        $note = Install-Folders $entry $ex
        $notes = Get-NotesSafe { Get-NotesFromFolder (Join-Path $script:AddOns $entry.folders[0]) $localVer $bestVer }
        Add-Result $name $localStr $bestStr ("已更新（從下載資料夾的 $($bestZip.Name)）" + $note) 'Green' $notes
        return
    }
    Add-Result $name $localStr '?' "只在 CurseForge，查不到新版。要更新：打開 $($entry.page) 按 Download，下載好再雙擊一次就會自動裝" 'Cyan'
}

# 只在 CurseForge、但作者把程式放在 GitHub 的插件（例：Details）：半自動（v1.3.7 起）
# ・看作者 GitHub 上的版本號（check.url 裡用 check.pattern 抓數字），跟本機那個檔（check.localFile）比
# ・「下載」資料夾已經有比較新的 zip → 直接裝
# ・有新版、下載資料夾沒有 → 幫你打開 CurseForge 下載頁（download），下載會自己開始；等它下載好就裝
#   同一個新版只會自動打開一次；沒等到就說「下載好再雙擊一次」
function Open-Url([string]$url) { Start-Process $url }
function Get-NumberFrom([string]$text, [string]$pattern) {
    if (-not $text) { return $null }
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { return $null }
    $n = 0L
    if ([long]::TryParse($m.Groups[1].Value, [ref]$n)) { return $n }
    return $null
}
function Find-NewerZip($entry, $localVer, [datetime]$since) {
    $dl = Get-DownloadsDir
    $best = $null
    $zips = @(Get-ChildItem -LiteralPath $dl -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-60) -and $_.LastWriteTime -ge $since -and $_.Length -lt 300MB })
    foreach ($zf in $zips) {
        $v = Get-ZipAddonVersion $zf.FullName $entry.folders[0]
        $vv = Get-Ver $v
        if ($vv -and ((-not $localVer) -or $vv -gt $localVer) -and ((-not $best) -or $vv -gt $best.Ver)) {
            $best = [pscustomobject]@{ File = $zf; Str = $v; Ver = $vv }
        }
    }
    return $best
}
function Install-FromZip($entry, $z, $localStr, $localVer) {
    Say "  從下載資料夾裝 $($entry.name) $($z.Str)（$($z.File.Name)）…"
    $tmp = New-TempDir
    $ex = Join-Path $tmp 'x'
    Expand-Zip $z.File.FullName $ex
    $note = Install-Folders $entry $ex
    $notes = Get-NotesSafe { Get-NotesFromFolder (Join-Path $script:AddOns $entry.folders[0]) $localVer $z.Ver }
    Add-Result $entry.name $localStr $z.Str ((Get-DoneWord $localStr) + "（從下載資料夾的 $($z.File.Name)）" + $note) 'Green' $notes
}
function Update-CurseForgeAssist($entry, $state) {
    $name = $entry.name
    $localStr = Get-LocalVersion $entry.folders[0]
    $localVer = Get-Ver $localStr
    # 1. 下載資料夾已經有比較新的
    $z = Find-NewerZip $entry $localVer ([datetime]::MinValue)
    if ($z) { Install-FromZip $entry $z $localStr $localVer; return }
    # 2. 看作者 GitHub 上的版本號
    $remoteNum = $null
    try { $remoteNum = Get-NumberFrom (Get-Text ([string]$entry.check.url)) ([string]$entry.check.pattern) } catch { }
    $localNum = $null
    if ($localStr -and $entry.check.localFile) {
        $lf = Join-Path $script:AddOns ([string]$entry.check.localFile)
        if (Test-Path -LiteralPath $lf) { $localNum = Get-NumberFrom ([IO.File]::ReadAllText($lf)) ([string]$entry.check.pattern) }
    }
    if (-not $remoteNum) {
        Add-Result $name $localStr '?' "查不到作者 GitHub 上的版本號，這次不檢查。要更新：打開 $($entry.page) 按 Download，下載好再雙擊一次" 'Yellow'
        return
    }
    if ($localStr -and $localNum -and $remoteNum -le $localNum) { Add-Result $name $localStr "第 $remoteNum 版" '已經是最新' 'DarkGray'; return }
    $key = 'cfassist|' + $entry.folders[0]
    $what = "第 $remoteNum 版"
    if ([string]$state.$key -eq [string]$remoteNum) {
        Add-Result $name $localStr $what "有新版，之前幫你打開過下載頁。下載好再雙擊一次就會裝（下載頁：$($entry.download)）" 'Cyan'
        return
    }
    $state | Add-Member -NotePropertyName $key -NotePropertyValue ([string]$remoteNum) -Force
    $since = (Get-Date).AddSeconds(-5)
    if ($localStr) { Say "  $name 有新版（$what），幫你打開 CurseForge 的下載頁，下載會自己開始…" 'Cyan' }
    else { Say "  幫你裝 $name：打開 CurseForge 的下載頁，下載會自己開始…" 'Cyan' }
    try { Open-Url ([string]$entry.download) } catch { Add-Result $name $localStr $what "打不開瀏覽器：請自己打開 $($entry.download)，下載好再雙擊一次" 'Yellow'; return }
    $wait = 120; if ($env:ADDON_UPDATER_WAIT) { $wait = [int]$env:ADDON_UPDATER_WAIT }
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $wait) {
        Start-Sleep -Seconds 2
        $z = Find-NewerZip $entry $localVer $since
        if ($z) { Start-Sleep -Seconds 1; Install-FromZip $entry $z $localStr $localVer; return }
    }
    Add-Result $name $localStr $what "等了 $wait 秒還沒看到下載好的檔。瀏覽器下載好以後，再雙擊一次就會裝（下載頁：$($entry.download)）" 'Cyan'
}

# 作者把程式放在 GitHub、成品只在別的網站發布的插件（例：Details）：從作者 GitHub 的原始碼自己組裝（v1.3.7 起）
# 跟作者的發布工具做一樣的事：附加的資料夾搬到外面（layout）、填版本號、debug 區塊註解掉
# entry：repo、branch、check{file, pattern}（看哪個檔的版本號）、layout{資料夾: repo 裡的路徑（"" = 整個 repo）}、
#        keepIfStub（新的那個檔是空殼、舊的有內容就留舊的，例：翻譯檔）
# 下載資料夾有作者正式版的 zip、而且不比 GitHub 舊，就用正式版
function Get-ZipEntryText([string]$zipPath, [string]$entryPath) {
    $z = $null
    try {
        $z = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Read, [Text.Encoding]::UTF8)
        $want = $entryPath.Replace('\', '/')
        foreach ($e in $z.Entries) {
            if ($e.FullName.Replace('\', '/') -ieq $want) {
                $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
                $t = $sr.ReadToEnd(); $sr.Close(); return $t
            }
        }
        return $null
    } catch { return $null }
    finally { if ($z) { $z.Dispose() } }
}
function Get-LineCount([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    return @([IO.File]::ReadAllLines($path)).Count
}
function Update-GitHubSource($entry, $state) {
    $name = $entry.name
    $main = [string]$entry.folders[0]
    $localStr = Get-LocalVersion $main
    $pattern = [string]$entry.check.pattern
    $branch = [string]$entry.branch; if (-not $branch) { $branch = 'main' }
    $remoteNum = Get-NumberFrom (Get-Text "https://raw.githubusercontent.com/$($entry.repo)/$branch/$($entry.check.file)") $pattern
    if (-not $remoteNum) { Add-Result $name $localStr '' '看不懂 GitHub 上的版本號，略過（原本的沒動）' 'Yellow'; return }
    $what = "第 $remoteNum 版"
    $localNum = $null
    $lf = Join-Path (Join-Path $script:AddOns $main) ([string]$entry.check.file)
    if (Test-Path -LiteralPath $lf) { $localNum = Get-NumberFrom ([IO.File]::ReadAllText($lf)) $pattern }
    $localWhat = $localStr; if ($localNum) { $localWhat = "第 $localNum 版" }
    # 下載資料夾的作者正式版 zip
    $best = $null
    $dl = Get-DownloadsDir
    foreach ($zf in @(Get-ChildItem -LiteralPath $dl -Filter '*.zip' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-60) -and $_.Length -lt 300MB })) {
        $n = Get-NumberFrom (Get-ZipEntryText $zf.FullName ("$main/" + [string]$entry.check.file)) $pattern
        if ($n -and $n -ge $remoteNum -and ((-not $localNum) -or $n -gt $localNum) -and ((-not $best) -or $n -gt $best.N)) { $best = [pscustomobject]@{ File = $zf; N = $n } }
    }
    if ($best) {
        Say "  從下載資料夾裝 $name 第 $($best.N) 版（作者正式版 $($best.File.Name)）…"
        $tmp = New-TempDir; $ex = Join-Path $tmp 'x'
        Expand-Zip $best.File.FullName $ex
        $note = Install-Folders $entry $ex
        Add-Result $name $localWhat "第 $($best.N) 版" ((Get-DoneWord $localStr) + "（從下載資料夾的 $($best.File.Name)）" + $note) 'Green'
        return
    }
    $lack = @(Get-MissingDeps $main)
    if ($localNum -and $remoteNum -le $localNum -and $lack.Count -eq 0) { Add-Result $name $localWhat $what '已經是最新' 'DarkGray'; return }

    Say "  下載 $name $what（作者 GitHub 的原始碼）…"
    $tmp = New-TempDir
    $zip = Join-Path $tmp 'download.zip'
    Save-Download "https://github.com/$($entry.repo)/archive/refs/heads/$branch.zip" $zip
    $ex = Join-Path $tmp 'x'
    Expand-Zip $zip $ex
    $roots = @(Get-ChildItem -LiteralPath $ex -Directory)
    if ($roots.Count -ne 1) { throw '下載的原始碼格式看不懂（最上層不是一個資料夾）' }
    $root = $roots[0].FullName
    Say "  組裝 $name…"
    $stage = Join-Path $tmp 'build'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $moved = @()
    foreach ($f in @($entry.folders)) {
        $rel = [string]$entry.layout.$f
        $src = $root; if ($rel) { $src = Join-Path $root ($rel.Replace('/', '\')) }
        if (-not (Test-Path -LiteralPath $src)) { continue }
        Copy-Item -LiteralPath $src -Destination (Join-Path $stage $f) -Recurse
        if ($rel) { $moved += $rel.Replace('/', '\') }
    }
    $mainStage = Join-Path $stage $main
    if (-not (Test-Path -LiteralPath $mainStage)) { throw "原始碼裡找不到主資料夾 $main" }
    # 主資料夾是整個 repo 時：搬出去的附加，主資料夾裡那一份刪掉（作者的發布工具也是這樣）
    if (-not [string]$entry.layout.$main) {
        foreach ($m in $moved) { $p = Join-Path $mainStage $m; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
    }
    # 開頭是「.」的（.git、.github、.pkgmeta 這種開發用的）拿掉，作者的發布工具也不放
    foreach ($d in @(Get-ChildItem -LiteralPath $stage -Recurse -Force | Where-Object { $_.Name.StartsWith('.') } | Sort-Object { $_.FullName.Length } -Descending)) {
        if (Test-Path -LiteralPath $d.FullName) { Remove-Item -LiteralPath $d.FullName -Recurse -Force }
    }
    # 填版本號、debug 區塊註解掉
    $ver = "GitHub-$remoteNum"
    foreach ($t in @(Get-ChildItem -LiteralPath $stage -Filter '*.toc' -File -Recurse)) {
        $s = [IO.File]::ReadAllText($t.FullName)
        if ($s.Contains('@project-version@')) { [IO.File]::WriteAllText($t.FullName, $s.Replace('@project-version@', $ver), (New-Object Text.UTF8Encoding $false)) }
    }
    foreach ($l in @(Get-ChildItem -LiteralPath $stage -Filter '*.lua' -File -Recurse)) {
        $s = [IO.File]::ReadAllText($l.FullName)
        if ($s.Contains('--@debug@')) {
            $s = $s.Replace('--@end-debug@', '--@end-debug@]==]').Replace('--@debug@', '--[==[@debug@')
            [IO.File]::WriteAllText($l.FullName, $s, (New-Object Text.UTF8Encoding $false))
        }
    }
    # 新的是空殼、舊的有內容（例：之前裝的正式版的翻譯）→ 留舊的
    $kept = @()
    foreach ($k in @($entry.keepIfStub)) {
        if (-not $k) { continue }
        $old = Join-Path $script:AddOns $k; $new = Join-Path $stage $k
        if ((Get-LineCount $old) -gt 5 -and (Get-LineCount $new) -le 5) { Copy-Item -LiteralPath $old -Destination $new -Force; $kept += (Split-Path -Leaf $k) }
    }
    $note = Install-Folders $entry $stage
    if ($kept.Count -gt 0) { $note += "（留著原本的 $($kept -join '、')）" }
    Add-Result $name $localWhat $what ((Get-DoneWord $localStr) + '（作者 GitHub 的原始碼，自己組裝）' + $note) 'Green'
}

# 作者每一版在 GitHub 打版本標籤、.toc 的版本號只在發布時才填的插件（例：ProcDoc）：照最新的標籤下載（v1.3.8 起）
# 跟作者的發布工具做一樣的事：.pkgmeta 的 ignore 拿掉、開頭是「.」的拿掉、填版本號、debug 區塊註解掉
# entry：repo、folders、（可以不寫）tagPattern（只看符合的標籤）、layout{主資料夾: repo 裡的路徑}（不寫＝整個 repo 就是主資料夾）
function Get-PkgmetaIgnore([string]$file) {
    $out = @()
    if (-not (Test-Path -LiteralPath $file)) { return $out }
    $in = $false
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -match '^\S') { $in = ($line -match '^ignore\s*:\s*$'); continue }
        if ($in) {
            $m = [regex]::Match($line, '^\s+-\s+(.+?)\s*$')
            if ($m.Success) { $out += $m.Groups[1].Value.Trim('"', "'") }
        }
    }
    return $out
}
function Update-GitHubTag($entry, $state) {
    $name = $entry.name
    $main = [string]$entry.folders[0]
    $localStr = Get-LocalVersion $main
    $localVer = Get-Ver $localStr
    $tags = @(Get-Json "https://api.github.com/repos/$($entry.repo)/tags?per_page=100" | ForEach-Object { $_ })
    $tag = $null; $remoteVer = $null
    foreach ($t in $tags) {
        $n = [string]$t.name
        if (-not $n) { continue }
        if ($entry.tagPattern -and $n -notmatch [string]$entry.tagPattern) { continue }
        $v = Get-Ver $n
        if ($v -and ((-not $remoteVer) -or $v -gt $remoteVer)) { $remoteVer = $v; $tag = $n }
    }
    if (-not $tag) { Add-Result $name $localStr '' '找不到作者的版本標籤，略過（原本的沒動）' 'Yellow'; return }
    $lack = @(Get-MissingDeps $main)
    # 本機的版本號看不懂（例：直接拿原始碼放的，寫著 @project-version@）→ 換成標籤那一版
    if ($localVer -and $remoteVer -le $localVer) {
        $depKey = 'deps|' + $entry.repo + '/' + $main
        if ($lack.Count -gt 0 -and [string]$state.$depKey -ne $tag) {
            $state | Add-Member -NotePropertyName $depKey -NotePropertyValue $tag -Force
            Say "  $name 少了它要的 $($lack -join '、')（沒有就開不起來），重新裝一次 $tag 補上…" 'Yellow'
        } else {
            Add-Result $name $localStr $tag '已經是最新' 'DarkGray'; return
        }
    }
    Say "  下載 $name $tag（作者 GitHub 的版本標籤）…"
    $tmp = New-TempDir
    $zip = Join-Path $tmp 'download.zip'
    Save-Download "https://github.com/$($entry.repo)/archive/refs/tags/$tag.zip" $zip
    $ex = Join-Path $tmp 'x'
    Expand-Zip $zip $ex
    $roots = @(Get-ChildItem -LiteralPath $ex -Directory)
    if ($roots.Count -ne 1) { throw '下載的檔案格式看不懂（最上層不是一個資料夾）' }
    $root = $roots[0].FullName
    $rel = [string]$entry.layout.$main
    $src = $root; if ($rel) { $src = Join-Path $root ($rel.Replace('/', '\')) }
    if (-not (Test-Path -LiteralPath $src)) { throw "下載的檔案裡找不到主資料夾 $main" }
    $stage = Join-Path $tmp 'build'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $mainStage = Join-Path $stage $main
    Copy-Item -LiteralPath $src -Destination $mainStage -Recurse
    # .pkgmeta 寫的 ignore（作者發布時不放進去的：說明圖、做圖的工具…）
    foreach ($ig in @(Get-PkgmetaIgnore (Join-Path $root '.pkgmeta'))) {
        if (-not $ig -or $ig -match '\.\.' -or [IO.Path]::IsPathRooted($ig)) { continue }
        $p = Join-Path $mainStage ($ig.Replace('/', '\'))
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $stage -Recurse -Force | Where-Object { $_.Name.StartsWith('.') } | Sort-Object { $_.FullName.Length } -Descending)) {
        if (Test-Path -LiteralPath $d.FullName) { Remove-Item -LiteralPath $d.FullName -Recurse -Force }
    }
    if (-not @(Get-ChildItem -LiteralPath $mainStage -Filter '*.toc' -File -ErrorAction SilentlyContinue)) { throw "下載的檔案裡 $main 沒有 .toc" }
    foreach ($t in @(Get-ChildItem -LiteralPath $stage -Filter '*.toc' -File -Recurse)) {
        $s = [IO.File]::ReadAllText($t.FullName)
        if ($s.Contains('@project-version@')) { [IO.File]::WriteAllText($t.FullName, $s.Replace('@project-version@', $tag), (New-Object Text.UTF8Encoding $false)) }
    }
    foreach ($l in @(Get-ChildItem -LiteralPath $stage -Filter '*.lua' -File -Recurse)) {
        $s = [IO.File]::ReadAllText($l.FullName)
        if ($s.Contains('--@debug@')) {
            $s = $s.Replace('--@end-debug@', '--@end-debug@]==]').Replace('--@debug@', '--[==[@debug@')
            [IO.File]::WriteAllText($l.FullName, $s, (New-Object Text.UTF8Encoding $false))
        }
    }
    $note = Install-Folders $entry $stage
    $state | Add-Member -NotePropertyName ($entry.repo + '/' + $main) -NotePropertyValue @{ version = $tag; updated = (Get-Date -Format 'yyyy-MM-dd HH:mm') } -Force
    $notes = Get-NotesSafe { Get-NotesFromFolder (Join-Path $script:AddOns $main) $localVer $remoteVer }
    if ($notes.Count -eq 0) { $notes = Get-NotesSafe { Get-CommitNotes $entry $tag $localStr } }
    Add-Result $name $localStr $tag ((Get-DoneWord $localStr) + '（作者 GitHub 的版本標籤）' + $note) 'Green' $notes
}

# ---------------------------------------------------------------------------
# 更新程式自己更新（v1.3.5 起）
# 線上清單寫 "updater": { "version": "1.3.6", "files": [{ "path": "插件更新/update_addons.ps1", "url": ..., "sha256": ... }], "notes": [...] }
# 比自己新才換；下載的檔：檢查碼要跟清單一樣、PowerShell 讀得懂、裡面寫的版本號要跟清單一樣，三個都對才換
# 舊的留在 插件更新\舊版_v<舊版本>\；沒成功就照舊版跑，什麼都不動
# ---------------------------------------------------------------------------
function Update-Self($info) {
    if (-not $info -or -not $info.version) { return $false }
    if ($env:ADDON_UPDATER_SELFUPDATED) { return $false }
    $want = Get-Ver ([string]$info.version)
    $have = Get-Ver $UpdaterVersion
    if (-not $want -or -not $have -or $want -le $have) { return $false }
    $f = @(@($info.files) | Where-Object { $_ -and ([string]$_.path) -match 'update_addons\.ps1$' }) | Select-Object -First 1
    if (-not $f -or -not $f.url -or -not $f.sha256) { return $false }
    Say "更新程式有新版 v$($info.version)（你的是 v$UpdaterVersion），先更新自己…" 'Cyan'
    try {
        $tmp = New-TempDir
        $new = Join-Path $tmp 'update_addons.ps1'
        Save-Download ([string]$f.url) $new
        $hash = (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash
        if ($hash -ine [string]$f.sha256) { throw '下載的檔跟清單寫的檢查碼不一樣（GitHub 可能還在更新，過幾分鐘再雙擊）' }
        $txt = [IO.File]::ReadAllText($new, [Text.Encoding]::UTF8)
        $vline = "`$UpdaterVersion = '" + [string]$info.version + "'"
        if (-not $txt.Contains($vline)) { throw '下載的檔裡寫的版本號跟清單不一樣' }
        $tokens = $null; $perr = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($new, [ref]$tokens, [ref]$perr)
        if ($perr -and @($perr).Count -gt 0) { throw "下載的檔有寫錯的地方（$(@($perr)[0].Message)）" }
        $bakDir = Join-Path $Here ('舊版_v' + $UpdaterVersion)
        New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
        $bak = Join-Path $bakDir 'update_addons.ps1'
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $SelfPath -Destination $bak }
        Copy-Item -LiteralPath $new -Destination $SelfPath -Force
        Say "更新程式換成 v$($info.version) 了（舊的在 插件更新\舊版_v$UpdaterVersion\），用新的從頭再跑一次：" 'Green'
        foreach ($n in @($info.notes)) { if ($n) { Say "  ・$n" 'Gray' } }
        return $true
    } catch {
        Say "更新程式自己更新沒成功，這次照舊版跑：$($_.Exception.Message)" 'Yellow'
        return $false
    }
}

# 測試用（平常不會跑）：設了 ADDON_UPDATER_TEST 環境變數才載入那個檔，用假的網路回應測試
if ($env:ADDON_UPDATER_TEST -and (Test-Path -LiteralPath $env:ADDON_UPDATER_TEST)) { . $env:ADDON_UPDATER_TEST }

# ---------------------------------------------------------------------------
# 主程式
# ---------------------------------------------------------------------------
Say ''
Say "=== 魔獸世界：永恆 插件自動更新 v$UpdaterVersion ===" 'White'
$config = Get-Content -LiteralPath (Join-Path $Here 'addons.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$GameDir = Find-GameDir $config
if (-not $GameDir) {
    Say '找不到遊戲資料夾（裡面要有 Interface\AddOns）。' 'Red'
    Say '請用記事本打開 addons.json，把 "gameDir" 改成你的遊戲資料夾，例如 "D:\\World of Warcraft\\_forever_"（斜線要打兩個）。' 'Red'
    exit 1
}
$script:AddOns = Join-Path $GameDir 'Interface\AddOns'
$script:BackupRoot = Join-Path $GameDir '插件備份'
$script:TmpRoot = Join-Path $GameDir '插件更新暫存'
$script:Stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Say "遊戲資料夾：$GameDir"
if ((Split-Path -Leaf $GameDir) -ine '_forever_') { Say '注意：這個資料夾不叫 _forever_，確定是「魔獸世界：永恆」的遊戲資料夾嗎？不是的話關掉視窗，把「插件更新」資料夾放進 _forever_ 再雙擊。' 'Yellow' }

$running = Test-GameRunning $GameDir
if ($running) {
    Say "魔獸還開著（$($running.ProcessName)），插件檔案正在被用。先整個關掉遊戲再雙擊一次。" 'Red'
    exit 1
}

# addons.json 寫了 "taintLog": true 才做：在遊戲設定檔打開「污染紀錄」（遊戲會把「哪個插件、哪一行弄髒的」寫進 Logs\taint.log）
# 遊戲關著才改得了（開著時遊戲關閉會把設定檔整個重寫），所以放在確認遊戲沒開之後
if ($config.taintLog) {
    try {
        $cfgPath = Join-Path $GameDir 'WTF\Config.wtf'
        if (Test-Path -LiteralPath $cfgPath) {
            $cfgLines = @(Get-Content -LiteralPath $cfgPath -Encoding UTF8)
            $want = 'SET taintLog "1"'
            $idx = -1
            for ($i = 0; $i -lt $cfgLines.Count; $i++) { if ($cfgLines[$i] -match '^\s*SET\s+taintLog\s') { $idx = $i; break } }
            if ($idx -ge 0 -and $cfgLines[$idx].Trim() -eq $want) {
                Say '污染紀錄：開著' 'DarkGray'
            } else {
                $bak = $cfgPath + '.污染紀錄前的備份'
                if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $cfgPath -Destination $bak }
                if ($idx -ge 0) { $cfgLines[$idx] = $want } else { $cfgLines += $want }
                [IO.File]::WriteAllLines($cfgPath, [string[]]$cfgLines, (New-Object Text.UTF8Encoding $false))
                Say '污染紀錄：幫你打開了（進遊戲後會寫 Logs\taint.log；原本的設定檔備份在 WTF\Config.wtf.污染紀錄前的備份）' 'Green'
            }
        }
    } catch {
        Say "污染紀錄：設定檔改不了（$($_.Exception.Message)），不影響更新。" 'Yellow'
    }
}

$statePath = Join-Path $Here 'state.json'
$state = New-Object PSObject
if (Test-Path -LiteralPath $statePath) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = New-Object PSObject }
}

if (Test-Path -LiteralPath $script:TmpRoot) { Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

# 線上清單（addons.json 的 lists）：清單上的插件加進來；跟 addons.json 同一個主資料夾的，用清單上的寫法
# 讀不到就照 addons.json 跑
$entries = New-Object System.Collections.ArrayList
foreach ($e in @($config.addons)) { if ($e) { [void]$entries.Add($e) } }
$relaunch = $false
$sharedPatchList = New-Object System.Collections.ArrayList
foreach ($u in @($config.lists)) {
    if (-not $u) { continue }
    try {
        $rl = (Get-Text ([string]$u)) | ConvertFrom-Json
        if (Update-Self $rl.updater) { $relaunch = $true; break }
        $added = @(); $replaced = 0
        foreach ($re in @($rl.addons)) {
            if (-not $re -or -not $re.type -or -not $re.folders -or -not $re.name) { continue }
            $main = ([string]@($re.folders)[0]).ToLower()
            $idx = -1
            for ($i = 0; $i -lt $entries.Count; $i++) {
                if ($entries[$i].folders -and ([string]@($entries[$i].folders)[0]).ToLower() -eq $main) { $idx = $i; break }
            }
            if ($idx -ge 0) { $entries[$idx] = $re; $replaced++ } else { [void]$entries.Add($re); $added += [string]$re.name }
        }
        $msg = "讀到線上清單（$(@($rl.addons).Count) 個插件）"
        if ($added.Count -gt 0) { $msg += "，addons.json 沒寫的：" + ($added -join '、') }
        Say $msg 'DarkGray'
        if ($rl.notice) { Say ("清單上的公告：" + [string]$rl.notice) 'Cyan' }
        foreach ($pm in @($rl.patches)) { if ($pm) { [void]$sharedPatchList.Add($pm) } }
    } catch {
        Say "讀不到線上清單（$u）：$($_.Exception.Message)　這次照 addons.json 裡寫的跑。" 'Yellow'
    }
}
if ($relaunch) {
    # 換好新版：用新的從頭跑一次（同一個視窗）；這個環境變數讓新的那次不會再換一次
    $env:ADDON_UPDATER_SELFUPDATED = '1'
    Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    Say ''
    & $SelfPath
    exit
}

$skip = @{}
foreach ($s in @($config.skip)) { if ($s) { $skip[([string]$s).ToLower()] = $true } }

$known = @{}
foreach ($entry in $entries) {
    foreach ($f in $entry.folders) { $known[$f.ToLower()] = $true }
    $mainDir = Join-Path $script:AddOns $entry.folders[0]
    if ($skip.ContainsKey(([string]$entry.folders[0]).ToLower())) {
        $v = Get-LocalVersion $entry.folders[0]
        Add-Result $entry.name $v '' '你在 addons.json 的 skip 寫了不要，不裝也不更新' 'DarkGray'
        continue
    }
    if ($entry.type -eq 'own') {
        $v = Get-LocalVersion $entry.folders[0]
        if ($v) { Add-Result $entry.name $v '' '自己做的，不檢查' 'DarkGray' }
        continue
    }
    if ($entry.type -ne 'bundled' -and -not (Test-Path -LiteralPath $mainDir)) {
        # 沒裝的：addons.json 寫 installMissing，或清單上標 autoInstall（我們自己做的）才裝
        # 清單上標 optional（v1.3.8）的：installMissing 也不裝，要的人自己先放一次
        if (-not ($entry.autoInstall -or ($config.installMissing -and -not $entry.optional))) {
            $why = '沒裝，不更新（要裝的話自己先放一次）'
            if ($entry.optional) { $why = '沒裝，不更新（這個是給要的人用的：自己先放一次，之後才會幫你更新）' }
            Add-Result $entry.name '（沒裝）' '' $why 'DarkGray'
            continue
        }
        $lack = @(@($entry.needs) | Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $script:AddOns $_)) })
        if ($lack.Count -gt 0) {
            Add-Result $entry.name '（沒裝）' '' "要先有 $($lack -join '、') 才能用，所以沒裝" 'DarkGray'
            continue
        }
    }
    Say "檢查 $($entry.name)…"
    try {
        switch ($entry.type) {
            'github-release' { Update-GitHubRelease $entry $state }
            'github-branch' { Update-GitHubBranch $entry $state }
            'json-manifest' { Update-JsonManifest $entry $state }
            'bundled' { Update-Bundled $entry $state }
            'manual' { Update-Manual $entry $state }
            'curseforge-assist' { Update-CurseForgeAssist $entry $state }
            'github-source' { Update-GitHubSource $entry $state }
            'github-tag' { Update-GitHubTag $entry $state }
            default { Add-Result $entry.name '' '' "不認得的 type：$($entry.type)" 'Yellow' }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '403|rate limit') { $msg = 'GitHub 暫時限制查詢次數（每小時 60 次），等一小時再試' }
        elseif ($msg -match '無法解析|could not be resolved|無法連線|Unable to connect|timed out|逾時') { $msg = "連不上網路：$msg" }
        Add-Result $entry.name (Get-LocalVersion $entry.folders[0]) '' "失敗，沒有動到原本的：$msg" 'Red'
    }
}

# ---------------------------------------------------------------------------
# 補丁：改別人插件的一小段程式（更新完檢查一次，被新版蓋掉就再補；作者改到那段、補不上就不動檔案，寫出來）
# ・共用補丁（v1.3.6 起）：線上清單的 patches 列的，大家都會補。addons.json 寫 "sharedPatches": false＝全部不要；
#   "skipPatches": ["補丁的 id"]＝某幾個不要。補丁檔是 format 2：不放原作者的程式碼，位置用每一行的 SHA-256 認。
# ・本機補丁：addons.json 的 localPatches（只在這台電腦），補丁檔放 插件更新\本機補丁\；format 1（原文對原文）或 format 2 都可以。
#   本機補丁的 id 跟共用補丁一樣時，用共用的、本機那個不再單獨補。
# ・作者自己修好了：線上清單把那個補丁標 "retired": true（停用）→ 大家都不再補；或補丁檔寫 "maxVersion"＋"versionFolder"
#   （只補到那一版），插件比它新就不補。作者的新版本來就會整個蓋掉舊檔，所以不會擋到作者。
# 已經有記號（marker）＝補過了；補之前的原檔放 插件更新\本機補丁\補之前的原檔\<日期時間>\
# ---------------------------------------------------------------------------
function Get-OccurCount([string]$text, [string]$part) {
    if (-not $part) { return 0 }
    $n = 0; $at = 0
    while ($true) {
        $k = $text.IndexOf($part, $at, [StringComparison]::Ordinal)
        if ($k -lt 0) { break }
        $n++; $at = $k + $part.Length
    }
    return $n
}
$script:Sha = [Security.Cryptography.SHA256]::Create()
function Get-Sha256Hex([string]$s) {
    return ([BitConverter]::ToString($script:Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').ToLower()
}
function Split-NewText([string]$t) {
    $t = $t.Replace("`r`n", "`n")
    if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
    if ($t.Length -eq 0) { return , ([string[]]@()) }
    return , ([string[]]$t.Split("`n"))
}
# format 1：edits＝[{old,new}]，每段原文要剛好出現 1 次
function Invoke-PatchV1($spec, [string]$text) {
    $crlf = $text.Contains("`r`n")
    $pairs = @()
    $i = 0
    foreach ($e in @($spec.edits)) {
        $i++
        $old = [string]$e.old; $new = [string]$e.new
        if ($crlf) { $old = $old.Replace("`n", "`r`n"); $new = $new.Replace("`n", "`r`n") }
        $n = Get-OccurCount $text $old
        if ($n -ne 1) { return @{ Status = 'cannot'; Why = ("第 {0} 段（{1}）找到 {2} 處" -f $i, [string]$e.why, $n) } }
        $pairs += , @($old, $new)
    }
    foreach ($pr in $pairs) {
        $k = $text.IndexOf($pr[0], [StringComparison]::Ordinal)
        $text = $text.Substring(0, $k) + $pr[1] + $text.Substring($k + $pr[0].Length)
    }
    return @{ Status = 'applied'; Text = $text }
}
# format 2：edits＝[{kind, lines:[每一行的 SHA-256], count, find, repl, text}]
#   kind：sub（那一行裡的 find 換成 repl）、replace（那幾行換成 text）、insertBefore／insertAfter（那一行前／後加 text）
function Invoke-PatchV2($spec, [string]$text) {
    $crlf = $text.Contains("`r`n")
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in $text.Replace("`r`n", "`n").Split("`n")) { $lines.Add($l) }
    $hs = New-Object 'string[]' $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) { $hs[$i] = Get-Sha256Hex $lines[$i] }
    $plan = New-Object System.Collections.ArrayList
    $k = 0
    foreach ($e in @($spec.edits)) {
        $k++
        $want = @(@($e.lines) | ForEach-Object { ([string]$_).ToLower() })
        $n = $want.Count
        $cnt = 1; if ($e.count) { $cnt = [int]$e.count }
        $hits = @()
        if ($n -gt 0) {
            for ($i = 0; $i -le $lines.Count - $n; $i++) {
                if ($hs[$i] -ne $want[0]) { continue }
                $ok = $true
                for ($j = 1; $j -lt $n; $j++) { if ($hs[$i + $j] -ne $want[$j]) { $ok = $false; break } }
                if ($ok) { $hits += $i }
            }
        }
        if ($hits.Count -ne $cnt) { return @{ Status = 'cannot'; Why = ("第 {0} 段（{1}）找到 {2} 處" -f $k, [string]$e.why, $hits.Count) } }
        foreach ($i in $hits) {
            if ([string]$e.kind -eq 'sub' -and (Get-OccurCount $lines[$i] ([string]$e.find)) -ne 1) { return @{ Status = 'cannot'; Why = ("第 {0} 段（{1}）那一行裡找不到要換的字" -f $k, [string]$e.why) } }
            if (@('sub', 'replace', 'insertBefore', 'insertAfter') -notcontains [string]$e.kind) { return @{ Status = 'cannot'; Why = "不認得的改法 $($e.kind)" } }
            [void]$plan.Add([pscustomobject]@{ I = $i; N = $n; E = $e })
        }
    }
    $spans = @($plan | ForEach-Object { $len = 0; if (@('replace', 'sub') -contains [string]$_.E.kind) { $len = $_.N }; [pscustomobject]@{ A = $_.I; B = $_.I + $len } } | Sort-Object A, B)
    for ($t = 1; $t -lt $spans.Count; $t++) { if ($spans[$t - 1].B -gt $spans[$t].A) { return @{ Status = 'cannot'; Why = '補丁裡有兩段改到同一個地方' } } }
    $rank = @{ 'insertBefore' = 0; 'replace' = 1; 'sub' = 1; 'insertAfter' = 2 }
    $ordered = @($plan | Sort-Object @{ Expression = { $_.I }; Descending = $true }, @{ Expression = { $rank[[string]$_.E.kind] }; Descending = $true })
    foreach ($p in $ordered) {
        $e = $p.E; $i = $p.I
        switch ([string]$e.kind) {
            'sub' {
                $f = [string]$e.find; $at = $lines[$i].IndexOf($f, [StringComparison]::Ordinal)
                $lines[$i] = $lines[$i].Substring(0, $at) + [string]$e.repl + $lines[$i].Substring($at + $f.Length)
            }
            'replace' { $lines.RemoveRange($i, $p.N); $lines.InsertRange($i, (Split-NewText ([string]$e.text))) }
            'insertBefore' { $lines.InsertRange($i, (Split-NewText ([string]$e.text))) }
            'insertAfter' { $lines.InsertRange($i + 1, (Split-NewText ([string]$e.text))) }
        }
    }
    $out = [string]::Join("`n", $lines)
    if ($crlf) { $out = $out.Replace("`n", "`r`n") }
    return @{ Status = 'applied'; Text = $out }
}
# 補一個檔：回傳 'applied'／'already'／'cannot: 原因'／'nofile'
function Invoke-PatchSpec($spec) {
    $target = Join-Path $GameDir ([string]$spec.file)
    if (-not (Test-Path -LiteralPath $target)) { return 'nofile' }
    $bytes = [IO.File]::ReadAllBytes($target)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $skipN = 0; if ($bom) { $skipN = 3 }
    $text = (New-Object Text.UTF8Encoding $false).GetString($bytes, $skipN, $bytes.Length - $skipN)
    if ($spec.marker -and $text.Contains([string]$spec.marker)) { return 'already' }
    # 補丁寫了 maxVersion（只補到這一版）：插件比它新＝作者已經修好，不補，用作者的
    if ($spec.maxVersion -and $spec.versionFolder) {
        $iv = Get-Ver (Get-LocalVersion ([string]$spec.versionFolder))
        $mv = Get-Ver ([string]$spec.maxVersion)
        if ($iv -and $mv -and $iv -gt $mv) { return 'fixed' }
    }
    if ([int]$spec.format -eq 2) { $r = Invoke-PatchV2 $spec $text } else { $r = Invoke-PatchV1 $spec $text }
    if ($r.Status -ne 'applied') { return ('cannot: ' + $r.Why) }
    $bakDir = Join-Path $Here ('本機補丁\補之前的原檔\' + $script:Stamp)
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
    $bakFile = Join-Path $bakDir (Split-Path -Leaf $target)
    if (-not (Test-Path -LiteralPath $bakFile)) { Copy-Item -LiteralPath $target -Destination $bakFile }
    [IO.File]::WriteAllText($target, $r.Text, (New-Object Text.UTF8Encoding $bom))
    return 'applied'
}
function Invoke-LocalPatch($p) {
    $name = [string]$p.name
    $specPath = Join-Path $Here ([string]$p.patch)
    if (-not (Test-Path -LiteralPath $specPath)) { Add-Result $name '' '' "本機補丁：找不到補丁檔 $($p.patch)" 'Yellow'; return }
    $spec = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($spec.id -and $script:RetiredPatchIds.ContainsKey(([string]$spec.id).ToLower())) { Add-Result $name '' '' '本機補丁：線上把這個補丁停用了（作者已經修好），這裡也不補' 'DarkGray'; return }
    if ($spec.id -and $script:SharedPatchIds.ContainsKey(([string]$spec.id).ToLower())) { Add-Result $name '' '' '本機補丁：線上有一樣的共用補丁，用共用的（這個不再單獨補）' 'DarkGray'; return }
    $st = Invoke-PatchSpec $spec
    if ($st -eq 'fixed') { Add-Result $name '' '' '本機補丁：插件作者的新版已經修好，不用補了' 'DarkGray'; return }
    if ($st -eq 'nofile') { Add-Result $name '' '' '本機補丁：要補的檔案不在（插件沒裝？），跳過' 'DarkGray' }
    elseif ($st -eq 'already') { Add-Result $name '' '' '本機補丁：補著（不用再補）' 'DarkGray' }
    elseif ($st -eq 'applied') { Add-Result $name '' '' "本機補丁：補上了（補之前的原檔在 插件更新\本機補丁\補之前的原檔\$($script:Stamp)\）" 'Green' }
    else { Add-Result $name '' '' ("本機補丁套不上：作者改了這段程式，這次沒有補，檔案沒動（原本的問題會回來）。跟 Claude 說「補丁套不上」。" + $st.Substring(8)) 'Yellow' }
}
function Invoke-SharedPatch($meta) {
    $name = '共用補丁：' + [string]$meta.name
    $tmp = New-TempDir
    $f = Join-Path $tmp 'patch.json'
    Save-Download ([string]$meta.url) $f
    $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
    if ($meta.sha256 -and $hash -ine [string]$meta.sha256) { Add-Result $name '' '' '補丁檔的檢查碼跟清單不一樣（GitHub 可能還在更新），這次沒補，檔案沒動' 'Yellow'; return }
    $spec = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $st = Invoke-PatchSpec $spec
    if ($st -eq 'nofile') { return }   # 沒裝那個插件：不用補，也不提
    elseif ($st -eq 'fixed') { Add-Result $name '' '' '插件作者的新版已經修好，不用補了（用作者的）' 'DarkGray' }
    elseif ($st -eq 'already') { Add-Result $name '' '' '補著（不用再補）' 'DarkGray' }
    elseif ($st -eq 'applied') { Add-Result $name '' '' "補上了（補之前的原檔在 插件更新\本機補丁\補之前的原檔\$($script:Stamp)\）" 'Green' }
    else { Add-Result $name '' '' ("套不上：插件作者改了這段程式，這次沒補，檔案沒動（原本的問題會回來）；等補丁跟著更新。" + $st.Substring(8)) 'Yellow' }
}
$script:SharedPatchIds = @{}
$script:RetiredPatchIds = @{}
$skipP = @{}
foreach ($s in @($config.skipPatches)) { if ($s) { $skipP[([string]$s).ToLower()] = $true } }
if ($config.sharedPatches -ne $false) {
    foreach ($m in @($sharedPatchList)) {
        if (-not $m -or -not $m.id -or (-not $m.url -and -not $m.retired)) { continue }
        $id = ([string]$m.id).ToLower()
        if ($m.retired) { $script:RetiredPatchIds[$id] = $true; continue }   # 停用的（作者修好了）：不補、不提
        if ($skipP.ContainsKey($id) -or $script:SharedPatchIds.ContainsKey($id)) { continue }
        $script:SharedPatchIds[$id] = $true
        try { Invoke-SharedPatch $m } catch { Add-Result ('共用補丁：' + [string]$m.name) '' '' "出錯，檔案沒動：$($_.Exception.Message)" 'Yellow' }
    }
}
foreach ($p in @($config.localPatches)) {
    if (-not $p -or -not $p.patch) { continue }
    try { Invoke-LocalPatch $p } catch { Add-Result ([string]$p.name) '' '' "本機補丁出錯，檔案沒動：$($_.Exception.Message)" 'Yellow' }
}

# 每個插件 .toc 寫的必要前置插件有沒有裝（沒裝的話那個插件整個開不起來，遊戲只會默默不載入）
# 清單上插件要的前置插件也算「在清單裡」（跟著主插件一起裝、一起更新）
foreach ($entry in $entries) {
    foreach ($f in @($entry.folders)) {
        $fd = Join-Path $script:AddOns $f
        if (Test-Path -LiteralPath $fd) { foreach ($d in @(Get-TocDeps $fd)) { $known[$d.ToLower()] = $true } }
    }
}
foreach ($dir in @(Get-ChildItem -LiteralPath $script:AddOns -Directory -ErrorAction SilentlyContinue)) {
    if ($dir.Name.StartsWith('Blizzard_')) { continue }
    $lack = @(Get-MissingDeps $dir.Name)
    if ($lack.Count -gt 0) {
        Add-Result $dir.Name (Get-LocalVersion $dir.Name) '' ("開不起來：它要先有 $($lack -join '、')，但沒裝。把畫面拍給 Claude。") 'Red'
    }
}

# 清單裡沒有的插件
$others =@(Get-ChildItem -LiteralPath $script:AddOns -Directory | Where-Object { -not $known.ContainsKey($_.Name.ToLower()) -and -not $_.Name.StartsWith('Blizzard_') })

try { $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch { }
Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue

Say ''
Say '=== 結果 ===' 'White'
$NoteLinesShown = 8
$anyNotes = $false
foreach ($r in $Results) {
    $ver = $r.Local
    if ($r.Remote -and $r.Remote -ne $r.Local) { $ver = "$($r.Local) → $($r.Remote)" }
    Say ("{0}  {1}" -f $r.Name, $ver) 'White'
    Say ("    {0}" -f $r.Status) $r.Color
    if ($r.Notes.Count -gt 0) {
        $anyNotes = $true
        Say '    改了什麼：' 'Cyan'
        $shown = 0
        foreach ($nl in $r.Notes) {
            if ($shown -ge $NoteLinesShown) { break }
            $t = [string]$nl
            if ($t.Length -gt 160) { $t = $t.Substring(0, 157) + '…' }
            Say ("      {0}" -f $t) 'Gray'
            $shown++
        }
        if ($r.Notes.Count -gt $NoteLinesShown) { Say ("      …（還有 {0} 行，完整的在 插件更新\最近更新說明.txt）" -f ($r.Notes.Count - $NoteLinesShown)) 'DarkGray' }
    }
}
if ($anyNotes) {
    $nf = @("==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 這次更新改了什麼（作者寫的說明；英文的是原文）", '')
    foreach ($r in $Results) {
        if ($r.Notes.Count -eq 0) { continue }
        $nf += ("{0}  {1} → {2}" -f $r.Name, $r.Local, $r.Remote)
        foreach ($nl in $r.Notes) { $nf += ('  ' + $nl) }
        $nf += ''
    }
    try { Set-Content -LiteralPath (Join-Path $Here '最近更新說明.txt') -Value $nf -Encoding UTF8 } catch { }
}
if ($others.Count -gt 0) {
    Say ''
    Say ("沒在清單裡、不會自動更新：" + (($others | ForEach-Object { $_.Name }) -join '、')) 'Yellow'
    Say '（要加的話打開 addons.json 照別的寫一行）' 'DarkGray'
}
if (Test-Path -LiteralPath $script:BackupRoot) {
    Say ''
    Say "舊版都在 $script:BackupRoot，進遊戲確定沒問題再自己刪。" 'DarkGray'
}

$log = Join-Path $Here '更新紀錄.txt'
$lines = @("==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
foreach ($r in $Results) {
    $lines += ("{0} | {1} | {2} | {3}" -f $r.Name, $r.Local, $r.Remote, $r.Status)
    foreach ($nl in $r.Notes) { $lines += ('      ' + $nl) }
}
try { Add-Content -LiteralPath $log -Value $lines -Encoding UTF8 } catch { }
