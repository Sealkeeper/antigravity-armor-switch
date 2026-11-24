<#
armor-tray.ps1 — 托盘开关（Windows 通知区常驻）

所有写操作全部委托给 arm.ps1（单写入者），不直接写 state.json。
双击图标 = 开/关 切换。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 单实例防多开
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\AntigravityArmorTraySingleton', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$BUILD = '2026-11-24.1645'
$ErrorActionPreference = 'SilentlyContinue'
$cfg          = Join-Path $env:USERPROFILE '.gemini\config'
$arm          = Join-Path $cfg 'arm.ps1'
$hookDir      = Join-Path $cfg 'agy-hooks'
$promptsDir   = Join-Path $hookDir 'prompts'
$manifestPath = Join-Path $promptsDir 'profiles.json'
$state        = Join-Path $hookDir 'state.json'
$logs         = Join-Path $cfg 'logs'

function Get-St {
  $def = [pscustomobject]@{
    enabled=$false; contract=$true; allow=$true; stop=$true; maskLogs=$true
    guardDestructive=$true; rules=$true; profile='gemini-lite'
  }
  if (-not (Test-Path $state)) { return $def }
  try {
    $s = Get-Content $state -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in @('enabled','contract','allow','stop','maskLogs','guardDestructive','rules','profile')) {
      if ($null -eq $s.$k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $def.$k -Force }
    }
    return $s
  } catch { return $def }
}

function Get-ProfileList {
  $list = @()
  $seen = @{}
  if (Test-Path $manifestPath) {
    try {
      $items = @(Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
      foreach ($it in $items) {
        if ($it.id -and (Test-Path (Join-Path $promptsDir ($it.id + '.md')))) {
          $lbl = if ($it.label) { [string]$it.label } else { [string]$it.id }
          $list += [pscustomobject]@{ id = [string]$it.id; label = $lbl }
          $seen[[string]$it.id] = $true
        }
      }
    } catch { }
  }
  # 补充目录里未写进 profiles.json 的自定义 .md
  foreach ($f in (Get-ChildItem $promptsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    if (-not $seen.ContainsKey($id)) {
      $list += [pscustomobject]@{ id = $id; label = $id }
    }
  }
  return $list
}

function Set-TrayTip([string]$text) {
  # WinForms NotifyIcon.Text 硬上限 63 字符
  if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
  $ni.Text = $text
}

function Invoke-Arm {
  param([string[]]$ArmArgs)
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $arm @ArmArgs | Out-Null
  Update-Ui
}

function Set-Toggle {
  $s = Get-St
  if ($s.enabled) { Invoke-Arm @('-Off') } else { Invoke-Arm @('-On') }
}

function Restart-Tray {
  $ni.Visible = $false
  $mutex.ReleaseMutex()
  $mutex.Dispose()
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $PSCommandPath
  )
  [System.Windows.Forms.Application]::Exit()
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

$miOn = New-Object System.Windows.Forms.ToolStripMenuItem '开启破甲（全开）'
$miOn.Add_Click({ Invoke-Arm @('-On','-Contract','on','-Allow','on') })
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

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miGuard = New-Object System.Windows.Forms.ToolStripMenuItem '拦截破坏性命令（护栏）'
$miGuard.Add_Click({
  $s = Get-St
  if ($s.guardDestructive) { Invoke-Arm @('-Guard','off') } else { Invoke-Arm @('-Guard','on') }
})
[void]$menu.Items.Add($miGuard)

$miRules = New-Object System.Windows.Forms.ToolStripMenuItem '写入全局规则（AGENTS/GEMINI.md）'
$miRules.Add_Click({
  $s = Get-St
  if ($s.rules) { Invoke-Arm @('-Rules','off') } else { Invoke-Arm @('-Rules','on') }
})
[void]$menu.Items.Add($miRules)

$miProfile = New-Object System.Windows.Forms.ToolStripMenuItem '档位'
[void]$menu.Items.Add($miProfile)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miLogs = New-Object System.Windows.Forms.ToolStripMenuItem '打开日志目录'
$miLogs.Add_Click({ Start-Process explorer.exe $logs })
[void]$menu.Items.Add($miLogs)

$miRestart = New-Object System.Windows.Forms.ToolStripMenuItem '重启托盘'
$miRestart.Add_Click({ Restart-Tray })
[void]$menu.Items.Add($miRestart)

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem '退出'
$miExit.Add_Click({
  $ni.Visible = $false
  $mutex.ReleaseMutex()
  $mutex.Dispose()
  [System.Windows.Forms.Application]::Exit()
})
[void]$menu.Items.Add($miExit)

$ni.ContextMenuStrip = $menu

function Rebuild-ProfileMenu([string]$currentProfile) {
  $miProfile.DropDownItems.Clear()
  foreach ($p in (Get-ProfileList)) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $p.label
    $mi.Tag = $p.id
    $mi.Checked = ($p.id -eq $currentProfile)
    $mi.Add_Click({ Invoke-Arm @('-On','-Profile', $this.Tag) })
    [void]$miProfile.DropDownItems.Add($mi)
  }
}

function Update-Ui {
  $s = Get-St
  $agents = Join-Path $cfg 'AGENTS.md'
  $armed = if (Test-Path $agents) { (Get-Content $agents -Raw -Encoding UTF8) -like '<!-- profile:*' } else { $false }

  $zh = { param([bool]$v) if ($v) { '开' } else { '关' } }

  if ($s.enabled) {
    $ni.Icon = $iconOn
    Set-TrayTip "破甲: 开 | $($s.profile) | 护栏:$(& $zh $s.guardDestructive)"
    $miStatus.Text = "已开启 | $($s.profile) | 注入:$(& $zh $s.contract) 放行:$(& $zh $s.allow) 护栏:$(& $zh $s.guardDestructive)"
  } else {
    $ni.Icon = $iconOff
    Set-TrayTip "破甲: 关 (产品默认)"
    $miStatus.Text = if ($armed) { "已关闭 | ⚠ 检测到规则残留" } else { "已关闭（产品默认）" }
  }

  $miOn.Checked       = ([bool]$s.enabled -and [bool]$s.contract -and [bool]$s.allow)
  $miAllow.Checked    = ([bool]$s.enabled -and (-not [bool]$s.contract) -and [bool]$s.allow)
  $miContract.Checked = ([bool]$s.enabled -and [bool]$s.contract -and (-not [bool]$s.allow))
  $miOff.Checked      = (-not [bool]$s.enabled)
  $miGuard.Checked    = [bool]$s.guardDestructive
  $miRules.Checked    = [bool]$s.rules

  Rebuild-ProfileMenu ([string]$s.profile)

  $stale = $false
  try {
    $fileAge = ((Get-Date) - (Get-Item $PSCommandPath).LastWriteTime).TotalMinutes
    $upMin   = ((Get-Date) - (Get-Process -Id $PID).StartTime).TotalMinutes
    $stale   = ($fileAge + 0.3) -lt $upMin
  } catch { }
  $miRestart.Text = if ($stale) { '⚠ 重启托盘（脚本已更新）' } else { "重启托盘 [$BUILD]" }
}

$menu.Add_Opening({ Update-Ui })
$ni.Add_MouseDoubleClick({ Set-Toggle })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Ui })
$timer.Start()

Update-Ui
$ni.ShowBalloonTip(2500, 'armor-switch', "破甲开关已就位：双击图标切换", [System.Windows.Forms.ToolTipIcon]::Info)

[System.Windows.Forms.Application]::Run()
