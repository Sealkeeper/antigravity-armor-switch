# panic.ps1 - one-shot stop: restore every surface, then (optionally) unbind PreToolUse.
#
#   .\panic.ps1            # full restore via arm.ps1 -Off, then drop PreToolUse from hooks.json
#   .\panic.ps1 -Restore   # put PreToolUse back
#
# Unlike the earlier version this does NOT stop at state.json: AGENTS.md goes
# back to neutral and GEMINI.md is removed, so new conversations load no policy
# text at all. Use before "arm.ps1 -Off" if the product still blocks every call.
[CmdletBinding()]
param([switch]$Restore)

$ErrorActionPreference = 'Stop'
$cfg = Join-Path $env:USERPROFILE '.gemini\config'
$arm = Join-Path $cfg 'arm.ps1'
$hj  = Join-Path $cfg 'hooks.json'

if (-not $Restore) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $arm -Off | Out-Null
  Write-Host "[ok] arm.ps1 -Off: state.json enabled=false, AGENTS.md neutral, GEMINI.md removed"
}

if (-not (Test-Path $hj)) { Write-Host "[skip] hooks.json not present - product calls no hooks"; return }

Copy-Item $hj ($hj + '.panic.bak') -Force
$cfgObj = Get-Content $hj -Raw | ConvertFrom-Json
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cfg\agy-hooks\pre_tool_use.ps1"

foreach ($name in @($cfgObj.PSObject.Properties.Name)) {
  $entry = $cfgObj.$name
  if ($Restore) {
    if (-not $entry.PreToolUse) {
      $entry | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @(@{ matcher='*'; hooks=@(@{ type='command'; command=$cmd; timeout=15 }) }) -Force
      Write-Host "[ok] PreToolUse restored"
    }
  } else {
    if ($entry.PreToolUse) {
      $entry.PSObject.Properties.Remove('PreToolUse')
      Write-Host "[ok] PreToolUse removed (other hooks kept: inject still off while disabled)"
    }
  }
}

$json = $cfgObj | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($hj, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[done] hooks.json updated. If calls still fail, restart Antigravity or rename hooks.json."
