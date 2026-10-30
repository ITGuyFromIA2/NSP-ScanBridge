[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [switch]$IntakeOnly,
    [switch]$SkipAlerts
)
$ErrorActionPreference = 'Stop'
$workerFailed = $false
$alertFailed = $false
$workerHeld = $false
try {
    Import-Module NSP.ScanBridge -ErrorAction Stop
    $workerResults = @(Invoke-NSPScanBridge -ConfigurationPath $ConfigurationPath -IntakeOnly:$IntakeOnly -ErrorAction Stop)
    $workerResults
    $workerHeld = @($workerResults | Where-Object { $_.State -in @('ManualReviewRequired','PendingReviewOrRetry') }).Count -gt 0
} catch {
    $workerFailed = $true
    Write-Warning 'ScanBridge worker failed. Details are available only in restricted local diagnostics.'
}
if (-not $SkipAlerts -and -not $IntakeOnly) {
    try {
        $configuration = Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
        if ($configuration.Alerts -and $configuration.Alerts.Enabled) {
            Send-NSPScanBridgeAlert -ConfigurationPath $ConfigurationPath -WorkerFailed:$workerFailed -WorkerSucceeded:(-not $workerFailed) -ErrorAction Stop
        }
    } catch {
        $alertFailed = $true
        Write-Warning 'ScanBridge alert submission failed. Check the restricted local configuration and logs.'
    }
}
if ($alertFailed) { exit 3 }
if ($workerFailed -or $workerHeld) { exit 2 }
exit 0
