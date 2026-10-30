[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [switch]$IntakeOnly,
    [switch]$SkipAlerts
)
$ErrorActionPreference = 'Stop'
Import-Module NSP.ScanBridge -ErrorAction Stop
$workerFailed = $false
$alertFailed = $false
try {
    Invoke-NSPScanBridge -ConfigurationPath $ConfigurationPath -IntakeOnly:$IntakeOnly -ErrorAction Stop
} catch {
    $workerFailed = $true
    Write-Warning 'ScanBridge worker failed. Details are available only in restricted local diagnostics.'
}
if (-not $SkipAlerts -and -not $IntakeOnly) {
    try {
        $configuration = Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
        if ($configuration.Alerts -and $configuration.Alerts.Enabled) {
            Send-NSPScanBridgeAlert -ConfigurationPath $ConfigurationPath -WorkerFailed:$workerFailed -ErrorAction Stop
        }
    } catch {
        $alertFailed = $true
        Write-Warning 'ScanBridge alert submission failed. Check the restricted local configuration and logs.'
    }
}
if ($alertFailed) { exit 3 }
if ($workerFailed) { exit 2 }
exit 0
