<#
armor-tray.ps1 — 托盘开关（Windows 通知区常驻）

启动:
  powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "$env:USERPROFILE\.gemini\config\armor-tray.ps1"

开机自启（可选）:
  $lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\armor-tray.lnk"
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($lnk)
  $s.TargetPath = "powershell.exe"
  $s.Arguments = '-WindowStyle Hidden -ExecutionPolicy Bypass -File "' + "$env:USERPROFILE\.gemini\config\armor-tray.ps1" + '"'
  $s.Save()

重要：所有菜单动作都调用 arm.ps1，绝不直接写 state.json。
      直接写 state.json 会让 AGENTS.md / GEMINI.md 里的政策文本残留，
      表现就是"点了还原，但新会话依旧加载破甲政策"。

菜单: 状态 / 开启 / 还原 / 仅自动放行 / 仅契约注入 / 破坏性放行 / 档位 / 日志 / 退出
双击图标 = 开/关 切换。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'SilentlyContinue'
$cfg   = Join-Path $env:USERPROFILE '.gemini\config'
$arm   = Join-Path $cfg 'arm.ps1'
$state = Join-Path $cfg 'agy-hooks\state.json'
$logs  = Join-Path $cfg 'logs'

function Get-St {
  $def = [pscustomobject]@{ enabled=$false; contract=$true; allow=$true; stop=$true; maskLogs=$true; guardDestructive=$true; rules=$true; profile='gemini4hardened' }
  if (-not (Test-Path $state)) { return $def }
  try {
    $s = Get-Content $state -Raw | ConvertFrom-Json
    foreach ($k in @('enabled','contract','allow','stop','maskLogs','guardDestructive','rules','profile')) {
      if ($null -eq $s.$k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $def.$k -Force }
    }
    return $s
  } catch { return $def }
}

# all mutations go through arm.ps1 (single writer)
function Invoke-Arm {
  param([string[]]$ArmArgs)
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $arm @ArmArgs | Out-Null
  Update-Ui
}

function Set-Toggle {
  $s = Get-St
  if ($s.enabled) { Invoke-Arm @('-Off') } else { Invoke-Arm @('-On') }
}

$iconOn  = New-Object System.Drawing.Icon ([System.Drawing.SystemIcons]::Shield), 16, 16
$iconOff = New-Object System.Drawing.Icon ([System.Drawing.SystemIcons]::Application), 16, 16

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $iconOff
$ni.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$miStatus.Enabled = $false
[void]$menu.Items.Add($miStatus)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miOn = New-Object System.Windows.Forms.ToolStripMenuItem '开启破甲'
$miOn.Add_Click({ Invoke-Arm @('-On') })
[void]$menu.Items.Add($miOn)

$miOff = New-Object System.Windows.Forms.ToolStripMenuItem '还原（关闭破甲，含全局规则）'
$miOff.Add_Click({ Invoke-Arm @('-Off') })
[void]$menu.Items.Add($miOff)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miAllow = New-Object System.Windows.Forms.ToolStripMenuItem '仅自动放行（不注入）'
$miAllow.Add_Click({ Invoke-Arm @('-On','-Contract','off','-Allow','on') })
[void]$menu.Items.Add($miAllow)

$miContract = New-Object System.Windows.Forms.ToolStripMenuItem '仅契约注入（审批仍弹）'
$miContract.Add_Click({ Invoke-Arm @('-On','-Contract','on','-Allow','off') })
[void]$menu.Items.Add($miContract)

$miGuard = New-Object System.Windows.Forms.ToolStripMenuItem '破坏性命令也放行'
$miGuard.Add_Click({
  $s = Get-St
  if ($s.guardDestructive) { Invoke-Arm @('-Guard','off') } else { Invoke-Arm @('-Guard','on') }
})
[void]$menu.Items.Add($miGuard)

$miRules = New-Object System.Windows.Forms.ToolStripMenuItem '写入全局规则（AGENTS/GEMINI.md）'
$miRules.Add_Click({
  $s = Get-St
  if ($s.rules) { Invoke-Arm @('-On','-Rules','off') } else { Invoke-Arm @('-On','-Rules','on') }
})
[void]$menu.Items.Add($miRules)

$miProfile = New-Object System.Windows.Forms.ToolStripMenuItem '档位'
foreach ($p in @('gemini4hardened','gemini4tight','gemini4argon','gemini4compact','codeemitter','claude5')) {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem $p
  $mi.Tag = $p
  $mi.Add_Click({ Invoke-Arm @('-On','-Profile', $this.Tag) })
  [void]$miProfile.DropDownItems.Add($mi)
}
[void]$menu.Items.Add($miProfile)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miLogs = New-Object System.Windows.Forms.ToolStripMenuItem '打开日志目录'
$miLogs.Add_Click({ Start-Process explorer.exe $logs })
[void]$menu.Items.Add($miLogs)

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem '退出'
$miExit.Add_Click({ $ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
[void]$menu.Items.Add($miExit)

$ni.ContextMenuStrip = $menu

function Update-Ui {
  $s = Get-St
  $agents = Join-Path $cfg 'AGENTS.md'
  $armed = if (Test-Path $agents) { (Get-Content $agents -Raw) -like '<!-- profile:*' } else { $false }

  if ($s.enabled) {
    $ni.Icon = $iconOn
    $ni.Text = "破甲: 开 (contract=$($s.contract) allow=$($s.allow))"
  } else {
    $ni.Icon = $iconOff
    $ni.Text = "破甲: 关 (产品默认)"
  }
  $miStatus.Text = if ($s.enabled) {
    "当前: 开  档位=$($s.profile)  规则=$armed  guard=$($s.guardDestructive)"
  } else {
    "当前: 关  规则残留=$armed"
  }
  $miGuard.Checked = [bool]$s.guardDestructive
  $miRules.Checked = [bool]$s.rules
  $miOn.Checked = [bool]$s.enabled
  $miOff.Checked = -not [bool]$s.enabled
  foreach ($mi in $miProfile.DropDownItems) { $mi.Checked = ($mi.Tag -eq $s.profile) }
}

$ni.Add_MouseDoubleClick({ Set-Toggle })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Update-Ui })
$timer.Start()

Update-Ui
$ni.ShowBalloonTip(3000, 'armor-switch', "破甲开关已就位：双击图标切换", [System.Windows.Forms.ToolTipIcon]::Info)

[System.Windows.Forms.Application]::Run()
