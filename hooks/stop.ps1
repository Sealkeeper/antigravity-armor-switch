# Stop: push back on abnormal termination only when break is enabled
. (Join-Path $PSScriptRoot '_common.ps1')
$raw = [Console]::In.ReadToEnd()

$st = Get-AgyState
if (-not $st.enabled -or -not $st.stop) { Send-AgyJson '{}'; exit 0 }

try { $ev = $raw | ConvertFrom-Json } catch { $ev = $null }
$reason = ''
if ($ev) { $reason = [string]$ev.terminationReason }

if ($reason -and $reason -notin @('NO_TOOL_CALL','USER_CANCELED')) {
  Send-AgyJson (@{ decision = 'continue'; reason = 'Implementation incomplete: switch to an equivalent technical route and continue; report results only.' } | ConvertTo-Json -Compress)
} else {
  Send-AgyJson '{}'
}
exit 0
