# Store HQ: send to registers
# StoreHQ-regsend
# Every 5 minutes: asks Store HQ whether the owner tapped "Send to registers". If so, runs SSCS VS-Poll with /SENDITEMS,
# the same thing the nightly poll does, which sends what is waiting in Sunray (prices, items) to the registers now.
# It never changes a price itself and never types a password; VS-Poll uses its own saved setup.
#
# First time, on the store PC (in the same folder as vsupload.ps1 and token.txt):
#   double-click "Setup send to registers.bat"
param(
  [string]$Store = "655675",          # Goldenrod 655675, Trail 654287
  [string]$Site = "011",              # VSPoll site folder (Goldenrod 011, Trail 004)
  [string]$Url = "https://closeout.petro-goldenrod.workers.dev",
  [switch]$Setup
)
$ScriptVersion = 1
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $here "regsend.log"
function Log($m) { $l = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $m; Add-Content -Path $log -Value $l; if ($Setup) { Write-Host $l } }
$Token = ""; $tf = Join-Path $here "token.txt"; if (Test-Path $tf) { $Token = (Get-Content $tf -Raw).Trim() }
if (-not $Token) { Log "No upload token: put this script in the same folder as vsupload.ps1 and token.txt."; if ($Setup) { Read-Host "Press Enter to close" }; exit 1 }
$H = @{ "x-import-token" = $Token }

# How VS-Poll is started on this PC: take the nightly scheduled task (or a VS-Poll shortcut) and swap /AUTO for /SENDITEMS.
function Find-VsPoll {
  $found = @()
  try {
    foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
      foreach ($a in $t.Actions) { if ($a.Execute -match 'vspoll') { $found += [pscustomobject]@{ Exe = $a.Execute.Trim('"'); Args = [string]$a.Arguments; Dir = [string]$a.WorkingDirectory; From = "scheduled task '" + $t.TaskName + "'" } } }
    }
  } catch {}
  if (-not $found) {
    $sh = New-Object -ComObject WScript.Shell
    foreach ($d in @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("CommonDesktopDirectory"), [Environment]::GetFolderPath("StartMenu"), [Environment]::GetFolderPath("CommonStartMenu"))) {
      if (-not $d -or -not (Test-Path $d)) { continue }
      foreach ($l in Get-ChildItem $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue) {
        try { $k = $sh.CreateShortcut($l.FullName); if ($k.TargetPath -match 'vspoll') { $found += [pscustomobject]@{ Exe = $k.TargetPath; Args = [string]$k.Arguments; Dir = [string]$k.WorkingDirectory; From = "shortcut '" + $l.Name + "'" } } } catch {}
      }
    }
  }
  # Prefer one that names this site.
  $pick = $found | Where-Object { $_.Args -match ("\b0*" + [int]$Site + "\b") } | Select-Object -First 1
  if (-not $pick) { $pick = $found | Select-Object -First 1 }
  if (-not $pick) { return $null }
  $args2 = $pick.Args
  if ($args2 -match '(?i)/AUTO\b') { $args2 = $args2 -replace '(?i)/AUTODIAL\b|/AUTO\b', '/SENDITEMS' }
  elseif ($args2 -notmatch '(?i)/SENDITEMS') { $args2 = ($args2 + " /SENDITEMS").Trim() }
  if (-not $pick.Dir) { $pick.Dir = Split-Path -Parent $pick.Exe }
  return [pscustomobject]@{ Exe = $pick.Exe; Args = $args2; Dir = $pick.Dir; From = $pick.From; Original = $pick.Args }
}

function Find-SiteLog { foreach ($d in @("C:\VSPoll\$Site", "C:\VSPOLL2\$Site")) { $f = Join-Path $d "VSPOLL.LOG"; if (Test-Path $f) { return $f } }; return $null }

if ($Setup) {
  Write-Host ""; Write-Host "Store HQ: send to registers - store $Store, site $Site"
  $vp = Find-VsPoll
  if (-not $vp) { Log "Couldn't find how VS-Poll is started on this PC (no scheduled task or shortcut for vspoll.exe). Nothing was set up. Tell Claude."; Read-Host "Press Enter to close"; exit 1 }
  Log ("Found VS-Poll in " + $vp.From + ": " + $vp.Exe + " " + $vp.Original)
  Log ("A send will run: " + $vp.Exe + " " + $vp.Args)
  try {
    $ps = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Store ' + $Store + ' -Site ' + $Site) -WorkingDirectory $here
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::FromDays(3650))
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 25)
    $pri = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
    Register-ScheduledTask -TaskName "StoreHQ Send To Registers" -Action $act -Trigger $trg -Settings $set -Principal $pri -Force | Out-Null
    Log "Scheduled: checks Store HQ every 5 minutes while this Windows user is signed in."
  } catch { Log ("Couldn't create the scheduled task: " + $_.Exception.Message); Read-Host "Press Enter to close"; exit 1 }
  try { Invoke-RestMethod -Uri "$Url/api/pc-regsend?store=$Store&v=$ScriptVersion" -Headers $H -TimeoutSec 30 | Out-Null; Log "Store HQ reached. The Send to registers button is ready." } catch { Log ("Couldn't reach Store HQ: " + $_.Exception.Message) }
  Write-Host ""; Read-Host "All set. Press Enter to close"; exit 0
}

# ---- Every 5 minutes
try { $r = Invoke-RestMethod -Uri "$Url/api/pc-regsend?store=$Store&v=$ScriptVersion" -Headers $H -TimeoutSec 30 } catch { exit 0 }
if (-not $r.send) { exit 0 }
$id = $r.send
function Report($ok, $msg) { Log $msg; try { Invoke-RestMethod -Method Post -Uri "$Url/api/pc-regsend?store=$Store" -Headers $H -ContentType "application/json" -Body (@{ id = $id; ok = $ok; log = $msg } | ConvertTo-Json -Compress) -TimeoutSec 30 | Out-Null } catch {} }

$vp = Find-VsPoll
if (-not $vp) { Report $false "Couldn't find how VS-Poll is started on this PC."; exit 1 }
# Wait for a VS-Poll that is already running (the nightly one) to finish, up to 10 minutes.
$t0 = Get-Date; while ((Get-Process -Name vspoll -ErrorAction SilentlyContinue) -and ((Get-Date) - $t0).TotalMinutes -lt 10) { Start-Sleep -Seconds 15 }
if (Get-Process -Name vspoll -ErrorAction SilentlyContinue) { Report $false "VS-Poll was already running for over 10 minutes; try again later."; exit 1 }

$lf = Find-SiteLog; $before = if ($lf) { (Get-Item $lf).Length } else { 0 }
Log ("Running " + $vp.Exe + " " + $vp.Args)
try {
  $p = Start-Process -FilePath $vp.Exe -ArgumentList $vp.Args -WorkingDirectory $vp.Dir -PassThru
  if (-not $p.WaitForExit(20 * 60 * 1000)) { Report $false "VS-Poll didn't finish within 20 minutes."; exit 1 }
} catch { Report $false ("Couldn't start VS-Poll: " + $_.Exception.Message); exit 1 }

$new = ""
if ($lf) { try { $fs = [IO.File]::Open($lf, 'Open', 'Read', 'ReadWrite'); $fs.Seek([Math]::Min($before, $fs.Length), 'Begin') | Out-Null; $sr = New-Object IO.StreamReader($fs); $new = $sr.ReadToEnd(); $sr.Close() } catch {} }
$lines = ($new -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { ($_ -replace '^\s*\d+\s+\w{3} \w{3}\s+\d+ [\d:]+ \d{4}\s+', '').Trim() })
$text = ($lines | Select-Object -Last 12) -join " / "
$bad = $lines | Where-Object { $_ -match '(?i)fail|error|unable|cannot|invalid' }
if ($bad) { Report $false ("VS-Poll reported a problem: " + (($bad | Select-Object -First 3) -join " / ")) }
elseif ($lines | Where-Object { $_ -match '(?i)successful|update cmd sent|finished' }) { Report $true ("Sent. " + $text) }
elseif (-not $lines) { Report $true "VS-Poll ran and finished (nothing new in its log, so there may have been nothing waiting in Sunray)." }
else { Report $true ("VS-Poll finished. " + $text) }
exit 0
