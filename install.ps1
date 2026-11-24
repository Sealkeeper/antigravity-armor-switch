# Antigravity armor-break installer (hooks + prompts + switches), self-contained
#
# Usage:
#   .\install.ps1                        # hooks + prompts + switches + MCP + desktop shortcut
#   .\install.ps1 -Workspace "D:\proj"   # also drop repo-level rules into that project
#   .\install.ps1 -NoMcp -NoShortcut     # skip optional integrations
#   .\install.ps1 -Uninstall             # full restore (rules, hooks.json, GEMINI.md, MCP, shortcut)
#
# Design: arm.ps1 is the single writer of every surface. toggle.ps1 / armor-tray.ps1 /
# armor-mcp.js / panic.ps1 all delegate to it, so "off" really removes the policy text
# from AGENTS.md / GEMINI.md instead of only stopping the hook.

[CmdletBinding()]
param(
  [string]$Workspace = '',
  [switch]$Uninstall,
  [switch]$NoMcp,
  [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
$Root      = $PSScriptRoot
$CfgDir    = Join-Path $env:USERPROFILE '.gemini\config'
$HookDir   = Join-Path $CfgDir 'agy-hooks'
$PromptDir = Join-Path $HookDir 'prompts'
$HooksJson = Join-Path $CfgDir 'hooks.json'
$AgentsMd  = Join-Path $CfgDir 'AGENTS.md'
$GeminiMd  = Join-Path $CfgDir 'GEMINI.md'
$McpJson   = Join-Path $CfgDir 'mcp_config.json'
$BakSuffix = '.agybreak.bak'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $CfgDir | Out-Null

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
  foreach ($f in @($HooksJson, $AgentsMd)) {
    if (Test-Path ($f + $BakSuffix)) { Move-Item ($f + $BakSuffix) $f -Force; Write-Host "[restored] $f" }
    elseif (Test-Path $f) { Remove-Item $f -Force; Write-Host "[removed] $f" }
  }
  if (Test-Path $GeminiMd) { Remove-Item $GeminiMd -Force; Write-Host "[removed] $GeminiMd" }
  if (Test-Path $HookDir)  { Remove-Item $HookDir -Recurse -Force; Write-Host "[removed] $HookDir" }

  # MCP registration
  if (Test-Path $McpJson) {
    try {
      $m = Get-Content $McpJson -Raw | ConvertFrom-Json
      if ($m.mcpServers -and $m.mcpServers.'armor-switch') {
        $m.mcpServers.PSObject.Properties.Remove('armor-switch')
        [System.IO.File]::WriteAllText($McpJson, ($m | ConvertTo-Json -Depth 10), $Utf8NoBom)
        Write-Host "[removed] mcp_config.json: armor-switch"
      }
    } catch { Write-Host "[warn] mcp_config.json 未能解析，跳过" }
  }

  # desktop shortcut
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '破甲开关.lnk'
  if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "[removed] $lnk" }

  if ($Workspace) {
    $wr = Join-Path $Workspace '.agents\rules\00-operator.md'
    if (Test-Path $wr) { Remove-Item $wr -Force; Write-Host "[removed] $wr" }
  }
  Write-Host "Restored. Restart Antigravity to take effect."
  return
}

# ------------------------------------------------------------------ 1. hook scripts + prompts
Write-Host "[1/5] deploy hooks -> $HookDir"
New-Item -ItemType Directory -Force -Path $HookDir, $PromptDir | Out-Null
foreach ($n in 'pre_invocation.ps1','session_start.ps1','pre_tool_use.ps1','stop.ps1','state.json') {
  $src = Join-Path $Root "hooks\$n"
  if (Test-Path $src) { Copy-Item $src $HookDir -Force }
}
# every tail closer, not just the generic one: profiles may ship tail.<profile>.txt
$tails = @(Get-ChildItem (Join-Path $Root 'hooks') -Filter 'tail*.txt' -ErrorAction SilentlyContinue)
if (-not $tails) { Write-Warning "no tail*.txt found under hooks\" }
foreach ($t in $tails) { Copy-Item $t.FullName $HookDir -Force }
Write-Host "      tails: $($tails.Count) 份 ($(($tails | ForEach-Object { $_.Name }) -join ', '))"
if (Test-Path (Join-Path $Root 'hooks\override.txt')) {
  Copy-Item (Join-Path $Root 'hooks\override.txt') (Join-Path $HookDir 'override.txt') -Force
}
if (Test-Path (Join-Path $Root 'prompts')) {
  Copy-Item (Join-Path $Root 'prompts\*.md') $PromptDir -Force
  if (Test-Path (Join-Path $Root 'prompts\profiles.json')) {
    Copy-Item (Join-Path $Root 'prompts\profiles.json') $PromptDir -Force
  }
  Write-Host "      prompts: $((Get-ChildItem $PromptDir -Filter '*.md').Count) 份"
}
$neutralSrc = Join-Path $Root 'rules\AGENTS.neutral.md'
if (Test-Path $neutralSrc) { Copy-Item $neutralSrc (Join-Path $HookDir 'AGENTS.neutral.md') -Force }

# ------------------------------------------------------------------ 2. switches
Write-Host "[2/5] deploy switches -> $CfgDir"
foreach ($n in 'arm.ps1','toggle.ps1','panic.ps1','armor-tray.ps1') {
  Copy-Item (Join-Path $Root $n) $CfgDir -Force
}
Copy-Item (Join-Path $Root 'armor-mcp.js') $HookDir -Force

# ------------------------------------------------------------------ 3. hooks.json (NO BOM, no quotes around -File path)
Write-Host "[3/5] write hooks.json"
$psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $psExe) { $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
if (-not $psExe) { $psExe = 'powershell.exe' }
$ps = "$psExe -NoProfile -ExecutionPolicy Bypass -File"
$q  = { param($n) (Join-Path $HookDir $n) }
$cfg = [ordered]@{
  'operator-contract' = [ordered]@{
    SessionStart = @(
      @{ type = 'command'; command = "$ps $(& $q 'session_start.ps1')"; timeout = 15 }
    )
    PreInvocation = @(
      @{ type = 'command'; command = "$ps $(& $q 'pre_invocation.ps1')"; timeout = 15 }
    )
    PreToolUse = @(
      @{ matcher = '*'; hooks = @(@{ type = 'command'; command = "$ps $(& $q 'pre_tool_use.ps1')"; timeout = 15 }) }
    )
    Stop = @(
      @{ type = 'command'; command = "$ps $(& $q 'stop.ps1')"; timeout = 15 }
    )
  }
}
if (Test-Path $HooksJson) { Copy-Item $HooksJson ($HooksJson + $BakSuffix) -Force }
[System.IO.File]::WriteAllText($HooksJson, ($cfg | ConvertTo-Json -Depth 8), $Utf8NoBom)

# ------------------------------------------------------------------ 4. neutral global rules + initial state
Write-Host "[4/5] neutral global rules + state.json"
if (Test-Path $AgentsMd) { Copy-Item $AgentsMd ($AgentsMd + $BakSuffix) -Force }
if (Test-Path $neutralSrc) { Copy-Item $neutralSrc $AgentsMd -Force }
if (Test-Path $GeminiMd) { Remove-Item $GeminiMd -Force }

$state = Join-Path $HookDir 'state.json'
if (-not (Test-Path $state)) {
  @{ enabled=$false; contract=$true; allow=$true; stop=$true; maskLogs=$true; guardDestructive=$true
     rules=$true; sessionInject=$false; tail=$true; profile='gemini-lite'; contractFile='override.txt' } |
    ConvertTo-Json | ForEach-Object { [System.IO.File]::WriteAllText($state, $_, $Utf8NoBom) }
  Write-Host "      state.json 已新建：默认 OFF（用 arm.ps1 -On 开启）"
}

# ------------------------------------------------------------------ 5. optional integrations
Write-Host "[5/5] optional integrations"
if (-not $NoMcp) {
  $mcpServer = Join-Path $HookDir 'armor-mcp.js'
  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $node) { $node = 'C:\Program Files\nodejs\node.exe' }
  $m = if (Test-Path $McpJson) { try { Get-Content $McpJson -Raw | ConvertFrom-Json } catch { [pscustomobject]@{} } } else { [pscustomobject]@{} }
  if (-not $m.mcpServers) { $m | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force }
  $entry = [pscustomobject]@{ command = $node; args = @($mcpServer); env = [pscustomobject]@{} }
  $m.mcpServers | Add-Member -NotePropertyName 'armor-switch' -NotePropertyValue $entry -Force
  [System.IO.File]::WriteAllText($McpJson, ($m | ConvertTo-Json -Depth 10), $Utf8NoBom)
  Write-Host "      mcp_config.json: armor-switch -> $mcpServer（需重启反重力，工具列表才会出现）"
}
if (-not $NoShortcut) {
  try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop '破甲开关.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $CfgDir 'toggle.ps1') + '"'
    $sc.WorkingDirectory = $CfgDir
    $sc.IconLocation = 'shell32.dll,77'
    $sc.Description = '反重力破甲总开关'
    $sc.Save()
    Write-Host "      桌面快捷方式: $lnk"
  } catch { Write-Host "      [warn] 快捷方式创建失败: $_" }
}

if ($Workspace) {
  $wr = Join-Path $Workspace '.agents\rules'
  New-Item -ItemType Directory -Force -Path $wr | Out-Null
  Copy-Item (Join-Path $Root 'rules\AGENTS.md') (Join-Path $wr '00-operator.md') -Force
  Write-Host "      repo rules -> $(Join-Path $wr '00-operator.md')"
}

# ------------------------------------------------------------------ self-check
Write-Host ""
Write-Host "self-check:"
$probe = '{"hookEventName":"PreToolUse","toolCall":{"name":"run_command","args":{"CommandLine":"echo hi"}},"conversationId":"selfcheck"}'
Write-Host "  PreToolUse     -> $($probe | & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HookDir 'pre_tool_use.ps1'))"
Write-Host "  PreInvocation  length -> $('{}' | & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HookDir 'pre_invocation.ps1')).Length"
Write-Host ""
Write-Host "Done. 开启: powershell -File `"$CfgDir\arm.ps1`" -On"
Write-Host "      还原: powershell -File `"$CfgDir\arm.ps1`" -Off   (完整还原，含 AGENTS.md / GEMINI.md)"
Write-Host "      状态: powershell -File `"$CfgDir\arm.ps1`"          (含 sync 一致性检查)"
Write-Host "Hook log: $CfgDir\logs\tool_use.jsonl"
