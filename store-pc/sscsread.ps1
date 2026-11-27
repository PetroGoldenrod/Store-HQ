# Store HQ scratch-off counts
# StoreHQ-sscsread
# Reads the latest lottery shift counts (scratch-off tickets sold and sales $) from the SSCS website and sends them to
# Store HQ, so no browser is needed. Runs quietly every hour. Since v2 it also reads two Daily Book reports:
# item sales for Sales Movers (Mondays) and last month's department gross profit for the P&L (early each month).
# Read-only on SSCS: it only opens reports.
#
# First time, on the store PC (in the same folder as vsupload.ps1 and token.txt):
#   double-click "Setup scratch-offs.bat"
# It asks for the SSCS username and password (typed by the owner, saved encrypted for this Windows user only on this PC),
# logs in once (if SSCS sends a code by text or email, type it when asked), sends the latest counts, and schedules the
# hourly check. Later versions arrive by themselves from Store HQ.
param(
  [string]$Store = "655675",          # Circle K store number (Goldenrod 655675, Trail 654287)
  [string]$Site = "011",              # SSCS site (Goldenrod 011, Trail 004)
  [string]$Url = "https://closeout.petro-goldenrod.workers.dev",
  [switch]$Setup,
  [switch]$Poll
)
$ScriptVersion = 2
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $here "sscsread.log"
$credFile = Join-Path $here "sscsread.cred"
$devFile = Join-Path $here "sscsread.device"
$tokFile = Join-Path $here "sscsread.tok"
$Sscs = "https://sscsta.sscsinc.com"
$ClientId = "0a3f157f-8fbe-4442-8b6c-bcebd32e5ad5"
$Serial = "5969"
$TaskName = "StoreHQ Scratch-off Counts"
function Log($m) { $l = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $m; Add-Content -Path $log -Value $l; Write-Host $l }

$Token = ""; $tf = Join-Path $here "token.txt"; if (Test-Path $tf) { $Token = (Get-Content $tf -Raw).Trim() }
if (-not $Token) { Log "No upload token: put this script in the same folder as vsupload.ps1 and token.txt."; if ($Setup) { Read-Host "Press Enter to close" }; exit 1 }
$H = @{ "x-import-token" = $Token }
$SiteFull = $Serial.PadLeft(6, "0") + $Site.PadLeft(3, "0")

# Small secrets (device id, current login) are kept encrypted for this Windows user only.
function Save-Secret($file, [string]$text) { Set-Content -Path $file -Value (ConvertTo-SecureString $text -AsPlainText -Force | ConvertFrom-SecureString) }
function Read-Secret($file) {
  if (-not (Test-Path $file)) { return "" }
  try { $s = Get-Content $file -Raw | ConvertTo-SecureString; return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) } catch { return "" }
}

# Log in the same way the SSCS website does. Returns @{ ok; token; exp; err }.
function Sscs-Login($cred, [string]$code) {
  $u = $cred.UserName; $p = $cred.GetNetworkCredential().Password
  $dev = Read-Secret $devFile; if (-not $dev) { $dev = "undefined" }
  $c = if ($code) { $code } else { "undefined" }
  $f = { param($v) [Uri]::EscapeDataString([string]$v) }
  $body = "grant_type=password&username=" + (& $f $u) + "&password=" + (& $f $p) + "&client_id=" + $ClientId + "&device_id=" + (& $f $dev) + "&2fa_code=" + (& $f $c) + "&eula_check=undefined&app_name=undefined&eula_version=undefined"
  $p = $null
  $req = [Net.HttpWebRequest]::Create("$Sscs/Auth.Web/token"); $req.Method = "POST"; $req.ContentType = "application/x-www-form-urlencoded"
  $req.Headers.Add("X-Client-Referer", "$Sscs/Auth.App/"); $req.Accept = "application/json"; $req.Timeout = 60000
  $bb = [Text.Encoding]::UTF8.GetBytes($body); $body = $null; $req.ContentLength = $bb.Length
  $st = $req.GetRequestStream(); $st.Write($bb, 0, $bb.Length); $st.Close(); $bb = $null
  $resp = $null; $txt = ""
  try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { return @{ ok = $false; err = "Couldn't reach SSCS: " + $_.Exception.Message } } }
  try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $txt = $sr.ReadToEnd(); $nd = $resp.Headers["device_id"] } finally { $resp.Close() }
  if ($nd -and $nd -ne "null") { Save-Secret $devFile $nd }
  $j = $null; try { $j = $txt | ConvertFrom-Json } catch {}
  if ($j -and $j.access_token) {
    $exp = (Get-Date).AddSeconds([Math]::Max(600, [int]$j.expires_in - 600))
    Save-Secret $tokFile ($exp.ToString("o") + "|" + $j.access_token)
    return @{ ok = $true; token = $j.access_token; exp = $exp }
  }
  $e = if ($j -and $j.error_description) { [string]$j.error_description } elseif ($j -and $j.error) { [string]$j.error } elseif ($txt) { $txt.Substring(0, [Math]::Min(200, $txt.Length)) } else { "No answer" }
  return @{ ok = $false; err = $e }
}
function Get-Login {
  $saved = Read-Secret $tokFile
  if ($saved -and $saved.Contains("|")) { $p = $saved.Split("|", 2); try { if ([datetime]::Parse($p[0]) -gt (Get-Date)) { return @{ ok = $true; token = $p[1] } } } catch {} }
  if (-not (Test-Path $credFile)) { return @{ ok = $false; err = "Not set up yet: run 'Setup scratch-offs.bat' once." } }
  $cred = Import-Clixml $credFile
  return (Sscs-Login $cred "")
}
function Sscs-Get($token, $user, [string]$path) {
  $req = [Net.HttpWebRequest]::Create("$Sscs$path"); $req.Method = "GET"; $req.Accept = "application/json"; $req.Timeout = 60000
  $req.Headers.Add("Authorization", "Bearer " + $token); $req.Headers.Add("sscs-user", $user); $req.Headers.Add("sscs-sites", $SiteFull)
  $resp = $req.GetResponse(); try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $j = ($sr.ReadToEnd() | ConvertFrom-Json) } finally { $resp.Close() }
  if ($j -and -not ($j -is [array]) -and $j.PSObject.Properties["error"]) { throw ("SSCS: " + [string]$j.error) }
  return $j
}
function Iso($s) { return ([datetimeoffset]::Parse([string]$s, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

# Read the newest shift counts (last 2 days) and send them to Store HQ. Re-sending the same count is safe (updated, not duplicated).
function Pull-Counts($token, $user) {
  $e = (Get-Date).ToUniversalTime(); $s = $e.AddDays(-2)
  $q = "/Lot.Web/api/countmetadata?countTypes=shift&startTime=" + $s.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + "&endTime=" + $e.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
  $rows = @(Sscs-Get $token $user $q) | Sort-Object { [datetimeoffset]::Parse([string]$_.countTime) } -Descending | Select-Object -First 6
  $out = @()
  foreach ($r in $rows) {
    if (-not $r.countTime -or -not $r.previousCountTime) { continue }
    $a = Iso $r.previousCountTime; $b = Iso $r.countTime
    $agg = Sscs-Get $token $user ("/Lot.Web/api/salesagg?startTime=" + $a + "&endTime=" + $b)
    $tk = 0; foreach ($g in @($agg.gameTicketSales)) { $tk += [int]$g.ticketsSold }
    $out += [ordered]@{ name = ([string]$r.countName).Trim() -replace '\s*\d+/\d+/\d+\s*$', ''; startIso = $a; endIso = $b; tickets = $tk; sales = [double]$agg.totalSalesValue }
  }
  if (-not $out.Count) { return @{ n = 0; placed = @() } }
  $json = @{ counts = @($out); v = $ScriptVersion } | ConvertTo-Json -Depth 5 -Compress
  $res = Invoke-RestMethod -Method Post -Uri "$Url/api/sscs-import?store=$Store" -Headers $H -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 60
  return @{ n = $out.Count; placed = @($res.placed); counts = $out }
}

# Daily Book reports (CDB.REPORTING): same login, report requests are POSTs with a JSON body.
function Cdb-Post($token, $user, [string]$path, $obj) {
  $req = [Net.HttpWebRequest]::Create("$Sscs/CDB.REPORTING/api/$path"); $req.Method = "POST"; $req.ContentType = "application/json"; $req.Accept = "application/json"; $req.Timeout = 180000
  $req.Headers.Add("Authorization", "Bearer " + $token); $req.Headers.Add("sscs-user", $user); $req.Headers.Add("sscs-sites", $SiteFull)
  $bb = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5 -Compress)); $req.ContentLength = $bb.Length
  $st = $req.GetRequestStream(); $st.Write($bb, 0, $bb.Length); $st.Close()
  $resp = $req.GetResponse(); try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $txt = $sr.ReadToEnd() } finally { $resp.Close() }
  # Big reports: Windows PowerShell's ConvertFrom-Json stops at about 2 MB, so use the .NET reader with no size limit.
  Add-Type -AssemblyName System.Web.Extensions
  $ser = New-Object Web.Script.Serialization.JavaScriptSerializer; $ser.MaxJsonLength = [int]::MaxValue; $ser.RecursionLimit = 200
  $j = $ser.DeserializeObject($txt); $txt = $null
  if ($j -is [Collections.IDictionary] -and $j.ContainsKey("error")) { throw ("SSCS: " + [string]$j["error"]) }
  return $j
}
function Cdb-Body([string]$from, [string]$to) {
  $n = [int]$Site
  return [ordered]@{ sites = $SiteFull; serialSites = @([ordered]@{ serial = [int]$Serial; site = $n; siteNumber = [string]$n }); from = $from + "T00:00:00"; to = $to + "T00:00:00"; departmentId = $null; subDepartmentId = $null; totalsOnly = $true; groupBySite = $true }
}
function Send-Pc($obj) { return Invoke-RestMethod -Method Post -Uri "$Url/api/pc-sscs?store=$Store" -Headers $H -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 6 -Compress))) -TimeoutSec 120 }
function Item-Map($j) {
  $m = @{}
  foreach ($d in @($j.details)) { foreach ($x in @($d.itemDetailTotals)) {
    $id = [string]$x.id; if ($id -notmatch '^\d+$') { continue }
    if (-not $m.ContainsKey($id)) { $dep = ""; if ([string]$x.department -match '\((\d+)\)\s*$') { $dep = $Matches[1] }; $m[$id] = @{ q = 0.0; dep = $dep; desc = ([string]$x.description).Trim() } }
    $m[$id].q += [double]$x.qtySold
  } }
  return $m
}
function Marker($name) { $f = Join-Path $here ("sscsread." + $name); if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }; return "" }
function Set-Marker($name, $v) { Set-Content -Path (Join-Path $here ("sscsread." + $name)) -Value $v }

# Once: can this login open the Daily Book reports? (Store HQ shows the answer; nothing else depends on it.)
function Test-Cdb($token, $user) {
  if ((Marker "cdbtest") -eq "ok") { return $true }
  $y = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
  try { $g = Cdb-Post $token $user "dailybook/deptgrossprofit" (Cdb-Body $y $y); $n = @($g.details).Count; Send-Pc @{ kind = "test"; ok = $true; err = "" } | Out-Null; Set-Marker "cdbtest" "ok"; Log ("Daily Book reports open fine (" + $n + " rows)."); return $true }
  catch { $m = $_.Exception.Message; Log ("Daily Book reports: " + $m); try { Send-Pc @{ kind = "test"; ok = $false; err = $m.Substring(0, [Math]::Min(200, $m.Length)) } | Out-Null } catch {}; Set-Marker "cdbtest" ("failed " + (Get-Date -Format s)); return $false }
}
# Mondays (or the first run after): items sold in the 14 days ending Sunday vs the 14 days before, for Sales Movers.
function Pull-Movers($token, $user) {
  $today = (Get-Date).Date; $back = ([int]$today.DayOfWeek + 6) % 7; $monday = $today.AddDays(-$back)
  if ($back -eq 0 -and (Get-Date).Hour -lt 4) { $monday = $monday.AddDays(-7) }
  $end = $monday.AddDays(-1); $tag = $end.ToString("yyyy-MM-dd")
  if ((Marker "movers") -eq $tag) { return }
  $cf = $end.AddDays(-13); $pt = $cf.AddDays(-1); $pf = $pt.AddDays(-13)
  $A = Item-Map (Cdb-Post $token $user "dailybook/itemsalestotalsbyday" (Cdb-Body $cf.ToString("yyyy-MM-dd") $end.ToString("yyyy-MM-dd")))
  $B = Item-Map (Cdb-Post $token $user "dailybook/itemsalestotalsbyday" (Cdb-Body $pf.ToString("yyyy-MM-dd") $pt.ToString("yyyy-MM-dd")))
  $rows = New-Object System.Collections.ArrayList
  foreach ($id in (@($A.Keys) + @($B.Keys) | Select-Object -Unique)) { $o = if ($A.ContainsKey($id)) { $A[$id] } else { $B[$id] }; $qa = if ($A.ContainsKey($id)) { [Math]::Round($A[$id].q) } else { 0 }; $qb = if ($B.ContainsKey($id)) { [Math]::Round($B[$id].q) } else { 0 }; [void]$rows.Add(@($id, $o.dep, $qa, $qb, $o.desc)) }
  $depts = @{}; try { foreach ($d in @(Sscs-Get $token $user "/CDB.REPORTING/api/lookups/departments/$Serial")) { $depts[[string]$d.categoryID] = ([string]$d.desc).Trim() } } catch {}
  $lab = { param($d) $d.ToString("MMM d", [Globalization.CultureInfo]::InvariantCulture) }
  $r = Send-Pc @{ kind = "movers"; cur = (& $lab $cf) + " - " + (& $lab $end); prev = (& $lab $pf) + " - " + (& $lab $pt); depts = $depts; rows = @($rows) }
  Set-Marker "movers" $tag; Log ("Sales Movers sent: " + $rows.Count + " items (" + (& $lab $cf) + " - " + (& $lab $end) + ").")
}
# From the 1st of each month (after 4 AM): last month's department sales and cost, plus items selling at a loss or with no cost.
function Pull-Pnl($token, $user) {
  $now = Get-Date; if ($now.Day -eq 1 -and $now.Hour -lt 4) { return }
  $first = (Get-Date -Year $now.Year -Month $now.Month -Day 1).Date.AddMonths(-1); $last = $first.AddMonths(1).AddDays(-1); $tag = $first.ToString("yyyy-MM")
  if ((Marker "pnl") -eq $tag) { return }
  $b = Cdb-Body $first.ToString("yyyy-MM-dd") $last.ToString("yyyy-MM-dd")
  $g = Cdb-Post $token $user "dailybook/deptgrossprofit" $b
  $depts = @(); foreach ($x in @($g.details)) { if ($x.isTotalsRow -or (-not $x.periodSales -and -not $x.periodCost)) { continue }; $depts += ,@([int]$x.departmentId, ([string]$x.name).Trim(), [Math]::Round([double]$x.periodSales, 2), [Math]::Round([double]$x.periodCost, 2)) }
  $it = Cdb-Post $token $user "dailybook/itemsalestotalsbyday" $b
  $items = New-Object System.Collections.ArrayList
  foreach ($d in @($it.details)) { foreach ($x in @($d.itemDetailTotals)) {
    if ([string]$x.id -notmatch '^\d+$' -or [double]$x.sales -le 0) { continue }
    $dep = 0; if ([string]$x.department -match '\((\d+)\)\s*$') { $dep = [int]$Matches[1] }; if (@(27, 34, 79) -contains $dep) { continue }
    if ([double]$x.grossProfit -lt 0 -or [double]$x.marginPercentage -ge 99.5) { [void]$items.Add(@([string]$x.id, ([string]$x.description).Trim(), [Math]::Round([double]$x.sales, 2), [Math]::Round([double]$x.grossProfit, 2), $(if ([double]$x.grossProfit -lt 0) { "loss" } else { "no cost" }))) }
  } }
  $top = @($items | Sort-Object { - [double]$_[2] } | Select-Object -First 15)
  $r = Send-Pc @{ kind = "pnl"; month = $tag; depts = $depts; items = $top; itemCount = $items.Count }
  Set-Marker "pnl" $tag; Log ("P&L " + $tag + " sent: " + $depts.Count + " departments" + $(if ($r.saved) { ", saved" } else { " (" + $r.why + ")" }))
}

function Register-SscsTask {
  $ps = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
  $ws = Join-Path $env:WINDIR "System32\wscript.exe"
  $cmd = '"' + $ps + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Store ' + $Store + ' -Site ' + $Site + ' -Poll'
  if (Test-Path $ws) {
    $vbs = Join-Path $here "sscsread-quiet.vbs"
    Set-Content -Path $vbs -Encoding ASCII -Value ('CreateObject("WScript.Shell").Run "' + $cmd.Replace('"', '""') + '", 0, True')
    $act = New-ScheduledTaskAction -Execute $ws -Argument ('//B //Nologo "' + $vbs + '"') -WorkingDirectory $here
  } else {
    $act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Store ' + $Store + ' -Site ' + $Site + ' -Poll') -WorkingDirectory $here
  }
  $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::FromDays(3650))
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  $pri = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
  Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pri -Force | Out-Null
}

# Self-update: Store HQ can hold a newer version of this script; checked about once a day, installed only if it passes the checks.
function Update-Self {
  $stamp = Join-Path $here "sscsread.updcheck"
  if ((Test-Path $stamp) -and ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalHours -lt 20) { return }
  try {
    Set-Content -Path $stamp -Value (Get-Date -Format s)
    $u = Invoke-RestMethod -Method Get -Uri "$Url/api/pc-script?store=$Store&name=sscsread" -Headers $H -TimeoutSec 60
    if ([int]$u.version -le $ScriptVersion) { return }
    $txt = [string]$u.script
    $hh = [Security.Cryptography.SHA256]::Create(); $got = ([BitConverter]::ToString($hh.ComputeHash([Text.Encoding]::UTF8.GetBytes($txt))) -replace "-", "").ToLower()
    $ptok = $null; $perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$ptok, [ref]$perr)
    if ($got -ne ([string]$u.sha256).ToLower() -or $txt -notmatch "# StoreHQ-sscsread" -or $txt -notmatch ('\$ScriptVersion = ' + [int]$u.version + '\b') -or ($perr -and $perr.Count)) { Log "Script update skipped: it didn't pass the checks."; return }
    Copy-Item -Path $PSCommandPath -Destination (Join-Path $here "sscsread.prev.ps1") -Force
    [IO.File]::WriteAllText($PSCommandPath, $txt, (New-Object Text.UTF8Encoding $false))
    Log ("Script updated from v$ScriptVersion to v$($u.version).")
  } catch {}
}

if ($Setup) {
  Write-Host ""; Write-Host "Store HQ: scratch-off counts from SSCS - store $Store, site $SiteFull"; Write-Host ""
  Write-Host "Type the SSCS login you use on the SSCS website. It is saved encrypted on this PC, for this Windows user only."
  $user = Read-Host "SSCS username"
  $pw = Read-Host "SSCS password" -AsSecureString
  $cred = New-Object Management.Automation.PSCredential (($user.Trim()), $pw)
  $r = Sscs-Login $cred ""
  if (-not $r.ok) {
    Log ("SSCS login: " + $r.err)
    Write-Host ""; Write-Host "If SSCS just sent you a code (text or email), type it here. Otherwise just press Enter."
    $code = Read-Host "Code"
    if ($code.Trim()) { $r = Sscs-Login $cred $code.Trim(); if (-not $r.ok) { Log ("SSCS login with the code: " + $r.err) } }
  }
  if (-not $r.ok) { Write-Host ""; Write-Host "SSCS didn't accept the login, so nothing was set up. Tell Claude what it said above."; Read-Host "Press Enter to close"; exit 1 }
  $cred | Export-Clixml -Path $credFile
  Log "SSCS login works and is saved for this Windows user."
  try {
    $p = Pull-Counts $r.token $cred.UserName
    foreach ($c in $p.counts) { Log ("  " + $c.name + ": " + $c.tickets + " tickets, $" + ('{0:N2}' -f $c.sales) + "  (" + $c.startIso + " to " + $c.endIso + ")") }
    Log ("Sent " + $p.n + " count(s) to Store HQ: " + ($p.placed -join ", "))
    Register-SscsTask
    Log "Scheduled: a quiet check every hour."
    Write-Host ""; Write-Host "All set. The scratch-off counts are in Store HQ."
  } catch { Log ("Reading the counts failed: " + $_.Exception.Message); Write-Host "Tell Claude what it said above." }
  Read-Host "Press Enter to close"
  exit 0
}

# Hourly run
$r = Get-Login
if (-not $r.ok) { Log ("SSCS login failed: " + $r.err); try { Invoke-RestMethod -Method Post -Uri "$Url/api/sscs-import?store=$Store" -Headers $H -ContentType "application/json" -Body (@{ counts = @(); pcErr = $r.err; v = $ScriptVersion } | ConvertTo-Json -Compress) -TimeoutSec 30 | Out-Null } catch {}; Update-Self; exit 1 }
$user = (Import-Clixml $credFile).UserName
for ($try = 1; $try -le 2; $try++) {
  try { $p = Pull-Counts $r.token $user; if ($p.n) { Log ("Sent " + $p.n + " count(s): " + ($p.placed -join ", ")) }; break }
  catch {
    $m = $_.Exception.Message
    if ($try -eq 1 -and $m -match '401|Unauthorized|Authorization') { Remove-Item $tokFile -ErrorAction SilentlyContinue; $r = Get-Login; if ($r.ok) { continue }; $m = "SSCS login failed: " + $r.err }
    Log ("Reading the counts failed: " + $m)
    try { Invoke-RestMethod -Method Post -Uri "$Url/api/sscs-import?store=$Store" -Headers $H -ContentType "application/json" -Body (@{ counts = @(); pcErr = $m.Substring(0, [Math]::Min(200, $m.Length)); v = $ScriptVersion } | ConvertTo-Json -Compress) -TimeoutSec 30 | Out-Null } catch {}
    break
  }
}
# Daily Book reports (each step on its own, so one failing doesn't stop the others).
if ($r.ok -and (Test-Cdb $r.token $user)) {
  try { Pull-Movers $r.token $user } catch { Log ("Sales Movers failed: " + $_.Exception.Message) }
  try { Pull-Pnl $r.token $user } catch { Log ("P&L failed: " + $_.Exception.Message) }
}
Update-Self
exit 0
