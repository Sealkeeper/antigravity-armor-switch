# toggle.ps1 - double-click / shortcut: flip the master switch.
#
# Delegates to arm.ps1 so that ALL THREE surfaces move together:
#   state.json + override.txt (hook inject) + AGENTS.md/GEMINI.md (global rules)
# Never writes state.json directly - that is what left armored text resident
# in new sessions after a "restore".
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$cfg   = Join-Path $env:USERPROFILE '.gemini\config'
$arm   = Join-Path $cfg 'arm.ps1'
$state = Join-Path $cfg 'agy-hooks\state.json'

$cur = $false
if (Test-Path $state) {
  try { $cur = [bool](Get-Content $state -Raw | ConvertFrom-Json).enabled } catch { $cur = $false }
}

$flag = if ($cur) { '-Off' } else { '-On' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $arm $flag | Out-Null

$s = Get-Content $state -Raw | ConvertFrom-Json
$agents = Join-Path $cfg 'AGENTS.md'
$armed = if (Test-Path $agents) { (Get-Content $agents -Raw) -like '<!-- profile:*' } else { $false }

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = if ($s.enabled) { [System.Drawing.SystemIcons]::Shield } else { [System.Drawing.SystemIcons]::Application }
$ni.Text = if ($s.enabled) { '破甲: 开' } else { '破甲: 关' }
$ni.Visible = $true

if ($s.enabled) {
  $prof = [string]$s.profile
  $ni.ShowBalloonTip(4000, '破甲已开启',
    "注入=$($s.contract) 放行=$($s.allow) 全局规则=$armed 档位=$prof",
    [System.Windows.Forms.ToolTipIcon]::Warning)
} else {
  $ni.ShowBalloonTip(4000, '破甲已还原',
    "已回到产品默认：不注入、规则中性=$(-not $armed)、审批弹窗恢复",
    [System.Windows.Forms.ToolTipIcon]::Info)
}

Start-Sleep -Seconds 4
$ni.Visible = $false
$ni.Dispose()
