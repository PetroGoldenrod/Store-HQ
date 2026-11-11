# Store HQ nightly uploader
# StoreHQ-vsupload
# Reads the daily Verifone reports that SSCS VS-Poll saves on this PC (C:\VSPoll\<site>\*D###.XML)
# and sends a short summary of each day to the Close-Out app. Read-only: it never changes Verifone or SSCS files.
param(
  [string]$Store = "655675",          # Circle K store number (Goldenrod 655675, Trail 654287)
  [string]$Site = "011",              # VSPoll folder for this store
  [int]$Days = 4,                     # how many recent days to send (first run: use 100 to send history)
  [string]$Url = "https://closeout.petro-goldenrod.workers.dev",
  [string]$Token = ""
)
$ScriptVersion = 3
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $here "vsupload.log"
function Log($m) { $l = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $m; Add-Content -Path $log -Value $l; Write-Host $l }
if (-not $Token) { $tf = Join-Path $here "token.txt"; if (Test-Path $tf) { $Token = (Get-Content $tf -Raw).Trim() } }
if (-not $Token) { Log "No upload token (token.txt missing)."; exit 1 }
$errors = @(); $salesDays = 0; $shiftDays = ""; $newest = ""; $pollAge = -1; $updatedTo = 0

# Nightly health report to the app (so the owner can see this PC is fine without logging in to it).
function Send-Status([bool]$ok) {
  try {
    $tail = @(); if (Test-Path $log) { $tail = @(Get-Content $log -Tail 20 | ForEach-Object { ([string]$_).Substring(0, [math]::Min(([string]$_).Length, 200)) }) }
    $sha = ""; try { $h = [Security.Cryptography.SHA256]::Create(); $sha = ([BitConverter]::ToString($h.ComputeHash([IO.File]::ReadAllBytes($PSCommandPath))) -replace "-", "").ToLower() } catch {}
    $st = [ordered]@{ version = $ScriptVersion; host = $env:COMPUTERNAME; ps = [string]$PSVersionTable.PSVersion; dir = $dir; ok = $ok; salesDays = $salesDays; shiftDays = $shiftDays
      newestPoll = $newest; pollAgeH = $pollAge; scriptSha = $sha; updatedTo = $updatedTo; errors = @($errors); logTail = $tail }
    Invoke-RestMethod -Method Post -Uri "$Url/api/pc-status?store=$Store" -Headers @{ "x-import-token" = $Token } -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes(($st | ConvertTo-Json -Depth 4 -Compress))) -TimeoutSec 60 | Out-Null
  } catch { Log ("Status report failed: " + $_.Exception.Message) }
}

$dir = "C:\VSPoll\$Site"; if (-not (Test-Path $dir) -and (Test-Path "C:\VSPOLL2\$Site")) { $dir = "C:\VSPOLL2\$Site" }
if (-not (Test-Path $dir)) { Log "Folder $dir not found."; $errors += "VSPoll folder $dir not found"; Send-Status $false; exit 1 }
$nf = Get-ChildItem -Path $dir -Filter "MSMD*.XML" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($nf) { $newest = $nf.Name + " " + $nf.LastWriteTime.ToString("yyyy-MM-dd HH:mm"); $pollAge = [math]::Round(((Get-Date) - $nf.LastWriteTime).TotalHours, 1) }
if ($pollAge -gt 30) { $errors += "Newest VSPoll day file is $pollAge hours old (VSPoll may not be running)" }

function N($node, $path) { if ($null -eq $node) { return 0.0 } $x = $node.SelectSingleNode($path); if ($null -eq $x) { return 0.0 } $v = 0.0; [double]::TryParse($x.InnerText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) | Out-Null; return $v }
function T($node, $path) { if ($null -eq $node) { return "" } $x = $node.SelectSingleNode($path); if ($null -eq $x) { return "" } return $x.InnerText.Trim() }
function LoadXml($path) { if (-not (Test-Path $path)) { return $null } $x = New-Object System.Xml.XmlDocument; $x.Load($path); return $x }
# Namespaces are ignored: every path uses local-name().
function P($p) { return ($p -split "/" | ForEach-Object { if ($_ -eq "") { "" } elseif ($_ -eq ".") { "." } else { "*[local-name()='$_']" } }) -join "/" }

$msm = Get-ChildItem -Path $dir -Filter "MSMD*.XML" | Sort-Object LastWriteTime -Descending | Select-Object -First $Days
$out = @()
foreach ($f in $msm) {
  try {
    $suffix = $f.Name.Substring(4)            # e.g. 048.XML
    $x = LoadXml $f.FullName
    $root = $x.DocumentElement
    $per = $root.SelectSingleNode((P "period"))
    $seq = [int]$per.GetAttribute("periodSeqNum")
    $begin = $per.GetAttribute("periodBeginDate"); $end = $per.GetAttribute("periodEndDate")
    $date = $end.Substring(0, 10)
    $si = $root.SelectSingleNode((P "totals/summaryInfo"))
    $mop = @{}
    foreach ($m in $si.SelectNodes((P "mopTotals/sale/mopInfo"))) { $mop[(T $m (P "name"))] = @{ c = (N $m (P "count")); a = (N $m (P "amount")) } }
    $sales = [ordered]@{
      net = (N $si (P "mopTotals/netSales")); fuel = (N $si (P "fuelSales")); merch = (N $si (P "merchSales"))
      tax = (N $si (P "totalSalesTaxes")); items = (N $si (P "itemCount")); customers = (N $si (P "customerCount"))
      payOut = (N $si (P "payOut/amount")) + (N $si (P "inHousePayOut/amount")); drops = (N $si (P "safeDrop/total/amount")); dropCount = (N $si (P "safeDrop/total/count"))
      discounts = (N $si (P "totalDiscounts/amount")); noSale = (N $si (P "noSaleCount"))
      voidLineCnt = (N $si (P "voidLine/count")); voidLineAmt = (N $si (P "voidLine/amount"))
      errCorCnt = (N $si (P "errorCorrect/count")); errCorAmt = (N $si (P "errorCorrect/amount")); voidTicketCnt = (N $si (P "voidTicket/count"))
    }
    $depts = @()
    $mc = LoadXml (Join-Path $dir ("MCMD" + $suffix))
    if ($mc) { foreach ($d in $mc.DocumentElement.SelectNodes((P "totals/deptInfo"))) {
      $b = $d.SelectSingleNode((P "deptBase"))
      $depts += ,@($b.GetAttribute("sysid"), (T $b (P "name")), (N $d (P "netSales/count")), (N $d (P "netSales/amount"))) } }
    $fuel = @()
    $fa = LoadXml (Join-Path $dir ("FGAD" + $suffix))
    if ($fa) { foreach ($g in $fa.DocumentElement.SelectNodes((P "totals/prPriceLvlInfo"))) {
      $name = T $g (P "fuelProdBase/name"); $cg = 0.0; $ca = 0.0; $kg = 0.0; $ka = 0.0
      foreach ($l in $g.SelectNodes((P "priceLvlInfo"))) {
        $lv = T $l (P "fuelPriceLevel/name")
        if ($lv -eq "CASH") { $cg += (N $l (P "fuelInfo/volume")); $ca += (N $l (P "fuelInfo/amount")) } else { $kg += (N $l (P "fuelInfo/volume")); $ka += (N $l (P "fuelInfo/amount")) } }
      $fuel += ,@($name, [math]::Round($cg, 3), [math]::Round($ca, 2), [math]::Round($kg, 3), [math]::Round($ka, 2)) } }
    $tanks = @()
    $tp = LoadXml (Join-Path $dir ("TPMD" + $suffix))
    if ($tp) { foreach ($t in $tp.DocumentElement.SelectNodes((P "inventoryInfo"))) {
      $tanks += ,@((T $t (P "fuelTank")), (N $t (P "fuelVolume")), (N $t (P "ullage")), (N $t (P "waterLvl"))) } }
    $cards = @()
    $nw = LoadXml (Join-Path $dir ("NTWD" + $suffix))
    if ($nw) { foreach ($c in $nw.DocumentElement.SelectNodes((P "totals/cardInfo"))) {
      $cards += ,@((T $c (P "cardName")), (N $c (P "cardCharges/count")), (N $c (P "cardCharges/amount"))) } }
    $out += [ordered]@{ seq = $seq; date = $date; begin = $begin; end = $end; file = $f.Name; sales = $sales; mop = $mop; depts = $depts; fuel = $fuel; tanks = $tanks; cards = $cards }
  } catch { Log ("Skipped " + $f.Name + ": " + $_.Exception.Message) }
}
if (-not $out.Count) { Log "No day reports found in $dir."; $errors += "No day reports found in $dir"; Send-Status $false; exit 1 }
# Send in small batches
$sent = 0
for ($i = 0; $i -lt $out.Count; $i += 10) {
  $batch = $out[$i..([math]::Min($i + 9, $out.Count - 1))]
  $body = @{ days = @($batch) } | ConvertTo-Json -Depth 8 -Compress
  try {
    $r = Invoke-RestMethod -Method Post -Uri "$Url/api/vs-upload?store=$Store" -Headers @{ "x-import-token" = $Token } -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes($body))
    $sent += [int]$r.saved
  } catch { Log ("Upload failed: " + $_.Exception.Message); $errors += ("Sales upload failed: " + $_.Exception.Message); Send-Status $false; exit 1 }
}
Log ("Store $Store sent $sent day(s), newest " + $out[0].date); $salesDays = $sent

# Shift detail: the newest 3 day transaction logs (cashier sessions, drawer counts, safe drops, lotto, voids).
# The app rebuilds the last two days from them. A failure here is logged and does not affect the sales upload above.
try {
  $logs = Get-ChildItem -Path $dir -Filter "LOGD*.XML" | Sort-Object LastWriteTime -Descending | Select-Object -First 3
  $files = @()
  foreach ($lf in $logs) {
    $in = [IO.File]::Open($lf.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
    $in.CopyTo($gz); $gz.Close(); $in.Close()
    $files += [Convert]::ToBase64String($ms.ToArray())
  }
  if ($files.Count) {
    $json = '{"files":["' + ($files -join '","') + '"]}'
    $r = Invoke-RestMethod -Method Post -Uri "$Url/api/vs-log?store=$Store" -Headers @{ "x-import-token" = $Token } -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 180
    $shiftDays = (($r.days | ForEach-Object { $_.date + " " + $_.sessions + " cashier session(s)" }) -join ", ")
    Log ("Shift detail sent from " + $files.Count + " log(s): " + $shiftDays)
  } else { Log "Shift detail: no LOGD files in $dir."; $errors += "No LOGD transaction logs in $dir" }
} catch { Log ("Shift detail upload failed: " + $_.Exception.Message); $errors += ("Shift detail upload failed: " + $_.Exception.Message) }

# Self-update: if the app has a newer version of this script, check it and install it for the next run.
# The new script must arrive intact (SHA-256 matches), carry the Store HQ marker and its version number, and parse as valid PowerShell.
# The current script is kept as vsupload.prev.ps1.
try {
  $u = Invoke-RestMethod -Method Get -Uri "$Url/api/pc-script?store=$Store" -Headers @{ "x-import-token" = $Token } -TimeoutSec 60
  if ([int]$u.version -gt $ScriptVersion) {
    $txt = [string]$u.script
    $h = [Security.Cryptography.SHA256]::Create(); $got = ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($txt))) -replace "-", "").ToLower()
    $ptok = $null; $perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$ptok, [ref]$perr)
    if ($got -ne ([string]$u.sha256).ToLower()) { $errors += "Script update v$($u.version) skipped: download did not match its checksum" }
    elseif ($txt -notmatch "# StoreHQ-vsupload" -or $txt -notmatch ('\$ScriptVersion = ' + [int]$u.version + '\b')) { $errors += "Script update v$($u.version) skipped: not a Store HQ upload script" }
    elseif ($perr -and $perr.Count) { $errors += "Script update v$($u.version) skipped: it has a syntax error" }
    else {
      Copy-Item -Path $PSCommandPath -Destination (Join-Path $here "vsupload.prev.ps1") -Force
      [IO.File]::WriteAllText($PSCommandPath, $txt, (New-Object Text.UTF8Encoding $false))
      $updatedTo = [int]$u.version
      Log ("Script updated from v$ScriptVersion to v$($u.version); it runs from the next night on.")
    }
  }
} catch { if ($_.Exception.Message -notmatch "404") { Log ("Update check failed: " + $_.Exception.Message) } }

Send-Status ($errors.Count -eq 0)
