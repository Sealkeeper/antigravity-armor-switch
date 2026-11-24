# PreInvocation: inject the workspace operating policy (and optional tail reinforcement).
# ASCII-only on purpose: avoids the PowerShell 5.1 code-page trap.
$ErrorActionPreference = 'Stop'

function Emit([string]$json) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $b = [System.Text.Encoding]::UTF8.GetBytes($json)
  $o = [Console]::OpenStandardOutput(); $o.Write($b, 0, $b.Length); $o.Flush()
  exit 0
}

$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { }
$conv = ''
try { $conv = [string](($raw | ConvertFrom-Json).conversationId) } catch { }

try {
  $enabled = $false; $contract = $true; $file = 'override.txt'; $tailOn = $false
  $sp = Join-Path $PSScriptRoot 'state.json'
  if (Test-Path $sp) {
    $s = Get-Content $sp -Raw | ConvertFrom-Json
    if ($null -ne $s.enabled)  { $enabled  = [bool]$s.enabled }
    if ($null -ne $s.contract) { $contract = [bool]$s.contract }
    if ($s.contractFile)       { $file     = [string]$s.contractFile }
    if ($null -ne $s.tail)     { $tailOn   = [bool]$s.tail }
  }

  $msg = ''
  if ($enabled -and $contract) {
    $p = Join-Path $PSScriptRoot $file
    if (-not (Test-Path $p)) { $p = Join-Path $PSScriptRoot 'override.txt' }
    if (Test-Path $p) { $msg = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }

    $tp = Join-Path $PSScriptRoot 'tail.txt'
    if ($tailOn -and (Test-Path $tp)) { $msg = $msg + "`n`n---`n`n" + [System.IO.File]::ReadAllText($tp, [System.Text.Encoding]::UTF8) }
  }

  try {
    $ld = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
    New-Item -ItemType Directory -Force -Path $ld | Out-Null
    $line = [pscustomobject]@{ ts=(Get-Date).ToString('s'); conv=$conv; mode=$(if($msg){'on'}else{'off'}); file=$file; tail=$tailOn; chars=$msg.Length } | ConvertTo-Json -Compress
    Add-Content -Path (Join-Path $ld 'invoke.jsonl') -Value $line -Encoding UTF8
  } catch { }

  if (-not $msg) { Emit '{}' }
  Emit ('{"injectSteps":[{"systemMessage":{"systemMessage":' + (ConvertTo-Json -InputObject ([string]$msg) -Compress) + '}}]}')
} catch {
  Emit '{}'
}
