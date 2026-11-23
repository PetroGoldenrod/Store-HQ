# Store HQ tank reading
# StoreHQ-tankread
# Every 2 hours (Store HQ sets the interval), and right away when someone taps "Read now" on the Fuel page: asks the
# Verifone register (Commander) for its current tank report, which it reads live from the Veeder-Root tank gauge, and
# sends gallons / room / water per tank to Store HQ. Read-only: it changes nothing on the register, in Sunray or in SSCS,
# and never sends prices. A quiet check runs every 5 minutes (-Poll) and only reads the tanks when one is due.
#
# First time, on the store PC (in the same folder as vsupload.ps1 and token.txt):
#   double-click "Setup tank readings.bat"  (or: powershell -ExecutionPolicy Bypass -File tankread.ps1 -Setup)
# It asks for a register login (typed by the owner, saved encrypted for this Windows user only), tests one reading,
# and schedules the 5-minute check. Later versions arrive by themselves from Store HQ.
param(
  [string]$Store = "655675",          # Circle K store number (Goldenrod 655675, Trail 654287)
  [string]$Site = "011",              # VSPoll folder for this store (Goldenrod 011, Trail 004)
  [string]$Register = "",             # register IP; read from the VSPoll setup file when empty
  [string]$Url = "https://closeout.petro-goldenrod.workers.dev",
  [switch]$Setup,
  [switch]$Poll
)
$ScriptVersion = 3
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $here "tankread.log"
$credFile = Join-Path $here "tankread.cred"
function Log($m) { $l = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $m; Add-Content -Path $log -Value $l; Write-Host $l }

$Token = ""; $tf = Join-Path $here "token.txt"; if (Test-Path $tf) { $Token = (Get-Content $tf -Raw).Trim() }
if (-not $Token) { Log "No upload token: put this script in the same folder as vsupload.ps1 and token.txt."; if ($Setup) { Read-Host "Press Enter to close" }; exit 1 }
$H = @{ "x-import-token" = $Token }
$TaskName = "StoreHQ Tank Reading"

# The scheduled task: one quiet check every 5 minutes for this Windows user (the saved register login only works for this user).
function Register-TankTask {
  $ps = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
  $act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Store ' + $Store + ' -Site ' + $Site + ' -Poll') -WorkingDirectory $here
  $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::FromDays(3650))
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  $pri = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
  Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pri -Force | Out-Null
}
# Older versions ran at fixed times (12 AM, 6 AM, 12 PM, 6 PM). Switch this PC over to the 5-minute check once.
function Ensure-TankTask {
  try {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $ok = $t -and ($t.Actions | Where-Object { $_.Arguments -match '-Poll' }) -and ($t.Triggers | Where-Object { $_.Repetition.Interval -eq 'PT5M' })
    if (-not $ok) { Register-TankTask; Log "Tank readings switched to a 5-minute check (reads every 2 hours, or right away on Read now)." }
  } catch { Log ("Couldn't update the scheduled task: " + $_.Exception.Message) }
}

# Self-update: Store HQ can hold a newer tank script (checked once a day). It must arrive intact, carry the marker and
# its version number, and parse as valid PowerShell. The current one is kept as tankread.prev.ps1.
function Update-Self {
  $stamp = Join-Path $here "tankread.updcheck"
  if ((Test-Path $stamp) -and ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalHours -lt 20) { return }
  try {
    Set-Content -Path $stamp -Value (Get-Date -Format s)
    $u = Invoke-RestMethod -Method Get -Uri "$Url/api/pc-script?store=$Store&name=tankread" -Headers $H -TimeoutSec 60
    if ([int]$u.version -le $ScriptVersion) { return }
    $txt = [string]$u.script
    $hh = [Security.Cryptography.SHA256]::Create(); $got = ([BitConverter]::ToString($hh.ComputeHash([Text.Encoding]::UTF8.GetBytes($txt))) -replace "-", "").ToLower()
    $ptok = $null; $perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$ptok, [ref]$perr)
    if ($got -ne ([string]$u.sha256).ToLower()) { Log "Tank script update skipped: checksum didn't match."; return }
    if ($txt -notmatch "# StoreHQ-tankread" -or $txt -notmatch ('\$ScriptVersion = ' + [int]$u.version + '\b')) { Log "Tank script update skipped: not a Store HQ tank script."; return }
    if ($perr -and $perr.Count) { Log "Tank script update skipped: syntax error."; return }
    Copy-Item -Path $PSCommandPath -Destination (Join-Path $here "tankread.prev.ps1") -Force
    [IO.File]::WriteAllText($PSCommandPath, $txt, (New-Object Text.UTF8Encoding $false))
    Log ("Tank script updated from v$ScriptVersion to v$($u.version).")
  } catch { if ($_.Exception.Message -notmatch "404") { Log ("Tank script update check failed: " + $_.Exception.Message) } }
}

# ---- Quiet 5-minute check: read only when Store HQ asks (Read now) or the next scheduled reading is due.
$ReqId = ""; $every = 120
if ($Poll) { try { $q = Invoke-RestMethod -Uri "$Url/api/pc-tankreq?store=$Store&v=$ScriptVersion" -Headers $H -TimeoutSec 30; if ($q.every -ge 30) { $every = [int]$q.every }; if ($q.read) { $ReqId = [string]$q.read } } catch {} }
$now = Get-Date
$slot = $now.ToString("yyyy-MM-dd") + "-" + [string][math]::Floor(($now.Hour * 60 + $now.Minute) / $every)
$slotFile = Join-Path $here "tankread.slot"
$lastSlot = if (Test-Path $slotFile) { ([string](Get-Content $slotFile -Raw)).Trim() } else { "" }
if ($Poll -and -not $ReqId -and $lastSlot -eq $slot) { exit 0 }
try { Set-Content -Path $slotFile -Value $slot } catch {}

# Register address: the same one SSCS VS-Poll uses (MachineName in its setup file).
if (-not $Register) {
  foreach ($d in @("C:\VSPoll\$Site", "C:\VSPOLL2\$Site")) {
    $sf = Join-Path $d "SETUP.$Site"
    if (Test-Path $sf) { $m = Select-String -Path $sf -Pattern '^\s*MachineName\s*=\s*([0-9.]+)' | Select-Object -First 1; if ($m) { $Register = $m.Matches[0].Groups[1].Value; break } }
  }
}
if (-not $Register) { Log "Couldn't find the register address in the VSPoll setup file for site $Site."; if ($Setup) { Read-Host "Press Enter to close" }; exit 1 }

# The register uses its own (self-signed) certificate. Accept it for the register's address only.
if (-not ("StoreHqRegisterCert" -as [type])) {
  Add-Type -TypeDefinition @"
using System; using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public static class StoreHqRegisterCert {
  public static string Host = "";
  public static bool Check(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) {
    if (e == SslPolicyErrors.None) return true;
    var r = s as HttpWebRequest; return r != null && r.RequestUri.Host == Host;
  }
  public static void Use(string host) { Host = host; ServicePointManager.ServerCertificateValidationCallback = Check; }
}
"@
}
[StoreHqRegisterCert]::Use($Register)

function Send-Reading($tanks, $err, $how) {
  $body = [ordered]@{ version = $ScriptVersion; tanks = @($tanks); err = $err; how = $how; req = $ReqId } | ConvertTo-Json -Depth 5 -Compress
  try { Invoke-RestMethod -Method Post -Uri "$Url/api/tank-read?store=$Store" -Headers @{ "x-import-token" = $Token } -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60 | Out-Null; return $true }
  catch { Log ("Upload to Store HQ failed: " + $_.Exception.Message); return $false }
}

function Cgi($base, [hashtable]$form) {
  $pairs = @(); foreach ($k in $form.Keys) { $pairs += ([Uri]::EscapeDataString($k) + "=" + [Uri]::EscapeDataString([string]$form[$k])) }
  $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$base/cgi-bin/CGILink" -ContentType "application/x-www-form-urlencoded" -Body ($pairs -join "&") -TimeoutSec 90
  return [string]$r.Content
}
function Short($t) { $t = ([string]$t) -replace '<cookie>[^<]*</cookie>', '<cookie>...</cookie>' -replace '\s+', ' '; return $t.Substring(0, [math]::Min(220, $t.Length)) }

# ---- Setup: save the register login (DPAPI: only this Windows user on this PC can read it) and schedule the task.
if ($Setup) {
  Write-Host ""
  Write-Host "Store HQ tank readings - store $Store, register $Register"
  Write-Host "Type a register (Commander) login that can run reports. It is saved encrypted on this PC only."
  $keep = $false
  if (Test-Path $credFile) { $a = Read-Host "A register login is already saved. Press Enter to keep it, or type N to enter a new one"; $keep = ($a -notmatch '^\s*n') }
  if (-not $keep) {
    $c = Get-Credential -Message "Register (Commander) login for tank readings"
    if (-not $c) { Log "Setup cancelled."; exit 1 }
    $c | Export-Clixml -Path $credFile
    Log "Register login saved for Windows user $env:USERNAME."
  }
}

if (-not (Test-Path $credFile)) { Log "No register login saved yet. Run 'Setup tank readings.bat' once."; Send-Reading @() "No register login saved on the store PC yet (run the setup once)" "" | Out-Null; exit 1 }
$cred = Import-Clixml -Path $credFile
$user = $cred.UserName; $pass = $cred.GetNetworkCredential().Password

$tanks = @(); $err = ""; $how = ""; $cookie = ""; $base = ""
foreach ($b in @("https://$Register", "http://$Register")) {
  try {
    $t = Cgi $b @{ cmd = "validate"; user = $user; passwd = $pass }
    $m = [regex]::Match($t, '<cookie>\s*([^<\s]+)\s*</cookie>')
    if ($m.Success) { $cookie = $m.Groups[1].Value; $base = $b; break }
    $err = "Register login refused: " + (Short $t)
  } catch { $err = "Couldn't reach the register at $b : " + $_.Exception.Message }
}
$pass = $null

if ($cookie) {
  $err = ""
  # Current-period tank monitor report (the same data as the TPMD day file, but live).
  $tries = @()
  foreach ($rn in @("tankMonitor", "tankmonitor", "fuelTankMonitor", "tankMon")) { foreach ($pd in @(@{ period = "1"; filename = "current" }, @{ period = "2"; filename = "current" })) { $tries += , @($rn, $pd) } }
  foreach ($try in $tries) {
    try {
      $f = @{ cmd = "vrubyrept"; reptname = $try[0]; cookie = $cookie }; foreach ($k in $try[1].Keys) { $f[$k] = $try[1][$k] }
      $t = Cgi $base $f
      if ($t -notmatch "inventoryInfo") { if (-not $err) { $err = "Register answered without tank data (" + $try[0] + "): " + (Short $t) }; continue }
      $x = New-Object System.Xml.XmlDocument; $x.LoadXml($t)
      foreach ($n in $x.SelectNodes("//*[local-name()='inventoryInfo']")) {
        function V($name) { $e = $n.SelectSingleNode("*[local-name()='$name']"); if ($null -eq $e) { return $null }; $v = 0.0; if ([double]::TryParse($e.InnerText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }; return $null }
        $nm = $n.SelectSingleNode("*[local-name()='fuelTank']"); $label = if ($nm) { $nm.InnerText.Trim() + " #" + $nm.GetAttribute("sysid") } else { "Tank" }
        $tanks += , @($label, (V "fuelVolume"), (V "ullage"), (V "waterLvl"), (V "fuelTemperature"), (V "fuelLvl"))
      }
      if ($tanks.Count) { $how = $try[0] + " period " + $try[1].period; $err = ""; break }
    } catch { if (-not $err) { $err = "Tank report failed (" + $try[0] + "): " + $_.Exception.Message } }
  }
  try { Cgi $base @{ cmd = "logout"; cookie = $cookie } | Out-Null } catch {}
}

if ($tanks.Count) { Log ("Read " + $tanks.Count + " tank(s) via " + $how + ": " + (($tanks | ForEach-Object { $_[0] + " " + [math]::Round($_[1]) + " gal" }) -join ", ")) }
else { Log ("No reading: " + $err) }
$sent = Send-Reading $tanks $err $how

if ($Setup) {
  if ($tanks.Count) {
    try { Register-TankTask; $ok = $true } catch { $ok = $false; Log ("Couldn't create the scheduled task: " + $_.Exception.Message) }
    if ($ok) { Log "Scheduled: a quiet check every 5 minutes while this Windows user is signed in. Reads every 2 hours, or right away on Read now."; Write-Host ""; Write-Host "All set. The first reading is already in Store HQ (Store > Fuel)." }
  } else {
    Write-Host ""; Write-Host "The test reading didn't work, so nothing was scheduled. Store HQ has the reason; tell Claude."
  }
  Read-Host "Press Enter to close"
} else {
  Ensure-TankTask
  Update-Self
}
if ($tanks.Count) { exit 0 } else { exit 1 }
