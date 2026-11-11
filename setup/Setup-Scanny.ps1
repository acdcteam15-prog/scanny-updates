<#
  Scanny (Android phone app) - Windows setup + rebuild wizard
  Windows PowerShell 5.1 compatible. Saved as UTF-8 with BOM.
  Started by START-SCANNY-PHONE.bat (menu) or Rebuild-APK.bat (one-click rebuild).
#>
param(
  [ValidateSet('menu', 'setup', 'rebuild', 'publish', 'health', 'output', 'reset', 'fixgoogle', 'crashlog', 'link', 'phone', 'github', 'lib')]
  [string]$Mode = 'menu'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ------------------------------------------------------------------ constants
$WizardVersion = '1.5.1'
$AppName = 'Scanny'
$WizardVersion = '1.5.1'
$Package = 'com.scanny.app'
$FirestoreRegion = 'eur3'   # Europe (multi-region). Dammam (me-central2) is retired. Override: set SCANNY_FIRESTORE_REGION (for example nam5 = United States)
if ($env:SCANNY_FIRESTORE_REGION) { $FirestoreRegion = $env:SCANNY_FIRESTORE_REGION }
$RegionPolicy = 'eu-v1'
$KeyAlias = 'scanny'
$DesugarLib = 'com.android.tools:desugar_jdk_libs:2.1.4'
$SdkPackages = @('platform-tools', 'platforms;android-36', 'build-tools;36.0.0')
$CmdlineToolsUrls = @(
  'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip',
  'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'
)
# Public OAuth client of firebase-tools (it is in the firebase-tools source code).
$FbClientId = '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com'
$FbClientSecret = 'j9iVZfS8kkCEFUPaAeJV0sAi'

$OnWindows = ($env:OS -eq 'Windows_NT')
$TestMode = ($env:SCANNY_TEST -eq '1')
$BundleRoot = Split-Path -Parent $PSScriptRoot
if ($env:SCANNY_WORK) { $Work = $env:SCANNY_WORK } else { $Work = 'C:\ScannyBuild' }
$AppDir = Join-Path $Work 'app'
$OutDir = Join-Path $Work 'Output'
$StatePath = Join-Path $Work 'state.json'
$LogPath = Join-Path $OutDir 'setup.log'
$FlutterDir = Join-Path $Work 'flutter'
$SdkDir = Join-Path $Work 'android-sdk'
$KeyDir = Join-Path $Work 'keystore'
$KeystorePath = Join-Path $KeyDir 'scanny-release.jks'
$BackupDir = Join-Path $OutDir 'keystore-backup'

if ($OnWindows) { $FirebaseExe = 'firebase.cmd'; $NpmExe = 'npm.cmd' } else { $FirebaseExe = 'firebase'; $NpmExe = 'npm' }

$Script:State = @{}
$Script:Project = ''
$Script:Account = ''
$Script:LastHint = ''
$Script:Answers = $null
if ($TestMode -and $env:SCANNY_ANSWERS) {
  $Script:Answers = New-Object System.Collections.Queue
  foreach ($a in ($env:SCANNY_ANSWERS -split '\|')) { $Script:Answers.Enqueue($a) }
}

# ------------------------------------------------------------------ output helpers
# Tokens and keys printed by tools (the Firebase CLI prints OAuth tokens) must never reach setup.log.
function Remove-Secrets([string]$s) {
  if (-not $s) { return $s }
  $s = [regex]::Replace($s, '("(?:access_token|refresh_token|id_token|client_secret|api_key|apiKey)"\s*:\s*")[^"]+', '$1<redacted>')
  $s = [regex]::Replace($s, 'ya29\.[A-Za-z0-9_\-\.]{20,}', '<redacted-token>')
  $s = [regex]::Replace($s, '1//[A-Za-z0-9_\-]{20,}', '<redacted-token>')
  $s = [regex]::Replace($s, 'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}', '<redacted-jwt>')
  $s = [regex]::Replace($s, 'AIza[0-9A-Za-z_\-]{30,}', '<redacted-key>')
  return $s
}
function Write-Log([string]$msg) {
  try {
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    Add-Content -Path $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 's'), (Remove-Secrets $msg))
  } catch { }
}
function Say([string]$m, [string]$color = 'Gray') { Write-Host $m -ForegroundColor $color; Write-Log $m }
function Ok([string]$m) { Say ('  [OK]  ' + $m) 'Green' }
function Warn([string]$m) { Say ('  [!]   ' + $m) 'Yellow' }
function Fail([string]$m) { Say ('  [X]   ' + $m) 'Red' }
function Info([string]$m) { Say ('        ' + $m) 'Gray' }
function Head([string]$m) { Say ''; Say ('=== ' + $m + ' ===') 'Cyan' }
function Wait-Sec([int]$s) { if ($TestMode) { return }; Start-Sleep -Seconds $s }

function Ask([string]$prompt) {
  if ($null -ne $Script:Answers) {
    if ($Script:Answers.Count -gt 0) {
      $a = [string]$Script:Answers.Dequeue()
      Write-Host ($prompt + ': ' + $a)
      Write-Log ('ASK ' + $prompt + ' -> ' + $a)
      return $a
    }
    throw ('TEST: no scripted answer for prompt: ' + $prompt)
  }
  $v = Read-Host $prompt
  if ($null -eq $v) { $v = '' }
  return $v
}

function Open-Url([string]$url) {
  Write-Log ('OPEN ' + $url)
  if ($OnWindows -and -not $TestMode) { try { Start-Process $url } catch { Warn ('Open this page yourself: ' + $url) } }
}

function New-RandomString([int]$len, [string]$chars) {
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  $bytes = New-Object byte[] $len
  $rng.GetBytes($bytes)
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
  return $sb.ToString()
}

function Write-TextFile([string]$path, [string]$text) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

# ------------------------------------------------------------------ state (PS 5.1: no -AsHashtable)
function ConvertTo-Hash($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
    return $h
  }
  if (($o -is [System.Collections.IEnumerable]) -and -not ($o -is [string])) {
    $l = @()
    foreach ($i in $o) { $l += , (ConvertTo-Hash $i) }
    return , $l
  }
  return $o
}

function Load-State {
  $Script:State = @{}
  if (Test-Path $StatePath) {
    try { $Script:State = ConvertTo-Hash (Get-Content -Raw -Path $StatePath | ConvertFrom-Json) }
    catch { Warn 'state.json could not be read - starting with fresh progress.'; $Script:State = @{} }
  }
  if ($null -eq $Script:State) { $Script:State = @{} }
  if (-not $Script:State.ContainsKey('done') -or -not ($Script:State['done'] -is [hashtable])) { $Script:State['done'] = @{} }
  if ($Script:State.ContainsKey('projectId') -and $Script:State['projectId']) { $Script:Project = [string]$Script:State['projectId'] }
}
function Save-State {
  if (-not (Test-Path $Work)) { New-Item -ItemType Directory -Force -Path $Work | Out-Null }
  Write-TextFile $StatePath ($Script:State | ConvertTo-Json -Depth 10)
}
function Get-St([string]$k) { if ($Script:State.ContainsKey($k)) { return $Script:State[$k] }; return $null }
function Set-St([string]$k, $v) { $Script:State[$k] = $v; Save-State }

# ------------------------------------------------------------------ native commands
function Add-NativeLine($item, $list, [bool]$stream) {
  if ($item -is [System.Management.Automation.ErrorRecord]) { $t = [string]$item.Exception.Message } else { $t = [string]$item }
  $t = $t -replace '\x1b\[[0-9;]*[A-Za-z]', ''
  if ($t -match '^\s*System\.Management\.Automation\.RemoteException\s*$') { return }
  $t = $t -replace 'System\.Management\.Automation\.RemoteException', ''
  $list.Add($t)
  if ($stream) { Write-Host $t }
  Write-Log ('  | ' + $t)
}

# firebase-tools (version 15) can finish the real work, print its normal result, and THEN fail with
# "Error: An unexpected error has occurred." (the real reason, "Timed out.", is only in firebase-debug.log).
# The work is done, so that tail must not count as a failure.
function Test-FirebaseLogTimedOut([string]$dir) {
  try {
    $log = Join-Path $dir 'firebase-debug.log'
    if (-not (Test-Path $log)) { return $false }
    $tail = @(Get-Content -Path $log -Tail 40 -ErrorAction SilentlyContinue)
    return [bool]($tail | Where-Object { $_ -match 'Timed out' })
  } catch { return $false }
}

# Returns the output WITHOUT the timeout tail when the rest looks like a normal success, else $null.
function Get-FirebaseCleanOutput([string[]]$lines, [string]$dir) {
  $txt = ($lines -join "`n")
  $timedOut = ($txt -match 'Timed out')
  if (-not $timedOut -and $txt -match 'An unexpected error has occurred') { $timedOut = (Test-FirebaseLogTimedOut $dir) }
  if (-not $timedOut) { return $null }
  $txt = [regex]::Replace($txt, '\{\s*"status"\s*:\s*"error"\s*,\s*"error"\s*:\s*"Timed out\.?"\s*\}', '')
  $keep = New-Object System.Collections.Generic.List[string]
  foreach ($l in ($txt -split "`n")) {
    if ($l -match 'Timed out|An unexpected error has occurred|From firebase-debug\.log|^\s*\[(debug|error)\]') { continue }
    if ($l.Trim().Length -eq 0) { continue }
    $keep.Add($l)
  }
  if ($keep.Count -eq 0) { return $null }
  if (($keep -join "`n") -match '(?i)\berror\b|failed|denied|not found|permission|credential|quota|already exists') { return $null }
  return ,$keep
}

# Usage reporting ("analytics") is a network call the Firebase CLI makes when a command ends. If it cannot finish,
# the command fails with "Timed out" after doing its work. Turn it off in the CLI's own settings file.
$Script:UsageOff = $false
function Disable-FirebaseUsageTracking {
  if ($Script:UsageOff) { return }
  $Script:UsageOff = $true
  try {
    $dir = Join-Path (Join-Path $HOME '.config') 'configstore'
    $cfg = Join-Path $dir 'firebase-tools.json'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if (-not (Test-Path $cfg)) { [IO.File]::WriteAllText($cfg, '{"usage": false}', $utf8); return }
    $t = [IO.File]::ReadAllText($cfg)
    if ($t -match '"usage"\s*:\s*false') { return }
    if ($t -match '"usage"\s*:\s*(true|false)') { $t = [regex]::Replace($t, '"usage"\s*:\s*(true|false)', '"usage": false', 1) }
    elseif ($t -match '^\s*\{\s*\}\s*$') { $t = '{"usage": false}' }
    else { $t = [regex]::Replace($t, '^\s*\{', '{ "usage": false,', 1) }
    [IO.File]::WriteAllText($cfg, $t, $utf8)
  } catch { }
}

function Invoke-Native {
  param([string]$Exe, [string[]]$ArgList = @(), [string]$Cwd = '', [switch]$Stream, [string]$InputText = '')
  if ($Exe -match 'firebase') { Disable-FirebaseUsageTracking }
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $lines = New-Object System.Collections.Generic.List[string]
  $code = -1
  $pushed = $false
  try {
    if ($Cwd) { Push-Location $Cwd; $pushed = $true }
    Write-Log ('RUN ' + $Exe + ' ' + ($ArgList -join ' '))
    $global:LASTEXITCODE = 0
    if ($InputText) {
      $InputText | & $Exe @ArgList 2>&1 | ForEach-Object { Add-NativeLine $_ $lines $Stream.IsPresent }
    } else {
      & $Exe @ArgList 2>&1 | ForEach-Object { Add-NativeLine $_ $lines $Stream.IsPresent }
    }
    $code = $global:LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
  } catch {
    $lines.Add([string]$_.Exception.Message)
    $code = 9009
  } finally {
    if ($pushed) { Pop-Location }
    $ErrorActionPreference = $old
  }
  Write-Log ('EXIT ' + $code)
  if ($code -ne 0 -and ($Exe -match 'firebase')) {
    $logDir = $Cwd
    if (-not $logDir) { $logDir = (Get-Location).Path }
    $clean = Get-FirebaseCleanOutput ($lines.ToArray()) $logDir
    if ($null -ne $clean) {
      Write-Log 'NOTE: firebase printed its result and then "Timed out" - treated as success.'
      $lines = $clean
      $code = 0
    }
  }
  return [pscustomobject]@{ Code = [int]$code; Out = ($lines -join "`n"); Lines = $lines.ToArray() }
}

function Invoke-Interactive([string]$Exe, [string[]]$ArgList) {
  if ($TestMode) { return (Invoke-Native $Exe $ArgList).Code }
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Exe @ArgList; return [int]$LASTEXITCODE } catch { return 9009 } finally { $ErrorActionPreference = $old }
}

function Have([string]$name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Get-BinPath([string]$dir, [string]$name, [string]$winExt) {
  $b = Join-Path $dir 'bin'
  if ($OnWindows) { return (Join-Path $b ($name + $winExt)) }
  return (Join-Path $b $name)
}

function Update-SessionPath {
  if (-not $OnWindows) { return }
  $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $u = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @()
  if ($env:JAVA_HOME) { $parts += (Join-Path $env:JAVA_HOME 'bin') }
  $parts += (Join-Path $FlutterDir 'bin')
  $parts += (Join-Path $SdkDir 'platform-tools')
  $parts += (Join-Path (Join-Path $SdkDir 'cmdline-tools') 'latest\bin')
  if ($env:APPDATA) { $parts += (Join-Path $env:APPDATA 'npm') }
  $parts += $m
  $parts += $u
  $env:Path = ($parts -join ';')
}

function Install-Winget([string]$Id) {
  if (-not (Have 'winget')) { throw ('winget is missing. Install "App Installer" from the Microsoft Store, then run START-SCANNY-PHONE again. (Needed for ' + $Id + ')') }
  Info ('Installing ' + $Id + ' with winget (a few minutes)...')
  $r = Invoke-Native 'winget' @('install', '--id', $Id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Stream
  Update-SessionPath
  return $r.Code
}

function Get-FlutterExe {
  $bat = Join-Path (Join-Path $FlutterDir 'bin') 'flutter.bat'
  if ($OnWindows -and (Test-Path $bat)) { return $bat }
  $sh = Join-Path (Join-Path $FlutterDir 'bin') 'flutter'
  if (-not $OnWindows -and (Test-Path $sh)) { return $sh }
  if (Have 'flutter') { return 'flutter' }
  return ''
}

# 3.47: first Flutter that can build with built-in Kotlin (no more "plugins that apply KGP" warning)
$MinFlutter = [version]'3.47.0'

function Get-FlutterVersion([string]$text) {
  $m = [regex]::Match($text, 'Flutter\s+(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return [version]('{0}.{1}.{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
}

function Test-FlutterVersion {
  $f = Get-FlutterExe
  if (-not $f) { return $false }
  $r = Invoke-Native $f @('--version')
  if ($r.Code -ne 0) { return $false }
  $v = Get-FlutterVersion $r.Out
  if ($null -eq $v) { return $false }
  if ($v -lt $MinFlutter) { $Script:LastHint = ('Flutter ' + $v + ' is older than ' + $MinFlutter + '.'); return $false }
  return $true
}

function Get-SdkManager {
  $b = Join-Path (Join-Path (Join-Path $SdkDir 'cmdline-tools') 'latest') 'bin'
  if ($OnWindows) { $p = Join-Path $b 'sdkmanager.bat' } else { $p = Join-Path $b 'sdkmanager' }
  if (Test-Path $p) { return $p }
  if (Have 'sdkmanager') { return 'sdkmanager' }
  return ''
}

function Get-Keytool {
  if ($env:JAVA_HOME) {
    $k = Get-BinPath $env:JAVA_HOME 'keytool' '.exe'
    if (Test-Path $k) { return $k }
  }
  if (Have 'keytool') { return 'keytool' }
  return ''
}

# ------------------------------------------------------------------ JSON / HTTP
function ConvertFrom-JsonLoose([string]$text) {
  if (-not $text) { return $null }
  $i = $text.IndexOf('{')
  $j = $text.LastIndexOf('}')
  if ($i -lt 0 -or $j -le $i) { return $null }
  try { return ($text.Substring($i, $j - $i + 1) | ConvertFrom-Json) } catch { return $null }
}

function New-HttpResult([int]$status, [string]$text) {
  $j = $null
  if ($text) { try { $j = $text | ConvertFrom-Json } catch { $j = $null } }
  return [pscustomobject]@{ Status = $status; Text = $text; Json = $j }
}

function Invoke-Http {
  param([string]$Method = 'GET', [string]$Uri, [hashtable]$Headers = @{}, $Body = $null, [hashtable]$Form = $null)
  Write-Log ('HTTP ' + $Method + ' ' + ($Uri -replace 'key=[^&]+', 'key=***'))
  if (Get-Command 'Mock-Http' -ErrorAction SilentlyContinue) {
    return (Mock-Http -Method $Method -Uri $Uri -Headers $Headers -Body $Body -Form $Form)
  }
  $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 90 }
  if ($null -ne $Form) { $p['Body'] = $Form; $p['ContentType'] = 'application/x-www-form-urlencoded' }
  elseif ($null -ne $Body) {
    $p['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
    $p['ContentType'] = 'application/json; charset=utf-8'
  }
  try {
    $resp = Invoke-WebRequest @p
    $content = $resp.Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    return (New-HttpResult ([int]$resp.StatusCode) ([string]$content))
  } catch {
    $er = $_
    $status = 0
    $txt = ''
    try { if ($er.Exception.Response) { $status = [int]$er.Exception.Response.StatusCode } } catch { }
    if ($er.ErrorDetails -and $er.ErrorDetails.Message) { $txt = $er.ErrorDetails.Message }
    elseif ($er.Exception.Response) {
      try { $sr = New-Object IO.StreamReader($er.Exception.Response.GetResponseStream()); $txt = $sr.ReadToEnd() } catch { }
    }
    if (-not $txt) { $txt = [string]$er.Exception.Message }
    return (New-HttpResult $status $txt)
  }
}

function Get-ApiError($r) {
  if ($null -eq $r) { return '' }
  if ($r.Json -and $r.Json.error) {
    if ($r.Json.error.message) { return [string]$r.Json.error.message }
    return [string]$r.Json.error
  }
  if ($r.Status -ge 400) { return [string]$r.Text }
  return ''
}

# ------------------------------------------------------------------ manual step (R / C / Q)
function Set-AuthUser([string]$url) {
  if (-not $url -or -not $Script:Account) { return $url }
  $u = [regex]::Replace($url, '[?&]authuser=[^&]*', '')
  if (-not $u.Contains('?') -and $u.Contains('&')) { $i = $u.IndexOf('&'); $u = $u.Substring(0, $i) + '?' + $u.Substring($i + 1) }
  $sep = '?'
  if ($u.Contains('?')) { $sep = '&' }
  return ($u + $sep + 'authuser=' + [uri]::EscapeDataString($Script:Account))
}

function Invoke-Manual {
  param([string]$Title, [string[]]$Steps, [string]$Url, [scriptblock]$Check)
  Head ('Manual step: ' + $Title)
  $Url = Set-AuthUser $Url
  if ($Url) { Info ('Opening: ' + $Url); Open-Url $Url }
  $n = 1
  foreach ($s in $Steps) { Say ('   {0}. {1}' -f $n, $s) 'White'; $n++ }
  Info ('The page opens with Google account: ' + $Script:Account + '. Wrong account, or the page says you have no access? Type A.')
  while ($true) {
    $a = ([string](Ask 'Press Enter when you have done this (A = sign in with another Google account)')).Trim().ToUpper()
    if ($a -ne 'A') { break }
    Switch-FirebaseAccount
    $Url = Set-AuthUser $Url
    if ($Url) { Info ('Opening again for ' + $Script:Account + ': ' + $Url); Open-Url $Url }
  }
  while ($true) {
    Info 'Checking...'
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $ok = $false }
    if ($ok) { Ok ($Title + ' - confirmed.'); return $true }
    Warn ($Title + ' - not detected yet (changes can take a minute to appear).')
    if ($Script:LastHint) { Info ('Detail: ' + $Script:LastHint) }
    $c = ([string](Ask 'R = re-check, A = another Google account, C = continue anyway, Q = quit')).Trim().ToUpper()
    if ($c -eq 'C') { Warn 'Continuing without confirmation.'; return $false }
    if ($c -eq 'Q') { throw 'USER_QUIT' }
    if ($c -eq 'A') {
      Switch-FirebaseAccount
      $Url = Set-AuthUser $Url
      if ($Url) { Info ('Opening again for ' + $Script:Account + ': ' + $Url); Open-Url $Url }
      continue
    }
    if ($c -ne 'R' -and $c -ne '') { $n = 1; foreach ($s in $Steps) { Say ('   {0}. {1}' -f $n, $s) 'White'; $n++ } }
    Wait-Sec 5
  }
}

# ------------------------------------------------------------------ step runner
function Invoke-Step($step) {
  $id = $step.Id
  Head $step.Title
  if ($step.Note) { Info $step.Note }
  $done = $Script:State['done']
  $ok = $false
  try { $ok = [bool](& $step.Check) } catch { $ok = $false }
  if ($done.ContainsKey($id) -and $done[$id]) {
    if ($ok) { Ok 'Already done (re-verified) - skipping.'; return }
    Warn 'Was done before, but the check fails now - repairing.'
  } elseif ($ok) {
    $done[$id] = $true; Save-State; Ok 'Already in place (verified).'; return
  }
  $null = & $step.Do
  $ok = $false
  try { $ok = [bool](& $step.Check) } catch { $ok = $false }
  if (-not $ok) { throw ('Step "' + $step.Title + '" could not be verified.' + $(if ($Script:LastHint) { ' ' + $Script:LastHint } else { '' })) }
  $done[$id] = $true
  Save-State
  Ok 'Done and verified.'
}

# ------------------------------------------------------------------ Gradle patches (pure text functions, unit-tested)
$SdkHookScript = @'
// scanny-sdk-hook: raises compileSdk to 36 for Flutter PLUGIN modules only (never :app).
// Applied from the root build.gradle(.kts). Safe to apply more than once.
subprojects { p ->
    if (p.name == 'app') return
    def raise = {
        def android = p.extensions.findByName('android')
        if (android == null) return
        try {
            int cur = 0
            if (android.hasProperty('compileSdk') && android.compileSdk != null) {
                cur = android.compileSdk as int
            } else if (android.hasProperty('compileSdkVersion') && android.compileSdkVersion != null) {
                def m = (android.compileSdkVersion.toString() =~ /(\d+)/)
                if (m.find()) cur = m.group(1) as int
            }
            if (cur < 36) {
                if (android.hasProperty('compileSdk')) { android.compileSdk = 36 } else { android.compileSdkVersion(36) }
                p.logger.lifecycle("scanny-sdk-hook: ${p.name} compileSdk ${cur} -> 36")
            }
        } catch (Throwable t) {
            p.logger.warn("scanny-sdk-hook: ${p.name}: ${t.message}")
        }
    }
    if (p.state.executed) { raise() } else { p.afterEvaluate { raise() } }
}
'@

function Update-AppGradleText([string]$text, [bool]$kts, [string]$pkg) {
  $t = $text -replace "`r`n", "`n"
  # applicationId
  if ($kts) { $t = [regex]::Replace($t, '(?m)^([ \t]*)applicationId\s*=?\s*["''][^"''\n]*["'']', ('${1}applicationId = "' + $pkg + '"')) }
  else { $t = [regex]::Replace($t, '(?m)^([ \t]*)applicationId\s*=?\s*["''][^"''\n]*["'']', ('${1}applicationId "' + $pkg + '"')) }
  # minSdk 23 (keep a higher literal number)
  $t = [regex]::Replace($t, '(?m)^([ \t]*)minSdk(?:Version)?\b[^\n]*$', {
      param($m)
      $line = $m.Value
      $num = [regex]::Match($line, '\b(\d+)\s*$')
      if ($num.Success -and [int]$num.Groups[1].Value -ge 23) { return $line }
      if ($kts) { return ($m.Groups[1].Value + 'minSdk = 23') }
      return ($m.Groups[1].Value + 'minSdkVersion 23')
    })
  # core library desugaring flag
  if ($t -notmatch 'oreLibraryDesugaringEnabled') {
    if ($kts) { $flag = 'isCoreLibraryDesugaringEnabled = true' } else { $flag = 'coreLibraryDesugaringEnabled true' }
    $rx = New-Object regex '(?m)^([ \t]*)compileOptions\s*\{[ \t]*$'
    if ($rx.IsMatch($t)) {
      $t = $rx.Replace($t, { param($m) $m.Value + "`n" + $m.Groups[1].Value + '    ' + $flag }, 1)
    } else {
      $rxA = New-Object regex '(?m)^android\s*\{[ \t]*$'
      $t = $rxA.Replace($t, { param($m) $m.Value + "`n    compileOptions {`n        " + $flag + "`n    }" }, 1)
    }
  }
  # desugaring dependency
  if ($t -notmatch [regex]::Escape('desugar_jdk_libs')) {
    if ($kts) { $dep = '    coreLibraryDesugaring("' + $DesugarLib + '")' } else { $dep = "    coreLibraryDesugaring '" + $DesugarLib + "'" }
    $rxD = New-Object regex '(?m)^dependencies\s*\{[ \t]*$'
    if ($rxD.IsMatch($t)) { $t = $rxD.Replace($t, { param($m) $m.Value + "`n" + $dep }, 1) }
    else { $t = $t.TrimEnd() + "`n`ndependencies {`n" + $dep + "`n}`n" }
  }
  # release signing (reads android/key.properties)
  # kts: inside android { } the name `java` means Gradle's Java extension, so use imports
  if ($kts) {
    foreach ($imp in @('import java.io.FileInputStream', 'import java.util.Properties')) {
      if ($t -notmatch ('(?m)^' + [regex]::Escape($imp) + '\s*$')) { $t = $imp + "`n" + $t }
    }
  }
  # older wizard versions wrote a block that does not compile - remove it so it is rewritten
  $t = [regex]::Replace($t, '(?s)[ \t]*// scanny-signing-begin.*?// scanny-signing-end[ \t]*\n?', '')
  if ($t -notmatch 'scanny-signing-begin') {
    if ($kts) {
      $block = @'
    // scanny-signing-begin
    signingConfigs {
        create("release") {
            val kp = Properties()
            val kf = rootProject.file("key.properties")
            if (kf.exists()) { FileInputStream(kf).use { stream -> kp.load(stream) } }
            keyAlias = kp.getProperty("keyAlias")
            keyPassword = kp.getProperty("keyPassword")
            val sf: String? = kp.getProperty("storeFile")
            if (sf != null) { storeFile = file(sf) }
            storePassword = kp.getProperty("storePassword")
        }
    }
    // scanny-signing-end
'@
    } else {
      $block = @'
    // scanny-signing-begin
    signingConfigs {
        release {
            def kp = new Properties()
            def kf = rootProject.file('key.properties')
            if (kf.exists()) { kf.withInputStream { kp.load(it) } }
            keyAlias kp['keyAlias']
            keyPassword kp['keyPassword']
            storeFile kp['storeFile'] ? file(kp['storeFile']) : null
            storePassword kp['storePassword']
        }
    }
    // scanny-signing-end
'@
    }
    $block = $block -replace "`r`n", "`n"
    $rxB = New-Object regex '(?m)^[ \t]*buildTypes\s*\{'
    if ($rxB.IsMatch($t)) { $t = $rxB.Replace($t, { param($m) $block + "`n" + $m.Value }, 1) }
  }
  if ($kts) { $t = [regex]::Replace($t, 'signingConfig\s*=\s*signingConfigs\.getByName\(\s*"debug"\s*\)', 'signingConfig = signingConfigs.getByName("release")') }
  else { $t = [regex]::Replace($t, 'signingConfig\s+signingConfigs\.debug\b', 'signingConfig signingConfigs.release') }
  # R8 code shrinking stripped WorkManager's database class -> app crashed at start. Keep everything.
  if ($t -notmatch 'scanny-noshrink') {
    if ($kts) {
      $ns = "`n// scanny-noshrink: R8 removed classes WorkManager needs (crash at start), so shrinking is off`nandroid {`n    buildTypes {`n        getByName(`"release`") {`n            isMinifyEnabled = false`n            isShrinkResources = false`n        }`n    }`n}`n"
    } else {
      $ns = "`n// scanny-noshrink: R8 removed classes WorkManager needs (crash at start), so shrinking is off`nandroid {`n    buildTypes {`n        release {`n            minifyEnabled false`n            shrinkResources false`n        }`n    }`n}`n"
    }
    $t = $t.TrimEnd() + "`n" + $ns
  }
  return $t
}

function Test-AppGradleText([string]$text, [bool]$kts, [string]$pkg) {
  $t = $text -replace "`r`n", "`n"
  if ($t -notmatch ('applicationId\s*=?\s*"' + [regex]::Escape($pkg) + '"')) { return $false }
  $mins = [regex]::Matches($t, '(?m)^[ \t]*minSdk(?:Version)?\s*=?\s*(\d+)\s*$')
  if ($mins.Count -lt 1) { return $false }
  foreach ($mm in $mins) { if ([int]$mm.Groups[1].Value -lt 23) { return $false } }
  if ($kts) { if ($t -notmatch 'isCoreLibraryDesugaringEnabled\s*=\s*true') { return $false } }
  else { if ($t -notmatch 'coreLibraryDesugaringEnabled\s*=?\s*true') { return $false } }
  if ($t -notmatch 'coreLibraryDesugaring\s*\(?\s*["'']com\.android\.tools:desugar_jdk_libs') { return $false }
  if ($t -notmatch 'scanny-signing-begin') { return $false }
  if ($kts) { if ($t -notmatch 'signingConfig\s*=\s*signingConfigs\.getByName\("release"\)') { return $false } }
  if ($kts) {
    if ($t -notmatch '(?m)^import java\.util\.Properties\s*$' -or $t -notmatch '(?m)^import java\.io\.FileInputStream\s*$') { return $false }
    if ($t -match 'java\.util\.Properties\(\)|java\.io\.FileInputStream\(') { return $false }
  }
  else { if ($t -notmatch 'signingConfig\s+signingConfigs\.release') { return $false } }
  if ([regex]::Matches($t, 'scanny-signing-begin').Count -ne 1) { return $false }
  if ([regex]::Matches($t, 'scanny-noshrink').Count -ne 1) { return $false }
  return $true
}

function Update-RootGradleText([string]$text, [bool]$kts) {
  $t = $text -replace "`r`n", "`n"
  if ($t -match 'scanny-sdk-hook\.gradle') { return $t }
  if ($kts) { $line = 'apply(from = "scanny-sdk-hook.gradle")' } else { $line = "apply from: 'scanny-sdk-hook.gradle'" }
  return ($t.TrimEnd() + "`n`n// scanny: raise compileSdk of plugin modules`n" + $line + "`n")
}

function Test-RootGradleText([string]$text) {
  return ([regex]::Matches($text, 'scanny-sdk-hook\.gradle').Count -eq 1)
}

$ManifestPermissions = @('android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE', 'android.permission.POST_NOTIFICATIONS', 'android.permission.VIBRATE', 'android.permission.RECEIVE_BOOT_COMPLETED', 'android.permission.WAKE_LOCK', 'android.permission.USE_BIOMETRIC', 'android.permission.REQUEST_INSTALL_PACKAGES', 'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_DATA_SYNC', 'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS')

$BlockedPermissions = @('android.permission.READ_SMS', 'android.permission.RECEIVE_SMS')

function Update-ManifestText([string]$text) {
  $t = $text -replace "`r`n", "`n"
  # Play Protect blocks sideloaded apps that request SMS access - remove it (older wizard added it)
  foreach ($bp in $BlockedPermissions) {
    $t = [regex]::Replace($t, '(?m)^[ \t]*<uses-permission\s+android:name="' + [regex]::Escape($bp) + '"\s*/>[ \t]*\n?', '')
  }
  # proper app name under the icon
  $t = [regex]::Replace($t, 'android:label="scanny"', 'android:label="Scanny"')
  # our Application class (crash screen) + round icon
  $t = $t.Replace('android:name="${applicationName}"', 'android:name=".ScannyApp"')
  if ($t -notmatch 'android:roundIcon=') {
    $t = [regex]::Replace($t, '(?m)^([ \t]*)android:icon="@mipmap/ic_launcher"', ('${1}android:icon="@mipmap/ic_launcher"' + "`n" + '${1}android:roundIcon="@mipmap/ic_launcher_round"'), 1)
  }
  if ($t -notmatch 'scanny-crash-activity') {
    $ca = @(
      '        <!-- scanny-crash-activity -->',
      '        <activity android:name=".CrashActivity" android:process=":crash" android:exported="false"',
      '            android:theme="@android:style/Theme.DeviceDefault.NoActionBar" />') -join "`n"
    $rc = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $rc.Replace($t, { param($m) $ca + "`n" + $m.Value }, 1)
  }
  foreach ($perm in $ManifestPermissions) {
    if ($t -match ('android:name="' + [regex]::Escape($perm) + '"')) { continue }
    $rx = New-Object regex '(?m)^([ \t]*)<application\b'
    if ($rx.IsMatch($t)) {
      $t = $rx.Replace($t, { param($m) $m.Groups[1].Value + '<uses-permission android:name="' + $perm + '"/>' + "`n" + $m.Value }, 1)
    }
  }
  # speech_to_text: Android 11+ must be allowed to see the speech recognition service
  if ($t -notmatch 'android\.speech\.RecognitionService') {
    $intent = '        <intent>' + "`n" + '            <action android:name="android.speech.RecognitionService"/>' + "`n" + '        </intent>'
    $rq = New-Object regex '(?m)^([ \t]*)<queries>[ \t]*$'
    if ($rq.IsMatch($t)) { $t = $rq.Replace($t, { param($m) $m.Value + "`n" + $intent }, 1) }
    else { $t = $t -replace '</manifest>', ('    <queries>' + "`n" + $intent + "`n" + '    </queries>' + "`n" + '</manifest>') }
  }
  # flutter_tts: Android 11+ must be allowed to see the text-to-speech engines
  if ($t -notmatch 'android\.intent\.action\.TTS_SERVICE') {
    $ttsIntent = '        <intent>' + "`n" + '            <action android:name="android.intent.action.TTS_SERVICE"/>' + "`n" + '        </intent>'
    $rq2 = New-Object regex '(?m)^([ \t]*)<queries>[ \t]*$'
    if ($rq2.IsMatch($t)) { $t = $rq2.Replace($t, { param($m) $m.Value + "`n" + $ttsIntent }, 1) }
    else { $t = $t -replace '</manifest>', ('    <queries>' + "`n" + $ttsIntent + "`n" + '    </queries>' + "`n" + '</manifest>') }
  }
  # scheduled notifications (daily reminder) need these receivers
  if ($t -notmatch 'scanny-notification-receivers') {
    $nr = @(
      '        <!-- scanny-notification-receivers -->',
      '        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />',
      '        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">',
      '            <intent-filter>',
      '                <action android:name="android.intent.action.BOOT_COMPLETED"/>',
      '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>',
      '                <action android:name="android.intent.action.QUICKBOOT_POWERON" />',
      '                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>',
      '            </intent-filter>',
      '        </receiver>') -join "`n"
    $rb = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $rb.Replace($t, { param($m) $nr + "`n" + $m.Value }, 1)
  }
  # home-screen widget receiver
  if ($t -notmatch 'scanny-widget-receiver') {
    $recv = @(
      '        <!-- scanny-widget-receiver -->',
      '        <receiver android:name=".ScannyWidget" android:label="Scanny alerts" android:exported="false">',
      '            <intent-filter>',
      '                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>',
      '            </intent-filter>',
      '            <meta-data android:name="android.appwidget.provider" android:resource="@xml/scanny_widget_info"/>',
      '        </receiver>') -join "`n"
    $ra = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $ra.Replace($t, { param($m) $recv + "`n" + $m.Value }, 1)
  }
  # in-app updates: the downloaded APK is shared with the Android installer through this provider
  if ($t -notmatch 'scanny-file-provider') {
    $fp = @(
      '        <!-- scanny-file-provider -->',
      '        <provider android:name=".ScannyFileProvider" android:authorities="${applicationId}.scannyfiles"',
      '            android:exported="false" android:grantUriPermissions="true">',
      '            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/scanny_file_paths"/>',
      '        </provider>') -join "`n"
    $rfp = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $rfp.Replace($t, { param($m) $fp + "`n" + $m.Value }, 1)
  }
  # update download keeps running with the screen off: foreground service of flutter_local_notifications
  if ($t -notmatch 'scanny-update-service') {
    $us = @(
      '        <!-- scanny-update-service -->',
      '        <service android:name="com.dexterous.flutterlocalnotifications.ForegroundService"',
      '            android:exported="false" android:stopWithTask="false" android:foregroundServiceType="dataSync"/>') -join "`n"
    $ru = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $ru.Replace($t, { param($m) $us + "`n" + $m.Value }, 1)
  }
  # shopping-list widget receiver
  if ($t -notmatch 'scanny-shopping-widget-receiver') {
    $recv2 = @(
      '        <!-- scanny-shopping-widget-receiver -->',
      '        <receiver android:name=".ScannyShoppingWidget" android:label="Scanny top findings" android:exported="false">',
      '            <intent-filter>',
      '                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>',
      '            </intent-filter>',
      '            <meta-data android:name="android.appwidget.provider" android:resource="@xml/scanny_shopping_widget_info"/>',
      '        </receiver>') -join "`n"
    $rc = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $rc.Replace($t, { param($m) $recv2 + "`n" + $m.Value }, 1)
  }
  return $t
}

function Test-ManifestText([string]$text) {
  if ($text -notmatch 'android:name="\.ScannyApp"') { return $false }
  if ([regex]::Matches($text, 'scanny-crash-activity').Count -ne 1) { return $false }
  if ($text -notmatch 'android:roundIcon="@mipmap/ic_launcher_round"') { return $false }
  foreach ($bp in $BlockedPermissions) { if ($text -match [regex]::Escape($bp)) { return $false } }
  if ([regex]::Matches($text, 'android\.speech\.RecognitionService').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'android\.intent\.action\.TTS_SERVICE').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'scanny-widget-receiver').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'scanny-shopping-widget-receiver').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'scanny-file-provider').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'scanny-update-service').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'scanny-notification-receivers').Count -ne 1) { return $false }
  if ($text -notmatch 'ScheduledNotificationBootReceiver') { return $false }
  if ($text -notmatch '<receiver android:name="\.ScannyWidget"') { return $false }
  foreach ($perm in $ManifestPermissions) {
    if ([regex]::Matches($text, ('<uses-permission\s+android:name="' + [regex]::Escape($perm) + '"')).Count -ne 1) { return $false }
  }
  return $true
}

function Get-ManifestPath {
  $src = Join-Path (Join-Path (Join-Path $AppDir 'android') 'app') 'src'
  return (Join-Path (Join-Path $src 'main') 'AndroidManifest.xml')
}

# ------------------------------------------------------------------ home-screen widget (native Android part)
$WidgetKotlin = @'
// scanny-widget: generated by the setup wizard. Shows "left this week" and a + button.
package {PKG}

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

class ScannyWidget : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.scanny_widget).apply {
                setTextViewText(R.id.widget_label, widgetData.getString("label", "Scanny"))
                setTextViewText(R.id.widget_value, widgetData.getString("left", "-"))
                setTextViewText(R.id.widget_sub, widgetData.getString("sub", ""))
                setOnClickPendingIntent(R.id.widget_root, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java))
                setOnClickPendingIntent(R.id.widget_add, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("scanny://open")))
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
'@

$WidgetLayout = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- scanny-widget -->
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/widget_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@drawable/scanny_widget_bg"
    android:gravity="center_vertical"
    android:orientation="horizontal"
    android:padding="14dp">
    <LinearLayout
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:layout_weight="1"
        android:orientation="vertical">
        <TextView android:id="@+id/widget_label" android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:textColor="#DDFFFFFF" android:textSize="13sp" android:text="Scanny" />
        <TextView android:id="@+id/widget_value" android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:textColor="#FFFFFFFF" android:textSize="24sp" android:textStyle="bold" android:text="-" />
        <TextView android:id="@+id/widget_sub" android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:textColor="#BBFFFFFF" android:textSize="12sp" />
    </LinearLayout>
    <TextView android:id="@+id/widget_add" android:layout_width="52dp" android:layout_height="52dp"
        android:background="@drawable/scanny_widget_btn" android:gravity="center" android:text="&#8250;"
        android:textColor="#FF3F4FD8" android:textSize="30sp" android:contentDescription="Open Scanny" />
</LinearLayout>
'@

$WidgetBg = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- scanny-widget -->
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:angle="45" android:startColor="#FF1B2559" android:endColor="#FF4256FF" />
    <corners android:radius="24dp" />
</shape>
'@

$WidgetBtn = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- scanny-widget -->
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="oval">
    <solid android:color="#FFFFFFFF" />
</shape>
'@

$WidgetInfo = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- scanny-widget -->
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:initialLayout="@layout/scanny_widget"
    android:minWidth="180dp"
    android:minHeight="70dp"
    android:targetCellWidth="3"
    android:targetCellHeight="1"
    android:resizeMode="horizontal|vertical"
    android:updatePeriodMillis="0"
    android:widgetCategory="home_screen" />
'@

$ShopWidgetKotlin = @'
// scanny-shopping-widget: generated by the setup wizard. Shows the open shopping items.
package {PKG}

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

class ScannyShoppingWidget : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.scanny_shopping_widget).apply {
                setTextViewText(R.id.shop_label, widgetData.getString("shop_label", "Top findings"))
                setTextViewText(R.id.shop_count, widgetData.getString("shop_count", ""))
                setTextViewText(R.id.shop_items, widgetData.getString("shop_items", ""))
                setOnClickPendingIntent(R.id.shop_root, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java))
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
'@

$ShopWidgetLayout = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- scanny-shopping-widget -->
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/shop_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@drawable/scanny_widget_bg"
    android:orientation="vertical"
    android:padding="14dp">
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:gravity="center_vertical"
        android:orientation="horizontal">
        <TextView android:id="@+id/shop_label" android:layout_width="0dp" android:layout_height="wrap_content"
            android:layout_weight="1" android:textColor="#DDFFFFFF" android:textSize="13sp" android:text="Top findings" />
        <TextView android:id="@+id/shop_count" android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:textColor="#FFFFFFFF" android:textSize="22sp" android:textStyle="bold" />
    </LinearLayout>
    <TextView android:id="@+id/shop_items" android:layout_width="match_parent" android:layout_height="wrap_content"
        android:layout_marginTop="6dp" android:ellipsize="end" android:maxLines="7"
        android:textColor="#FFFFFFFF" android:textSize="13sp" />
</LinearLayout>
'@

$ShopWidgetInfo = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- scanny-shopping-widget -->
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:initialLayout="@layout/scanny_shopping_widget"
    android:minWidth="180dp"
    android:minHeight="110dp"
    android:targetCellWidth="3"
    android:targetCellHeight="2"
    android:resizeMode="horizontal|vertical"
    android:updatePeriodMillis="0"
    android:widgetCategory="home_screen" />
'@

$MainActivityKotlin = @'
// scanny-main-activity: generated by the setup wizard (do not edit).
// FlutterFragmentActivity is required by local_auth (fingerprint lock).
package {PKG}

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    // Held only while an update is downloading (the screen may be off). Released at once when the download ends.
    private var cpuLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    @Suppress("DEPRECATION")
    private fun holdLocks(on: Boolean) {
        try {
            if (on) {
                if (cpuLock == null) {
                    cpuLock = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "scanny:update")
                }
                if (cpuLock?.isHeld != true) cpuLock?.acquire(2 * 60 * 60 * 1000L)
                if (wifiLock == null) {
                    wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "scanny:update")
                }
                if (wifiLock?.isHeld != true) wifiLock?.acquire()
            } else {
                if (cpuLock?.isHeld == true) cpuLock?.release()
                if (wifiLock?.isHeld == true) wifiLock?.release()
            }
        } catch (e: Exception) {
        }
    }

    override fun onDestroy() {
        holdLocks(false)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "scanny/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    if (call.argument<Boolean>("on") == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(true)
                }
                "buildInfo" -> {
                    try {
                        val pi = packageManager.getPackageInfo(packageName, 0)
                        val code = if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()
                        result.success(mapOf("name" to (pi.versionName ?: ""), "build" to code))
                    } catch (e: Exception) {
                        result.error("buildInfo", e.message, null)
                    }
                }
                "canInstallApks" -> {
                    result.success(if (Build.VERSION.SDK_INT >= 26) packageManager.canRequestPackageInstalls() else true)
                }
                "openInstallSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "openUrl" -> {
                    try {
                        val u = Uri.parse(call.argument<String>("url") ?: "")
                        if (u.scheme == "http" || u.scheme == "https") {
                            startActivity(Intent(Intent.ACTION_VIEW, u).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "installApk" -> {
                    try {
                        val file = File(call.argument<String>("path") ?: "")
                        val uri = FileProvider.getUriForFile(this, packageName + ".scannyfiles", file)
                        val intent = Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("installApk", e.message, null)
                    }
                }
                "setWakeLock" -> {
                    holdLocks(call.argument<Boolean>("on") == true)
                    result.success(true)
                }
                "isMetered" -> {
                    try {
                        result.success((getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered)
                    } catch (e: Exception) {
                        result.success(true)
                    }
                }
                "batteryExempt" -> {
                    try {
                        result.success((getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(packageName))
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "requestBatteryExempt" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
'@

$FilePathsXml = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- scanny-file-paths: generated by the setup wizard. Where the downloaded update APK lives. -->
<paths>
    <cache-path name="scanny_updates" path="updates/" />
    <files-path name="scanny_updates_files" path="updates/" />
</paths>
'@

$FileProviderKotlin = @'
// scanny-file-provider: generated by the setup wizard (do not edit).
// Own subclass so the manifest merger does not clash with the FileProviders of other plugins.
package {PKG}

import androidx.core.content.FileProvider

class ScannyFileProvider : FileProvider()
'@

$AppKotlin = @'
// scanny-app: generated by the setup wizard (do not edit).
// Catches any crash and shows it on screen (CrashActivity) instead of just closing.
package {PKG}

import android.app.Application
import android.content.Intent
import android.os.Build
import android.os.Process
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import kotlin.system.exitProcess

class ScannyApp : Application() {
    override fun onCreate() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val sw = StringWriter()
                error.printStackTrace(PrintWriter(sw))
                val text = "Scanny crash report\n" +
                    Build.MANUFACTURER + " " + Build.MODEL + " - Android " + Build.VERSION.RELEASE +
                    " (SDK " + Build.VERSION.SDK_INT + ")\n" +
                    "Thread: " + thread.name + "\n\n" + sw.toString()
                File(filesDir, "last-crash.txt").writeText(text)
                val intent = Intent(this, CrashActivity::class.java)
                    .putExtra("text", text)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                startActivity(intent)
                Process.killProcess(Process.myPid())
                exitProcess(10)
            } catch (t: Throwable) {
                previous?.uncaughtException(thread, error)
            }
        }
        super.onCreate()
    }
}
'@

$CrashKotlin = @'
// scanny-crash: generated by the setup wizard (do not edit).
// Plain Android screen (no Flutter) that shows the crash text with Copy / Share buttons.
package {PKG}

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.File

class CrashActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getStringExtra("text")
            ?: File(filesDir, "last-crash.txt").let { if (it.exists()) it.readText() else "No crash report found." }
        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(pad, pad * 2, pad, pad)
        root.setBackgroundColor(Color.parseColor("#FF0B0F1E"))
        val title = TextView(this)
        title.text = "Scanny stopped - please send this report"
        title.setTextColor(Color.WHITE)
        title.textSize = 18f
        title.setTypeface(null, Typeface.BOLD)
        root.addView(title)
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        val copy = Button(this)
        copy.text = "Copy / نسخ"
        copy.setOnClickListener {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("Scanny crash", text))
            Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
        }
        val share = Button(this)
        share.text = "Share / مشاركة"
        share.setOnClickListener {
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
            startActivity(Intent.createChooser(send, "Scanny crash"))
        }
        val retry = Button(this)
        retry.text = "Retry / إعادة"
        retry.setOnClickListener {
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            finish()
        }
        row.addView(copy)
        row.addView(share)
        row.addView(retry)
        root.addView(row)
        val body = TextView(this)
        body.text = text
        body.setTextColor(Color.parseColor("#FFE0F2F1"))
        body.textSize = 12f
        body.typeface = Typeface.MONOSPACE
        body.setTextIsSelectable(true)
        val scroll = ScrollView(this)
        scroll.addView(body)
        root.addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }
}
'@

function Get-MainActivityInfo {
  $main = Join-Path (Join-Path (Join-Path (Join-Path $AppDir 'android') 'app') 'src') 'main'
  foreach ($sub in @('kotlin', 'java')) {
    $root = Join-Path $main $sub
    if (-not (Test-Path $root)) { continue }
    $f = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MainActivity.kt' -or $_.Name -eq 'MainActivity.java' } | Select-Object -First 1
    if ($f) {
      $m = [regex]::Match([IO.File]::ReadAllText($f.FullName), '(?m)^\s*package\s+([A-Za-z0-9_.]+)')
      if ($m.Success) { return @{ Dir = $f.DirectoryName; Package = $m.Groups[1].Value; Main = $main } }
    }
  }
  return $null
}

function Get-WidgetFiles {
  $mi = Get-MainActivityInfo
  if ($null -eq $mi) { return $null }
  $res = Join-Path $mi.Main 'res'
  return [ordered]@{
    (Join-Path $mi.Dir 'MainActivity.kt') = ($MainActivityKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path $mi.Dir 'ScannyWidget.kt') = ($WidgetKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path $mi.Dir 'ScannyApp.kt') = ($AppKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path $mi.Dir 'CrashActivity.kt') = ($CrashKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path (Join-Path $res 'layout') 'scanny_widget.xml') = $WidgetLayout
    (Join-Path (Join-Path $res 'drawable') 'scanny_widget_bg.xml') = $WidgetBg
    (Join-Path (Join-Path $res 'drawable') 'scanny_widget_btn.xml') = $WidgetBtn
    (Join-Path (Join-Path $res 'xml') 'scanny_widget_info.xml') = $WidgetInfo
    (Join-Path $mi.Dir 'ScannyShoppingWidget.kt') = ($ShopWidgetKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path (Join-Path $res 'layout') 'scanny_shopping_widget.xml') = $ShopWidgetLayout
    (Join-Path (Join-Path $res 'xml') 'scanny_shopping_widget_info.xml') = $ShopWidgetInfo
    (Join-Path (Join-Path $res 'xml') 'scanny_file_paths.xml') = $FilePathsXml
    (Join-Path $mi.Dir 'ScannyFileProvider.kt') = ($FileProviderKotlin -replace '\{PKG\}', $mi.Package)
  }
}

function Write-WidgetFiles {
  $files = Get-WidgetFiles
  if ($null -eq $files) { throw 'MainActivity not found - cannot add the home-screen widget.' }
  foreach ($k in $files.Keys) { Write-TextFile $k (([string]$files[$k]) -replace "`r`n", "`n") }
}

function Test-WidgetFiles {
  $files = Get-WidgetFiles
  if ($null -eq $files) { return $false }
  foreach ($k in $files.Keys) {
    if (-not (Test-Path $k)) { return $false }
    if (([IO.File]::ReadAllText($k) -replace "`r`n", "`n") -ne (([string]$files[$k]) -replace "`r`n", "`n")) { return $false }
  }
  return $true
}

function Get-ResOverlay {
  $src = Join-Path $PSScriptRoot 'android-res'
  $dst = Join-Path (Join-Path (Join-Path (Join-Path $AppDir 'android') 'app') 'src') 'main'
  return @{ Src = $src; Dst = (Join-Path $dst 'res') }
}

function Get-FileSha([string]$path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = [IO.File]::OpenRead($path)
  try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') } finally { $fs.Dispose() }
}

function Copy-AndroidRes {
  $o = Get-ResOverlay
  if (-not (Test-Path $o.Src)) { throw ('Icon resources missing: ' + $o.Src) }
  foreach ($f in (Get-ChildItem -Path $o.Src -Recurse -File)) {
    $rel = $f.FullName.Substring($o.Src.Length).TrimStart('\', '/')
    $to = Join-Path $o.Dst $rel
    $dir = Split-Path -Parent $to
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -Force $f.FullName $to
  }
}

function Test-AndroidRes {
  $o = Get-ResOverlay
  if (-not (Test-Path $o.Src)) { return $false }
  foreach ($f in (Get-ChildItem -Path $o.Src -Recurse -File)) {
    $rel = $f.FullName.Substring($o.Src.Length).TrimStart('\', '/')
    $to = Join-Path $o.Dst $rel
    if (-not (Test-Path $to)) { return $false }
    if ((Get-FileSha $f.FullName) -ne (Get-FileSha $to)) { return $false }
  }
  return $true
}

function Update-TextFileKeepEol([string]$path, [scriptblock]$transform) {
  $raw = [IO.File]::ReadAllText($path)
  $crlf = $raw.Contains("`r`n")
  $new = & $transform $raw
  if ($crlf) { $new = ($new -replace "`r`n", "`n") -replace "`n", "`r`n" }
  if ($new -ne $raw) { Write-TextFile $path $new; return $true }
  return $false
}

function Get-GradleFiles {
  $android = Join-Path $AppDir 'android'
  $appK = Join-Path (Join-Path $android 'app') 'build.gradle.kts'
  $appG = Join-Path (Join-Path $android 'app') 'build.gradle'
  $rootK = Join-Path $android 'build.gradle.kts'
  $rootG = Join-Path $android 'build.gradle'
  $r = @{ Android = $android; App = ''; AppKts = $false; Root = ''; RootKts = $false }
  if (Test-Path $appK) { $r.App = $appK; $r.AppKts = $true } elseif (Test-Path $appG) { $r.App = $appG }
  if (Test-Path $rootK) { $r.Root = $rootK; $r.RootKts = $true } elseif (Test-Path $rootG) { $r.Root = $rootG }
  return $r
}

function Invoke-GradlePatches {
  $g = Get-GradleFiles
  if (-not $g.App -or -not $g.Root) { throw 'Android Gradle files not found - the Flutter project was not created.' }
  $kts = $g.AppKts
  [void](Update-TextFileKeepEol $g.App { param($s) Update-AppGradleText $s $kts $Package })
  $rk = $g.RootKts
  [void](Update-TextFileKeepEol $g.Root { param($s) Update-RootGradleText $s $rk })
  Write-TextFile (Join-Path $g.Android 'scanny-sdk-hook.gradle') ($SdkHookScript -replace "`r`n", "`n")
  $mf = Get-ManifestPath
  if (-not (Test-Path $mf)) { throw ('AndroidManifest.xml not found: ' + $mf) }
  [void](Update-TextFileKeepEol $mf { param($s) Update-ManifestText $s })
  Write-WidgetFiles
  Copy-AndroidRes
}

function Test-GradlePatches {
  $g = Get-GradleFiles
  if (-not $g.App -or -not $g.Root) { return $false }
  if (-not (Test-AppGradleText ([IO.File]::ReadAllText($g.App)) $g.AppKts $Package)) { return $false }
  if (-not (Test-RootGradleText ([IO.File]::ReadAllText($g.Root)))) { return $false }
  if (-not (Test-Path (Join-Path $g.Android 'scanny-sdk-hook.gradle'))) { return $false }
  $mf = Get-ManifestPath
  if (-not (Test-Path $mf)) { return $false }
  if (-not (Test-ManifestText ([IO.File]::ReadAllText($mf)))) { return $false }
  if (-not (Test-WidgetFiles)) { return $false }
  return (Test-AndroidRes)
}

# ------------------------------------------------------------------ JDK (re-detected before EVERY build)
function Get-JavaMajor([string]$javaExe) {
  $r = Invoke-Native $javaExe @('-version')
  if ($r.Out -match 'version "(\d+)(?:\.(\d+))?') {
    $m = [int]$Matches[1]
    if ($m -eq 1 -and $Matches[2]) { $m = [int]$Matches[2] }
    return $m
  }
  return 0
}

function Find-Jdk {
  $c = New-Object System.Collections.Generic.List[string]
  if ($env:SCANNY_JDK_CANDIDATES) { foreach ($x in ($env:SCANNY_JDK_CANDIDATES -split ';')) { if ($x) { $c.Add($x) } } }
  if ($env:JAVA_HOME) { $c.Add($env:JAVA_HOME) }
  if ($OnWindows) {
    $u = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User'); if ($u) { $c.Add($u) }
    $mach = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'); if ($mach) { $c.Add($mach) }
    foreach ($root in @((Join-Path $env:ProgramFiles 'Microsoft'), (Join-Path $env:ProgramFiles 'Eclipse Adoptium'), (Join-Path $env:ProgramFiles 'Java'), (Join-Path $env:ProgramFiles 'Zulu'))) {
      if (Test-Path $root) { Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $c.Add($_.FullName) } }
    }
    $c.Add((Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'))
  }
  $best = ''
  $bestMajor = 0
  $seen = @{}
  foreach ($dir in $c) {
    if ($seen.ContainsKey($dir)) { continue }
    $seen[$dir] = $true
    $java = Get-BinPath $dir 'java' '.exe'
    if (-not (Test-Path $java)) { continue }   # removed / broken folder
    $m = Get-JavaMajor $java
    if ($m -lt 17) { continue }
    if ($m -eq 17) { return $dir }
    if (-not $best -or $m -lt $bestMajor) { $best = $dir; $bestMajor = $m }
  }
  return $best
}

function Ensure-Jdk {
  $j = Find-Jdk
  if (-not $j) {
    Warn 'No working JDK 17+ found - installing Microsoft OpenJDK 17.'
    [void](Install-Winget 'Microsoft.OpenJDK.17')
    $j = Find-Jdk
  }
  if (-not $j) { throw 'JDK 17 could not be found after installing it. Reboot Windows and run again.' }
  $env:JAVA_HOME = $j
  if ($OnWindows) { [Environment]::SetEnvironmentVariable('JAVA_HOME', $j, 'User') }
  Update-SessionPath
  $f = Get-FlutterExe
  if ($f) { [void](Invoke-Native $f @('config', '--jdk-dir', $j)) }
  Ok ('JDK: ' + $j)
  return $j
}

# ------------------------------------------------------------------ keystore
function Get-KeystoreSha1 {
  $kt = Get-Keytool
  $pw = Get-St 'storePass'
  if (-not $kt -or -not $pw -or -not (Test-Path $KeystorePath)) { return '' }
  $r = Invoke-Native $kt @('-list', '-v', '-keystore', $KeystorePath, '-alias', $KeyAlias, '-storepass', $pw)
  $m = [regex]::Match($r.Out, 'SHA1:\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){19})')
  if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
  return ''
}

function Write-KeyProperties {
  $pw = Get-St 'storePass'
  $store = $KeystorePath -replace '\\', '/'
  $txt = "storePassword=$pw`nkeyPassword=$pw`nkeyAlias=$KeyAlias`nstoreFile=$store`n"
  Write-TextFile (Join-Path (Join-Path $AppDir 'android') 'key.properties') $txt
}

function Backup-Keystore {
  if (-not (Test-Path $KeystorePath)) { return }
  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
  Copy-Item -Force $KeystorePath (Join-Path $BackupDir 'scanny-release.jks')
  $info = "KEEP THIS FOLDER SAFE (USB / cloud). Without it you can never update the installed app.`r`n" +
    "Keystore: scanny-release.jks`r`nAlias: $KeyAlias`r`nPassword (store and key): $(Get-St 'storePass')`r`nSHA-1: $(Get-St 'sha1')`r`n"
  Write-TextFile (Join-Path $BackupDir 'KEYSTORE-PASSWORD-PRIVATE.txt') $info
}

function Ensure-Keystore {
  if (-not (Test-Path $KeystorePath)) {
    $bk = Join-Path $BackupDir 'scanny-release.jks'
    $bkInfo = Join-Path $BackupDir 'KEYSTORE-PASSWORD-PRIVATE.txt'
    if ((Test-Path $bk) -and (Test-Path $bkInfo)) {
      Warn 'Keystore missing in the work folder - restoring it from the backup (same key = updates keep working).'
      New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
      Copy-Item -Force $bk $KeystorePath
      $m = [regex]::Match([IO.File]::ReadAllText($bkInfo), 'Password \(store and key\):\s*(\S+)')
      if ($m.Success) { Set-St 'storePass' $m.Groups[1].Value }
    }
  }
  if (-not (Test-Path $KeystorePath)) {
    Info 'Creating your release signing key (one time).'
    New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
    $pw = New-RandomString 20 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    Set-St 'storePass' $pw
    $kt = Get-Keytool
    if (-not $kt) { throw 'keytool not found (part of the JDK).' }
    $r = Invoke-Native $kt @('-genkeypair', '-v', '-keystore', $KeystorePath, '-storetype', 'PKCS12', '-keyalg', 'RSA', '-keysize', '2048',
      '-validity', '10000', '-alias', $KeyAlias, '-storepass', $pw, '-keypass', $pw, '-dname', 'CN=Scanny, O=Home, C=AE')
    if ($r.Code -ne 0) { throw ('keytool failed: ' + $r.Out) }
  }
  $sha = Get-KeystoreSha1
  if ($sha) { Set-St 'sha1' $sha }
  Backup-Keystore
}

# ------------------------------------------------------------------ app source
# "1.6.0" from "version: 1.6.0+1" in a pubspec.yaml ('?' when it cannot be read).
function Get-PubspecVersion([string]$path) {
  try {
    $m = [regex]::Match([IO.File]::ReadAllText($path), '(?m)^version:\s*([0-9][^\s+]*)')
    if ($m.Success) { return $m.Groups[1].Value }
  } catch { }
  return '?'
}

function Sync-AppSource {
  $src = Join-Path $BundleRoot 'app'
  if (-not (Test-Path $src)) { throw ('App source folder not found: ' + $src) }
  Info ('App code comes from: ' + $src + '   (Scanny version ' + (Get-PubspecVersion (Join-Path $src 'pubspec.yaml')) + ')')
  New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
  foreach ($item in @('lib', 'test', 'assets', 'packages')) {
    $s = Join-Path $src $item
    if (Test-Path $s) {
      $d = Join-Path $AppDir $item
      if (Test-Path $d) { Remove-Item -Recurse -Force $d }
      Copy-Item -Recurse -Force $s $d
    }
  }
  foreach ($f in @('pubspec.yaml', 'analysis_options.yaml', 'firestore.rules', 'firebase.json')) {
    $s = Join-Path $src $f
    if (Test-Path $s) { Copy-Item -Force $s (Join-Path $AppDir $f) }
  }
  Remove-TemplateTest
  # the copied lib/ has the placeholder - put the real config back
  if (Get-St 'cfg') { Write-FirebaseConfigFiles (Get-St 'cfg') }
}

function Test-FlutterProject {
  return ((Test-Path (Join-Path (Join-Path $AppDir 'lib') 'main.dart')) -and (Get-GradleFiles).App -ne '')
}

function New-FlutterProject {
  $f = Get-FlutterExe
  if (-not $f) { throw 'Flutter is not installed.' }
  Sync-AppSource
  Info 'Creating the Android project around the app code (flutter create)...'
  $r = Invoke-Native $f @('create', '--org', 'com.scanny', '--project-name', 'scanny', '--platforms', 'android', '.') -Cwd $AppDir -Stream
  if ($r.Code -ne 0) { throw ('flutter create failed: ' + $r.Out) }
  Remove-TemplateTest
}

# `flutter create` writes a sample test that refers to a class called MyApp. Scanny has no MyApp, so the code check would report an error.
function Remove-TemplateTest {
  $t = Join-Path (Join-Path $AppDir 'test') 'widget_test.dart'
  if ((Test-Path $t) -and ([IO.File]::ReadAllText($t) -match '\bMyApp\b')) { Remove-Item -Force $t; Info 'Removed the sample test written by flutter create.' }
}

# ------------------------------------------------------------------ Firebase CLI
function Get-FirebaseAccount {
  $r = Invoke-Native $FirebaseExe @('login:list', '--json')
  # The CLI can print the account list and then a SECOND json block ({"status":"error","error":"Timed out."}),
  # so the output is not one valid JSON document and the exit code is not 0. The account is still in the text.
  $m0 = [regex]::Match($r.Out, '"email"\s*:\s*"([^"\s]+@[^"\s]+)"')
  if ($m0.Success) { return $m0.Groups[1].Value }
  $j = ConvertFrom-JsonLoose $r.Out
  if ($j -and $j.result) {
    foreach ($a in @($j.result)) { if ($a -and $a.user -and $a.user.email) { return [string]$a.user.email } }
  }
  $m = [regex]::Match($r.Out, 'Logged in as\s+(\S+@\S+)')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-ConsoleUrl([string]$path) {
  $u = 'https://console.firebase.google.com/project/' + $Script:Project + '/' + $path
  if ($Script:Account) { $u = $u + '?authuser=' + [uri]::EscapeDataString($Script:Account) }
  return $u
}

function Get-CloudUrl([string]$path) {
  $u = 'https://console.cloud.google.com/' + $path + '?project=' + $Script:Project
  if ($Script:Account) { $u = $u + '&authuser=' + [uri]::EscapeDataString($Script:Account) }
  return $u
}

function Invoke-FirebaseLogin([bool]$reauth) {
  Info 'A browser will open - sign in with the Google account that should own the Firebase project.'
  Info 'No browser, or no link shown within 20 seconds? Press Ctrl+C, double-click Sign-In-Firebase.bat (same folder as START-SCANNY-PHONE.bat),'
  Info 'follow its 4 steps, then run START-SCANNY-PHONE.bat again.'
  if ($reauth) { $a = @('login', '--reauth') } else { $a = @('login') }
  [void](Invoke-Interactive $FirebaseExe $a)
  $Script:Account = Get-FirebaseAccount
}

function Ensure-FirebaseLogin {
  $Script:Account = Get-FirebaseAccount
  if (-not $Script:Account) { Invoke-FirebaseLogin $false }
  if (-not $Script:Account) { throw 'Firebase CLI is not signed in. Double-click Sign-In-Firebase.bat (same folder as START-SCANNY-PHONE.bat), then run START-SCANNY-PHONE.bat again.' }
  Ok ('Firebase CLI uses Google account: ' + $Script:Account)
  Info 'Console pages open with ?authuser=<this account>. If a page says "project does not exist", you are viewing it with another account.'
}

function Test-ProjectReachable([string]$id) {
  if (-not $id) { return $false }
  $r = Invoke-Native $FirebaseExe @('apps:list', '--project', $id, '--json')
  if ($r.Code -eq 0) { return $true }
  $l = Invoke-Native $FirebaseExe @('projects:list', '--json')
  if ($l.Code -eq 0) {
    $j = ConvertFrom-JsonLoose $l.Out
    if ($j) { foreach ($p in @($j.result)) { if ($p -and $p.projectId -eq $id) { return $true } } }
  }
  return $false
}

function Wait-ProjectVisible([string]$id, [int]$tries) {
  for ($i = 1; $i -le $tries; $i++) {
    if (Test-ProjectReachable $id) { return $true }
    Info ('Waiting for Google to finish creating ' + $id + ' (' + $i + '/' + $tries + ')...')
    Wait-Sec 10
  }
  return $false
}

function Switch-FirebaseAccount {
  Info ('Currently signed in as: ' + $Script:Account)
  Info 'Signing out, then a browser opens: choose the Google account that OWNS the Firebase project.'
  [void](Invoke-Interactive $FirebaseExe @('logout'))
  [void](Invoke-Interactive $FirebaseExe @('login'))
  $Script:Account = Get-FirebaseAccount
  if ($Script:Account) { Ok ('Firebase CLI now uses: ' + $Script:Account); Set-St 'account' $Script:Account }
  else { Warn 'No account signed in - type L to try again.' }
}

function Ask-ExistingProject {
  Info ('Signed in as ' + $Script:Account + '. If the project belongs to another Google account, type L.')
  while ($true) {
    $id = ([string](Ask 'Paste an existing Firebase project ID (L = use another Google account, Q = quit)')).Trim()
    if ($id.ToUpper() -eq 'Q') { throw 'USER_QUIT' }
    if ($id.ToUpper() -eq 'L') { Switch-FirebaseAccount; continue }
    if (-not $id) { continue }
    if (Test-ProjectReachable $id) { return $id }
    Warn ('Project ' + $id + ' is not reachable with ' + $Script:Account + '.')
    Info 'Check the ID (Firebase console > Project settings > Project ID), or type L to sign in with the account that owns it.'
  }
}

function Get-FirebaseDebugErrors {
  $log = Join-Path $Work 'firebase-debug.log'
  if (-not (Test-Path $log)) { return '' }
  $lines = @(Get-Content -Path $log -Tail 200 -ErrorAction SilentlyContinue |
      Where-Object { $_ -match '(?i)(error|denied|terms|permission|quota|billing|PRECONDITION|FAILED_PRECONDITION|"message")' })
  return (($lines | Select-Object -Last 8) -join "`n")
}

function Test-GcpCreated([string]$out) {
  return ($out -match '(?m)^\s*[^\s\-]\s+Creating Google Cloud Platform project')
}

function Add-FirebaseToProject([string]$id) {
  $r = Invoke-Native $FirebaseExe @('projects:addfirebase', $id) -Cwd $Work -Stream
  if ($r.Code -ne 0 -and $r.Out -notmatch '(?i)already') {
    $Script:LastHint = (Get-FirebaseDebugErrors)
    return $false
  }
  return (Wait-ProjectVisible $id 6)
}

function Resume-GcpProject([string]$id) {
  Warn ('Google Cloud project ' + $id + ' exists, but Firebase could not be added to it yet.')
  Info 'Most common reason on a new account: the Firebase terms have not been accepted.'
  $dbg = Get-FirebaseDebugErrors
  if ($dbg) { Info 'From firebase-debug.log:'; foreach ($l in ($dbg -split "`n")) { Info ('  ' + $l.Trim()) } }
  $url = 'https://console.firebase.google.com/'
  if ($Script:Account) { $url = $url + '?authuser=' + [uri]::EscapeDataString($Script:Account) }
  $ok = Invoke-Manual -Title ('Add Firebase to ' + $id) -Url $url -Steps @(
    ('Check the top-right avatar is ' + $Script:Account + ' (switch account if not).'),
    'If a "Terms of service" / welcome box appears, tick the box and click Continue / Accept.',
    'Do NOT create a new project. Just close the console tab after accepting.',
    'Come back here and press Enter - the wizard adds Firebase to the existing project itself.') -Check { Add-FirebaseToProject $id }
  if ($ok) {
    Set-St 'projectId' $id
    $Script:Project = $id
    Ok ('Firebase added to ' + $id)
    return $true
  }
  return $false
}

function Ensure-Project {
  $saved = Get-St 'projectId'
  if ($saved) {
    if (Test-ProjectReachable $saved) { $Script:Project = $saved; return }
    Warn ('Saved project ' + $saved + ' is not reachable with account ' + $Script:Account + '.')
    $c = ([string](Ask 'L = log in with another account, N = create a NEW project with this account, P = paste another project ID, Q = quit')).Trim().ToUpper()
    if ($c -eq 'Q') { throw 'USER_QUIT' }
    if ($c -eq 'N') { Start-NewProject; Ensure-Project; return }
    if ($c -eq 'L') { Switch-FirebaseAccount; if (Test-ProjectReachable $saved) { $Script:Project = $saved; return } }
    $id = Ask-ExistingProject
    Set-St 'projectId' $id; $Script:Project = $id; return
  }
  $gcp = Get-St 'gcpProjectId'
  if ($gcp) {
    if (Test-ProjectReachable $gcp) { Set-St 'projectId' $gcp; $Script:Project = $gcp; return }
    if (Resume-GcpProject $gcp) { return }
    $id = Ask-ExistingProject
    Set-St 'projectId' $id; $Script:Project = $id; return
  }
  $pending = Get-St 'pendingProjectId'
  if ($pending) {
    Info ('A project was already created earlier (' + $pending + ') - waiting for it instead of creating another one.')
    if (Wait-ProjectVisible $pending 18) { Set-St 'projectId' $pending; $Script:Project = $pending; return }
    Warn ('Project ' + $pending + ' is still not visible.')
    $id = Ask-ExistingProject
    Set-St 'projectId' $id; $Script:Project = $id; return
  }
  $relogged = $false
  $id = 'scanny-' + (New-RandomString 6 'abcdefghijkmnpqrstuvwxyz23456789')
  while ($true) {
    Info ('Creating Firebase project ' + $id + ' (one time)...')
    $r = Invoke-Native $FirebaseExe @('projects:create', $id, '--display-name', 'Scanny') -Cwd $Work -Stream
    if ($r.Code -eq 0) {
      Set-St 'pendingProjectId' $id     # remember BEFORE waiting: never create twice
      if (-not (Wait-ProjectVisible $id 18)) {
        Warn 'The project was created but is not visible yet (Google lags). Re-run START-SCANNY-PHONE in a few minutes; it will NOT create another one.'
        throw ('Project ' + $id + ' not visible yet.')
      }
      Set-St 'projectId' $id; $Script:Project = $id
      Ok ('Created project ' + $id)
      return
    }
    $out = $r.Out
    if (Test-GcpCreated $out) {
      Set-St 'gcpProjectId' $id     # never create a second one
      if (Resume-GcpProject $id) { return }
      $p = Ask-ExistingProject
      Set-St 'projectId' $p; $Script:Project = $p; return
    }
    $dbg = Get-FirebaseDebugErrors
    if ($dbg) { Info 'From firebase-debug.log:'; foreach ($l in ($dbg -split "`n")) { Info ('  ' + $l.Trim()) } }
    if ($out -match '(?i)(project quota|quota exceeded|too many projects|exceeded your quota|project limit)') {
      Warn 'Google refused to create another project (project quota reached). Earlier attempts may already have created one: reuse it.'
      Info 'See your projects: https://console.firebase.google.com  (or run: firebase projects:list). Paste the ID of the one named Scanny.'
      Info 'Open https://console.firebase.google.com, pick or create a project there, and paste its ID.'
      $p = Ask-ExistingProject
      Set-St 'projectId' $p; $Script:Project = $p; return
    }
    if ($out -match '(?i)already exists|ALREADY_EXISTS|not available|is taken') {
      if (Get-St 'replacementUsed') { Warn 'The project ID is taken again.'; $p = Ask-ExistingProject; Set-St 'projectId' $p; $Script:Project = $p; return }
      Set-St 'replacementUsed' $true
      $id = 'scanny-' + (New-RandomString 8 'abcdefghijkmnpqrstuvwxyz23456789')
      Warn ('ID taken - trying ONE replacement: ' + $id)
      continue
    }
    if (($out -match '(?i)permission|PERMISSION_DENIED|403|credential|authenticat|login') -and -not $relogged) {
      Warn 'Permission error from Google.'
      $c = ([string](Ask 'L = log in again (another account?), P = paste existing project ID, Q = quit')).Trim().ToUpper()
      if ($c -eq 'Q') { throw 'USER_QUIT' }
      if ($c -eq 'L') { Switch-FirebaseAccount; $relogged = $true; continue }
      $p = Ask-ExistingProject; Set-St 'projectId' $p; $Script:Project = $p; return
    }
    Fail ('Project creation failed: ' + $out)
    $p = Ask-ExistingProject
    Set-St 'projectId' $p; $Script:Project = $p; return
  }
}

function Get-AndroidAppId {
  $r = Invoke-Native $FirebaseExe @('apps:list', 'ANDROID', '--project', $Script:Project, '--json')
  if ($r.Code -ne 0) { return '' }
  $j = ConvertFrom-JsonLoose $r.Out
  if ($null -eq $j) { return '' }
  foreach ($a in @($j.result)) { if ($a -and $a.packageName -eq $Package) { return [string]$a.appId } }
  return ''
}

function Ensure-AndroidApp {
  $id = Get-AndroidAppId
  if (-not $id) {
    Info ('Registering Android app ' + $Package + '...')
    $r = Invoke-Native $FirebaseExe @('apps:create', 'ANDROID', 'Scanny', '--package-name', $Package, '--project', $Script:Project, '--json')
    if ($r.Code -ne 0) { throw ('apps:create failed: ' + $r.Out) }
    for ($i = 0; $i -lt 12 -and -not $id; $i++) { $id = Get-AndroidAppId; if (-not $id) { Wait-Sec 5 } }
  }
  if ($id) { Set-St 'appId' $id }
}

function Test-ShaRegistered {
  $sha = Get-St 'sha1'; $app = Get-St 'appId'
  if (-not $sha -or -not $app) { return $false }
  $r = Invoke-Native $FirebaseExe @('apps:android:sha:list', $app, '--project', $Script:Project)
  if ($r.Code -ne 0) { return $false }
  $want = ($sha -replace ':', '').ToLower()
  $have = ($r.Out -replace ':', '').ToLower()
  return $have.Contains($want)
}

function Register-Sha {
  $r = Invoke-Native $FirebaseExe @('apps:android:sha:create', (Get-St 'appId'), (Get-St 'sha1'), '--project', $Script:Project)
  if ($r.Code -ne 0 -and $r.Out -notmatch '(?i)already exists') { Warn ('SHA-1 registration said: ' + $r.Out) }
  Wait-Sec 3
}

# ------------------------------------------------------------------ config generation (no flutterfire_cli)
function Get-SdkConfig {
  $r = Invoke-Native $FirebaseExe @('apps:sdkconfig', 'ANDROID', (Get-St 'appId'), '--project', $Script:Project, '--json')
  if ($r.Code -ne 0) { return $null }
  $j = ConvertFrom-JsonLoose $r.Out
  if ($null -eq $j -or $null -eq $j.result) { return $null }
  $contents = $j.result.fileContents
  if ($contents -is [string]) { try { return ($contents | ConvertFrom-Json) } catch { return $null } }
  return $contents
}

function ConvertTo-FirebaseCfg($gs, [string]$pkg) {
  if ($null -eq $gs) { return $null }
  $client = $null
  foreach ($c in @($gs.client)) {
    if ($c -and $c.client_info -and $c.client_info.android_client_info -and $c.client_info.android_client_info.package_name -eq $pkg) { $client = $c }
  }
  if ($null -eq $client) { return $null }
  $web = ''
  foreach ($o in @($client.oauth_client)) { if ($o -and [int]$o.client_type -eq 3) { $web = [string]$o.client_id } }
  if (-not $web -and $client.services -and $client.services.appinvite_service) {
    foreach ($o in @($client.services.appinvite_service.other_platform_oauth_client)) { if ($o -and [int]$o.client_type -eq 3) { $web = [string]$o.client_id } }
  }
  $bucket = ''
  if ($gs.project_info.storage_bucket) { $bucket = [string]$gs.project_info.storage_bucket }
  return @{
    apiKey = [string](@($client.api_key)[0].current_key)
    appId = [string]$client.client_info.mobilesdk_app_id
    senderId = [string]$gs.project_info.project_number
    projectId = [string]$gs.project_info.project_id
    bucket = $bucket
    webClientId = $web
    json = ($gs | ConvertTo-Json -Depth 20)
  }
}

function Get-DartString([string]$s) { return "'" + ($s -replace '\\', '\\' -replace "'", "\'" -replace '\$', '\$') + "'" }

function New-FirebaseOptionsDart($cfg) {
  return @"
// GENERATED by the Scanny setup wizard from ``firebase apps:sdkconfig``. Do not edit.
import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static const FirebaseOptions currentPlatform = FirebaseOptions(
    apiKey: $(Get-DartString $cfg.apiKey),
    appId: $(Get-DartString $cfg.appId),
    messagingSenderId: $(Get-DartString $cfg.senderId),
    projectId: $(Get-DartString $cfg.projectId),
    storageBucket: $(Get-DartString $cfg.bucket),
  );

  /// OAuth "web" client id (client_type 3) used by Google Sign-In.
  static const String googleWebClientId = $(Get-DartString $cfg.webClientId);
}
"@
}

function Write-FirebaseConfigFiles($cfg) {
  Write-TextFile (Join-Path (Join-Path $AppDir 'lib') 'firebase_options.dart') ((New-FirebaseOptionsDart $cfg) -replace "`r`n", "`n")
  $gsPath = Join-Path (Join-Path (Join-Path $AppDir 'android') 'app') 'google-services.json'
  if (Test-Path (Split-Path -Parent $gsPath)) { Write-TextFile $gsPath ([string]$cfg.json) }
}

function Update-FirebaseConfig {
  $gs = Get-SdkConfig
  $cfg = ConvertTo-FirebaseCfg $gs $Package
  if ($null -eq $cfg) { throw 'Could not read the app config from Firebase (apps:sdkconfig).' }
  Set-St 'cfg' $cfg
  Write-FirebaseConfigFiles $cfg
  return $cfg
}

function Test-FirebaseConfigFile {
  $p = Join-Path (Join-Path $AppDir 'lib') 'firebase_options.dart'
  if (-not (Test-Path $p)) { return $false }
  $t = [IO.File]::ReadAllText($p)
  $cfg = Get-St 'cfg'
  if ($null -eq $cfg) { return $false }
  return ($t -notmatch 'REPLACE_ME' -and $t.Contains([string]$cfg.apiKey) -and $t.Contains([string]$cfg.projectId))
}

# ------------------------------------------------------------------ Google APIs (best effort via firebase-tools token)
function Get-GoogleAccessToken {
  if ($env:SCANNY_FIREBASE_CONFIG) { $cfgPath = $env:SCANNY_FIREBASE_CONFIG }
  else { $cfgPath = Join-Path (Join-Path (Join-Path $HOME '.config') 'configstore') 'firebase-tools.json' }
  if (-not (Test-Path $cfgPath)) { return '' }
  try { $j = Get-Content -Raw -Path $cfgPath | ConvertFrom-Json } catch { return '' }
  if ($null -eq $j.tokens -or -not $j.tokens.refresh_token) { return '' }
  $r = Invoke-Http -Method 'POST' -Uri 'https://oauth2.googleapis.com/token' -Form @{
    grant_type = 'refresh_token'; refresh_token = [string]$j.tokens.refresh_token; client_id = $FbClientId; client_secret = $FbClientSecret
  }
  if ($r.Json -and $r.Json.access_token) { return [string]$r.Json.access_token }
  return ''
}

function Test-ApiEnabled([string]$api, [string]$tok) {
  $r = Invoke-Http -Uri ('https://serviceusage.googleapis.com/v1/projects/' + $Script:Project + '/services/' + $api) -Headers @{ Authorization = 'Bearer ' + $tok }
  return ($r.Json -and $r.Json.state -eq 'ENABLED')
}

function Enable-GoogleApis([string[]]$apis) {
  $tok = Get-GoogleAccessToken
  if (-not $tok) { Warn 'Could not get a Google token from firebase-tools - APIs will be checked by the next steps.'; return $false }
  $all = $true
  foreach ($api in $apis) {
    if (Test-ApiEnabled $api $tok) { Ok ($api + ' enabled'); continue }
    Info ('Enabling ' + $api + '...')
    $base = 'https://serviceusage.googleapis.com/v1/projects/' + $Script:Project + '/services/' + $api
    $e = Invoke-Http -Method 'POST' -Uri ($base + ':enable') -Headers @{ Authorization = 'Bearer ' + $tok } -Body @{}
    $done = $false
    for ($i = 0; $i -lt 12; $i++) { if (Test-ApiEnabled $api $tok) { $done = $true; break }; Wait-Sec 5 }
    if ($done) { Ok ($api + ' enabled') }
    else {
      $all = $false
      Warn ($api + ' not enabled yet: ' + (Get-ApiError $e))
      $null = Invoke-Manual -Title ('Enable ' + $api) -Url (Get-CloudUrl ('apis/library/' + $api)) -Steps @(
        ('Make sure the top bar shows project ' + $Script:Project + ' and account ' + $Script:Account + '.'),
        'Click the blue "Enable" button and wait until the page shows "API enabled".') -Check { Test-ApiEnabled $api $tok }
    }
  }
  return $all
}

# ------------------------------------------------------------------ Firestore + rules
function Test-Firestore {
  # existence by EXIT CODE only (output format changes between CLI versions)
  $r = Invoke-Native $FirebaseExe @('firestore:databases:get', '--project', $Script:Project)
  return ($r.Code -eq 0)
}

function Ensure-Firestore {
  if (Test-Firestore) { return }
  if (Get-St 'firestoreCreated') {
    Info 'Firestore was created earlier - waiting for it to become visible...'
    for ($i = 0; $i -lt 12; $i++) { if (Test-Firestore) { return }; Wait-Sec 10 }
    return
  }
  Info ('Creating Firestore database in ' + $FirestoreRegion + ' (cannot be changed later)...')
  $r = Invoke-Native $FirebaseExe @('firestore:databases:create', '"(default)"', '--location', $FirestoreRegion, '--project', $Script:Project) -Stream
  if ($r.Code -eq 0 -or $r.Out -match '(?i)already exists') {
    Set-St 'firestoreCreated' $true
    for ($i = 0; $i -lt 12; $i++) { if (Test-Firestore) { return }; Wait-Sec 10 }
    return
  }
  $Script:LastHint = $r.Out
  $null = Invoke-Manual -Title 'Create the Firestore database' -Url (Get-ConsoleUrl 'firestore') -Steps @(
    'Click "Create database".',
    'Choose "Standard edition" if asked, Database ID "(default)".',
    ('Location: pick "' + $FirestoreRegion + '" (eur3 = Europe, nam5 = United States). Do NOT pick Dammam. It can NOT be changed later.'),
    'Choose "Start in production mode", then Create.') -Check { Test-Firestore }
  if (Test-Firestore) { Set-St 'firestoreCreated' $true }
}

function Get-FileHashText([string]$path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $bytes = [Text.Encoding]::UTF8.GetBytes(([IO.File]::ReadAllText($path) -replace "`r`n", "`n"))
  return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '')
}

function Deploy-Rules {
  $r = Invoke-Native $FirebaseExe @('deploy', '--only', 'firestore:rules', '--project', $Script:Project, '--non-interactive') -Cwd $AppDir -Stream
  if ($r.Code -ne 0) { $Script:LastHint = $r.Out; return }
  Set-St 'rulesHash' (Get-FileHashText (Join-Path $AppDir 'firestore.rules'))
  Set-St 'rulesProject' $Script:Project
}

function Test-RulesDeployed {
  $p = Join-Path $AppDir 'firestore.rules'
  if (-not (Test-Path $p)) { return $false }
  return ((Get-St 'rulesHash') -eq (Get-FileHashText $p) -and (Get-St 'rulesProject') -eq $Script:Project)
}

# ------------------------------------------------------------------ Auth
function Get-AndroidHeaders {
  return @{ 'X-Android-Package' = $Package; 'X-Android-Cert' = ((Get-St 'sha1') -replace ':', '').ToUpper() }
}

function Get-IdentityUrl([string]$path) {
  $cfg = Get-St 'cfg'
  return ('https://identitytoolkit.googleapis.com/v1/' + $path + '?key=' + $cfg.apiKey)
}

function Test-EmailAuthEnabled {
  $Script:LastHint = ''
  $r = Invoke-Http -Method 'POST' -Uri (Get-IdentityUrl 'accounts:signInWithPassword') -Headers (Get-AndroidHeaders) -Body @{
    email = 'probe-no-such-user@scanny.invalid'; password = 'probe-password-1'; returnSecureToken = $true }
  $msg = Get-ApiError $r
  Write-Log ('auth probe: ' + $msg)
  if ($msg -match 'OPERATION_NOT_ALLOWED|PASSWORD_LOGIN_DISABLED') { $Script:LastHint = 'Email/Password sign-in is still disabled.'; return $false }
  if ($msg -match 'EMAIL_NOT_FOUND|INVALID_LOGIN_CREDENTIALS|INVALID_PASSWORD') { return $true }
  if ($msg -match 'CONFIGURATION_NOT_FOUND') { $Script:LastHint = 'Authentication has not been started yet (click "Get started").'; return $false }
  if ($msg -match 'API_KEY|API key|blocked|referer') { $Script:LastHint = ('The API key rejected the request: ' + $msg); return $false }
  if ($msg) { $Script:LastHint = $msg } else { $Script:LastHint = ('HTTP ' + $r.Status + ' ' + $r.Text) }
  return $false
}

# The "Get started" button of Authentication, pressed by the wizard: creates the Authentication configuration of the project.
function Initialize-FirebaseAuth {
  $tok = Get-GoogleAccessToken
  if (-not $tok) { return $false }
  $h = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
  $cfgUrl = 'https://identitytoolkit.googleapis.com/admin/v2/projects/' + $Script:Project + '/config'
  $c = Invoke-Http -Uri $cfgUrl -Headers $h
  if ($c.Status -eq 200) { return $true }
  if ((Get-St 'authApiNeedsBilling') -eq $Script:Project) { return $false }
  Info 'Starting Authentication for the project (the "Get started" button) - done for you...'
  $r = Invoke-Http -Method 'POST' -Uri ('https://identitytoolkit.googleapis.com/v2/projects/' + $Script:Project + '/identityPlatform:initializeAuth') -Headers $h -Body @{}
  $err = Get-ApiError $r
  if ($err) { Write-Log ('initializeAuth: ' + $err) }
  if ($err -match 'BILLING_NOT_ENABLED') {
    Set-St 'authApiNeedsBilling' $Script:Project
    Info 'Google only allows the program to start Authentication on a paid plan. On the free plan it is ONE click in the browser: the next step opens the page for you.'
    return $false
  }
  if ($err) { Info ('Google answered: ' + $err) }
  for ($i = 0; $i -lt 8; $i++) {
    $c = Invoke-Http -Uri $cfgUrl -Headers $h
    if ($c.Status -eq 200) { Ok 'Authentication is started.'; return $true }
    Wait-Sec 4
  }
  return $false
}

function Enable-EmailAuth {
  [void](Initialize-FirebaseAuth)
  $tok = Get-GoogleAccessToken
  if ($tok) {
    $h = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
    $url = 'https://identitytoolkit.googleapis.com/admin/v2/projects/' + $Script:Project + '/config?updateMask=signIn.email.enabled,signIn.email.passwordRequired'
    $r = Invoke-Http -Method 'PATCH' -Uri $url -Headers $h -Body @{ signIn = @{ email = @{ enabled = $true; passwordRequired = $true } } }
    $err = Get-ApiError $r
    if ($err) { Write-Log ('enable email auth: ' + $err) }
    for ($i = 0; $i -lt 6; $i++) { if (Test-EmailAuthEnabled) { return }; Wait-Sec 5 }
  }
  $null = Invoke-Manual -Title 'Turn on Email/Password sign-in' -Url (Get-ConsoleUrl 'authentication/providers') -Steps @(
    'If you see a "Get started" button, click it first.',
    'Under "Sign-in providers" click "Email/Password" (or "Add new provider" > "Email/Password").',
    'Switch ON the first toggle "Email/Password" (leave "Email link" off).',
    'Click Save.') -Check { Test-EmailAuthEnabled }
}

function Test-GoogleAuthEnabled {
  $Script:LastHint = ''
  $tok = Get-GoogleAccessToken
  if ($tok) {
    $h = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
    $r = Invoke-Http -Uri ('https://identitytoolkit.googleapis.com/admin/v2/projects/' + $Script:Project + '/defaultSupportedIdpConfigs/google.com') -Headers $h
    if ($r.Json -and $r.Json.enabled -eq $true) {
      $cfg = ConvertTo-FirebaseCfg (Get-SdkConfig) $Package
      if ($cfg -and $cfg.webClientId) { return $true }
      $Script:LastHint = 'Google is enabled, but the web client ID is not in the app config yet.'
      return $false
    }
    if ($r.Status -eq 200 -or $r.Status -eq 404) { $Script:LastHint = 'Google provider is still off.'; return $false }
  }
  # fallback: the web OAuth client appears in the app config once Google is enabled
  $cfg = ConvertTo-FirebaseCfg (Get-SdkConfig) $Package
  if ($cfg -and $cfg.webClientId) { return $true }
  $Script:LastHint = 'No Google web client in the app config yet.'
  return $false
}

function Enable-GoogleAuth {
  [void](Initialize-FirebaseAuth)
  if (-not (Test-GoogleAuthEnabled)) {
    $null = Invoke-Manual -Title 'Start Authentication and turn on Google sign-in' -Url (Get-ConsoleUrl 'authentication/providers') -Steps @(
      'If you see a blue "Get started" button, click it (this starts Authentication; it is free).',
      'Click "Add new provider" (or "Sign-in method" > "Add new provider"), then "Google".',
      'Switch the "Enable" toggle ON.',
      ('Pick a "Project support email" (your Gmail ' + $Script:Account + ').'),
      'Click Save.') -Check { Test-GoogleAuthEnabled }
  }
  [void](Update-FirebaseConfig)
}

function Test-GoogleConfigReady {
  $cfg = Get-St 'cfg'
  return ($cfg -and $cfg.webClientId -and (Test-FirebaseConfigFile))
}

# ------------------------------------------------------------------ accounts via REST
function Invoke-SignUp([string]$email, [string]$pw) {
  return (Invoke-Http -Method 'POST' -Uri (Get-IdentityUrl 'accounts:signUp') -Headers (Get-AndroidHeaders) -Body @{ email = $email; password = $pw; returnSecureToken = $true })
}
function Invoke-SignIn([string]$email, [string]$pw) {
  return (Invoke-Http -Method 'POST' -Uri (Get-IdentityUrl 'accounts:signInWithPassword') -Headers (Get-AndroidHeaders) -Body @{ email = $email; password = $pw; returnSecureToken = $true })
}
function Remove-AuthUser([string]$idToken) {
  $null = Invoke-Http -Method 'POST' -Uri (Get-IdentityUrl 'accounts:delete') -Headers (Get-AndroidHeaders) -Body @{ idToken = $idToken }
}

# ------------------------------------------------------------------ live rules test
function Get-FsDocUrl([string]$path) {
  return ('https://firestore.googleapis.com/v1/projects/' + $Script:Project + '/databases/(default)/documents/' + $path)
}

function ConvertTo-FsValue($v) {
  if ($v -is [string]) { return @{ stringValue = $v } }
  if ($v -is [bool]) { return @{ booleanValue = $v } }
  if ($v -is [array]) { return @{ arrayValue = @{ values = @($v | ForEach-Object { ConvertTo-FsValue $_ }) } } }
  if ($v -is [hashtable]) {
    $f = @{}
    foreach ($k in $v.Keys) { $f[$k] = ConvertTo-FsValue $v[$k] }
    return @{ mapValue = @{ fields = $f } }
  }
  return @{ doubleValue = [double]$v }
}

function ConvertTo-FsDoc([hashtable]$h) {
  $f = @{}
  foreach ($k in $h.Keys) { $f[$k] = ConvertTo-FsValue $h[$k] }
  return @{ fields = $f }
}

# ------------------------------------------------------------------ user accounts (optional)
# ------------------------------------------------------------------ live rules test (Scanny: groups, members, status with proof, comments, devices)
function Get-FsCommitUrl { return ('https://firestore.googleapis.com/v1/projects/' + $Script:Project + '/databases/(default)/documents:commit') }

function Invoke-FsCommit([string]$idToken, [string]$path, [hashtable]$fields, [string[]]$mask, [string[]]$serverTs) {
  $name = 'projects/' + $Script:Project + '/databases/(default)/documents/' + $path
  $w = @{ update = @{ name = $name; fields = (ConvertTo-FsDoc $fields).fields }; updateMask = @{ fieldPaths = @($mask) } }
  if ($serverTs -and @($serverTs).Count -gt 0) { $w['updateTransforms'] = @($serverTs | ForEach-Object { @{ fieldPath = $_; setToServerValue = 'REQUEST_TIME' } }) }
  return (Invoke-Http -Method 'POST' -Uri (Get-FsCommitUrl) -Headers @{ Authorization = 'Bearer ' + $idToken } -Body @{ writes = @($w) })
}

function New-VerifiedUser([string]$tok, [string]$email, [string]$pw) {
  $h = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
  $r = Invoke-Http -Method 'POST' -Uri ('https://identitytoolkit.googleapis.com/v1/projects/' + $Script:Project + '/accounts') -Headers $h -Body @{ email = $email; password = $pw; emailVerified = $true }
  if ($r.Json -and $r.Json.localId) { return [string]$r.Json.localId }
  $Script:LastHint = Get-ApiError $r
  return ''
}

# Returns $true (all checks passed), $false (some failed) or $null (the test could not run, which is not an error).
function Invoke-RulesLiveTest {
  $tok = Get-GoogleAccessToken
  if (-not $tok) { $Script:LastHint = 'No Google token from firebase-tools.'; return $null }
  $tag = New-RandomString 6 'abcdefghijkmnpqrstuvwxyz23456789'
  $pw = 'T' + (New-RandomString 14 'abcdefghijkmnpqrstuvwxyz23456789') + '!'
  $ea = 'scanny-rt-a-' + $tag + '@example.com'
  $eb = 'scanny-rt-b-' + $tag + '@example.com'
  $ec = 'scanny-rt-c-' + $tag + '@example.com'
  $ga = 'rt-a-' + $tag
  $gb = 'rt-b-' + $tag
  $admin = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
  $ids = @{}
  $users = @()
  foreach ($e in @($ea, $eb, $ec)) {
    $uid = New-VerifiedUser $tok $e $pw
    if (-not $uid) { $Script:LastHint = 'Could not create a temporary test user: ' + $Script:LastHint; foreach ($u in $users) { Remove-AuthUser $u }; return $null }
    $si = Invoke-SignIn $e $pw
    if (-not ($si.Json -and $si.Json.idToken)) { $Script:LastHint = 'Could not sign in a temporary test user: ' + (Get-ApiError $si); foreach ($u in $users) { Remove-AuthUser $u }; return $null }
    $ids[$e] = [string]$si.Json.idToken
    $users += , [string]$si.Json.idToken
  }
  $hA = @{ Authorization = 'Bearer ' + $ids[$ea] }
  $hB = @{ Authorization = 'Bearer ' + $ids[$eb] }
  $hC = @{ Authorization = 'Bearer ' + $ids[$ec] }
  $wp = 'watch/rt-w-' + $tag
  $paths = @('members/' + $ea, 'members/' + $eb, 'members/' + $ec, $wp, ('groups/' + $ga + '/findings/f1'), ('groups/' + $gb + '/findings/f1'), ('groups/' + $ga + '/comments/c1'), ('groups/' + $ga + '/comments/c2'), 'devices/rt-a', 'groups/' + $ga, 'groups/' + $gb)
  $results = @()
  try {
    $null = Invoke-Http -Method 'PATCH' -Uri (Get-FsDocUrl ('members/' + $ea)) -Headers $admin -Body (ConvertTo-FsDoc @{ email = $ea; name = 'A'; role = 'member'; groups = @($ga); active = $true })
    $null = Invoke-Http -Method 'PATCH' -Uri (Get-FsDocUrl ('members/' + $eb)) -Headers $admin -Body (ConvertTo-FsDoc @{ email = $eb; name = 'B'; role = 'member'; groups = @($gb); active = $true; watch = $true })
    $null = Invoke-Http -Method 'PATCH' -Uri (Get-FsDocUrl ('members/' + $ec)) -Headers $admin -Body (ConvertTo-FsDoc @{ email = $ec; name = 'C'; role = 'admin'; groups = @(); active = $true })
    foreach ($g in @($ga, $gb)) {
      $null = Invoke-Http -Method 'PATCH' -Uri (Get-FsDocUrl ('groups/' + $g)) -Headers $admin -Body (ConvertTo-FsDoc @{ name = $g; pushMin = 'critical' })
      $null = Invoke-Http -Method 'PATCH' -Uri (Get-FsDocUrl ('groups/' + $g + '/findings/f1')) -Headers $admin -Body (ConvertTo-FsDoc @{ cve = 'CVE-0000-0001'; sid = 's1'; score = 90; label = 'critical'; status = 'ongoing'; groups = @($g) })
    }
    $null = Invoke-Http -Method 'PATCH' -Uri (Get-FsDocUrl $wp) -Headers $admin -Body (ConvertTo-FsDoc @{ title = 'Test article'; feed = 'Test'; link = 'https://example.com'; mine = $false })
    $f1 = 'groups/' + $ga + '/findings/f1'
    $r = Invoke-Http -Uri (Get-FsDocUrl $f1) -Headers $hA
    $results += , @('Member reads a finding of their own group', ($r.Status -eq 200), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl ('groups/' + $gb + '/findings/f1')) -Headers $hA
    $results += , @('Member is DENIED another group''s finding', ($r.Status -eq 403), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl ('groups/' + $gb + '/findings/f1')) -Headers $hC
    $results += , @('Admin reads every group', ($r.Status -eq 200), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl $f1)
    $results += , @('Anonymous (no login) is DENIED', ($r.Status -eq 403 -or $r.Status -eq 401), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl ('members/' + $ea)) -Headers $hA
    $results += , @('Member reads their own member record', ($r.Status -eq 200), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl ('members/' + $eb)) -Headers $hA
    $results += , @('Member is DENIED someone else''s member record', ($r.Status -eq 403), $r.Status)
    $r = Invoke-FsCommit $ids[$ea] $f1 @{ status = 'acknowledged'; statusBy = $ea; statusByName = 'A' } @('status', 'statusAt', 'statusBy', 'statusByName') @('statusAt')
    $results += , @('Member sets Acknowledged', ($r.Status -eq 200), $r.Status)
    $r = Invoke-FsCommit $ids[$ea] $f1 @{ status = 'solved'; solved = @{ upgrade = $true; version = ''; actions = '' }; statusBy = $ea; statusByName = 'A' } @('status', 'solved', 'statusAt', 'statusBy', 'statusByName') @('statusAt')
    $results += , @('Solved WITHOUT proof is DENIED', ($r.Status -eq 403), $r.Status)
    $r = Invoke-FsCommit $ids[$ea] $f1 @{ status = 'solved'; solved = @{ upgrade = $true; version = '2.1'; actions = '' }; statusBy = $ea; statusByName = 'A' } @('status', 'solved', 'statusAt', 'statusBy', 'statusByName') @('statusAt')
    $results += , @('Solved WITH the upgraded version is accepted', ($r.Status -eq 200), $r.Status)
    $r = Invoke-FsCommit $ids[$ea] $f1 @{ status = 'solved'; solved = @{ upgrade = $false; version = ''; actions = 'Blocked port 443 on the firewall' }; statusBy = $ea; statusByName = 'A' } @('status', 'solved', 'statusAt', 'statusBy', 'statusByName') @('statusAt')
    $results += , @('Solved WITH restrictive actions is accepted', ($r.Status -eq 200), $r.Status)
    $r = Invoke-FsCommit $ids[$ea] $f1 @{ score = 1 } @('score') @()
    $results += , @('Changing the score is DENIED', ($r.Status -eq 403), $r.Status)
    $r = Invoke-FsCommit $ids[$eb] $f1 @{ status = 'acknowledged'; statusBy = $eb; statusByName = 'B' } @('status', 'statusAt', 'statusBy', 'statusByName') @('statusAt')
    $results += , @('Another group cannot change the status', ($r.Status -eq 403), $r.Status)
    $r = Invoke-FsCommit $ids[$ea] ('groups/' + $ga + '/comments/c1') @{ fid = 's1_CVE-0000-0001'; cve = 'CVE-0000-0001'; text = 'checked'; by = $ea; byName = 'A' } @('fid', 'cve', 'text', 'by', 'byName', 'at') @('at')
    $results += , @('Member writes a comment as themselves', ($r.Status -eq 200), $r.Status)
    $r = Invoke-FsCommit $ids[$ea] ('groups/' + $ga + '/comments/c2') @{ fid = 's1_CVE-0000-0001'; cve = 'CVE-0000-0001'; text = 'spoof'; by = $eb; byName = 'B' } @('fid', 'cve', 'text', 'by', 'byName', 'at') @('at')
    $results += , @('A comment in someone else''s name is DENIED', ($r.Status -eq 403), $r.Status)
    $r = Invoke-Http -Method 'PATCH' -Uri (Get-FsDocUrl 'devices/rt-a') -Headers $hA -Body (ConvertTo-FsDoc @{ email = $ea; token = 'x'; platform = 'android' })
    $results += , @('Member registers their phone for push', ($r.Status -eq 200), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl 'devices/rt-a') -Headers $hB
    $results += , @('Another member cannot read that phone record', ($r.Status -eq 403), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl $wp) -Headers $hB
    $results += , @('Zero-day watch: a member with the switch ON reads the articles', ($r.Status -eq 200), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl $wp) -Headers $hA
    $results += , @('Zero-day watch: a member with the switch OFF is DENIED', ($r.Status -eq 403), $r.Status)
    $r = Invoke-Http -Uri (Get-FsDocUrl $wp) -Headers $hC
    $results += , @('Zero-day watch: an admin reads the articles', ($r.Status -eq 200), $r.Status)
    $r = Invoke-Http -Method 'PATCH' -Uri (Get-FsDocUrl $wp) -Headers $hB -Body (ConvertTo-FsDoc @{ title = 'Changed by a phone' })
    $results += , @('Zero-day watch: a phone can never write an article', ($r.Status -eq 403), $r.Status)
  } finally {
    # twice: the first pass can miss a document that was still being written; the groups themselves go last
    foreach ($pass in 1..2) { foreach ($pth in $paths) { $null = Invoke-Http -Method 'DELETE' -Uri (Get-FsDocUrl $pth) -Headers $admin } }
    foreach ($u in $users) { Remove-AuthUser $u }
  }
  $allOk = $true
  foreach ($row in $results) {
    if ($row[1]) { Ok ($row[0] + ' (HTTP ' + $row[2] + ')') } else { Fail ($row[0] + ' (HTTP ' + $row[2] + ')'); $allOk = $false }
  }
  if (-not $allOk) { $Script:LastHint = 'Some rule checks failed. New rules can take about a minute to apply.' }
  return $allOk
}

function Test-RulesLive {
  for ($i = 1; $i -le 3; $i++) {
    $res = Invoke-RulesLiveTest
    if ($null -eq $res) { Warn ('The live rules test could not run (' + $Script:LastHint + '). Continuing: the app is still set up.'); Set-St 'rulesTestSkipped' $true; return $true }
    if ($res) { Set-St 'rulesTestedHash' (Get-St 'rulesHash'); return $true }
    if ($i -lt 3) { Info 'Retrying in 30 seconds (rules propagation)...'; Wait-Sec 30 }
  }
  Warn 'Some security-rule checks still fail. Setup continues, but if the phone app says "permission denied" run START-SCANNY-PHONE option 3 and send me the log.'
  Set-St 'rulesTestSkipped' $true
  return $false
}

# ------------------------------------------------------------------ who may sign in
function Ask-TeamMembers {
  if (Get-St 'membersAsked') { return }
  Info 'Only the Google addresses you list here can sign in to the phone app. You can change this later in Scanny for Windows > Team > Members.'
  $raw = [string](Ask 'Google email addresses, separated by commas (Enter = only you)')
  $list = @()
  foreach ($x in ($raw -split '[,;\s]+')) {
    $e = $x.Trim().ToLower()
    if ($e -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' -and $e -ne ([string]$Script:Account).ToLower()) { $list += $e }
  }
  Set-St 'members' $list
  Set-St 'membersAsked' $true
  if ($list.Count -gt 0) { Ok ('Members: ' + ($list -join ', ')) } else { Info 'Only your own account for now.' }
}

# ------------------------------------------------------------------ link to Scanny for Windows (creates the service account key and hands it over by file)
function Get-ScannyDataDir {
  if ($env:SCANNY_HOME) { return $env:SCANNY_HOME }
  if ($OnWindows -and $env:APPDATA) { return (Join-Path $env:APPDATA 'Scanny') }
  return (Join-Path $HOME '.scanny')
}

function Get-IamUrl([string]$path) { return ('https://iam.googleapis.com/v1/' + $path) }

function Find-AdminSdkAccount([string]$tok) {
  $h = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
  for ($i = 0; $i -lt 8; $i++) {
    $r = Invoke-Http -Uri (Get-IamUrl ('projects/' + $Script:Project + '/serviceAccounts?pageSize=100')) -Headers $h
    if ($r.Json -and $r.Json.accounts) {
      foreach ($a in @($r.Json.accounts)) { if ([string]$a.email -like 'firebase-adminsdk-*') { return [string]$a.email } }
    }
    if ($i -eq 0) { Info 'Waiting for Firebase to create its admin service account...' }
    Wait-Sec 8
  }
  return ''
}

function New-ServiceAccountKey([string]$tok, [string]$email) {
  $h = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
  $r = Invoke-Http -Method 'POST' -Uri (Get-IamUrl ('projects/' + $Script:Project + '/serviceAccounts/' + $email + '/keys')) -Headers $h -Body @{ keyAlgorithm = 'KEY_ALG_RSA_2048'; privateKeyType = 'TYPE_GOOGLE_CREDENTIALS_FILE' }
  if ($r.Json -and $r.Json.privateKeyData) {
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$r.Json.privateKeyData))
    return @{ Json = $json; KeyId = ([string]$r.Json.name -replace '^.*/keys/', '') }
  }
  $Script:LastHint = Get-ApiError $r
  return $null
}

function Remove-ServiceAccountKey([string]$tok, [string]$email, [string]$keyId) {
  if (-not $keyId) { return }
  $h = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
  $null = Invoke-Http -Method 'DELETE' -Uri (Get-IamUrl ('projects/' + $Script:Project + '/serviceAccounts/' + $email + '/keys/' + $keyId)) -Headers $h
}

function Test-WindowsLinked {
  return ((Get-St 'linkedProject') -eq $Script:Project -and [bool](Get-St 'linkedAt'))
}

function Write-WindowsLink {
  $tok = Get-GoogleAccessToken
  $keyJson = ''
  $keyId = ''
  $email = ''
  if ($tok) {
    $email = Find-AdminSdkAccount $tok
    if ($email) {
      $k = New-ServiceAccountKey $tok $email
      if ($k) { $keyJson = [string]$k.Json; $keyId = [string]$k.KeyId; Ok ('Created a key for ' + $email) }
    }
  }
  if (-not $keyJson) {
    Warn ('The key could not be created automatically' + $(if ($Script:LastHint) { ': ' + $Script:LastHint } else { '.' }))
    Info 'Some Google accounts forbid creating keys (an organisation policy). You can download one by hand instead:'
    $null = Invoke-Manual -Title 'Download the Firebase service account key' -Url (Get-ConsoleUrl 'settings/serviceaccounts/adminsdk') -Steps @(
      'Click "Generate new private key", then "Generate key". A .json file downloads.',
      'Remember where it was saved (usually the Downloads folder).') -Check { $true }
    $pth = ([string](Ask 'Full path of the downloaded .json file (Enter = skip, link later with option 7)')).Trim().Trim('"')
    if ($pth -and (Test-Path $pth)) { $keyJson = [IO.File]::ReadAllText($pth) }
  }
  if (-not $keyJson) { Warn 'The Windows app was NOT linked. Run START-SCANNY-PHONE option 7 later.'; return $false }
  try { $sa = $keyJson | ConvertFrom-Json } catch { Warn 'That file is not a valid service account key.'; return $false }
  if (-not $sa.client_email -or -not $sa.private_key) { Warn 'That file has no client_email or private_key.'; return $false }
  $cfg = Get-St 'cfg'
  $members = @()
  foreach ($m in @(Get-St 'members')) { if ($m) { $members += , @{ email = [string]$m; name = ([string]$m -split '@')[0]; role = 'member' } } }
  $link = [ordered]@{
    version = 1
    project_id = $Script:Project
    service_account = $sa
    web_api_key = [string]$cfg.apiKey
    app_id = [string]$cfg.appId
    hosting_url = ('https://' + $Script:Project + '.web.app')
    admin_email = [string]$Script:Account
    admin_name = ([string]$Script:Account -split '@')[0]
    members = $members
    created = (Get-Date).ToString('s')
  }
  $dir = Get-ScannyDataDir
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $file = Join-Path $dir 'firebase-link.json'
  [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $link -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
  $oldKey = [string](Get-St 'linkKeyId')
  if ($oldKey -and $oldKey -ne $keyId -and $tok -and $email) { Remove-ServiceAccountKey $tok $email $oldKey }
  Set-St 'linkedProject' $Script:Project
  Set-St 'linkedAt' ((Get-Date).ToString('s'))
  if ($keyId) { Set-St 'linkKeyId' $keyId }
  Ok ('Link file written for Scanny for Windows: ' + $file)
  Info 'Scanny for Windows picks it up by itself, switches phone sync on, deploys the rules and adds you as the first admin.'
  $done = $false
  for ($i = 0; $i -lt 12; $i++) {
    Wait-Sec 5
    try { $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json; if ($j.imported) { $done = $true; break } } catch { }
  }
  if ($done) { Ok 'Scanny for Windows linked itself. Open Team in its sidebar: it says "Linked".' }
  else { Info 'Scanny for Windows is not running (or is locked) right now. It links itself the next time it runs, or open Team > "I ran it, check now".' }
  return $true
}

function Invoke-LinkOnly {
  Head 'Link Firebase to Scanny for Windows'
  Update-SessionPath
  Assert-NewRegionProject
  $Script:Project = [string](Get-St 'projectId')
  if (-not $Script:Project -or -not (Get-St 'cfg')) { throw 'There is no Firebase project yet - run START-SCANNY-PHONE option 1 first.' }
  Ensure-FirebaseLogin
  Ask-TeamMembers
  if (Write-WindowsLink) { Set-St 'linkSkipped' $false }
}

function Publish-ToWindows {
  $apk = Join-Path $OutDir 'Scanny-latest.apk'
  if (-not (Test-Path $apk)) { return }
  try {
    $dir = Join-Path (Get-ScannyDataDir) 'phone-app'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ver = Get-PubspecVersion (Join-Path $AppDir 'pubspec.yaml')
    $n = [int](Get-St 'buildNumber')
    foreach ($old in @(Get-ChildItem -Path $dir -Filter '*.apk' -ErrorAction SilentlyContinue)) { Remove-Item -Force $old.FullName }
    Copy-Item -Force $apk (Join-Path $dir ('Scanny-' + $ver + '.apk'))
    $info = [ordered]@{ version = $ver; build = $n; notes = (Get-LatestChangeNotes); hosting_url = ('https://' + $Script:Project + '.web.app'); sha256 = (Get-FileSha $apk).ToLower(); date = (Get-Date).ToString('yyyy-MM-dd') }
    [IO.File]::WriteAllText((Join-Path $dir 'version.json'), (ConvertTo-Json -InputObject $info -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Ok ('Copied the app for Scanny for Windows: Team > Phones and sync now shows a QR code to install it (' + $dir + ').')
  } catch { Warn ('Could not copy the app for Scanny for Windows: ' + $_.Exception.Message) }
}


# ------------------------------------------------------------------ build
$KnownOverrides = @{ 'record_linux' = '1.1.1' }

function Add-DependencyOverride([string]$name, [string]$ver) {
  $p = Join-Path $AppDir 'pubspec.yaml'
  $t = [IO.File]::ReadAllText($p) -replace "`r`n", "`n"
  if ($t -match ('(?m)^\s+' + [regex]::Escape($name) + ':')) { if ($t -match '(?m)^dependency_overrides:') { return } }
  if ($t -notmatch '(?m)^dependency_overrides:') { $t = $t.TrimEnd() + "`n`ndependency_overrides:`n" }
  $t = $t.TrimEnd() + "`n  " + $name + ': ' + $ver + "`n"
  Write-TextFile $p $t
  Info ('Added dependency override ' + $name + ': ' + $ver)
}

function Invoke-PubGet([string]$f) {
  $r = Invoke-Native $f @('pub', 'get') -Cwd $AppDir -Stream
  if ($r.Code -eq 0) { return }
  foreach ($k in $KnownOverrides.Keys) { if ($r.Out -match [regex]::Escape($k)) { Add-DependencyOverride $k $KnownOverrides[$k] } }
  Warn 'pub get failed - trying to upgrade package versions (google_sign_in stays on v6).'
  $null = Invoke-Native $f @('pub', 'upgrade', '--major-versions', 'firebase_core', 'firebase_auth', 'cloud_firestore', 'flutter_lints', 'shared_preferences', 'flutter_animate', 'provider', 'dynamic_color') -Cwd $AppDir -Stream
  $r = Invoke-Native $f @('pub', 'get') -Cwd $AppDir -Stream
  if ($r.Code -ne 0) {
    Write-BuildError $r.Lines 'flutter pub get'
    throw 'Downloading Dart packages failed - see Output\build-error.txt.'
  }
}

function Get-BuildHints([string]$text) {
  $h = @()
  if ($text -match '(?i)Unsupported class file major version|Could not determine java version|JAVA_HOME is set to an invalid|requires Java 17|Java 17') { $h += 'Java/JDK problem: run Rebuild again (the JDK is re-detected each time). If it repeats, uninstall old JDKs.' }
  if ($text -match '(?i)License for package .+ not accepted|You have not accepted the license agreements') { $h += 'Android SDK licenses not accepted: run START-SCANNY-PHONE option 1 (it accepts them).' }
  if ($text -match '(?i)Could not (resolve|GET|download)|Connection (timed out|refused|reset)|UnknownHostException|PKIX') { $h += 'Network problem downloading build files (proxy, VPN, firewall or SSL inspection). Try another network.' }
  if ($text -match '(?i)compileSdk|android-36|checkDebugAarMetadata|checkReleaseAarMetadata|requires libraries and applications that depend on it to compile against version') { $h += 'Android SDK level problem: run START-SCANNY-PHONE option 3 (Health check) - it verifies platform android-36 and the compileSdk hook.' }
  if ($text -match '(?i)coreLibraryDesugaring|desugar') { $h += 'Desugaring problem: the Gradle patch may have been undone. Rebuild re-applies it; if it repeats, send build-error.txt.' }
  if ($text -match '(?i)minSdk(Version)? \d+ cannot be smaller|uses-sdk:minSdkVersion') { $h += 'minSdk problem: Rebuild re-applies minSdk 23.' }
  if ($text -match '(?i)Script compilation error|build\.gradle(\.kts)?:\d+:\d+: Unresolved reference') { $h += 'Android build-file (Gradle) error: run Rebuild again - the wizard re-checks and rewrites its build-file changes. If it repeats, send build-error.txt.' }
  if ($text -match '(?i)Keystore was tampered|password was incorrect|keystore.*not found|Failed to read key') { $h += 'Signing key problem: key.properties does not match the keystore. Do NOT create a new key; send setup.log.' }
  if ($text -match '(?i)Filename too long|path too long|MAX_PATH') { $h += 'Windows path too long: keep the work folder at C:\ScannyBuild.' }
  if ($text -match '(?i)No space left|not enough space') { $h += 'Disk is full: free at least 10 GB.' }
  if ($text -match '(?i)version solving failed') { $h += 'Dart package versions conflict: send build-error.txt.' }
  if ($text -match '(?i)\berror\b.*\.dart:\d+') { $h += 'Dart code error in the app: send build-error.txt and analyze-report.txt.' }
  return $h
}

function Write-BuildError([string[]]$lines, [string]$what) {
  $errs = @($lines | Where-Object { $_ -match '(?i)(\berror\b|FAILURE:|What went wrong|Exception:|\* Error)' -and $_ -notmatch '(?i)RemoteException' })
  $tail = @($lines | Select-Object -Last 150)
  $hints = Get-BuildHints ($lines -join "`n")
  $txt = @('SCANNY BUILD ERROR - ' + $what, (Get-Date -Format 's'), '')
  if ($hints.Count -gt 0) { $txt += 'WHAT IT PROBABLY MEANS:'; foreach ($x in $hints) { $txt += ('  - ' + $x) }; $txt += '' }
  $txt += '=== ERROR LINES ==='
  $txt += ($errs | Select-Object -First 80)
  $txt += ''
  $txt += '=== LAST 150 LINES ==='
  $txt += $tail
  Write-TextFile (Join-Path $OutDir 'build-error.txt') ($txt -join "`r`n")
  Fail ($what + ' failed.')
  if ($hints.Count -gt 0) { foreach ($x in $hints) { Warn $x } } else { Info 'No known cause matched - please send Output\build-error.txt.' }
  foreach ($e in ($errs | Select-Object -First 8)) { Info $e }
}

function Invoke-Analyze([string]$f) {
  Info 'Checking the code (flutter analyze)...'
  $r = Invoke-Native $f @('analyze', '--no-fatal-infos', '--no-fatal-warnings') -Cwd $AppDir
  Write-TextFile (Join-Path $OutDir 'analyze-report.txt') ($r.Lines -join "`r`n")
  $errs = @($r.Lines | Where-Object { $_ -match '^\s*error\s*[•-]' })
  if ($errs.Count -gt 0) {
    Fail ('The code has ' + $errs.Count + ' error(s) - see Output\analyze-report.txt')
    foreach ($e in ($errs | Select-Object -First 10)) { Info $e }
    return $false
  }
  Ok 'Code check passed (warnings/infos, if any, are in analyze-report.txt).'
  return $true
}

# ------------------------------------------------------------------ built-in Kotlin
# Flutter warns "plugins that apply Kotlin Gradle Plugin (KGP)" while the app still uses the old Kotlin plugin.
# With Flutter 3.47+ and Android Gradle Plugin 9+, Kotlin comes from AGP itself: the app drops kotlin-android,
# gradle.properties says android.builtInKotlin=true, and every plugin (updated ones and the local copies in
# app\packages) stops applying KGP. Skipped on older Flutter / AGP, or when SCANNY_NO_BUILTIN_KOTLIN is set.
function Get-AgpMajor {
  $android = Join-Path $AppDir 'android'
  foreach ($n in @('settings.gradle.kts', 'settings.gradle')) {
    $p = Join-Path $android $n
    if (Test-Path $p) {
      $m = [regex]::Match([IO.File]::ReadAllText($p), 'com\.android\.application["'']\s*\)?\s*version\s*["''](\d+)\.')
      if ($m.Success) { return [int]$m.Groups[1].Value }
    }
  }
  return 0
}

function Update-AppGradleBuiltInKotlin([string]$text) {
  $t = $text -replace "`r`n", "`n"
  if ($t -match 'scanny-builtin-kotlin') { return $t }
  # keep the app's Java level for Kotlin (JavaVersion.VERSION_17 -> JVM_17, VERSION_1_8 -> JVM_1_8)
  $jvm = 'JVM_17'
  $jm = [regex]::Match($t, 'jvmTarget\s*=\s*JavaVersion\.VERSION_(\d+)(?:_(\d+))?')
  if ($jm.Success) { if ($jm.Groups[2].Success) { $jvm = 'JVM_' + $jm.Groups[1].Value + '_' + $jm.Groups[2].Value } else { $jvm = 'JVM_' + $jm.Groups[1].Value } }
  $t = [regex]::Replace($t, '(?m)^[ \t]*id\(\s*["'']?(?:kotlin-android|org\.jetbrains\.kotlin\.android)["'']?\s*\)[^\n]*\n', '')
  $t = [regex]::Replace($t, '(?m)^[ \t]*id\s+["''](?:kotlin-android|org\.jetbrains\.kotlin\.android)["''][^\n]*\n', '')
  $t = [regex]::Replace($t, '(?m)^[ \t]*apply plugin:\s*["'']kotlin-android["''][^\n]*\n', '')
  $t = [regex]::Replace($t, '(?ms)^[ \t]*kotlinOptions\s*\{[^{}]*\}[ \t]*\n?', '')
  $block = "`n// scanny-builtin-kotlin: Kotlin comes from the Android Gradle Plugin (android.builtInKotlin=true)`nkotlin {`n    compilerOptions {`n        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget." + $jvm + "`n    }`n}`n"
  return ($t.TrimEnd() + "`n" + $block)
}

function Update-GradlePropertiesBuiltInKotlin([string]$text) {
  $t = $text -replace "`r`n", "`n"
  if ($t -match '(?m)^android\.builtInKotlin\s*=') { return [regex]::Replace($t, '(?m)^android\.builtInKotlin\s*=.*$', 'android.builtInKotlin=true') }
  return ($t.TrimEnd() + "`nandroid.builtInKotlin=true`n")
}

function Enable-BuiltInKotlin {
  if ($env:SCANNY_NO_BUILTIN_KOTLIN) { Info 'Built-in Kotlin: skipped (SCANNY_NO_BUILTIN_KOTLIN is set).'; return }
  try {
    $f = Get-FlutterExe
    $r = Invoke-Native $f @('--version')
    $v = Get-FlutterVersion $r.Out
    if ($null -eq $v -or $v -lt [version]'3.47.0') { Warn 'Built-in Kotlin needs Flutter 3.47+ - skipped (the Kotlin warnings stay; the build still works).'; return }
    $agp = Get-AgpMajor
    if ($agp -lt 9) { Info ('Built-in Kotlin: this Android project uses Android Gradle Plugin ' + $agp + ' (needs 9+) - skipped.'); return }
    $g = Get-GradleFiles
    if (-not $g.App) { return }
    $props = Join-Path $g.Android 'gradle.properties'
    foreach ($file in @($props, $g.App)) {
      if ((Test-Path $file) -and -not (Test-Path ($file + '.scanny-bak'))) { Copy-Item -Force $file ($file + '.scanny-bak') }
    }
    if (Test-Path $props) { [void](Update-TextFileKeepEol $props { param($s) Update-GradlePropertiesBuiltInKotlin $s }) }
    else { Write-TextFile $props "android.builtInKotlin=true`n" }
    [void](Update-TextFileKeepEol $g.App { param($s) Update-AppGradleBuiltInKotlin $s })
    Ok 'Built-in Kotlin is on (no more "plugins that apply KGP" warning). To undo: set SCANNY_NO_BUILTIN_KOTLIN=1 and restore the .scanny-bak files in C:\ScannyBuild\app\android.'
  } catch {
    Warn ('Built-in Kotlin could not be enabled (' + $_.Exception.Message + ') - building without it.')
  }
}

function Invoke-Build {
  Head 'Building the APK'
  [void](Ensure-Jdk)
  $f = Get-FlutterExe
  if (-not $f) { throw 'Flutter not found - run START-SCANNY-PHONE option 1.' }
  if (-not (Test-FlutterVersion)) {
    Warn ('Flutter must be ' + $MinFlutter + ' or newer - upgrading the stable channel.')
    [void](Invoke-Native $f @('upgrade', '--force') -Stream)
    if (-not (Test-FlutterVersion)) { throw 'Flutter could not be upgraded to 3.47+.' }
  }
  if (Test-GradlePatches) { Ok 'Android build files: verified.' }
  else {
    Info 'Android build files need (re)patching - applying the current version...'
    Invoke-GradlePatches
    if (-not (Test-GradlePatches)) { throw 'Gradle patches could not be applied/verified.' }
    Ok 'Android build files: repaired and verified.'
  }
  Enable-BuiltInKotlin
  # A failed build must never leave an OLD apk that looks like the new one.
  foreach ($stale in @('Scanny-latest.apk')) {
    $sp = Join-Path $OutDir $stale
    if (Test-Path $sp) { Remove-Item -Force $sp }
  }
  Ensure-Keystore
  Write-KeyProperties
  if (-not (Test-FirebaseConfigFile)) { if (Get-St 'cfg') { Write-FirebaseConfigFiles (Get-St 'cfg') } }
  if (-not (Test-FirebaseConfigFile)) { throw 'lib/firebase_options.dart has no real Firebase values - run START-SCANNY-PHONE option 1.' }
  Invoke-PubGet $f
  if (-not (Invoke-Analyze $f)) {
    $c = ([string](Ask 'Build anyway? (y/N)')).Trim().ToUpper()
    if ($c -ne 'Y') { throw 'Stopped because of code errors (see Output\analyze-report.txt). NO new APK was made - send me that file.' }
  }
  $n = 1
  if (Get-St 'buildNumber') { $n = [int](Get-St 'buildNumber') + 1 }
  Info ('Building release APK #' + $n + '. The FIRST build takes 10-20 minutes (downloads Gradle and Android parts). Later builds: 2-5 minutes.')
  $r = Invoke-Native $f @('build', 'apk', '--release', '--no-shrink', '--build-number', [string]$n) -Cwd $AppDir -Stream
  $apk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
  if (-not $OnWindows) { $apk = Join-Path $AppDir 'build/app/outputs/flutter-apk/app-release.apk' }
  if ($r.Code -ne 0 -or -not (Test-Path $apk)) {
    Write-BuildError $r.Lines 'flutter build apk'
    throw 'Build failed - see Output\build-error.txt (send it together with setup.log).'
  }
  Set-St 'buildNumber' $n
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $ver = Get-PubspecVersion (Join-Path $AppDir 'pubspec.yaml')
  $named = Join-Path $OutDir ('Scanny-' + $ver + '-build' + $n + '.apk')
  Copy-Item -Force $apk $named
  Copy-Item -Force $apk (Join-Path $OutDir 'Scanny-latest.apk')
  $err = Join-Path $OutDir 'build-error.txt'
  if (Test-Path $err) { Remove-Item -Force $err }
  Ok ('APK ready: ' + $named)
  Ok ('This is Scanny ' + $ver + '. After installing, Settings > About must show version ' + $ver + '. If it shows another number, the old app is still installed or the app folder next to START-SCANNY-PHONE.bat is old.')
  Set-St 'lastBuildOk' $true
}

# ------------------------------------------------------------------ output files
# ------------------------------------------------------------------ in-app updates (Firebase Hosting)
# After every build the wizard puts the APK and a small version.json on Firebase Hosting
# (https://PROJECT.web.app/update/). The app checks it and offers "Update available". Free (Spark plan).
# Set SCANNY_NO_PUBLISH=1 to skip; SCANNY_MIN_BUILD=N makes every older build ask for the update as required.
function Get-LatestChangeNotes {
  $p = Join-Path $BundleRoot 'CHANGES-PHONE.md'
  if (-not (Test-Path $p)) { return '' }
  $t = ([IO.File]::ReadAllText($p) -replace "`r`n", "`n")
  $m = [regex]::Match($t, '(?s)\n## ([^\n]*)\n(.*?)(?=\n## |\z)')
  if (-not $m.Success) { return '' }
  $n = ($m.Groups[1].Value + "`n" + $m.Groups[2].Value).Trim()
  if ($n.Length -gt 1800) { $n = $n.Substring(0, 1800) + '...' }
  return $n
}

# Firebase Hosting on the free (Spark) plan REFUSES .apk files ("Executable files are forbidden"), so the APK itself
# is stored as a GitHub Release (free, public repository). Hosting only keeps version.json and the landing page.
function Initialize-GitHubTarget {
  $repo = [string](Get-St 'ghRepo')
  $tok = [string](Get-St 'ghToken')
  if ($repo -and $tok) { return @{ Repo = $repo; Token = $tok } }
  Say '' 'White'
  Say 'FREE UPDATES - one-time setup (about 2 minutes)' 'Cyan'
  Info 'Firebase Hosting (free plan) does not accept APK files, so the APK is stored on GitHub Releases (free).'
  Info '1) github.com > New repository. Name: scanny-updates. Public. Tick "Add a README file". Create repository.'
  Info '2) github.com/settings/personal-access-tokens/new  ->  Repository access: Only select repositories > scanny-updates;'
  Info '   Permissions > Repository permissions > Contents: Read and write.  Generate token and copy it.'
  Info 'The token stays on this computer. Leave the first answer empty to skip (phones then get no in-app updates).'
  $r = ([string](Ask 'GitHub repository as owner/name (for example badert/scanny-updates)')).Trim()
  if (-not $r) { return $null }
  $t = ([string](Ask 'GitHub token (starts with github_pat_)')).Trim()
  if (-not $t) { return $null }
  $r = $r -replace '^https?://github\.com/', ''
  $r = $r -replace '\.git$', ''
  $r = $r.Trim('/')
  Set-St 'ghRepo' $r
  Set-St 'ghToken' $t
  return @{ Repo = $r; Token = $t }
}

# Uploads the APK as a release asset and returns its public download address ('' when it did not work).
function Get-HttpStatusCode($err) {
  try {
    $r = $err.Exception.Response
    if ($r -and $r.StatusCode) { return [int]$r.StatusCode }
  } catch { }
  return 0
}

function Publish-ApkToGitHub([string]$apkPath, [string]$apkName, [string]$tag, [string]$title, [string]$notes) {
  $gh = Initialize-GitHubTarget
  if ($null -eq $gh) { return '' }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $oldPref = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  try {
    $h = @{ Authorization = ('Bearer ' + $gh.Token); 'User-Agent' = 'ScannyWizard'; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $api = 'https://api.github.com/repos/' + $gh.Repo
    try { $repoInfo = Invoke-RestMethod -Method Get -Uri $api -Headers $h -TimeoutSec 60 }
    catch {
      $code = Get-HttpStatusCode $_
      if ($code -eq 401 -or $code -eq 403 -or $code -eq 404) {
        Warn ('GitHub says: ' + $_.Exception.Message + ' - check the repository name and the token (it is asked again next time).')
        Set-St 'ghToken' ''
      } else {
        Warn ('GitHub could not be reached from this network (' + $_.Exception.Message + '). It may be blocked here.')
        Info 'Nothing is lost: the APK is built and saved in the Output folder, and your repository and token are kept.'
        Info 'Later, from a network where GitHub works, run option 10 (or Push-To-GitHub.bat). It pushes the last APK to GitHub only, without rebuilding.'
      }
      return ''
    }
    if ($repoInfo.private) {
      Warn 'The GitHub repository is PRIVATE, so phones could not download from it. Make it public: repository Settings > General > Danger Zone > Change visibility.'
      return ''
    }
    # Already uploaded (a retry of the same build)? Then reuse it instead of uploading again.
    $rel = $null
    try { $rel = Invoke-RestMethod -Method Get -Uri ($api + '/releases/tags/' + $tag) -Headers $h -TimeoutSec 60 } catch { $rel = $null }
    if ($rel) {
      foreach ($a in @($rel.assets)) {
        if ($a -and [string]$a.name -eq $apkName -and [string]$a.state -eq 'uploaded') {
          Info 'This build is already on GitHub - using it.'
          return [string]$a.browser_download_url
        }
      }
    }
    Info ('Uploading the APK to GitHub (' + $gh.Repo + ') - about 2 minutes...')
    if (-not $rel) {
      $payload = ConvertTo-Json -InputObject @{ tag_name = $tag; name = $title; body = $notes; draft = $false; prerelease = $false }
      $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
      $rel = Invoke-RestMethod -Method Post -Uri ($api + '/releases') -Headers $h -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
    }
    $upl = ([string]$rel.upload_url) -replace '\{.*$', ''
    $asset = Invoke-RestMethod -Method Post -Uri ($upl + '?name=' + [uri]::EscapeDataString($apkName)) -Headers $h -ContentType 'application/vnd.android.package-archive' -InFile $apkPath -TimeoutSec 3600
    return [string]$asset.browser_download_url
  } catch {
    Warn ('Could not upload the APK to GitHub: ' + $_.Exception.Message)
    Info 'The APK is built and saved in the Output folder. When GitHub works (another network), run option 10 or Push-To-GitHub.bat: it pushes the last APK to GitHub only, without rebuilding.'
    return ''
  } finally {
    $ProgressPreference = $oldPref
  }
}

function Publish-Update {
  if ($env:SCANNY_NO_PUBLISH) { Info 'Update publishing skipped (SCANNY_NO_PUBLISH is set).'; return }
  $apk = Join-Path $OutDir 'Scanny-latest.apk'
  if (-not (Test-Path $apk)) { return }
  if (-not $Script:Project) { $Script:Project = [string](Get-St 'projectId') }
  if (-not $Script:Project) { Warn 'No Firebase project known - the update was not published.'; return }
  try {
    $acct = Get-FirebaseAccount
    if (-not $acct) { Warn 'Firebase CLI is not logged in - the update was NOT published. Run START-SCANNY-PHONE option 3 (Health check), then Rebuild.'; return }
    $ver = Get-PubspecVersion (Join-Path $AppDir 'pubspec.yaml')
    $n = [int](Get-St 'buildNumber')
    $fj = Join-Path $AppDir 'firebase.json'
    if (-not (Test-Path $fj) -or ([IO.File]::ReadAllText($fj) -notmatch '"hosting"')) { Warn 'firebase.json has no hosting section - copy the new app folder next to START-SCANNY-PHONE.bat. Update not published.'; return }
    $apkName = 'Scanny-' + $ver + '-build' + $n + '.apk'
    $notes = Get-LatestChangeNotes
    # 1) the APK goes to GitHub Releases
    $apkUrl = Publish-ApkToGitHub $apk $apkName ('v' + $ver + '-build' + $n) ('Scanny ' + $ver + ' (build ' + $n + ')') $notes
    if (-not $apkUrl) {
      Warn 'The update was NOT published (no APK address). Phones can still use Scanny-latest.apk.'
      Info 'If GitHub is blocked here: later, from another network, run option 10 (Push-To-GitHub.bat) and then Publish-Update.bat. No rebuild is needed.'
      return
    }
    # 2) version.json and the landing page go to Firebase Hosting (small files, allowed on the free plan)
    $site = Join-Path $AppDir 'hosting'
    if (Test-Path $site) { Remove-Item -Recurse -Force $site }
    $upd = Join-Path $site 'update'
    New-Item -ItemType Directory -Force -Path $upd | Out-Null
    $minBuild = 0
    if ($env:SCANNY_MIN_BUILD) { try { $minBuild = [int]$env:SCANNY_MIN_BUILD } catch { $minBuild = 0 } }
    $info = [ordered]@{
      versionName = $ver; build = $n; apk = $apkUrl
      sha256 = (Get-FileSha $apk).ToLower(); size = (Get-Item $apk).Length
      minBuild = $minBuild; date = (Get-Date).ToString('yyyy-MM-dd'); notes = $notes
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $upd 'version.json'), (ConvertTo-Json -InputObject $info -Depth 4), $enc)
    $base = 'https://' + $Script:Project + '.web.app'
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scanny</title>
<style>body{font-family:system-ui,sans-serif;margin:0;background:#0b0f1e;color:#e8ecff;text-align:center}
main{max-width:420px;margin:0 auto;padding:48px 24px}h1{font-size:2rem;margin:0 0 4px}
a.btn{display:block;margin:24px 0 12px;padding:18px;border-radius:16px;background:#4256ff;color:#fff;font-size:1.2rem;text-decoration:none}
p{line-height:1.6;color:#b9c2ec}small{color:#8f98b7}</style></head>
<body><main>
<h1>Scanny</h1>
<p>Version $ver &middot; vulnerability alerts for your team</p>
<a class="btn" href="$apkUrl">Download / تنزيل</a>
<p>Open the downloaded file and tap Install. If Android asks, allow installing from this browser.<br>
افتح الملف الذي نزل واضغط تثبيت. إذا سأل أندرويد فاسمح بالتثبيت من المتصفح.</p>
<small>Already installed? Scanny updates itself: Settings &rarr; About &rarr; Check for updates.</small>
</main></body></html>
"@
    [IO.File]::WriteAllText((Join-Path $site 'index.html'), $html, $enc)
    # The iPhone web app (START-SCANNY-IPHONE.bat) lives on the same site: every publish replaces the whole site, so keep it.
    $iph = Join-Path (Join-Path $Work 'iphone-site') 'iphone'
    if (Test-Path $iph) { Copy-Item -Path $iph -Destination (Join-Path $site 'iphone') -Recurse -Force; Info 'The iPhone web app stays on the site.' }
    Info ('Publishing the version file to ' + $base + ' ...')
    $dep = @('deploy', '--only', 'hosting', '--project', $Script:Project, '--non-interactive')
    $r = $null
    $tries = 0
    while ($true) {
      $tries++
      $r = Invoke-Native $FirebaseExe $dep -Cwd $AppDir -Stream
      if ($r.Code -eq 0) { break }
      if ($r.Out -match '(?i)no hosting|site .* not found|has not been set up') {
        Info 'Creating the Firebase Hosting site (first time only)...'
        [void](Invoke-Native $FirebaseExe @('hosting:sites:create', $Script:Project, '--project', $Script:Project, '--non-interactive') -Cwd $AppDir)
        $r = Invoke-Native $FirebaseExe $dep -Cwd $AppDir -Stream
        if ($r.Code -eq 0) { break }
      }
      # "Failed to get Firebase project", time-outs and resets are usually the network (or an expired sign-in): try again.
      if ($tries -ge 3) { break }
      Info ('Firebase did not answer (try ' + $tries + ' of 3) - waiting a few seconds and trying again...')
      Start-Sleep -Seconds 8
    }
    if ($r.Code -ne 0) {
      Warn 'The version file could not be published. The APK is already on GitHub, so nothing is lost.'
      Info ('Firebase account signed in here: ' + $acct + '   project: ' + $Script:Project)
      Info 'If the account is not the one that owns this project, or the error says "Failed to get Firebase project": run START-SCANNY-PHONE option 3 (Health check) to sign in again.'
      Info 'Then double-click Publish-Update.bat (it publishes the last build again WITHOUT rebuilding).'
      return
    }
    Set-St 'updatePublishedBuild' $n
    $msgEn = "Scanny $ver is ready. Open this link on your phone: $base`r`nIf Scanny is already installed it updates itself (Settings > About > Check for updates)."
    $msgAr = "سكاني $ver جاهز. افتح هذا الرابط في هاتفك: $base`r`nإذا كان سكاني مثبتاً فهو يحدّث نفسه (الإعدادات > حول التطبيق > البحث عن تحديث)."
    Write-TextFile (Join-Path $OutDir 'Update-link.txt') ($msgAr + "`r`n`r`n----------`r`n`r`n" + $msgEn)
    Ok ('Update published: ' + $base + '   (Scanny ' + $ver + ' build ' + $n + ')')
    Info 'Phones with Scanny see "Update available" the next time the app opens. New phones: send them that link (Output\Update-link.txt).'
  } catch {
    Warn ('The update could not be published: ' + $_.Exception.Message)
  }
}

# ------------------------------------------------------------------ install on the phone with every permission granted
function Get-AdbDevices {
  $adb = Get-Adb
  if (-not $adb) { return @() }
  $r = Invoke-Native $adb @('devices')
  $out = @()
  foreach ($m in [regex]::Matches([string]$r.Out, '(?m)^(\S+)\s+device\s*$')) { $out += $m.Groups[1].Value }
  return $out
}

function Grant-PhonePermissions([string]$adb, [string]$dev) {
  $pkg = $Package
  # runtime permissions (installing with -g grants them already; this covers phones that ignore -g)
  foreach ($perm in @('android.permission.POST_NOTIFICATIONS')) { [void](Invoke-Native $adb @('-s', $dev, 'shell', 'pm', 'grant', $pkg, $perm)) }
  # special access: install its own updates, run in the background, exact alarms
  foreach ($op in @('REQUEST_INSTALL_PACKAGES', 'RUN_IN_BACKGROUND', 'RUN_ANY_IN_BACKGROUND', 'SCHEDULE_EXACT_ALARM', 'POST_NOTIFICATION')) {
    [void](Invoke-Native $adb @('-s', $dev, 'shell', 'cmd', 'appops', 'set', $pkg, $op, 'allow'))
  }
  # do not let battery saving kill the alert service
  [void](Invoke-Native $adb @('-s', $dev, 'shell', 'dumpsys', 'deviceidle', 'whitelist', ('+' + $pkg)))
  # allow data in the background (Data saver)
  $uid = Invoke-Native $adb @('-s', $dev, 'shell', 'pm', 'list', 'packages', '-U', $pkg)
  $m = [regex]::Match([string]$uid.Out, 'uid:(\d+)')
  if ($m.Success) { [void](Invoke-Native $adb @('-s', $dev, 'shell', 'cmd', 'netpolicy', 'add', 'restrict-background-whitelist', $m.Groups[1].Value)) }
}

function Install-OnPhone([bool]$Prompt) {
  $adb = Get-Adb
  if (-not $adb) { if ($Prompt) { Warn 'adb was not found, so the phone install was skipped.' }; return $false }
  $apk = Join-Path $OutDir 'Scanny-latest.apk'
  if (-not (Test-Path $apk)) { if ($Prompt) { Warn 'There is no APK yet.' }; return $false }
  [void](Invoke-Native $adb @('start-server'))
  $devs = @(Get-AdbDevices)
  if ($devs.Count -eq 0 -and $Prompt) {
    Say ''
    Say 'Install on a phone now (permissions are granted for you)?' 'Cyan'
    Info 'USB: Settings > About phone > tap Build number 7 times > Developer options > USB debugging ON, plug the phone in, tap Allow on the phone.'
    Info 'Wireless: Developer options > Wireless debugging ON, then type its address here, for example 192.168.1.20:37123.'
    $a = ([string](Ask 'Press Enter after connecting by USB, type the wireless address, or S to skip')).Trim()
    if ($a.ToUpper() -eq 'S') { return $false }
    if ($a -match '^\d+\.\d+\.\d+\.\d+:\d+$') { [void](Invoke-Native $adb @('connect', $a)) }
    $devs = @(Get-AdbDevices)
  }
  if ($devs.Count -eq 0) {
    if ($Prompt) { Warn 'No phone found. Run START-SCANNY-PHONE option 8 any time with the phone connected.'; if ($Script:LastHint) { Info $Script:LastHint } }
    return $false
  }
  $any = $false
  foreach ($d in $devs) {
    Info ('Installing Scanny on ' + $d + ' ...')
    $r = Invoke-Native $adb @('-s', $d, 'install', '-r', '-g', $apk) -Stream
    if ($r.Code -ne 0 -and $r.Out -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
      Warn 'An older Scanny with a different signing key is on this phone. Removing it (its saved data is on the server, nothing is lost) and installing again.'
      [void](Invoke-Native $adb @('-s', $d, 'uninstall', $Package))
      $r = Invoke-Native $adb @('-s', $d, 'install', '-r', '-g', $apk) -Stream
    }
    if ($r.Code -ne 0) { Warn ('Install on ' + $d + ' failed: ' + $r.Out); continue }
    Ok ('Installed on ' + $d)
    Grant-PhonePermissions $adb $d
    Ok 'Granted: notifications, background activity, battery exemption, install-updates access.'
    [void](Invoke-Native $adb @('-s', $d, 'shell', 'monkey', '-p', $Package, '-c', 'android.intent.category.LAUNCHER', '1'))
    $any = $true
  }
  if ($any) { Info 'Scanny opened on the phone. Sign in with a Google address that is listed as a member.' }
  return $any
}

function Invoke-PhoneOnly {
  Head 'Install on my phone (all permissions granted)'
  Update-SessionPath
  if (-not (Test-Path (Join-Path $OutDir 'Scanny-latest.apk'))) { throw 'There is no Output\Scanny-latest.apk yet - run START-SCANNY-PHONE option 1 or 2 first.' }
  if (-not (Install-OnPhone $true)) { Warn 'Nothing was installed.' }
}

function Write-OutputFiles {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Backup-Keystore
  $en = @"
Hi! Scanny now sends us vulnerability alerts on the phone.

1) Open this link on your phone and tap Download: __LINK__
   (or install the Scanny-latest.apk file I sent you). If Android asks, allow "Install unknown apps" for the app you opened it from.
2) Open Scanny and tap "Continue with Google". Use the Google address I added for you.
3) Allow notifications when asked. Critical alerts for your systems reach you even when the app is closed.

You can set a fingerprint lock in Settings. Mark each finding On-going, Acknowledged, Solved (with the upgraded version, or what you restricted) or False positive.
"@
  $ar = @"
مرحباً! تطبيق سكاني يرسل لنا الآن تنبيهات الثغرات الأمنية على الهاتف.

1) افتح هذا الرابط في هاتفك واضغط تنزيل: __LINK__
   (أو ثبّت ملف Scanny-latest.apk الذي أرسلته لك). إذا طلب أندرويد، اسمح بـ "تثبيت التطبيقات غير المعروفة".
2) افتح سكاني واضغط "المتابعة باستخدام Google" بالحساب الذي أضفته لك.
3) اسمح بالإشعارات عند الطلب لتصلك التنبيهات الحرجة حتى لو كان التطبيق مغلقاً.

يمكنك تفعيل قفل البصمة من الإعدادات. حدّد حالة كل ثغرة: جارٍ، تم الاطلاع، تم الحل (مع النسخة المحدّثة أو الإجراء المتخذ)، أو إنذار كاذب.
"@
  $link = 'https://' + $Script:Project + '.web.app'
  $en = $en.Replace('__LINK__', $link)
  $ar = $ar.Replace('__LINK__', $link)
  Write-TextFile (Join-Path $OutDir 'Message-to-team-EN.txt') ($en -replace "`r?`n", "`r`n")
  Write-TextFile (Join-Path $OutDir 'Message-to-team-AR.txt') ($ar -replace "`r?`n", "`r`n")
  Write-TextFile (Join-Path $OutDir 'Message-to-team-BOTH.txt') ((($ar + "`n`n----------`n`n" + $en)) -replace "`r?`n", "`r`n")
}

function Show-FinalScreen {
  Head 'ALL DONE'
  Ok ('Output folder: ' + $OutDir)
  Info 'Scanny-latest.apk          -> the phone app (already copied to Scanny for Windows: Team > Phones and sync shows a QR code)'
  Info 'Message-to-team-*.txt      -> ready to send to your team (Arabic + English)'
  Info 'keystore-backup\            -> COPY TO USB/CLOUD. Needed for every future update.'
  Say ''
  Say 'TEST CHECKLIST' 'Cyan'
  $items = @(
    'Scanny for Windows > Team: it says "Linked to <project>". Press Connection doctor: every line should be green.',
    'Team > Groups: create your groups. Team > Members: your teammates'' Google addresses (you are already an admin). Team > Systems: tick which group manages each system. Sync now.',
    'Phone: open Scanny, Continue with Google. Admins see every group; members see only their groups.',
    'Open a finding on the phone: set Acknowledged; on Windows the status and the History entry appear within a minute.',
    'Set Solved: it asks for the upgraded version or the restrictive actions; leave both empty and it refuses.',
    'Windows: change a finding to Solved with a comment; the phone shows the change and the comment.',
    'Windows scans and finds a Critical in a group: members of that group get a push notification (Team > Groups sets the level per group).',
    'Settings > Phones: the lock (fingerprint), offline mode (airplane mode: saved findings stay readable, changes are disabled), export CSV/PDF per group.',
    'Long-press the home screen > Widgets > Scanny: the alert counter and the top-findings list.',
    'If Google sign-in shows an error code, run START-SCANNY-PHONE option 6 and send me the code.'
  )
  $i = 1
  foreach ($x in $items) { Say ('  [ ] ' + $i + '. ' + $x) 'White'; $i++ }
  Say ''
  Info 'Updates later: put the new app folder next to START-SCANNY-PHONE.bat and double-click Rebuild-APK.bat. Phones with Scanny offer the update by themselves (Settings > About > Check for updates).'
  if ($OnWindows -and -not $TestMode) { try { Start-Process explorer.exe $OutDir } catch { } }
}

# Projects made by older versions of this wizard are in Dammam. They are never used again: a new project is created in $FirestoreRegion.
function Test-OldRegionProject {
  return ((Get-St 'projectId') -and ((Get-St 'regionPolicy') -ne $RegionPolicy))
}

function Retire-OldProject {
  $old = [string](Get-St 'projectId')
  Warn ('The saved project ' + $old + ' was created in Dammam. It will not be used again.')
  Info ('A new project is created in ' + $FirestoreRegion + '. Delete the old one when you like: https://console.firebase.google.com/project/' + $old + '/settings/general (Delete project).')
  $retired = @(Get-St 'retiredProjects')
  $retired += $old
  $keep = @{}
  foreach ($k in @('storePass', 'sha1', 'buildNumber', 'members', 'membersAsked')) { if ($Script:State.ContainsKey($k)) { $keep[$k] = $Script:State[$k] } }   # the signing key and the people stay
  $keep['done'] = @{}
  $keep['retiredProjects'] = $retired
  $Script:State = $keep
  Save-State
  $Script:Project = ''
}

# The saved project cannot be used (another Google account, or you want a fresh one): forget it, keep the signing key, members and account choice.
function Start-NewProject {
  $old = [string](Get-St 'projectId')
  $retired = @(Get-St 'retiredProjects')
  if ($old) { $retired += $old; Info ('Project ' + $old + ' is no longer used.') }
  $keep = @{}
  foreach ($k in @('storePass', 'sha1', 'buildNumber', 'members', 'membersAsked', 'regionPolicy', 'accountConfirmed', 'account')) { if ($Script:State.ContainsKey($k)) { $keep[$k] = $Script:State[$k] } }
  $keep['done'] = @{}
  $keep['retiredProjects'] = $retired
  $Script:State = $keep
  Save-State
  $Script:Project = ''
}

function Assert-NewRegionProject {
  if (Test-OldRegionProject) { throw ('The saved Firebase project is in Dammam (retired). Run START-SCANNY-PHONE option 1: it creates a new project in ' + $FirestoreRegion + ' and links everything again.') }
}

function Confirm-GoogleAccount {
  Info ('Firebase will use the Google account: ' + $Script:Account)
  Info 'This account will own the Firebase project. Press Enter to use it, or C to sign in with another Google account (a browser window opens).'
  while ($true) {
    $c = ([string](Ask 'Enter = use this account, C = change the Google account')).Trim().ToUpper()
    if ($c -ne 'C') { break }
    Switch-FirebaseAccount
    Info ('Now using: ' + $Script:Account)
  }
  Set-St 'accountConfirmed' ([string]$Script:Account)
}

# A text progress bar for the setup steps: how far along it is, and which step is next.
function Show-StepBar([int]$Index, [int]$Total, [string]$Title) {
  $w = 24
  $done = [int][math]::Floor($w * ($Index - 1) / [math]::Max(1, $Total))
  Say ''
  Say ('  [' + ('#' * $done) + ('-' * ($w - $done)) + ']  step ' + $Index + ' of ' + $Total + ':  ' + $Title) 'DarkCyan'
}

function Invoke-FullSetup {
  if (Test-OldRegionProject) { Retire-OldProject }
  Set-St 'regionPolicy' $RegionPolicy
  Head ('Scanny setup - everything is saved, you can stop and re-run any time')
  Info ('Work folder: ' + $Work + '   Log: ' + $LogPath)
  Update-SessionPath
  $stepNo = 0
  foreach ($s in $Steps) { $stepNo++; Show-StepBar $stepNo $Steps.Count ([string]$s.Title); Invoke-Step $s }
  Say ('  [' + ('#' * 24) + ']  all ' + $Steps.Count + ' setup steps done') 'Green'
  Invoke-Build
  Write-OutputFiles
  Publish-Update
  Publish-ToWindows
  [void](Install-OnPhone $true)
  Show-FinalScreen
}

function Invoke-Rebuild {
  Head 'Rebuild APK'
  Update-SessionPath
  Assert-NewRegionProject
  if (-not (Get-St 'cfg') -or -not (Test-Path $AppDir)) { throw 'Setup has not been completed yet - run START-SCANNY-PHONE option 1 first.' }
  $Script:Project = [string](Get-St 'projectId')
  Info 'Copying the latest app code from the app\ folder next to START-SCANNY-PHONE.bat...'
  Sync-AppSource
  if (-not (Test-RulesDeployed)) {
    Info 'firestore.rules changed - deploying the new rules.'
    Deploy-Rules
    if (Test-RulesDeployed) { [void](Test-RulesLive) }
  }
  Invoke-Build
  Write-OutputFiles
  Publish-Update
  Publish-ToWindows
  if (-not (Test-WindowsLinked) -and -not (Get-St 'linkSkipped')) { Info 'Scanny for Windows is not linked yet - linking now.'; Ensure-FirebaseLogin; Ask-TeamMembers; [void](Write-WindowsLink) }
  if (Install-OnPhone $false) { Ok 'The new build was installed on the connected phone.' }
  Ok 'Rebuild finished. Phones with Scanny offer the update by themselves; new phones: Output\Update-link.txt or the QR code in Scanny for Windows.'
  if ($OnWindows -and -not $TestMode) { try { Start-Process explorer.exe $OutDir } catch { } }
}


# ------------------------------------------------------------------ steps
$Steps = @(
  @{ Id = 'workdir'; Title = 'Work folder ' + $Work; Check = { Test-Path $OutDir }; Do = { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null } },
  @{ Id = 'git'; Title = 'Git'; Check = { Have 'git' }; Do = { [void](Install-Winget 'Git.Git') } },
  @{ Id = 'node'; Title = 'Node.js LTS'; Check = { Have $NpmExe }; Do = { [void](Install-Winget 'OpenJS.NodeJS.LTS') } },
  @{ Id = 'jdk'; Title = 'Java JDK 17'; Check = { [bool](Find-Jdk) }; Do = { [void](Ensure-Jdk) } },
  @{ Id = 'flutter'; Title = 'Flutter SDK (stable, 3.47 or newer)'; Note = 'First run downloads ~1 GB.'
    Check = { Test-FlutterVersion }
    Do = {
      if (-not (Test-Path $FlutterDir)) {
        $r = Invoke-Native 'git' @('clone', 'https://github.com/flutter/flutter.git', '-b', 'stable', '--depth', '1', $FlutterDir) -Stream
        if ($r.Code -ne 0) { throw ('git clone of Flutter failed: ' + $r.Out) }
      }
      Update-SessionPath
      $f = Get-FlutterExe
      [void](Invoke-Native $f @('config', '--no-analytics'))
      if (-not (Test-FlutterVersion)) {
        Info 'Flutter is older than 3.47 - upgrading (stable channel)...'
        [void](Invoke-Native $f @('channel', 'stable') -Stream)
        [void](Invoke-Native $f @('upgrade', '--force') -Stream)
      }
      [void](Invoke-Native $f @('--version') -Stream)
    } },
  @{ Id = 'android-sdk'; Title = 'Android SDK (command-line tools, platform 36, build-tools)'
    Check = { (Get-SdkManager) -and (Test-Path (Join-Path (Join-Path $SdkDir 'platforms') 'android-36')) -and (Test-Path (Join-Path $SdkDir 'platform-tools')) }
    Do = {
      if (-not (Get-SdkManager)) {
        $zip = Join-Path $Work 'cmdline-tools.zip'
        $okDl = $false
        foreach ($u in $CmdlineToolsUrls) {
          try { Info ('Downloading ' + $u); Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing; $okDl = $true; break } catch { Warn ('Download failed: ' + $_.Exception.Message) }
        }
        if (-not $okDl) { throw 'Could not download Android command-line tools.' }
        $tmp = Join-Path $Work 'cmdline-tmp'
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $dest = Join-Path (Join-Path $SdkDir 'cmdline-tools') 'latest'
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Move-Item (Join-Path $tmp 'cmdline-tools') $dest
        Remove-Item -Recurse -Force $tmp; Remove-Item -Force $zip
      }
      [void](Ensure-Jdk)
      $sm = Get-SdkManager
      $yes = ((1..60 | ForEach-Object { 'y' }) -join "`n")
      $args1 = @(('--sdk_root=' + $SdkDir)) + @($SdkPackages | ForEach-Object { '"' + $_ + '"' })   # literal quotes: cmd.exe splits on ';'
      $r = Invoke-Native $sm $args1 -InputText $yes -Stream
      if ($r.Code -ne 0) { Warn ('sdkmanager: ' + $r.Out) }
    } },
  @{ Id = 'licenses'; Title = 'Android SDK licenses'
    Check = { Test-Path (Join-Path (Join-Path $SdkDir 'licenses') 'android-sdk-license') }
    Do = {
      [void](Ensure-Jdk)
      $yes = ((1..60 | ForEach-Object { 'y' }) -join "`n")
      [void](Invoke-Native (Get-SdkManager) @('--licenses', ('--sdk_root=' + $SdkDir)) -InputText $yes)
      if ($OnWindows) { [Environment]::SetEnvironmentVariable('ANDROID_HOME', $SdkDir, 'User') }
      $env:ANDROID_HOME = $SdkDir
      [void](Invoke-Native (Get-FlutterExe) @('config', '--android-sdk', $SdkDir))
    } },
  @{ Id = 'firebase-tools'; Title = 'Firebase CLI'
    Check = { (Invoke-Native $FirebaseExe @('--version')).Code -eq 0 }
    Do = { $r = Invoke-Native $NpmExe @('install', '-g', 'firebase-tools') -Stream; Update-SessionPath; if ($r.Code -ne 0) { throw ('npm install firebase-tools failed: ' + $r.Out) } } },
  @{ Id = 'project-files'; Title = 'App project files'
    Check = { Test-FlutterProject }; Do = { New-FlutterProject } },
  @{ Id = 'gradle'; Title = 'Android build settings (minSdk 23, desugaring, signing, SDK 36 hook, notification/mic permission, home-screen widget)'
    Check = { Test-GradlePatches }; Do = { Invoke-GradlePatches } },
  @{ Id = 'keystore'; Title = 'Release signing key'
    Check = { (Test-Path $KeystorePath) -and [bool](Get-KeystoreSha1) -and (Test-Path (Join-Path $BackupDir 'scanny-release.jks')) }
    Do = { [void](Ensure-Jdk); Ensure-Keystore } },
  @{ Id = 'login'; Title = 'Firebase login'
    Check = { $Script:Account = Get-FirebaseAccount; return [bool]$Script:Account }
    Do = { Ensure-FirebaseLogin } },
  @{ Id = 'account'; Title = 'Which Google account to use'
    Check = { [bool](Get-St 'accountConfirmed') -and ((Get-St 'accountConfirmed') -eq $Script:Account) }
    Do = { Confirm-GoogleAccount } },
  @{ Id = 'project'; Title = 'Firebase project'
    Check = { $p = Get-St 'projectId'; if ($p -and (Test-ProjectReachable $p)) { $Script:Project = $p; return $true }; return $false }
    Do = { Ensure-Project } },
  @{ Id = 'android-app'; Title = 'Android app in Firebase (' + $Package + ')'
    Check = { $id = Get-AndroidAppId; if ($id) { Set-St 'appId' $id }; return [bool]$id }
    Do = { Ensure-AndroidApp } },
  @{ Id = 'sha'; Title = 'SHA-1 fingerprint registered (needed for Google sign-in)'
    Check = { Test-ShaRegistered }; Do = { Register-Sha } },
  @{ Id = 'apis'; Title = 'Google APIs (Firestore, Auth, Rules, Push notifications, Hosting, Keys)'
    Check = { [bool](Get-St 'apisEnabled2') }
    Do = { [void](Enable-GoogleApis @('firestore.googleapis.com', 'identitytoolkit.googleapis.com', 'firebaserules.googleapis.com', 'fcm.googleapis.com', 'firebasehosting.googleapis.com', 'iam.googleapis.com')); Set-St 'apisEnabled2' $true } },
  @{ Id = 'firestore'; Title = ('Firestore database (' + $FirestoreRegion + ')')
    Check = { (Test-Firestore) -or [bool](Get-St 'firestoreCreated') }; Do = { Ensure-Firestore } },
  @{ Id = 'rules'; Title = 'Security rules deployed'
    Check = { Test-RulesDeployed }; Do = { Deploy-Rules } },
  @{ Id = 'config'; Title = 'App config (firebase_options.dart)'
    Check = { Test-FirebaseConfigFile }; Do = { [void](Update-FirebaseConfig) } },
  @{ Id = 'auth-google'; Title = 'Google sign-in'
    Check = { Test-GoogleConfigReady }; Do = { Enable-GoogleAuth } },
  @{ Id = 'auth-email'; Title = 'Email/Password provider (used only by the self-test; the app itself uses Google sign-in)'
    Check = { Test-EmailAuthEnabled }; Do = { Enable-EmailAuth } },
  @{ Id = 'rules-test'; Title = 'Live test of the security rules (never blocks setup)'
    Check = { ((Get-St 'rulesTestedHash') -and (Get-St 'rulesTestedHash') -eq (Get-St 'rulesHash')) -or [bool](Get-St 'rulesTestSkipped') }
    Do = { [void](Test-RulesLive) } },
  @{ Id = 'members'; Title = 'Who may sign in to the phone app'
    Check = { [bool](Get-St 'membersAsked') }; Do = { Ask-TeamMembers } },
  @{ Id = 'link'; Title = 'Link this Firebase project to Scanny for Windows (automatic)'
    Check = { (Test-WindowsLinked) -or [bool](Get-St 'linkSkipped') }; Do = { if (-not (Write-WindowsLink)) { Set-St 'linkSkipped' $true } } }
)

function Invoke-PublishOnly {
  Head 'Publish the last build (no rebuild)'
  Update-SessionPath
  Assert-NewRegionProject
  if (-not (Get-St 'cfg') -or -not (Test-Path $AppDir)) { throw 'Setup has not been completed yet - run START-SCANNY-PHONE option 1 first.' }
  $Script:Project = [string](Get-St 'projectId')
  if (-not (Test-Path (Join-Path $OutDir 'Scanny-latest.apk'))) { throw 'There is no Output\Scanny-latest.apk yet - run Rebuild-APK.bat first.' }
  Info ('Publishing Scanny ' + (Get-PubspecVersion (Join-Path $AppDir 'pubspec.yaml')) + ' (build ' + (Get-St 'buildNumber') + ')...')
  Publish-Update
}

# GitHub only: the build is fine but GitHub was blocked, or you want to push from another network. No rebuild, no Firebase.
# When the phones should be told about it afterwards, run Publish-Update.bat: it reuses this upload instead of uploading again.
function Invoke-GitHubOnly {
  Head 'Push the last APK to GitHub only (no rebuild, no Firebase)'
  Update-SessionPath
  $apk = Join-Path $OutDir 'Scanny-latest.apk'
  if (-not (Test-Path $apk) -and (Test-Path $OutDir)) {
    $c = Get-ChildItem -Path $OutDir -Filter 'Scanny-*-build*.apk' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($c) { $apk = $c.FullName }
  }
  if (-not (Test-Path $apk)) { throw 'There is no APK in the Output folder yet - run option 2 (Rebuild APK) first.' }
  $ver = ''
  $n = 0
  $m = [regex]::Match((Split-Path $apk -Leaf), '^Scanny-(.+)-build(\d+)\.apk$')
  if ($m.Success) { $ver = $m.Groups[1].Value; $n = [int]$m.Groups[2].Value }
  else {
    $pub = Join-Path $AppDir 'pubspec.yaml'
    if (Test-Path $pub) { $ver = Get-PubspecVersion $pub }
    if (Get-St 'buildNumber') { $n = [int](Get-St 'buildNumber') }
  }
  if (-not $ver -or $n -le 0) { throw 'Could not tell which version this APK is. Use Output\Scanny-<version>-build<number>.apk or run option 2 (Rebuild APK).' }
  $apkName = 'Scanny-' + $ver + '-build' + $n + '.apk'
  $size = [math]::Round((Get-Item $apk).Length / 1MB, 1)
  Info ('APK: ' + (Split-Path $apk -Leaf) + '  (' + $size + ' MB)   version ' + $ver + ' build ' + $n)
  $notes = ''
  try { $notes = Get-LatestChangeNotes } catch { $notes = '' }
  $url = Publish-ApkToGitHub $apk $apkName ('v' + $ver + '-build' + $n) ('Scanny ' + $ver + ' (build ' + $n + ')') $notes
  if (-not $url) {
    Fail 'The APK is NOT on GitHub yet. Read the message above, then run this option again (it is safe to repeat).'
    return
  }
  Set-St 'ghApkUrl' $url
  Set-St 'ghApkBuild' $n
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Write-TextFile (Join-Path $OutDir 'GitHub-release.txt') ('Scanny ' + $ver + ' (build ' + $n + ')' + [Environment]::NewLine + $url + [Environment]::NewLine)
  Ok ('On GitHub: ' + $url)
  Info 'Only GitHub was updated. To make the phones see "Update available", run Publish-Update.bat later (it reuses this upload, nothing is uploaded twice).'
}

function Invoke-HealthCheck {
  Head 'Health check (changes nothing)'
  Update-SessionPath
  $Script:Project = [string](Get-St 'projectId')
  $jh = Find-Jdk
  if ($jh) { $env:JAVA_HOME = $jh; Update-SessionPath }
  $bad = 0
  foreach ($s in $Steps) {
    $ok = $false
    try { $ok = [bool](& $s.Check) } catch { $ok = $false }
    if ($ok) { Ok $s.Title } else { Fail $s.Title; $bad++ }
  }
  if ($jh) { Ok ('JDK found: ' + $jh) } else { Fail 'No JDK 17+ found'; $bad++ }
  if (Test-Path (Join-Path $OutDir 'Scanny-latest.apk')) { Ok 'APK exists in Output' } else { Warn 'No APK built yet' }
  if (Test-WindowsLinked) { Ok ('Linked to Scanny for Windows since ' + (Get-St 'linkedAt')) } else { Warn 'Not linked to Scanny for Windows yet (option 7)' }
  $adbH = Get-Adb
  if ($adbH) { $nd = @(Get-AdbDevices).Count; if ($nd -gt 0) { Ok ($nd.ToString() + ' phone(s) connected') } else { Info 'No phone connected right now' } }
  if ($Script:Account) { Info ('Firebase CLI account: ' + $Script:Account) }
  if ($bad -eq 0) { Ok 'Everything looks healthy.' } else { Warn ($bad.ToString() + ' item(s) need attention - option 1 repairs them.') }
}

function Invoke-FixGoogle {
  Head 'Fix Google sign-in'
  Update-SessionPath
  Assert-NewRegionProject
  $Script:Project = [string](Get-St 'projectId')
  if (-not $Script:Project) { throw 'No Firebase project yet - run option 1 first.' }
  Ensure-FirebaseLogin
  [void](Ensure-Jdk)
  Ensure-Keystore
  Info ('Release key SHA-1: ' + (Get-St 'sha1'))
  Ensure-AndroidApp
  if (Test-ShaRegistered) { Ok 'SHA-1 is registered in Firebase.' } else { Register-Sha; if (Test-ShaRegistered) { Ok 'SHA-1 registered now.' } else { Fail 'SHA-1 could not be registered.' } }
  Enable-GoogleAuth
  if (Test-GoogleConfigReady) { Ok 'Google web client ID is in the app config.' } else { Fail 'Google web client ID is still missing.' }
  Info 'Error 10 = SHA-1/package not registered; 12500 = support email missing; 7 = network.'
  $c = ([string](Ask 'Rebuild the APK now with the fixed config? (Y/n)')).Trim().ToUpper()
  if ($c -ne 'N') { Invoke-Build; Write-OutputFiles; Publish-Update }
}

function Invoke-Reset {
  Head 'Reset progress'
  Info 'Every step will be re-checked next time. Your signing key and its backup are NEVER deleted.'
  $forget = ([string](Ask 'Also forget the Firebase project ID? (y/N)')).Trim().ToUpper()
  $keep = @{}
  foreach ($k in @('storePass', 'sha1', 'buildNumber', 'members', 'membersAsked', 'linkKeyId', 'regionPolicy', 'retiredProjects')) { if ($Script:State.ContainsKey($k)) { $keep[$k] = $Script:State[$k] } }
  if ($forget -ne 'Y') { foreach ($k in @('projectId', 'appId', 'cfg', 'firestoreCreated')) { if ($Script:State.ContainsKey($k)) { $keep[$k] = $Script:State[$k] } } }
  $keep['done'] = @{}
  $Script:State = $keep
  Save-State
  Ok 'Progress reset.'
}

function Get-Adb {
  $p = Join-Path (Join-Path $SdkDir 'platform-tools') 'adb.exe'
  if (-not $OnWindows) { $p = Join-Path (Join-Path $SdkDir 'platform-tools') 'adb' }
  if (Test-Path $p) { return $p }
  if (Have 'adb') { return 'adb' }
  return ''
}

function Test-AdbDevice {
  $adb = Get-Adb
  if (-not $adb) { return $false }
  $r = Invoke-Native $adb @('devices')
  if ($r.Out -match '(?m)^\S+\s+unauthorized') { $Script:LastHint = 'The phone is connected but USB debugging was not allowed yet - unlock the phone and tap "Allow".' }
  return ($r.Out -match '(?m)^\S+\s+device\s*$')
}

function Invoke-CrashLog {
  Head 'Read crash log from phone (USB)'
  $adb = Get-Adb
  if (-not $adb) { throw 'adb not found - run START-SCANNY-PHONE option 1 first (it installs the Android SDK).' }
  [void](Invoke-Native $adb @('start-server'))
  if (-not (Test-AdbDevice)) {
    $null = Invoke-Manual -Title 'Connect the phone with USB debugging' -Steps @(
      'On the phone: Settings > About phone > Software information > tap "Build number" 7 times (Developer options turn on).',
      'Settings > Developer options > switch ON "USB debugging".',
      'Connect the phone to this PC with a USB cable (a data cable, not charge-only).',
      'Unlock the phone; when it asks "Allow USB debugging?" tick "Always allow" and tap Allow.') -Check { Test-AdbDevice }
  }
  if (-not (Test-AdbDevice)) { throw 'No phone found over USB.' }
  Ok 'Phone connected.'
  $apk = Join-Path $OutDir 'Scanny-latest.apk'
  if (Test-Path $apk) {
    $c = ([string](Ask 'Install the latest APK on this phone first? (Y/n)')).Trim().ToUpper()
    if ($c -ne 'N') {
      $ir = Invoke-Native $adb @('install', '-r', $apk) -Stream
      if ($ir.Code -eq 0) { Ok 'Installed.' } else { Warn ('Install said: ' + $ir.Out) }
    }
  }
  [void](Invoke-Native $adb @('logcat', '-c'))
  Info ('Starting Scanny on the phone and recording for 15 seconds...')
  [void](Invoke-Native $adb @('shell', 'monkey', '-p', $Package, '-c', 'android.intent.category.LAUNCHER', '1'))
  Wait-Sec 15
  $crash = Invoke-Native $adb @('logcat', '-d', '-b', 'crash', '-v', 'time')
  $all = Invoke-Native $adb @('logcat', '-d', '-v', 'time')
  $keep = @($all.Lines | Where-Object { $_ -match '(?i)(AndroidRuntime|FATAL|flutter|scanny|Firebase|DartVM|libc\b|DEBUG\s*:|E/)' })
  $pidLine = Invoke-Native $adb @('shell', 'pidof', $Package)
  $report = @('SCANNY CRASH LOG - ' + (Get-Date -Format 's'), ('App running after 15 s: ' + $(if ($pidLine.Out.Trim()) { 'YES (pid ' + $pidLine.Out.Trim() + ')' } else { 'NO' })), '',
    '=== CRASH BUFFER ===') + $crash.Lines + @('', '=== ERRORS / FLUTTER / FIREBASE (filtered) ===') + ($keep | Select-Object -Last 400)
  $file = Join-Path $OutDir 'crash-log.txt'
  Write-TextFile $file ($report -join "`r`n")
  $fatal = @($crash.Lines + $keep | Where-Object { $_ -match '(?i)(FATAL EXCEPTION|Caused by|Exception:|Error:)' } | Select-Object -First 8)
  if ($fatal.Count -gt 0) { Fail 'Crash found:'; foreach ($l in $fatal) { Info $l } } else { Ok 'No crash recorded in this run.' }
  Ok ('Saved: ' + $file + '  - please send this file.')
  if ($OnWindows -and -not $TestMode) { try { Start-Process notepad.exe $file } catch { } }
}

function Show-Menu {
  while ($true) {
    Say ''
    Say '  ==============================================' 'Cyan'
    Say '     SCANNY (phone app) - setup & build' 'Cyan'
    Say '  ==============================================' 'Cyan'
    if (Get-St 'projectId') { Info ('Project: ' + (Get-St 'projectId')) }
    Say '   1. Full setup: tools, Firebase, build, link to Scanny for Windows, install on the phone'
    Say '   2. Rebuild APK (after changing the app folder)'
    Say '   3. Health check'
    Say '   4. Open Output folder'
    Say '   5. Reset progress'
    Say '   6. Fix Google sign-in'
    Say '   7. Link to Scanny for Windows (again)'
    Say '   8. Install on my phone (USB or wireless, all permissions granted)'
    Say '   9. Read crash log from phone (USB)'
    Say '  10. Push the last APK to GitHub only (no rebuild, no Firebase)'
    Say '   0. Exit'
    $c = ([string](Ask 'Choose')).Trim()
    try {
      switch ($c) {
        '1' { Invoke-FullSetup }
        '2' { Invoke-Rebuild }
        '3' { Invoke-HealthCheck }
        '4' { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null; if ($OnWindows -and -not $TestMode) { Start-Process explorer.exe $OutDir } else { Info $OutDir } }
        '5' { Invoke-Reset }
        '6' { Invoke-FixGoogle }
        '7' { Invoke-LinkOnly }
        '8' { Invoke-PhoneOnly }
        '9' { Invoke-CrashLog }
        '10' { Invoke-GitHubOnly }
        'g' { Invoke-GitHubOnly }
        '0' { return }
        default { Warn 'Type a number from the menu.' }
      }
    } catch {
      if ($_.Exception.Message -eq 'USER_QUIT') { Warn 'Stopped. Progress is saved.' }
      else { Fail $_.Exception.Message; Info ('Full log: ' + $LogPath); Write-Log ($_ | Out-String) }
    }
  }
}

# ------------------------------------------------------------------ entry
if ($Mode -eq 'lib') { return }
if ($TestMode -and $env:SCANNY_HTTP_MOCK) { . $env:SCANNY_HTTP_MOCK }
Load-State
Write-Host ('Scanny wizard v' + $WizardVersion) -ForegroundColor Cyan
Write-Log ('==== start wizard v' + $WizardVersion + ' mode=' + $Mode + ' PS ' + $PSVersionTable.PSVersion.ToString() + ' wizard ' + $WizardVersion + ' from ' + $PSScriptRoot)
Say ('Scanny wizard v' + $WizardVersion + '  (' + $PSScriptRoot + ')') 'DarkGray'
$exit = 0
try {
  switch ($Mode) {
    'menu' { Show-Menu }
    'setup' { Invoke-FullSetup }
    'rebuild' { Invoke-Rebuild }
    'publish' { Invoke-PublishOnly }
    'health' { Invoke-HealthCheck }
    'output' { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null; if ($OnWindows) { Start-Process explorer.exe $OutDir } }
    'reset' { Invoke-Reset }
    'fixgoogle' { Invoke-FixGoogle }
    'crashlog' { Invoke-CrashLog }
    'link' { Invoke-LinkOnly }
    'phone' { Invoke-PhoneOnly }
    'github' { Invoke-GitHubOnly }
  }
} catch {
  if ($_.Exception.Message -eq 'USER_QUIT') { Warn 'Stopped. Progress is saved - run again to continue.'; $exit = 2 }
  else { Fail $_.Exception.Message; Info ('Full log: ' + $LogPath); Write-Log ($_ | Out-String); $exit = 1 }
}
exit $exit
