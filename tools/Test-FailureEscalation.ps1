$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$alertCode = Get-Content -LiteralPath (Join-Path $root 'Public/Send-NSPScanBridgeAlert.ps1') -Raw
$runnerCode = Get-Content -LiteralPath (Join-Path $root 'scripts/Run-ScanBridge.ps1') -Raw
$alerts = [System.Management.Automation.Language.Parser]::ParseInput($alertCode, [ref]$null, [ref]$null)
if (-not $alerts) { throw 'Alert code failed parse.' }
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($alertCode,[ref]$null,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Alert code has parser errors.' }
[void][System.Management.Automation.Language.Parser]::ParseInput($runnerCode,[ref]$null,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Runner code has parser errors.' }
if ($alertCode -notmatch 'HealthCheckFailed' -or $alertCode -notmatch 'WorkerFailure') {
    throw 'Failure escalations missing from alert handler.'
}
if ($runnerCode -notmatch 'WorkerFailed:\$workerFailed') {
    throw 'Runner does not pass worker failure status to dispatch.'
}
Write-Host 'Passed: failure escalation parse and wiring assertions.'
