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
  [string]$Fallback = "",             # address to try if none is found on the store network (the one Hik-Connect shows)
  [string]$Url = "https://closeout.petro-goldenrod.workers.dev",
  [switch]$Setup,
  [switch]$Poll
)
$ScriptVersion = 7
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

# ---- Quiet 5-minute check: pictures when someone asked for them, and clips for new voids / no-sales.
$ReqId = ""; $Jobs = $null
if ($Poll) {
  try { $q = Invoke-RestMethod -Uri "$Url/api/pc-camreq?store=$Store&v=$ScriptVersion" -Headers $H -TimeoutSec 30; if ($q.snap) { $ReqId = [string]$q.snap } } catch {}
  try { $Jobs = Invoke-RestMethod -Uri "$Url/api/pc-clipjobs?store=$Store&v=$ScriptVersion" -Headers $H -TimeoutSec 30 } catch {}
  if (-not $ReqId -and -not ($Jobs -and $Jobs.items -and @($Jobs.items).Count)) { exit 0 }
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
  $mine = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } | ForEach-Object { $_.IPAddress })
  # Also the register's network (from the VSPoll setup file) and the usual home-router networks.
  $nets = @(); foreach ($a in $mine) { $p = $a.Split('.'); $nets += ($p[0] + "." + $p[1] + "." + $p[2] + ".") }
  foreach ($d in (Get-ChildItem -Path "C:\VSPoll", "C:\VSPOLL2" -Directory -ErrorAction SilentlyContinue)) {
    foreach ($sf in (Get-ChildItem -Path $d.FullName -Filter "SETUP.*" -ErrorAction SilentlyContinue)) {
      $m = Select-String -Path $sf.FullName -Pattern '^\s*MachineName\s*=\s*(\d+\.\d+\.\d+)\.\d+' | Select-Object -First 1
      if ($m) { $nets += ($m.Matches[0].Groups[1].Value + ".") }
    }
  }
  $nets += @("192.168.1.", "192.168.0.", "192.168.254.", "10.0.0.")
  foreach ($net in ($nets | Select-Object -Unique)) {
    Write-Host ("Looking for the camera recorder on " + $net + "x ...")
    $jobs = @()
    foreach ($port in @(80, 801, 8080)) {
      for ($i = 1; $i -le 254; $i++) {
        $addr = $net + $i
        if ($mine -contains $addr) { continue }
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
    if ($found.Count -eq 0 -and $Fallback) {
      Write-Host ("Not on the store network; trying the recorder's internet address " + $Fallback + " ...")
      try { $req = [Net.HttpWebRequest]::Create("http://" + $Fallback + "/ISAPI/System/deviceInfo"); $req.Timeout = 8000; try { $r = $req.GetResponse(); $r.Close(); $found = @($Fallback) } catch [Net.WebException] { $r = $_.Exception.Response; if ($r -and [int]$r.StatusCode -eq 401) { $found = @($Fallback) } else { Log ("No answer from " + $Fallback + ": " + $_.Exception.Message) } } } catch {}
    }
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

# HTTP with Digest login over a plain socket. Needed because the recorder's download call is a GET that carries an XML body,
# which .NET's web classes refuse to send. Writes the answer body to $outFile; returns @{ code; type }.
function Md5Hex($t) { $m = [Security.Cryptography.MD5]::Create(); return ([BitConverter]::ToString($m.ComputeHash([Text.Encoding]::UTF8.GetBytes($t))) -replace "-", "").ToLower() }
function RawHttp($hostPort, $method, $path, $body, $auth, $outFile, [long]$cap = 0) {
  $hp = $hostPort.Split(':'); $h0 = $hp[0]; $port = if ($hp.Count -gt 1) { [int]$hp[1] } else { 80 }
  $cl = New-Object Net.Sockets.TcpClient; $cl.ReceiveTimeout = 60000; $cl.SendTimeout = 30000; $cl.Connect($h0, $port)
  try {
    $ns = $cl.GetStream(); $bb = [Text.Encoding]::UTF8.GetBytes([string]$body)
    $hd = "$method $path HTTP/1.1`r`nHost: $hostPort`r`nConnection: close`r`nContent-Type: application/xml`r`nContent-Length: " + $bb.Length + "`r`n"
    if ($auth) { $hd += "Authorization: " + $auth + "`r`n" }
    $hd += "`r`n"; $hb = [Text.Encoding]::ASCII.GetBytes($hd); $ns.Write($hb, 0, $hb.Length); if ($bb.Length) { $ns.Write($bb, 0, $bb.Length) }
    # headers
    $hdr = New-Object Text.StringBuilder; $last4 = ""
    while ($true) { $b = $ns.ReadByte(); if ($b -lt 0) { break }; [void]$hdr.Append([char]$b); $last4 = ($last4 + [char]$b); if ($last4.Length -gt 4) { $last4 = $last4.Substring($last4.Length - 4) }; if ($last4 -eq "`r`n`r`n") { break } }
    $ht = $hdr.ToString(); $code = 0; if ($ht -match '^HTTP/1\.[01] (\d+)') { $code = [int]$matches[1] }
    $type = if ($ht -match '(?im)^Content-Type:\s*([^\r\n;]+)') { $matches[1].Trim() } else { "" }
    $wa = if ($ht -match '(?im)^WWW-Authenticate:\s*Digest\s+([^\r\n]+)') { $matches[1] } else { "" }
    $chunked = $ht -match '(?im)^Transfer-Encoding:\s*chunked'
    $len = if ($ht -match '(?im)^Content-Length:\s*(\d+)') { [long]$matches[1] } else { -1 }
    $fs = [IO.File]::Create($outFile); $capped = $false
    try {
      $buf = New-Object byte[] 65536
      if ($chunked) {
        while ($true) {
          $line = ""; while ($true) { $b = $ns.ReadByte(); if ($b -lt 0) { break }; if ($b -eq 10) { break }; if ($b -ne 13) { $line += [char]$b } }
          $sz = [Convert]::ToInt64((($line -split ';')[0]).Trim(), 16); if ($sz -le 0) { break }
          $left = $sz; while ($left -gt 0) { $n = $ns.Read($buf, 0, [int][Math]::Min($buf.Length, $left)); if ($n -le 0) { break }; $fs.Write($buf, 0, $n); $left -= $n }
          if ($cap -gt 0 -and $fs.Length -ge $cap) { $capped = $true; break }
          [void]$ns.ReadByte(); [void]$ns.ReadByte()
        }
      } else {
        $left = $len; while ($left -ne 0) { $want = if ($left -lt 0) { $buf.Length } else { [int][Math]::Min($buf.Length, $left) }; $n = $ns.Read($buf, 0, $want); if ($n -le 0) { break }; $fs.Write($buf, 0, $n); if ($left -gt 0) { $left -= $n }; if ($cap -gt 0 -and $fs.Length -ge $cap) { $capped = $true; break } }
      }
    } finally { $fs.Close() }
    return @{ code = $code; type = $type; www = $wa; capped = $capped; len = $len }
  } finally { $cl.Close() }
}
function DigestHeader($www, $method, $path, $cred) {
  $p = @{}; foreach ($m in [regex]::Matches($www, '(\w+)="?([^",]*)"?')) { $p[$m.Groups[1].Value] = $m.Groups[2].Value }
  $nc = "00000001"; $cn = [Guid]::NewGuid().ToString("N").Substring(0, 16)
  $u = $cred.UserName; $pw = $cred.GetNetworkCredential().Password
  $ha1 = Md5Hex ($u + ":" + $p["realm"] + ":" + $pw); $ha2 = Md5Hex ($method + ":" + $path)
  if ($p["qop"]) { $resp = Md5Hex ($ha1 + ":" + $p["nonce"] + ":" + $nc + ":" + $cn + ":auth:" + $ha2); $q = ', qop=auth, nc=' + $nc + ', cnonce="' + $cn + '"' } else { $resp = Md5Hex ($ha1 + ":" + $p["nonce"] + ":" + $ha2); $q = "" }
  $pw = $null
  return 'Digest username="' + $u + '", realm="' + $p["realm"] + '", nonce="' + $p["nonce"] + '", uri="' + $path + '", response="' + $resp + '"' + $q + $(if ($p["opaque"]) { ', opaque="' + $p["opaque"] + '"' } else { "" })
}
function AuthedRaw($hostPort, $method, $path, $body, $cred, $outFile, [long]$cap = 0) {
  $r = RawHttp $hostPort $method $path $body $null $outFile $cap
  if ($r.code -eq 401 -and $r.www) { $r = RawHttp $hostPort $method $path $body (DigestHeader $r.www $method $path $cred) $outFile $cap }
  return $r
}
function RecPost($base, $path, $xml, $cred, [int]$timeout = 30) {
  $req = [Net.HttpWebRequest]::Create($base + $path); $req.Method = "POST"; $req.ContentType = "application/xml"
  $req.Credentials = $cred.GetNetworkCredential(); $req.Timeout = $timeout * 1000; $req.ReadWriteTimeout = $timeout * 1000
  $bb = [Text.Encoding]::UTF8.GetBytes($xml); $req.ContentLength = $bb.Length; $st = $req.GetRequestStream(); $st.Write($bb, 0, $bb.Length); $st.Close()
  $resp = $req.GetResponse(); try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); return $sr.ReadToEnd() } finally { $resp.Close() }
}
# ---- FFmpeg (free video tool, official Windows build linked from ffmpeg.org; the owner OK'd it on Nov 25, 2026).
# Downloaded once into this folder. It asks the recorder to play back just the seconds around a void (RTSP playback)
# and saves them as a normal MP4 a phone can play. Nothing else uses it.
function Get-FFmpeg {
  $ff = Join-Path $here "ffmpeg.exe"; if (Test-Path $ff) { return $ff }
  $mark = Join-Path $here "ffmpeg.try"
  if ((Test-Path $mark) -and ((Get-Date) - (Get-Item $mark).LastWriteTime).TotalHours -lt 6) { return "" }
  Set-Content -Path $mark -Value (Get-Date -Format s)
  $zip = Join-Path $env:TEMP "storehq-ffmpeg.zip"; $dir = Join-Path $env:TEMP "storehq-ffmpeg"
  try {
    Log "Downloading FFmpeg (one time, about 100 MB) for the void clips..."
    (New-Object Net.WebClient).DownloadFile("https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip", $zip)
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    $exe = Get-ChildItem -Path $dir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    if (-not $exe) { throw "ffmpeg.exe not found in the download" }
    Copy-Item $exe.FullName $ff -Force
    $v = & $ff -hide_banner -version 2>&1 | Select-Object -First 1
    Log ("FFmpeg ready: " + $v)
    return $ff
  } catch { Log ("FFmpeg download failed: " + $_.Exception.Message); return "" }
  finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue; Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
function Get-RtspPort($base, $cred) {
  $f = Join-Path $here "camread.rtsp"; if (Test-Path $f) { $p = (Get-Content $f -Raw).Trim(); if ($p -match '^\d+$') { return [int]$p } }
  $port = 554
  try {
    $x = [xml]([Text.Encoding]::UTF8.GetString((RecGet $base "/ISAPI/Security/adminAccesses" $cred 15).bytes))
    foreach ($n in $x.SelectNodes("//*[local-name()='AdminAccessProtocol']")) { if ([string]$n.SelectSingleNode("*[local-name()='protocol']").InnerText -match 'RTSP') { $port = [int]$n.SelectSingleNode("*[local-name()='portNo']").InnerText } }
  } catch {}
  Set-Content -Path $f -Value $port
  return $port
}
function Get-ClipRtsp($ff, $base, $ch, $date, $sec, [int]$before, [int]$after, $cred, $outFile) {
  $t = [datetime]::ParseExact($date + " " + $sec, "yyyy-MM-dd HH:mm:ss", $null)
  $a = $t.AddSeconds(-$before); $b = $t.AddSeconds($after); $len = $before + $after
  $hostOnly = (($base -replace '^https?://', '') -split ':')[0]; $port = Get-RtspPort $base $cred
  $nc = $cred.GetNetworkCredential(); $auth = [Uri]::EscapeDataString($nc.UserName) + ":" + [Uri]::EscapeDataString($nc.Password) + "@"
  $last = ""
  foreach ($track in @(([int]$ch * 100 + 2), ([int]$ch * 100 + 1))) {
    $raw = $outFile + ".raw.mp4"; Remove-Item $raw, $outFile -Force -ErrorAction SilentlyContinue
    $url = "rtsp://" + $auth + $hostOnly + ":" + $port + "/Streaming/tracks/" + $track + "?starttime=" + $a.ToString("yyyyMMddTHHmmss") + "Z&endtime=" + $b.ToString("yyyyMMddTHHmmss") + "Z"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $pi = New-Object Diagnostics.ProcessStartInfo; $pi.FileName = $ff; $pi.UseShellExecute = $false; $pi.CreateNoWindow = $true; $pi.RedirectStandardError = $true
    $pi.Arguments = '-hide_banner -loglevel error -rtsp_transport tcp -timeout 15000000 -i "' + $url + '" -t ' + $len + ' -an -c:v copy -movflags +faststart -y "' + $raw + '"'
    $pr = [Diagnostics.Process]::Start($pi); $errTask = $pr.StandardError.ReadToEndAsync()
    if (-not $pr.WaitForExit(($len + 60) * 1000)) { try { $pr.Kill() } catch {} }
    $nc = $null; $pi.Arguments = ""
    $err = ""; try { $err = [string]$errTask.Result } catch {}
    if ((Test-Path $raw) -and (Get-Item $raw).Length -gt 20000) {
      # iPhones play H.265 only when it's tagged hvc1, so check the codec and re-wrap when needed (no re-encoding).
      $info = (& $ff -hide_banner -i $raw 2>&1 | Out-String)
      if ($info -match 'Video: hevc') { & $ff -hide_banner -loglevel error -i $raw -c copy -tag:v hvc1 -movflags +faststart -y $outFile 2>&1 | Out-Null } else { Move-Item $raw $outFile -Force }
      Remove-Item $raw -Force -ErrorAction SilentlyContinue
      if ((Test-Path $outFile) -and (Get-Item $outFile).Length -gt 20000) { return @{ ok = $true; fmt = "mp4"; track = $track; mb = [Math]::Round((Get-Item $outFile).Length / 1MB, 1); secs = [Math]::Round($sw.Elapsed.TotalSeconds) } }
    }
    $e2 = (($err -replace '[\r\n]+', ' ') -replace 'rtsp://[^ ]*', 'rtsp://...').Trim()
    $last = "FFmpeg got no video (track $track, RTSP port $port)" + $(if ($e2) { ": " + $e2.Substring(0, [Math]::Min(120, $e2.Length)) } else { "" })
    Remove-Item $raw -Force -ErrorAction SilentlyContinue
  }
  return @{ ok = $false; err = $last }
}
# One clip: find the recording that covers the moment, then download just those seconds (sub-stream first, it's smaller).
function Get-Clip($base, $hostPort, $ch, $date, $sec, [int]$before, [int]$after, $cred, $outFile) {
  if ($script:FF) { $rr = Get-ClipRtsp $script:FF $base $ch $date $sec $before $after $cred $outFile; if ($rr.ok) { return $rr }; return $rr }
  $t = [datetime]::ParseExact($date + " " + $sec, "yyyy-MM-dd HH:mm:ss", $null)
  $a = $t.AddSeconds(-$before); $b = $t.AddSeconds($after)
  $last = ""
  foreach ($track in @(([int]$ch * 100 + 2), ([int]$ch * 100 + 1))) {
    $xml = '<?xml version="1.0" encoding="UTF-8"?><CMSearchDescription><searchID>' + [Guid]::NewGuid().ToString().ToUpper() + '</searchID><trackList><trackID>' + $track + '</trackID></trackList><timeSpanList><timeSpan><startTime>' + $a.ToString("yyyy-MM-ddTHH:mm:ssZ") + '</startTime><endTime>' + $b.ToString("yyyy-MM-ddTHH:mm:ssZ") + '</endTime></timeSpan></timeSpanList><maxResults>5</maxResults><searchResultPostion>0</searchResultPostion><metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList></CMSearchDescription>'
    try { $res = [xml](RecPost $base "/ISAPI/ContentMgmt/search" $xml $cred 30) } catch { continue }
    $uri = $res.SelectSingleNode("//*[local-name()='playbackURI']"); if (-not $uri) { continue }
    $pu = [string]$uri.InnerText
    $pu = $pu -replace 'starttime=[0-9TZ]+', ('starttime=' + $a.ToString("yyyyMMddTHHmmssZ")) -replace 'endtime=[0-9TZ]+', ('endtime=' + $b.ToString("yyyyMMddTHHmmssZ"))
    # name= and size= make some recorders send the whole recording file; without them they cut by the times.
    $pu = $pu -replace '&(amp;)?(name|size)=[^&]*', ''
    $why = ""
    $dl = '<?xml version="1.0" encoding="UTF-8"?><downloadRequest><playbackURI>' + [Security.SecurityElement]::Escape($pu) + '</playbackURI></downloadRequest>'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = AuthedRaw $hostPort "GET" "/ISAPI/ContentMgmt/download" $dl $cred $outFile 25MB
    $mb = [Math]::Round((Get-Item $outFile).Length / 1MB, 1)
    if ($r.capped) { $last = "The recorder sent more than 25 MB for a 25-second clip (whole recording, " + $(if ($r.len -gt 0) { [Math]::Round($r.len / 1MB) } else { "?" }) + " MB), track $track"; continue }
    if ($r.code -ne 200) { $last = "Recorder answered " + $r.code + " to the download (track $track)"; continue }
    if ($r.code -eq 200 -and (Get-Item $outFile).Length -gt 20000) {
      $fsx = [IO.File]::OpenRead($outFile); $hb = New-Object byte[] 12; [void]$fsx.Read($hb, 0, 12); $fsx.Close()
      $fmt = if ([Text.Encoding]::ASCII.GetString($hb, 4, 4) -eq "ftyp") { "mp4" } else { "ps" }
      return @{ ok = $true; fmt = $fmt; track = $track; mb = $mb; secs = [Math]::Round($sw.Elapsed.TotalSeconds) }
    }
  }
  return @{ ok = $false; err = $(if ($last) { $last } else { "No recording found for that moment" }) }
}
function Run-ClipJobs($jobs, $base, $hostPort, $cred) {
  $script:FF = Get-FFmpeg
  $done = 0; $clock = [Diagnostics.Stopwatch]::StartNew(); $n = 0
  foreach ($j in @($jobs.items)) {
    if ($n -ge 2 -or $clock.Elapsed.TotalMinutes -gt 4) { break }; $n++
    $f = Join-Path $env:TEMP ("storehq-clip-" + $j.key + ".bin")
    try {
      $r = Get-Clip $base $hostPort $jobs.ch $j.date $j.sec ([int]$j.before) ([int]$j.after) $cred $f
      if ($r.ok) {
        Invoke-RestMethod -Method Post -Uri ("$Url/api/clip-upload?store=$Store&key=" + [Uri]::EscapeDataString($j.key) + "&fmt=" + $r.fmt) -Headers $H -ContentType "application/octet-stream" -InFile $f -TimeoutSec 180 | Out-Null
        $done++; Log ("Clip " + $j.key + ": " + $r.mb + " MB " + $r.fmt + " in " + $r.secs + " s, sent")
      } else { Log ("Clip " + $j.key + ": " + $r.err); Invoke-RestMethod -Method Post -Uri ("$Url/api/clip-upload?store=$Store&key=" + [Uri]::EscapeDataString($j.key) + "&err=" + [Uri]::EscapeDataString($r.err.Substring(0, [Math]::Min(150, $r.err.Length)))) -Headers $H -TimeoutSec 30 | Out-Null }
    } catch { try { Invoke-RestMethod -Method Post -Uri ("$Url/api/clip-upload?store=$Store&key=" + [Uri]::EscapeDataString($j.key) + "&err=" + [Uri]::EscapeDataString(($_.Exception.Message).Substring(0, [Math]::Min(150, $_.Exception.Message.Length)))) -Headers $H -TimeoutSec 30 | Out-Null } catch {} }
    finally { Remove-Item $f -ErrorAction SilentlyContinue }
  }
  if (@($jobs.items).Count) { Log ("Clips: " + $done + " of " + @($jobs.items).Count + " uploaded.") }
}

# Self-update: Store HQ can hold a newer camera script (checked once a day, same checks as the other store PC scripts).
# The scheduled task: a check every 5 minutes, started through a tiny hidden launcher (wscript) so no window flashes on the screen.
function Register-CamTask {
  $ps = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
  $ws = Join-Path $env:WINDIR "System32\wscript.exe"
  $cmd = '"' + $ps + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Store ' + $Store + ' -Poll'
  if (Test-Path $ws) {
    $vbs = Join-Path $here "camread-quiet.vbs"
    Set-Content -Path $vbs -Encoding ASCII -Value ('CreateObject("WScript.Shell").Run "' + $cmd.Replace('"', '""') + '", 0, True')
    $act = New-ScheduledTaskAction -Execute $ws -Argument ('//B //Nologo "' + $vbs + '"') -WorkingDirectory $here
  } else {
    $act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Store ' + $Store + ' -Poll') -WorkingDirectory $here
  }
  $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::FromDays(3650))
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  $pri = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
  Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pri -Force | Out-Null
}
# Older versions started PowerShell directly, which flashed a window every 5 minutes. Switch this PC over once.
function Ensure-CamTask {
  try {
    if (-not (Test-Path (Join-Path $env:WINDIR "System32\wscript.exe"))) { return }
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t -and -not ($t.Actions | Where-Object { $_.Execute -match 'wscript' })) { Register-CamTask; Log "Camera task updated: it now runs without a window popping up." }
  } catch { Log ("Couldn't update the scheduled task: " + $_.Exception.Message) }
}
function Update-Self {
  $stamp = Join-Path $here "camread.updcheck"
  if ((Test-Path $stamp) -and ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalHours -lt 20) { return }
  try {
    Set-Content -Path $stamp -Value (Get-Date -Format s)
    $u = Invoke-RestMethod -Method Get -Uri "$Url/api/pc-script?store=$Store&name=camread" -Headers $H -TimeoutSec 60
    if ([int]$u.version -le $ScriptVersion) { return }
    $txt = [string]$u.script
    $hh = [Security.Cryptography.SHA256]::Create(); $got = ([BitConverter]::ToString($hh.ComputeHash([Text.Encoding]::UTF8.GetBytes($txt))) -replace "-", "").ToLower()
    $ptok = $null; $perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$ptok, [ref]$perr)
    if ($got -ne ([string]$u.sha256).ToLower() -or $txt -notmatch "# StoreHQ-camread" -or $txt -notmatch ('\$ScriptVersion = ' + [int]$u.version + '\b') -or ($perr -and $perr.Count)) { Log "Camera script update skipped: it didn't pass the checks."; return }
    Copy-Item -Path $PSCommandPath -Destination (Join-Path $here "camread.prev.ps1") -Force
    [IO.File]::WriteAllText($PSCommandPath, $txt, (New-Object Text.UTF8Encoding $false))
    Log ("Camera script updated from v$ScriptVersion to v$($u.version).")
  } catch {}
}
# ---- Read: camera list + one picture each
$base = ""; $err = ""; $model = ""
foreach ($b in @("http://$Recorder", "https://$Recorder")) {
  try { $r = RecGet $b "/ISAPI/System/deviceInfo" $cred 15; $base = $b; $x = [xml]([Text.Encoding]::UTF8.GetString($r.bytes)); $model = [string]$x.DeviceInfo.model + " " + [string]$x.DeviceInfo.deviceName; break }
  catch { $m = $_.Exception.Message; if ($m -match '401') { $err = "The recorder refused the login (wrong username or password). Run Setup cameras again and type it again." } elseif (-not $err) { $err = "Couldn't reach the recorder at $b : $m" } }
}
if ($Poll) { Ensure-CamTask; Update-Self }
if ($Poll -and $base -and $Jobs -and $Jobs.items -and @($Jobs.items).Count) { Run-ClipJobs $Jobs $base ($base -replace '^https?://', '') $cred }
if ($Poll -and -not $ReqId) { exit 0 }
$chans = @(); $snaps = @()
if ($base) {
  $err = ""
  # Hybrid recorders have both: analog cameras (Video inputs, channels 1..n) and IP cameras (InputProxy, often 33 and up).
  $seen = @{}
  foreach ($p in @("/ISAPI/System/Video/inputs/channels", "/ISAPI/ContentMgmt/InputProxy/channels")) {
    try {
      $x = [xml]([Text.Encoding]::UTF8.GetString((RecGet $base $p $cred 20).bytes))
      foreach ($n in $x.SelectNodes("//*[local-name()='InputProxyChannel' or local-name()='VideoInputChannel']")) {
        $id = [string]$n.SelectSingleNode("*[local-name()='id']").InnerText
        $en = $n.SelectSingleNode("*[local-name()='videoInputEnabled']"); if ($en -and [string]$en.InnerText -eq "false") { continue }
        $nm = $n.SelectSingleNode("*[local-name()='name']"); $nm = if ($nm -and [string]$nm.InnerText) { [string]$nm.InnerText } else { "Camera $id" }
        if ($id -and -not $seen[$id]) { $seen[$id] = 1; $chans += [ordered]@{ ch = $id; name = $nm; ok = $false; err = "" } }
      }
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
      Register-CamTask
      Log "Scheduled: a quiet check every 5 minutes; it only gets pictures when you tap Get fresh pictures in Store HQ."
      Write-Host ""; Write-Host "All set. The pictures are in Store HQ (Store > Cameras)."
    } catch { Log ("Couldn't create the scheduled task: " + $_.Exception.Message) }
  } else { Write-Host ""; Write-Host "No pictures came back, so nothing was scheduled. Store HQ has the reason; tell Claude." }
  Read-Host "Press Enter to close"
}
if (-not $Setup) { Update-Self }
if ($snaps.Count) { exit 0 } else { exit 1 }
