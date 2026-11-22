# Store HQ tank reading
# StoreHQ-tankread
# Every 6 hours: asks the Verifone register (Commander) for its current tank report, which it reads live from the
# Veeder-Root tank gauge, and sends gallons / room / water per tank to Store HQ. Read-only: it changes nothing on the
# register, in Sunray or in SSCS, and never sends prices.
#
# First time, on the store PC (in the same folder as vsupload.ps1 and token.txt):
#   double-click "Setup tank readings.bat"  (or: powershell -ExecutionPolicy Bypass -File tankread.ps1 -Setup)
# It asks for a register login (typed by the owner, saved encrypted for this Windows user only), tests one reading,
# and schedules it at 12 AM, 6 AM, 12 PM and 6 PM.
param(
  [string]$Store = "655675",          # Circle K store number (Goldenrod 655675, Trail 654287)
  [string]$Site = "011",              # VSPoll folder for this store (Goldenrod 011, Trail 004)
  [string]$Register = "",             # register IP; read from the VSPoll setup file when empty
  [string]$Url = "https://closeout.petro-goldenrod.workers.dev",
  [switch]$Setup
)
$ScriptVersion = 1
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $here "tankread.log"
$credFile = Join-Path $here "tankread.cred"
function Log($m) { $l = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $m; Add-Content -Path $log -Value $l; Write-Host $l }

$Token = ""; $tf = Join-Path $here "token.txt"; if (Test-Path $tf) { $Token = (Get-Content $tf -Raw).Trim() }
if (-not $Token) { Log "No upload token: put this script in the same folder as vsupload.ps1 and token.txt."; if ($Setup) { Read-Host "Press Enter to close" }; exit 1 }

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
  $body = [ordered]@{ version = $ScriptVersion; tanks = @($tanks); err = $err; how = $how } | ConvertTo-Json -Depth 5 -Compress
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
  $c = Get-Credential -Message "Register (Commander) login for tank readings"
  if (-not $c) { Log "Setup cancelled."; exit 1 }
  $c | Export-Clixml -Path $credFile
  Log "Register login saved for Windows user $env:USERNAME."
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
    $ps = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $tr = '"' + $ps + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Store ' + $Store + ' -Site ' + $Site
    schtasks /Create /F /TN "StoreHQ Tank Reading" /SC HOURLY /MO 6 /ST 00:00 /TR $tr | Out-Null
    if ($LASTEXITCODE -eq 0) { Log "Scheduled: every 6 hours (12 AM, 6 AM, 12 PM, 6 PM) while this Windows user is signed in." ; Write-Host ""; Write-Host "All set. The first reading is already in Store HQ (Sales page)." }
    else { Log "Couldn't create the scheduled task (schtasks exit $LASTEXITCODE)." }
  } else {
    Write-Host ""; Write-Host "The test reading didn't work, so nothing was scheduled. Store HQ has the reason; tell Claude."
  }
  Read-Host "Press Enter to close"
}
if ($tanks.Count) { exit 0 } else { exit 1 }
