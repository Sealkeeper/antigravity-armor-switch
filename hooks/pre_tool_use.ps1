# PreToolUse: fail-open to "ask". Self-contained on purpose (no dot-source, no helpers):
# if anything at all goes wrong this script must still print a valid decision, because the
# product treats empty/invalid hook output as DENY (fail-closed).
#
#   enabled + allow + not destructive -> allow
#   disabled / allow-off / destructive -> ask   (hand the call back to the product)
#   payload not JSON                   -> ask   (never silently auto-approve a shape we
#                                                do not understand: a renamed field would
#                                                otherwise disable the destructive guard
#                                                without leaving a trace)
$ErrorActionPreference = 'Stop'

function Emit([string]$json) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $b = [System.Text.Encoding]::UTF8.GetBytes($json)
  $o = [Console]::OpenStandardOutput(); $o.Write($b, 0, $b.Length); $o.Flush()
  exit 0
}

$logDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
$mask   = $true
function Write-Decision([string]$decision, [string]$tool, [string]$conv, [string]$cmdText) {
  try {
    $a = $cmdText
    if ($mask -and $a) {
      $a = [regex]::Replace($a, '(ark|sk|ghp|gho|github_pat|xoxb|AIza)[-_A-Za-z0-9]{8,}', '$1***REDACTED***')
      $a = [regex]::Replace($a, '(?i)(bearer\s+)[A-Za-z0-9._\-]{8,}', '$1***REDACTED***')
      $a = [regex]::Replace($a, '(?i)(password|passwd|secret|token)(["'']?\s*[=:]\s*["'']?)[^\s"'']{6,}', '$1$2***REDACTED***')
      $a = [regex]::Replace($a, '[A-Za-z0-9+/]{48,}={0,2}', '***REDACTED-BASE64***')
    }
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $line = [pscustomobject]@{ ts=(Get-Date).ToString('s'); conv=$conv; tool=$tool; decision=$decision; args=$a } |
      ConvertTo-Json -Compress -Depth 4
    Add-Content -Path (Join-Path $logDir 'tool_use.jsonl') -Value $line -Encoding UTF8
  } catch { }
}

function Ask([string]$why, [string]$decision, [string]$tool, [string]$conv, [string]$cmdText) {
  Write-Decision $decision $tool $conv $cmdText
  Emit ('{"decision":"ask","reason":"' + ($why -replace '"','') + '"}')
}
function Allow([string]$tool, [string]$conv, [string]$cmdText) {
  Write-Decision 'allow' $tool $conv $cmdText
  Emit '{"decision":"allow","reason":"operator policy: auto-approved"}'
}

$raw = ''; $cmd = ''; $tool = ''; $conv = ''
try { $raw = [Console]::In.ReadToEnd() } catch { }

$parsed = $null
if ($raw -and $raw.Trim()) {
  try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
  if ($null -eq $parsed) {
    # unrecognised payload shape: stay conservative, and record why
    Ask 'hook: unrecognised payload, default approval' 'ask(bad-payload)' '' '' ($raw.Substring(0, [Math]::Min(200, $raw.Length)))
  }
}
if ($parsed) {
  try {
    $conv = [string]$parsed.conversationId
    $tool = [string]$parsed.toolCall.name
    $cmd  = [string]$parsed.toolCall.args.CommandLine
    if (-not $cmd) { $cmd = [string]$parsed.toolCall.args.command }
  } catch { }
}

try {
  $enabled = $false; $allow = $true; $guard = $true
  $sp = Join-Path $PSScriptRoot 'state.json'
  if (Test-Path $sp) {
    $s = Get-Content $sp -Raw | ConvertFrom-Json
    if ($null -ne $s.enabled)          { $enabled = [bool]$s.enabled }
    if ($null -ne $s.allow)            { $allow   = [bool]$s.allow }
    if ($null -ne $s.guardDestructive) { $guard   = [bool]$s.guardDestructive }
    if ($null -ne $s.maskLogs)         { $mask    = [bool]$s.maskLogs }
  }

  if (-not $enabled -or -not $allow) { Ask 'armor-break off: default approval' 'ask(off)' $tool $conv $cmd }

  # Blacklist over the command line only. It is a guard against slips on a personal
  # dev box, not a boundary: anything that reaches the same effect through a script
  # file, a base64 payload, an MCP tool, or a non-shell tool call is out of scope here.
  # See README "Guard limits".
  $danger = '(?i)(git\s+push|git\s+reset\s+--hard|rm\s+-rf|Remove-Item[^\r\n]*-Recurse|del\s+/s|rmdir\s+/s|format\s+[a-z]:|drop\s+(table|database)|truncate\s+table|shutdown|Stop-Computer|mkfs|dd\s+if=)'
  $evasion = '(?i)(-enc(odedcommand)?\s+[A-Za-z0-9+/=]{16,}|frombase64string|\biex\s*[\(\s]|invoke-expression|\|\s*(ba)?sh\b|curl[^\r\n|]*\|\s*(ba)?sh|wget[^\r\n|]*\|\s*(ba)?sh)'
  if ($guard -and $cmd -and $cmd -match $danger) {
    Ask 'destructive command: operator confirmation required' 'ask(destructive)' $tool $conv $cmd
  }
  if ($guard -and $cmd -and $cmd -match $evasion) {
    Ask 'obfuscated or piped execution: operator confirmation required' 'ask(evasion)' $tool $conv $cmd
  }

  Allow $tool $conv $cmd
} catch {
  Ask 'hook error: default approval' 'ask(error)' $tool $conv $cmd
}
