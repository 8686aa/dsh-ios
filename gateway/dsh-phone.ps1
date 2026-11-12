<#
  dsh-phone.ps1 - phone gateway for DeepSeek Harness.
  Gateway  : 0.0.0.0:8080  (every LAN adapter, one fixed access key, no token ever)
  Backend  : dsh web on 127.0.0.1:20202 (loopback only, auto started)

  Start   : powershell -ExecutionPolicy Bypass -File .\dsh-phone.ps1
  Restart : ... -Restart
  Stop    : ... -Stop
  Other   : ... -Port 9090
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$Restart,
    [switch]$Stop
)

$ErrorActionPreference = 'Continue'

$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$Node = "C:\Program Files\nodejs\node.exe"
$Proxy = Join-Path $PSScriptRoot 'dsh-phone-proxy.mjs'
$LogDir = Join-Path $DshHome 'logs'
$Log = Join-Path $LogDir "phone-gateway-$Port.log"
$ErrLog = "$Log.err"
$KeyFile = Join-Path $DshHome '.phone-key'
$Py = Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
$QrOut = Join-Path $PSScriptRoot 'qr.png'

foreach ($p in @($Node, $Proxy)) { if (-not (Test-Path -LiteralPath $p)) { throw "missing: $p" } }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Get-PortOwner([int]$p) {
    $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return [int]$c.OwningProcess }
    return 0
}

if ($Stop) {
    foreach ($p in @($Port, 20202)) {
        $o = Get-PortOwner $p
        if ($o) { Stop-Process -Id $o -Force -ErrorAction SilentlyContinue; "stopped pid $o on port $p" }
    }
    return
}

$owner = Get-PortOwner $Port
if ($owner -and $Restart) {
    foreach ($p in @($Port, 20202)) {
        $o = Get-PortOwner $p
        if ($o) { Stop-Process -Id $o -Force -ErrorAction SilentlyContinue; "killed pid $o on port $p" }
    }
    Start-Sleep -Milliseconds 900
} elseif ($owner) {
    "already running: gateway pid $owner on port $Port"
    $u = (Select-String -Path $Log -Pattern 'http://\S+:\d+/\?k=\S+' -ErrorAction SilentlyContinue | Select-Object -Last 1).Matches.Value
    if ($u) { "URL  = $u" }
    return
}

$ruleName = "dsh phone gateway $Port"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $Port -Profile Any -Description 'DeepSeek Harness phone gateway (LAN)' | Out-Null
}

if (Test-Path $Log) { Remove-Item $Log -Force -ErrorAction SilentlyContinue }
if (Test-Path $ErrLog) { Remove-Item $ErrLog -Force -ErrorAction SilentlyContinue }

$env:DSH_HOME = $DshHome
$env:DSH_PHONE_PORT = "$Port"
$proc = Start-Process -FilePath $Node -ArgumentList "`"$Proxy`"" -WorkingDirectory $PSScriptRoot `
        -RedirectStandardOutput $Log -RedirectStandardError $ErrLog -WindowStyle Hidden -PassThru
"launcher pid = $($proc.Id)"

$url = $null
$ErrorActionPreference = 'Continue'
for ($i = 0; $i -lt 180; $i++) {
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $Log)) { continue }
    $hit = Select-String -Path $Log -Pattern 'http://\S+:\d+/\?k=\S+' -ErrorAction SilentlyContinue |
           Where-Object { $_.Line -match 'WLAN|Wi-?Fi' } | Select-Object -Last 1
    if (-not $hit) {
        $hit = Select-String -Path $Log -Pattern 'http://\S+:\d+/\?k=\S+' -ErrorAction SilentlyContinue | Select-Object -Last 1
    }
    if ($hit) { $url = $hit.Matches.Value; break }
}

if (-not $url) {
    "gateway failed to start; log:"
    Get-Content $Log -Tail 50 -ErrorAction SilentlyContinue
    Get-Content $ErrLog -Tail 20 -ErrorAction SilentlyContinue
    return
}

$allUrls = (Select-String -Path $Log -Pattern 'http://\S+:\d+/\?k=\S+' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Matches.Value } | Select-Object -Unique)

$qrOk = $false
if (Test-Path $Py) {
    $pyCode = @'
import sys, qrcode
qrcode.make(sys.argv[1]).save(sys.argv[2])
print("qr-ok")
'@
    $pyFile = Join-Path $env:TEMP 'dsh-qr-gen.py'
    Set-Content -LiteralPath $pyFile -Value $pyCode -Encoding ASCII
    & $Py $pyFile $url $QrOut 2>$null | Out-Null
    $qrOk = Test-Path $QrOut
}

""
"URL    = $url"
$allUrls | Where-Object { $_ -ne $url } | ForEach-Object { "alt    = $_" }
"Key    = $(if (Test-Path $KeyFile) { (Get-Content $KeyFile -Raw).Trim() } else { '?' })"
"Gateway= 0.0.0.0:$Port   (pid $(Get-PortOwner $Port))"
"Backend= 127.0.0.1:20202 (pid $(Get-PortOwner 20202))"
"Log    = $Log"
if ($qrOk) { "QR     = $QrOut" } else { "QR     = n/a" }
try { Set-Clipboard -Value $url; "clipboard: URL copied" } catch { }
"Open the URL on your phone (same WiFi). No token needed; the access key cookie lasts 1 year."
