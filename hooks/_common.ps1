# shared helpers for agy-break hooks (dot-sourced)
$ErrorActionPreference = 'SilentlyContinue'

function Get-AgyState {
  $statePath = Join-Path $PSScriptRoot 'state.json'
  $def = [pscustomobject]@{ enabled = $false; contract = $true; allow = $true; stop = $true; maskLogs = $true; guardDestructive = $true }
  if (-not (Test-Path $statePath)) { return $def }
  try {
    $s = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($n in 'enabled','contract','allow','stop','maskLogs','guardDestructive') {
      if ($null -eq $s.$n) { $s | Add-Member -NotePropertyName $n -NotePropertyValue $def.$n -Force }
    }
    return $s
  } catch { return $def }
}

function Hide-AgySecrets {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $t = $Text
  $t = [regex]::Replace($t, '(ark|sk|ghp|gho|github_pat|xoxb|AIza)[-_A-Za-z0-9]{8,}', '$1***REDACTED***')
  $t = [regex]::Replace($t, '(?i)(bearer\s+)[A-Za-z0-9._\-]{8,}', '$1***REDACTED***')
  $t = [regex]::Replace($t, '(?i)(api[_-]?key["'']?\s*[=:]\s*["'']?)[A-Za-z0-9._\-]{8,}', '$1***REDACTED***')
  $t = [regex]::Replace($t, '(?i)(password|passwd|secret|token)(["'']?\s*[=:]\s*["'']?)[^\s"'']{6,}', '$1$2***REDACTED***')
  $t = [regex]::Replace($t, '[A-Za-z0-9+/]{48,}={0,2}', '***REDACTED-BASE64***')
  return $t
}

function Write-AgyLog {
  param([string]$Name, [string]$Line)
  $dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $st = Get-AgyState
  if ($st.maskLogs) { $Line = Hide-AgySecrets $Line }
  Add-Content -Path (Join-Path $dir $Name) -Value $Line -Encoding UTF8
}

function Send-AgyJson {
  param([string]$Json)
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
  $out = [Console]::OpenStandardOutput()
  $out.Write($bytes, 0, $bytes.Length)
  $out.Flush()
}
