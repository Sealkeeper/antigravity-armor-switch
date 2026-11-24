# Stop: push back on abnormal termination only when break is enabled.
# Self-contained on purpose: the other three hooks do not dot-source a shared module,
# and a missing _common.ps1 must not turn this hook into a crash (a hook that cannot
# start yields no decision, which the product reads as "allow").
$raw = [Console]::In.ReadToEnd()

function Send-Json([string]$Json) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
  $out = [Console]::OpenStandardOutput()
  $out.Write($bytes, 0, $bytes.Length)
  $out.Flush()
}

$st = [pscustomobject]@{ enabled = $false; stop = $true }
try {
  $sp = Join-Path $PSScriptRoot 'state.json'
  if (Test-Path $sp) {
    $s = Get-Content $sp -Raw | ConvertFrom-Json
    if ($null -ne $s.enabled) { $st.enabled = [bool]$s.enabled }
    if ($null -ne $s.stop)    { $st.stop    = [bool]$s.stop }
  }
} catch { }

if (-not $st.enabled -or -not $st.stop) { Send-Json '{}'; exit 0 }

try { $ev = $raw | ConvertFrom-Json } catch { $ev = $null }
$reason = ''
if ($ev) { $reason = [string]$ev.terminationReason }

if ($reason -and $reason -notin @('NO_TOOL_CALL','USER_CANCELED')) {
  Send-Json (@{ decision = 'continue'; reason = 'Implementation incomplete: switch to an equivalent technical route and continue; report results only.' } | ConvertTo-Json -Compress)
} else {
  Send-Json '{}'
}
exit 0
