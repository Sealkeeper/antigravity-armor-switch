# arm.ps1 - the ONLY writer of every armor-break surface.
#
#   .\arm.ps1                              # status (and self-heal surfaces)
#   .\arm.ps1 -On                          # enable
#   .\arm.ps1 -Off                         # full restore (rules + override.txt)
#   .\arm.ps1 -On -Profile gemini-lite     # lightweight default (~3k)
#   .\arm.ps1 -On -Profile gemini-full     # full policy (~14.6k)
#   .\arm.ps1 -On -Profile claude          # rules channel only (no hook inject)
#   .\arm.ps1 -Verify                      # exit 1 if any surface is inconsistent
[CmdletBinding()]
param(
  [switch]$On,
  [switch]$Off,
  [switch]$Verify,
  [ValidateSet('on','off')][string]$Contract,
  [ValidateSet('on','off')][string]$Allow,
  [ValidateSet('on','off')][string]$Stop,
  [ValidateSet('on','off')][string]$Guard,
  [ValidateSet('on','off')][string]$MaskLogs,
  [ValidateSet('on','off')][string]$Rules,
  [ValidateSet('on','off')][string]$Session,
  [ValidateSet('on','off')][string]$Tail,
  [ValidateSet('once','off')][string]$Inject,
  [string]$Profile,
  [ValidateSet('gemini','claude')][string]$Preset
)

$ErrorActionPreference = 'Stop'
$cfg     = Join-Path $env:USERPROFILE '.gemini\config'
$hookDir = Join-Path $cfg 'agy-hooks'
$prompts = Join-Path $hookDir 'prompts'
$state   = Join-Path $hookDir 'state.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $hookDir, $prompts | Out-Null

function Write-Text([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
}
function Read-Text([string]$path) {
  if (Test-Path $path) { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
  return ''
}

# Legacy profile aliases so older scripts/commands keep working seamlessly
$aliases = @{
  'gemini4tight'    = 'gemini-lite'
  'gemini4hardened' = 'gemini-full'
  'gemini4argon'    = 'gemini-full'
  'gemini4compact'  = 'gemini-lite'
  'claude5'         = 'claude'
}
function Resolve-ProfileName([string]$name) {
  if (-not $name) { return 'gemini-lite' }
  if ($aliases.ContainsKey($name)) { return $aliases[$name] }
  return $name
}

# Load profiles.json manifest if present
$manifestPath = Join-Path $prompts 'profiles.json'
$manifest = @()
if (Test-Path $manifestPath) {
  try { $manifest = @(Read-Text $manifestPath | ConvertFrom-Json) } catch { $manifest = @() }
}
function Get-ProfileMeta([string]$id) {
  foreach ($m in $manifest) { if ($m.id -eq $id) { return $m } }
  return $null
}

# ---------------- state ----------------
$def = [ordered]@{
  enabled=$false; contract=$true; allow=$true; stop=$true; maskLogs=$true
  guardDestructive=$true; rules=$true; sessionInject=$false; tail=$true; injectMode='once'
  profile='gemini-lite'; contractFile='override.txt'
}
$s = if (Test-Path $state) { Read-Text $state | ConvertFrom-Json } else { [pscustomobject]$def }
foreach ($k in @($def.Keys)) { if ($null -eq $s.$k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $def[$k] -Force } }
$s.profile = Resolve-ProfileName ([string]$s.profile)
# one source of truth: the hook always reads override.txt, whichever profile wrote it
$s | Add-Member -NotePropertyName contractFile -NotePropertyValue 'override.txt' -Force

function B([string]$v) { return ($v -eq 'on') }
if ($On)       { $s.enabled = $true }
if ($Off)      { $s.enabled = $false }
if ($Contract) { $s.contract         = B $Contract }
if ($Allow)    { $s.allow            = B $Allow }
if ($Stop)     { $s.stop             = B $Stop }
if ($Guard)    { $s.guardDestructive = B $Guard }
if ($MaskLogs) { $s.maskLogs         = B $MaskLogs }
if ($Rules)    { $s.rules            = B $Rules }
if ($Session)  { $s.sessionInject    = B $Session }
if ($Tail)     { $s.tail             = B $Tail }
if ($Inject)   { $s.injectMode       = $Inject }

if ($Profile) {
  $resolved = Resolve-ProfileName $Profile
  $candidate = Join-Path $prompts ($resolved + '.md')
  if (-not (Test-Path $candidate)) {
    throw "Unknown profile '$Profile' (file not found: $candidate)"
  }
  $s.profile = $resolved
  # Auto-apply channel binding from profiles.json unless caller explicitly overrode -Contract / -Rules
  $meta = Get-ProfileMeta $resolved
  if ($meta -and $meta.channel) {
    if ($meta.channel -eq 'rules') {
      if (-not $Contract) { $s.contract = $false }
      if (-not $Rules)    { $s.rules    = $true }
    } elseif ($meta.channel -eq 'hook') {
      if (-not $Contract) { $s.contract = $true }
    }
  }
}

if ($Preset -eq 'claude') {
  $s | Add-Member -NotePropertyName profile -NotePropertyValue 'claude' -Force
  $s.contract = $false
  $s.rules    = $true
  $s.enabled  = $true
}
if ($Preset -eq 'gemini') {
  $s | Add-Member -NotePropertyName profile -NotePropertyValue 'gemini-lite' -Force
  $s.contract = $true
  $s.rules    = $true
  $s.enabled  = $true
}

# ---------------- surfaces ----------------
$neutralPath = Join-Path $hookDir 'AGENTS.neutral.md'
$neutral = Read-Text $neutralPath
if (-not $neutral) {
  $neutral = "# Global rules`r`n`r`nProject conventions only. Armor text lives in agy-hooks\override.txt.`r`n"
  Write-Text $neutralPath $neutral
}

$promptPath = Join-Path $prompts ($s.profile + '.md')
$armor = Read-Text $promptPath

$agentsPath = Join-Path $cfg 'AGENTS.md'
$geminiPath = Join-Path $cfg 'GEMINI.md'
$overridePath = Join-Path $hookDir 'override.txt'
$agentsOrig = "$agentsPath.orig.bak"
$geminiOrig = "$geminiPath.orig.bak"

function Test-Foreign([string]$path, [string]$neutralText) {
  if (-not (Test-Path $path)) { return $false }
  $t = Read-Text $path
  if ($t -like '<!-- profile:*') { return $false }
  return ($t.Trim() -ne $neutralText.Trim())
}

if ($s.enabled) {
  if ($armor) {
    if ((Test-Path $agentsPath) -and -not (Test-Path $agentsOrig) -and (Test-Foreign $agentsPath $neutral)) {
      Copy-Item $agentsPath $agentsOrig -Force
    }
    if ((Test-Path $geminiPath) -and -not (Test-Path $geminiOrig) -and (Test-Foreign $geminiPath $neutral)) {
      Copy-Item $geminiPath $geminiOrig -Force
    }
    Write-Text $overridePath $armor
    if ($s.rules) {
      $header = "<!-- profile: $($s.profile) | generated by arm.ps1 | disable: arm.ps1 -Off -->`r`n`r`n"
      Write-Text $agentsPath ($header + $armor)
      Write-Text $geminiPath ($header + $armor)
    } else {
      Write-Text $agentsPath $neutral
      if (Test-Path $geminiPath) { Remove-Item $geminiPath -Force }
    }
  } else {
    Write-Host "  [warn] prompt profile not found: $promptPath"
  }
} else {
  if (Test-Path $agentsOrig) { Copy-Item $agentsOrig $agentsPath -Force } else { Write-Text $agentsPath $neutral }
  if (Test-Path $geminiOrig) {
    Copy-Item $geminiOrig $geminiPath -Force
  } elseif (Test-Path $geminiPath) {
    Remove-Item $geminiPath -Force
  }
  Write-Text $overridePath ''
}

Write-Text $state ($s | ConvertTo-Json)

# ---------------- report ----------------
$label  = if ($s.enabled) { 'ON ' } else { 'OFF' }
$ovLen  = if (Test-Path $overridePath) { (Get-Item $overridePath).Length } else { 0 }
$agLen  = if (Test-Path $agentsPath)   { (Get-Item $agentsPath).Length } else { 0 }
$gmLen  = if (Test-Path $geminiPath)   { (Get-Item $geminiPath).Length } else { 0 }
$agArmed = (Read-Text $agentsPath) -like '<!-- profile:*'
$gmArmed = (Test-Path $geminiPath) -and ((Read-Text $geminiPath) -like '<!-- profile:*')

$issues = @()
if ($s.enabled -and $s.rules) {
  if (-not $agArmed) { $issues += 'AGENTS.md is neutral while break is ON' }
  if (-not $gmArmed) { $issues += 'GEMINI.md missing while break is ON' }
  if ($ovLen -eq 0)  { $issues += 'override.txt empty while break is ON' }
}
if (-not $s.enabled) {
  if ($agArmed)      { $issues += 'AGENTS.md still armored while break is OFF' }
  if ((Test-Path $geminiPath) -and $gmArmed) { $issues += 'GEMINI.md still armored while break is OFF' }
  if ($ovLen -ne 0)  { $issues += "override.txt still holds $ovLen B while break is OFF" }
}
$restoreNote = if (-not $s.enabled -and (Test-Path $agentsOrig)) { ' (AGENTS.md 已还原为你自己的原件)' } else { '' }
$sync = if ($issues.Count -eq 0) { 'ok' } else { 'INCONSISTENT: ' + ($issues -join '; ') }

Write-Host ""
Write-Host "  state : $label   profile=$($s.profile)"
Write-Host "  inject: $($s.injectMode)"
Write-Host "  flags : contract=$($s.contract) allow=$($s.allow) stop=$($s.stop) guard=$($s.guardDestructive) rules=$($s.rules) session=$($s.sessionInject) tail=$($s.tail) maskLogs=$($s.maskLogs)"
Write-Host "  hook  : override.txt = $ovLen B"
Write-Host "  rules : AGENTS.md = $agLen B $(if($agArmed){'[ARMED]'}else{'[neutral]'}), GEMINI.md = $gmLen B $(if(Test-Path $geminiPath){if($gmArmed){'[ARMED]'}else{'[plain]'}}else{'[removed]'})$restoreNote"

$probe = '{"hookEventName":"PreToolUse","toolCall":{"name":"run_command","args":{"CommandLine":"echo hi"}},"conversationId":"arm-status"}'
$ans = $probe | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $hookDir 'pre_tool_use.ps1')
$inj = '{}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $hookDir 'pre_invocation.ps1')
$ses = '{}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $hookDir 'session_start.ps1')
Write-Host "  probe : PreToolUse=$ans"
Write-Host "          PreInvocationLen=$($inj.Length)  SessionStartLen=$($ses.Length)"
Write-Host "  sync  : $sync"
Write-Host ""

if ($Verify -and $issues.Count -gt 0) { exit 1 }
