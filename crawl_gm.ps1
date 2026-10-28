# 学创杯「总经理」页爬虫。登录后打开总经理窗口，双击同目录的 运行爬虫.bat。
# 只抓当前登录的这一家公司。可选参数：-OutDir 输出目录，-ListOnly 只列出将要抓的页面。
param(
    [string]$OutDir,
    [switch]$ListOnly
)

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $argList = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($PSBoundParameters.ContainsKey('OutDir')) { $argList += @('-OutDir', $OutDir) }
    if ($ListOnly) { $argList += '-ListOnly' }
    $proc = Start-Process -FilePath powershell.exe -ArgumentList $argList -Wait -PassThru -NoNewWindow
    exit $proc.ExitCode
}

$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class GmHtml {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWnd, EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string lpString);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
  [DllImport("oleacc.dll")] public static extern int ObjectFromLresult(IntPtr lResult, ref Guid riid, int wParam, [MarshalAs(UnmanagedType.IUnknown)] out object ppvObject);
  public static long[] FindDialogs() {
    var list = new System.Collections.Generic.List<long>();
    EnumWindows((h, l) => {
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (c.ToString() == "Internet Explorer_TridentDlgFrame" && IsWindowVisible(h)) list.Add(h.ToInt64());
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }
  public static string Title(long hwnd) {
    var s = new StringBuilder(512);
    GetWindowText(new IntPtr(hwnd), s, 512);
    return s.ToString();
  }
  public static long FindServer(long dialog) {
    long found = 0;
    EnumChildWindows(new IntPtr(dialog), (ch, l2) => {
      var cc = new StringBuilder(256); GetClassName(ch, cc, 256);
      if (cc.ToString() == "Internet Explorer_Server") found = ch.ToInt64();
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static object Doc(long hwnd) {
    uint msg = RegisterWindowMessage("WM_HTML_GETOBJECT");
    IntPtr result;
    SendMessageTimeout(new IntPtr(hwnd), msg, IntPtr.Zero, IntPtr.Zero, 2, 5000, out result);
    Guid iid = new Guid("626FC520-A41E-11CF-A731-00A0C9082637");
    object obj;
    int hr = ObjectFromLresult(result, ref iid, 0, out obj);
    if (hr != 0) throw new System.Exception("HR=" + hr.ToString("X"));
    return obj;
  }
}
"@

function Safe-Name([string]$s) {
    $s = ([string]$s).Trim()
    $s = [regex]::Replace($s, '[\\/:*?"<>|]', "_")
    $s = [regex]::Replace($s, '\s+', " ")
    if ([string]::IsNullOrWhiteSpace($s)) { return "untitled" }
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80) }
    return $s
}

function Get-PlainText([string]$html) {
    if ([string]::IsNullOrEmpty($html)) { return "" }
    $t = [regex]::Replace($html, '(?is)<script[^>]*>.*?</script>', ' ')
    $t = [regex]::Replace($t, '(?is)<style[^>]*>.*?</style>', ' ')
    $t = [regex]::Replace($t, '(?is)<br\s*/?>', "`n")
    $t = [regex]::Replace($t, '(?is)</tr>', "`n")
    $t = [regex]::Replace($t, '(?is)</t[dh]>', "`t")
    $t = [regex]::Replace($t, '(?is)</(p|div|h\d|li|table)>', "`n")
    $t = [regex]::Replace($t, '(?is)<[^>]+>', '')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $lines = $t -split "`n" | ForEach-Object { ($_ -replace '[ \t]+', ' ').Trim() } | Where-Object { $_ -ne '' }
    return ($lines -join "`n")
}

function Resolve-PageUrl([string]$href) {
    $href = [System.Net.WebUtility]::HtmlDecode($href).Trim()
    if ($href -match '^(#|javascript:)') { return $null }
    if ($href.StartsWith("//")) { return "http:" + $href }
    if ($href.StartsWith("http://") -or $href.StartsWith("https://")) { return $href }
    if ($href.StartsWith("/")) { return $BaseUrl.TrimEnd("/") + $href }
    return $null
}

function Invoke-PageGet($doc, [string]$url) {
    $safe = $url.Replace('\', '\\').Replace("'", "\'")
    $js = @"
var ta=document.getElementById('crawlbuf');
if(!ta){ta=document.createElement('textarea');ta.id='crawlbuf';document.body.appendChild(ta);}
try{
  var x=new ActiveXObject('Microsoft.XMLHTTP');
  x.open('GET','$safe',false);
  x.send();
  ta.value=String(x.status)+'\n'+String(x.responseText);
}catch(e){
  ta.value='ERR\n'+e.message;
}
"@
    $doc.parentWindow.execScript($js, "JavaScript")
    $raw = [string]$doc.getElementById("crawlbuf").value
    $nl = $raw.IndexOf("`n")
    if ($nl -lt 0) { return @{ status = "ERR"; body = $raw } }
    return @{ status = $raw.Substring(0, $nl).Trim(); body = $raw.Substring($nl + 1) }
}

function Invoke-PagePost($doc, [string]$url, [string]$body) {
    $safeUrl = $url.Replace('\', '\\').Replace("'", "\'")
    $safeBody = $body.Replace('\', '\\').Replace("'", "\'")
    $js = @"
var ta=document.getElementById('crawlbuf');
if(!ta){ta=document.createElement('textarea');ta.id='crawlbuf';document.body.appendChild(ta);}
try{
  var x=new ActiveXObject('Microsoft.XMLHTTP');
  x.open('POST','$safeUrl',false);
  x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
  x.send('$safeBody');
  ta.value=String(x.status)+'\n'+String(x.responseText);
}catch(e){
  ta.value='ERR\n'+e.message;
}
"@
    $doc.parentWindow.execScript($js, "JavaScript")
    $raw = [string]$doc.getElementById("crawlbuf").value
    $nl = $raw.IndexOf("`n")
    if ($nl -lt 0) { return @{ status = "ERR"; body = $raw } }
    return @{ status = $raw.Substring(0, $nl).Trim(); body = $raw.Substring($nl + 1) }
}

function Format-ChartXml([string]$xml) {
    if ($xml -notmatch '<chart') {
        if ($xml.Length -gt 400) { return $xml.Substring(0, 400) }
        return $xml
    }
    $caption = ""
    if ($xml -match "caption='([^']*)'") { $caption = $Matches[1] }
    $labels = @()
    foreach ($m in [regex]::Matches($xml, "<category [^>]*label='([^']*)'")) { $labels += $m.Groups[1].Value }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($caption) { $lines.Add($caption) }
    foreach ($ds in [regex]::Matches($xml, "(?s)<dataset ([^>]+)>(.*?)</dataset>")) {
        $name = "series"
        if ($ds.Groups[1].Value -match "seriesName='([^']*)'") { $name = $Matches[1] }
        elseif ($ds.Groups[1].Value -match "seriesname='([^']*)'") { $name = $Matches[1] }
        $vals = @()
        foreach ($v in [regex]::Matches($ds.Groups[2].Value, "value='([^']*)'")) { $vals += $v.Groups[1].Value }
        $pairs = @()
        for ($n = 0; $n -lt $labels.Count -and $n -lt $vals.Count; $n++) { $pairs += ($labels[$n] + "=" + $vals[$n]) }
        if ($pairs.Count -eq 0) { $pairs = $vals }
        $lines.Add($name + ": " + ($pairs -join ", "))
    }
    if ($xml -match "~(\{.*)$") {
        $tail = $Matches[1]
        if ($tail -match '"title"\s*:\s*"([^"]*)"') { $lines.Add("title=" + $Matches[1]) }
        if ($tail -match '"value"\s*:\s*([0-9.\-]+)') { $lines.Add("value=" + $Matches[1]) }
        if ($xml -match "displayValue='([^']*)'") { $lines.Add("marker=" + $Matches[1]) }
    }
    return ($lines -join "`n")
}

function Get-OwnChartPaths([string]$html, [string]$companyId) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($html, '/BSTCS/ChartAction\.do\?[^"''\s<]+')) {
        $u = [System.Net.WebUtility]::HtmlDecode($m.Value)
        if ($u -match ("companyid=" + [regex]::Escape($companyId) + "(&|$)")) { $list.Add($u) }
    }
    return $list | Select-Object -Unique
}

function Get-QueryValue([string]$url, [string]$key) {
    $m = [regex]::Match([string]$url, '(?i)(?:\?|&)' + [regex]::Escape($key) + '=([^&]*)')
    if ($m.Success) { return [uri]::UnescapeDataString($m.Groups[1].Value) }
    return ""
}

function Find-LeftDocument($rootDoc) {
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootDoc)
    while ($stack.Count -gt 0) {
        $doc = $stack.Pop()
        $count = 0
        try { $count = [int]$doc.frames.length } catch { $count = 0 }
        for ($i = 0; $i -lt $count; $i++) {
            $child = $null
            $name = ""
            $url = ""
            try {
                $frame = $doc.frames.item($i)
                $name = [string]$frame.name
                $child = $frame.document
                $url = [string]$child.url
            } catch { continue }
            if ($name -eq "left" -or $url -match '/CEO/left\.jsp') { return $child }
            $stack.Push($child)
        }
    }
    return $null
}

function Get-SelectNumbers([string]$html, [string]$field) {
    $block = [regex]::Match([string]$html, "(?is)<select\b[^>]*\bname\s*=\s*['""]?$field\b[^>]*>(.*?)</select>")
    if (-not $block.Success) { return @() }
    $nums = New-Object System.Collections.Generic.List[int]
    foreach ($o in [regex]::Matches($block.Groups[1].Value, "(?i)\bvalue\s*=\s*['""]?(\d+)")) {
        $n = [int]$o.Groups[1].Value
        if (-not $nums.Contains($n)) { $nums.Add($n) }
    }
    return @($nums)
}

function Get-FrameUrls([string]$html) {
    $found = @()
    foreach ($m in [regex]::Matches($html, '(?is)<(?:i?frame)\b[^>]*\bsrc\s*=\s*["'']([^"'']+)["'']')) {
        $u = Resolve-PageUrl $m.Groups[1].Value
        if ($u -and $u -match '\.jsp') { $found += $u }
    }
    return $found | Select-Object -Unique
}

$utf8 = New-Object System.Text.UTF8Encoding $true

$dialogs = @([GmHtml]::FindDialogs())
if ($dialogs.Count -eq 0) {
    throw "没有找到总经理窗口。请先登录客户端，打开总经理页面，不要关闭，再运行本脚本。"
}
$ordered = @($dialogs | Where-Object { [GmHtml]::Title($_) -match '总经理' }) + @($dialogs | Where-Object { [GmHtml]::Title($_) -notmatch '总经理' })
$left = $null
foreach ($dialog in $ordered) {
    $server = [GmHtml]::FindServer([int64]$dialog)
    if ($server -eq 0) { continue }
    $root = [GmHtml]::Doc($server)
    $left = Find-LeftDocument $root
    if ($left) { break }
}
if (-not $left) {
    throw "总经理窗口已打开，但没有读到左侧菜单。请确认当前停在总经理页面后再运行。"
}
Write-Host "LEFT $($left.url)"

$uri = [uri]([string]$left.url)
$BaseUrl = $uri.Scheme + "://" + $uri.Authority
$companyId = Get-QueryValue $left.url "companyid"
$studentId = Get-QueryValue $left.url "studentid"
$courseId = Get-QueryValue $left.url "courseid"
$databaseName = Get-QueryValue $left.url "databasename"
if ([string]::IsNullOrWhiteSpace($databaseName)) { $databaseName = "null" }

$menu = [string]$left.documentElement.outerHTML
$menu = [regex]::Replace($menu, '(?s)<!--.*?-->', '')
if (-not $companyId) {
    $picked = [regex]::Match($menu, '(?i)<option[^>]*\bselected\b[^>]*\bvalue\s*=\s*[''"]?(\d+)')
    if (-not $picked.Success) { $picked = [regex]::Match($menu, '(?i)<option[^>]*\bvalue\s*=\s*[''"]?(\d+)[^>]*\bselected\b') }
    if ($picked.Success) { $companyId = $picked.Groups[1].Value }
}
if (-not $studentId) {
    $picked = [regex]::Match($menu, 'studentid=(\d+)')
    if ($picked.Success) { $studentId = $picked.Groups[1].Value }
}
if (-not $courseId) {
    $picked = [regex]::Match($menu, 'courseid=(\d+)')
    if ($picked.Success) { $courseId = $picked.Groups[1].Value }
}
if (-not $companyId -or -not $studentId -or -not $courseId) {
    throw "没有从当前登录页读到公司、学生或课程编号。请重新进入总经理页面后再运行。"
}
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot ("gm_" + $companyId) }
Write-Host ("ACCOUNT company=$companyId student=$studentId course=$courseId base=$BaseUrl")

$sectionRe = [regex]'(?s)<DIV onclick="SwitchMenu\(''([^'']+)''\);" class=tableheadtext([^>]*)><SPAN class=leftnav>\s*([^<]+?)\s*</SPAN>\s*</DIV>\s*<SPAN id=\1\b[^>]*>(.*?)</SPAN>'
$sections = @()
foreach ($m in $sectionRe.Matches($menu)) {
    $attrs = $m.Groups[2].Value
    if ($attrs -match '(?i)DISPLAY\s*:\s*none') { continue }
    $name = $m.Groups[3].Value.Trim()
    $body = $m.Groups[4].Value
    $sections += [pscustomobject]@{ Name = $name; Body = $body }
}
Write-Host ("SECTIONS " + $sections.Count)

$pages = New-Object System.Collections.Generic.List[object]
$seenUrl = @{}
$trendSection = "trend"
foreach ($sec in $sections) {
    if ($sec.Body -match 'tree\.insertNewChild') { $trendSection = $sec.Name }
    foreach ($a in [regex]::Matches($sec.Body, '(?is)<a\b[^>]*href\s*=\s*["'']([^"'']+)["''][^>]*>(.*?)</a>')) {
        $url = Resolve-PageUrl $a.Groups[1].Value
        if (-not $url) { continue }
        $label = Get-PlainText $a.Groups[2].Value
        $key = ($url -replace '(?i)([&?])title=[^&]*', '$1').TrimEnd('&', '?')
        if ($seenUrl.ContainsKey($key)) { continue }
        $seenUrl[$key] = $true
        $pages.Add([pscustomobject]@{ Section = $sec.Name; Name = $label; Url = $url; Kind = "menu" })
    }
}

$titleEnc = [uri]::EscapeDataString("company")
$catName = "trend"
$trendRx = [regex]'tree\.insertNewChild\(0,\d+,"([^"]+)"|sql="([^"]+)";\s*tree\.insertNewChild\([^,]+,sql,"([^"]+)"'
foreach ($m in $trendRx.Matches($menu)) {
    if ($m.Groups[1].Success) {
        $catName = $m.Groups[1].Value
        continue
    }
    $node = $m.Groups[2].Value
    $label = $m.Groups[3].Value
    $parts = $node.Split('$', 2)
    if ($parts.Count -lt 2) { continue }
    $url = "{0}/BSTCS/student/CFO/C/CFO_C_8.jsp?courseid={1}&studentid={2}&companyid={3}&sql={4}&subject={5}&title={6}" -f $BaseUrl.TrimEnd("/"), $courseId, $studentId, $companyId, [uri]::EscapeDataString($parts[1]), [uri]::EscapeDataString($parts[0]), $titleEnc
    $pages.Add([pscustomobject]@{ Section = $trendSection; Group = $catName; Name = $label; Url = $url; Kind = "trend" })
}

Write-Host ("PAGES " + $pages.Count + " company=" + $companyId)
if ($ListOnly) {
    foreach ($p in $pages) { Write-Host ("- " + $p.Section + " / " + $p.Name) }
    Write-Host "LIST_ONLY"
    exit 0
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$manifest = New-Object System.Collections.Generic.List[object]
$reportHtml = $null
$cockpitHtml = $null
$cockpitSection = "cockpit"
if ($pages.Count -gt 0) { $cockpitSection = $pages[0].Section }
$i = 0
foreach ($p in $pages) {
    $i++
    $sectionDir = Join-Path $OutDir (Safe-Name $p.Section)
    if ($p.Kind -eq "trend") { $sectionDir = Join-Path $sectionDir (Safe-Name $p.Group) }
    New-Item -ItemType Directory -Force -Path $sectionDir | Out-Null
    $baseName = "{0:D2}_{1}" -f $i, (Safe-Name $p.Name)
    Write-Host ("[{0}/{1}] {2} / {3}" -f $i, $pages.Count, $p.Section, $p.Name)
    try {
        $res = Invoke-PageGet $left $p.Url
        $html = [string]$res.body
        $extra = @()
        foreach ($fu in (Get-FrameUrls $html)) {
            if ($fu -eq $p.Url) { continue }
            $sub = Invoke-PageGet $left $fu
            if ($sub.status -eq "200" -and $sub.body) {
                $extra += "`n`n----- FRAME $fu -----`n"
                $extra += (Get-PlainText $sub.body)
                $html += "`n<!-- FRAME $fu -->`n" + $sub.body
            }
        }
        $text = Get-PlainText $html
        if ($extra.Count -gt 0) { $text = $text + ($extra -join "") }
        $chartNotes = New-Object System.Collections.Generic.List[string]
        foreach ($chartPath in (Get-OwnChartPaths $html $companyId)) {
            $chartUrl = $BaseUrl.TrimEnd("/") + $chartPath
            $chart = Invoke-PageGet $left $chartUrl
            if ($chart.status -eq "200") {
                $chartNotes.Add((Format-ChartXml ([string]$chart.body)))
            }
        }
        if ($chartNotes.Count -gt 0) {
            $text = $text + "`n`n" + ($chartNotes -join "`n`n")
        }
        if ($p.Url -match 'report_bster_company\.jsp' -and -not $reportHtml) { $reportHtml = $html }
        if ($p.Url -match 'CEO/A/CEO_A_1\.jsp' -and -not $cockpitHtml) {
            $cockpitHtml = $html
            $cockpitSection = $p.Section
        }
        [IO.File]::WriteAllText((Join-Path $sectionDir ($baseName + ".html")), $html, $utf8)
        [IO.File]::WriteAllText((Join-Path $sectionDir ($baseName + ".txt")), $text, $utf8)
        $manifest.Add([pscustomobject]@{
            section = $p.Section; group = $p.Group; name = $p.Name; url = $p.Url
            status = $res.status; chars = $text.Length; file = $baseName
        })
    } catch {
        Write-Host ("FAIL " + $_.Exception.Message)
        $manifest.Add([pscustomobject]@{ section = $p.Section; name = $p.Name; url = $p.Url; status = "EXC"; error = $_.Exception.Message })
    }
}

$reportSection = "reports"
foreach ($p in $pages) {
    if ($p.Url -match 'report_bster_company\.jsp') { $reportSection = $p.Section; break }
}
$times = @()
$rpValues = @()
if ($reportHtml) {
    $times = @(Get-SelectNumbers $reportHtml "time")
    $rpValues = @(Get-SelectNumbers $reportHtml "rptype")
}
if ($times.Count -eq 0) { $times = @(1, 2, 3, 4, 5) }
if ($rpValues.Count -eq 0) { $rpValues = @(0, 1, 2) }
$rpNames = @{ 0 = "cashflow"; 1 = "income"; 2 = "balance" }
if ($reportHtml) {
    $reportRoot = Join-Path (Join-Path $OutDir (Safe-Name $reportSection)) "by_quarter"
    New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
    $reportUrl = $BaseUrl.TrimEnd("/") + "/BSTCS/teacher/reports/report_bster_company.jsp"
    foreach ($time in $times) {
        foreach ($rp in $rpValues) {
            $rpName = $rpNames[[int]$rp]
            if (-not $rpName) { $rpName = "type$rp" }
            $body = "databasename=$databaseName&courseid=$courseId&studentid=$studentId&companyid=$companyId&time=$time&rptype=$rp"
            Write-Host ("REPORT t={0} type={1}" -f $time, $rpName)
            $res = Invoke-PagePost $left $reportUrl $body
            $plain = Get-PlainText ([string]$res.body)
            $name = "q{0}_{1}" -f $time, $rpName
            [IO.File]::WriteAllText((Join-Path $reportRoot ($name + ".txt")), $plain, $utf8)
            $manifest.Add([pscustomobject]@{ section = $reportSection; name = $name; status = $res.status; chars = $plain.Length; file = $name })
        }
    }
}

$shaps = @()
if ($cockpitHtml) {
    foreach ($m in [regex]::Matches($cockpitHtml, "(?i)\bs\d\s*=\s*['""](\d+)['""]")) {
        $n = [int]$m.Groups[1].Value
        if ($shaps -notcontains $n) { $shaps += $n }
    }
}
$gaugeTimes = @($times)
if ($cockpitHtml) {
    $fromCockpit = @(Get-SelectNumbers $cockpitHtml "select2")
    if ($fromCockpit.Count -gt 0) { $gaugeTimes = $fromCockpit }
}
if ($cockpitHtml -and $shaps.Count -gt 0) {
    $gaugeDir = Join-Path (Join-Path $OutDir (Safe-Name $cockpitSection)) "gauges"
    New-Item -ItemType Directory -Force -Path $gaugeDir | Out-Null
    foreach ($time in $gaugeTimes) {
        foreach ($shap in $shaps) {
            $gurl = "{0}/BSTCS/ChartAction.do?type=12&databasename={1}&companyid={2}&courseid={3}&shap={4}&studentid={5}&time={6}" -f $BaseUrl.TrimEnd("/"), $databaseName, $companyId, $courseId, $shap, $studentId, $time
            $gres = Invoke-PageGet $left $gurl
            $gtext = Format-ChartXml ([string]$gres.body)
            $gname = "t{0}_s{1}" -f $time, $shap
            [IO.File]::WriteAllText((Join-Path $gaugeDir ($gname + ".txt")), $gtext, $utf8)
            $manifest.Add([pscustomobject]@{ section = $cockpitSection; name = $gname; status = $gres.status; chars = $gtext.Length; file = $gname })
        }
        Write-Host ("GAUGE quarter {0}" -f $time)
    }
}

$manPath = Join-Path $OutDir "manifest.json"
$summary = [ordered]@{
    companyId = $companyId
    studentId = $studentId
    courseId = $courseId
    baseUrl = $BaseUrl
    pages = $manifest
}
[IO.File]::WriteAllText($manPath, ($summary | ConvertTo-Json -Depth 5), $utf8)
Write-Host ("DONE " + $manifest.Count + " -> " + $OutDir)
