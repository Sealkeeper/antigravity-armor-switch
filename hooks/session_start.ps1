# SessionStart: inject the operator contract at session start only when break is enabled.
$ErrorActionPreference = 'Stop'

function Emit([string]$json) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $b = [System.Text.Encoding]::UTF8.GetBytes($json)
  $o = [Console]::OpenStandardOutput(); $o.Write($b, 0, $b.Length); $o.Flush()
  exit 0
}

try { $null = [Console]::In.ReadToEnd() } catch { }

try {
  $enabled = $false; $contract = $true; $file = 'override.txt'; $sessionInject = $false
  $sp = Join-Path $PSScriptRoot 'state.json'
  if (Test-Path $sp) {
    $s = Get-Content $sp -Raw | ConvertFrom-Json
    if ($null -ne $s.enabled)       { $enabled       = [bool]$s.enabled }
    if ($null -ne $s.contract)      { $contract      = [bool]$s.contract }
    if ($s.contractFile)            { $file          = [string]$s.contractFile }
    if ($null -ne $s.sessionInject) { $sessionInject = [bool]$s.sessionInject }
  }
  # PreInvocation injects every turn; a second copy at SessionStart only doubles the token
  # cost (and shows up as a duplicate block in the transcript) unless explicitly enabled.
  if (-not $enabled -or -not $contract -or -not $sessionInject) { Emit '{}' }

  $p = Join-Path $PSScriptRoot $file
  if (-not (Test-Path $p)) { $p = Join-Path $PSScriptRoot 'override.txt' }
  $msg = ''
  if (Test-Path $p) { $msg = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
  if (-not $msg) { Emit '{}' }

  Emit ('{"injectSteps":[{"systemMessage":{"systemMessage":' + (ConvertTo-Json -InputObject ([string]$msg) -Compress) + '}}]}')
} catch {
  Emit '{}'
}
