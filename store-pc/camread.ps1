# Store HQ cameras
# StoreHQ-camread
# Reads pictures from the store's Hikvision recorder (NVR) over the store network and sends them to Store HQ:
# one fresh picture per camera when someone taps "Get fresh pictures" on Store > Cameras. Read-only: it never changes
# anything on the recorder, never records, and never opens the recorder to the internet.
#
# First time, on the store PC (in the same folder as vsupload.ps1 and token.txt):
#   double-click "Setup cameras.bat"
# It finds the recorder on the store network, asks for the recorder login (typed by the owner, saved encrypted for
# this Windows user only), sends a first set of pictures, and schedules a quiet check every 5 minutes.
param(
  [string]$Store = "655675",          # Goldenrod 655675, Trail 654287
  [string]$Recorder = "",             # recorder address (ip or ip:port); found automatically when empty
  [string]$Url = "https://closeout.petro-goldenrod.workers.dev",
  [switch]$Setup,
  [switch]$Poll
)
$ScriptVersion = 1
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $here "camread.log"
$credFile = Join-Path $here "camread.cred"
$cfgFile = Join-Path $here "camread.recorder"
function Log($m) { $l = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $m; Add-Content -Path $log -Value $l; Write-Host $l }

$Token = ""; $tf = Join-Path $here "token.txt"; if (Test-Path $tf) { $Token = (Get-Content $tf -Raw).Trim() }
if (-not $Token) { Log "No upload token: put this script in the same folder as vsupload.ps1 and token.txt."; if ($Setup) { Read-Host "Press Enter to close" }; exit 1 }
$H = @{ "x-import-token" = $Token }
$TaskName = "StoreHQ Cameras"

# Recorders often use their own (self-signed) certificate; accept it for the recorder's address only.
if (-not ("StoreHqCamCert" -as [type])) {
  Add-Type -TypeDefinition @"
using System; using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public static class StoreHqCamCert {
  public static string Host = "";
  public static bool Check(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) {
    if (e == SslPolicyErrors.None) return true;
    var r = s as HttpWebRequest; return r != null && r.RequestUri.Host == Host;
  }
  public static void Use(string host) { Host = host; ServicePointManager.ServerCertificateValidationCallback = Check; }
}
"@
}

# ---- Quiet 5-minute check: only works when someone asked for pictures.
$ReqId = ""
if ($Poll) {
  try { $q = Invoke-RestMethod -Uri "$Url/api/pc-camreq?store=$Store&v=$ScriptVersion" -Headers $H -TimeoutSec 30; if ($q.snap) { $ReqId = [string]$q.snap } } catch {}
  if (-not $ReqId) { exit 0 }
}

function Get-Cred {
  if (Test-Path $credFile) { return Import-Clixml -Path $credFile }
  return $null
}

# Plain HTTP GET with the recorder login (Hikvision uses Digest; .NET answers the challenge itself).
function RecGet($base, $path, $cred, [int]$timeout = 20) {
  $req = [Net.HttpWebRequest]::Create($base + $path)
  $req.Credentials = $cred.GetNetworkCredential()
  $req.PreAuthenticate = $false; $req.Timeout = $timeout * 1000; $req.ReadWriteTimeout = $timeout * 1000; $req.AllowAutoRedirect = $true
  $resp = $req.GetResponse()
  try { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); return @{ type = [string]$resp.ContentType; bytes = $ms.ToArray() } } finally { $resp.Close() }
}

# Find the recorder: the address saved at setup, else scan this PC's own network for a Hikvision web interface.
function Find-Recorder {
  $cands = @()
  $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' }
  foreach ($ip in $ips) {
    $p = $ip.IPAddress.Split('.'); $net = $p[0] + "." + $p[1] + "." + $p[2] + "."
    Write-Host ("Looking for the camera recorder on " + $net + "x ...")
    $jobs = @()
    foreach ($port in @(80, 801, 8080)) {
      for ($i = 1; $i -le 254; $i++) {
        $addr = $net + $i
        if ($addr -eq $ip.IPAddress) { continue }
        $c = New-Object Net.Sockets.TcpClient
        $jobs += [pscustomobject]@{ Addr = $addr; Port = $port; Client = $c; Task = $c.ConnectAsync($addr, $port) }
      }
    }
    Start-Sleep -Milliseconds 1500
    foreach ($j in $jobs) {
      if ($j.Task.IsCompleted -and -not $j.Task.IsFaulted -and $j.Client.Connected) { $cands += ($j.Addr + ":" + $j.Port) }
      try { $j.Client.Close() } catch {}
    }
  }
  $hits = @()
  foreach ($c in $cands) {
    try {
      $req = [Net.HttpWebRequest]::Create("http://" + $c + "/ISAPI/System/deviceInfo"); $req.Timeout = 3000
      try { $r = $req.GetResponse(); $r.Close() } catch [Net.WebException] {
        $r = $_.Exception.Response
        if ($r -and [int]$r.StatusCode -eq 401) { $hits += $c }
      }
    } catch {}
  }
  return $hits
}

function Shrink($bytes) {
  # Make pictures phone-friendly: at most 1280 px wide, JPEG quality 70.
  Add-Type -AssemblyName System.Drawing
  $ms = New-Object IO.MemoryStream(, $bytes); $img = [Drawing.Image]::FromStream($ms)
  $w = [Math]::Min(1280, $img.Width); $h = [int]($img.Height * $w / $img.Width)
  $bmp = New-Object Drawing.Bitmap($w, $h); $g = [Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic; $g.DrawImage($img, 0, 0, $w, $h)
  $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
  $ep = New-Object Drawing.Imaging.EncoderParameters(1); $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter([Drawing.Imaging.Encoder]::Quality, [long]70)
  $out = New-Object IO.MemoryStream; $bmp.Save($out, $enc, $ep)
  $g.Dispose(); $bmp.Dispose(); $img.Dispose()
  return [Convert]::ToBase64String($out.ToArray())
}

function Send($body) {
  $json = $body | ConvertTo-Json -Depth 6 -Compress
  Invoke-RestMethod -Method Post -Uri "$Url/api/cam-upload?store=$Store" -Headers $H -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 120 | Out-Null
}

# ---- Setup
if ($Setup) {
  Write-Host ""; Write-Host "Store HQ cameras - store $Store"
  if (-not $Recorder -and (Test-Path $cfgFile)) { $Recorder = (Get-Content $cfgFile -Raw).Trim() }
  $found = @()
  if (-not $Recorder) {
    $found = @(Find-Recorder)
    if ($found.Count -eq 0) { Log "Couldn't find a Hikvision recorder on this PC's network. Tell Claude (a photo of the recorder's Network screen helps)."; Read-Host "Press Enter to close"; exit 1 }
    Log ("Hikvision device(s) found: " + ($found -join ", "))
  }
  $keep = $false
  if (Test-Path $credFile) { $a = Read-Host "A recorder login is already saved. Press Enter to keep it, or type N to enter a new one"; $keep = ($a -notmatch '^\s*n') }
  if (-not $keep) {
    Write-Host "Type the RECORDER login (the one you use on the recorder's own screen, often 'admin'). It is saved encrypted on this PC only."
    $c = Get-Credential -Message "Hikvision recorder login for Store HQ cameras"
    if (-not $c) { Log "Setup cancelled."; exit 1 }
    $c | Export-Clixml -Path $credFile
    Log "Recorder login saved for Windows user $env:USERNAME."
  }
  if (-not $Recorder) {
    # Several Hikvision devices (cameras can show up too): use the one that says it's a recorder (NVR/DVR).
    $cr = Get-Cred; $best = ""; $first = ""
    foreach ($f in $found) {
      try {
        [StoreHqCamCert]::Use(($f -split ':')[0])
        $x = [xml]([Text.Encoding]::UTF8.GetString((RecGet ("http://" + $f) "/ISAPI/System/deviceInfo" $cr 10).bytes))
        if (-not $first) { $first = $f }
        if ([string]$x.DeviceInfo.deviceType -match 'VR' -or [string]$x.DeviceInfo.model -match '^(DS-)?\d*(NVR|DVR|[67]\d\d\dN|[67]\d\d\dH)' -or [string]$x.DeviceInfo.model -match 'NI|HUHI|HQHI|NXI|76|77|96') { $best = $f; break }
      } catch {}
    }
    $Recorder = if ($best) { $best } elseif ($first) { $first } else { $found[0] }
  }
  Log ("Recorder: " + $Recorder)
  Set-Content -Path $cfgFile -Value $Recorder
}

if (-not $Recorder -and (Test-Path $cfgFile)) { $Recorder = (Get-Content $cfgFile -Raw).Trim() }
$cred = Get-Cred
if (-not $Recorder -or -not $cred) { Log "Not set up yet: run 'Setup cameras.bat' once."; try { Send @{ version = $ScriptVersion; err = "Cameras aren't set up on the store PC yet (run Setup cameras once)"; req = $ReqId; channels = @(); snaps = @() } } catch {}; exit 1 }
[StoreHqCamCert]::Use(($Recorder -split ':')[0])

# ---- Read: camera list + one picture each
$base = ""; $err = ""; $model = ""
foreach ($b in @("http://$Recorder", "https://$Recorder")) {
  try { $r = RecGet $b "/ISAPI/System/deviceInfo" $cred 15; $base = $b; $x = [xml]([Text.Encoding]::UTF8.GetString($r.bytes)); $model = [string]$x.DeviceInfo.model + " " + [string]$x.DeviceInfo.deviceName; break }
  catch { $m = $_.Exception.Message; if ($m -match '401') { $err = "The recorder refused the login (wrong username or password). Run Setup cameras again and type it again." } elseif (-not $err) { $err = "Couldn't reach the recorder at $b : $m" } }
}
$chans = @(); $snaps = @()
if ($base) {
  $err = ""
  # NVR with IP cameras: InputProxy channels. Older/analog recorders: Video inputs.
  foreach ($p in @("/ISAPI/ContentMgmt/InputProxy/channels", "/ISAPI/System/Video/inputs/channels")) {
    try {
      $x = [xml]([Text.Encoding]::UTF8.GetString((RecGet $base $p $cred 20).bytes))
      foreach ($n in $x.SelectNodes("//*[local-name()='InputProxyChannel' or local-name()='VideoInputChannel']")) {
        $id = [string]$n.SelectSingleNode("*[local-name()='id']").InnerText
        $nm = $n.SelectSingleNode("*[local-name()='name']"); $nm = if ($nm) { [string]$nm.InnerText } else { "Camera $id" }
        if ($id) { $chans += [ordered]@{ ch = $id; name = $nm; ok = $false; err = "" } }
      }
      if ($chans.Count) { break }
    } catch {}
  }
  if (-not $chans.Count) { for ($i = 1; $i -le 16; $i++) { $chans += [ordered]@{ ch = [string]$i; name = "Camera $i"; ok = $false; err = "" } } }
  foreach ($c in $chans) {
    try {
      $pic = RecGet $base ("/ISAPI/Streaming/channels/" + $c.ch + "01/picture") $cred 25
      if ($pic.bytes.Length -lt 1000) { throw "empty picture" }
      $snaps += @{ ch = $c.ch; b64 = (Shrink $pic.bytes) }; $c.ok = $true
    } catch { $c.err = ($_.Exception.Message -replace '^Exception calling "GetResponse" with "0" argument\(s\): ', '').Trim('"') }
  }
  # Without a camera list, keep only the channels that answered.
  if (($chans | Where-Object { $_.ok }).Count -and -not ($chans | Where-Object { $_.name -notmatch '^Camera \d+$' })) { $chans = @($chans | Where-Object { $_.ok }) }
  if (-not $snaps.Count -and -not $err) { $err = "The recorder answered but gave no pictures." }
}
$sent = $false
try { Send @{ version = $ScriptVersion; recorder = $Recorder; model = $model.Trim(); err = $err; req = $ReqId; channels = @($chans); snaps = @($snaps) }; $sent = $true } catch { Log ("Upload to Store HQ failed: " + $_.Exception.Message) }
Log ("Pictures: " + $snaps.Count + " of " + $chans.Count + " camera(s)" + $(if ($err) { " - " + $err } else { "" }) + $(if ($sent) { " - sent to Store HQ" } else { "" }))

if ($Setup) {
  if ($snaps.Count) {
    try {
      $ps = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
      $act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Store ' + $Store + ' -Poll') -WorkingDirectory $here
      $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::FromDays(3650))
      $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
      $pri = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
      Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pri -Force | Out-Null
      Log "Scheduled: a quiet check every 5 minutes; it only gets pictures when you tap Get fresh pictures in Store HQ."
      Write-Host ""; Write-Host "All set. The pictures are in Store HQ (Store > Cameras)."
    } catch { Log ("Couldn't create the scheduled task: " + $_.Exception.Message) }
  } else { Write-Host ""; Write-Host "No pictures came back, so nothing was scheduled. Store HQ has the reason; tell Claude." }
  Read-Host "Press Enter to close"
}
if ($snaps.Count) { exit 0 } else { exit 1 }
