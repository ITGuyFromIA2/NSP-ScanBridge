[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [ValidateRange(1,100000)][int]$MaximumPending = 25,
    [ValidateRange(1,10080)][int]$MaximumPendingMinutes = 10
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module NSP.ScanBridge -ErrorAction Stop
    $results = @(Test-NSPScanBridgeHealth -ConfigurationPath $ConfigurationPath -MaximumPending $MaximumPending -MaximumPendingMinutes $MaximumPendingMinutes)
    if ($results.Count -eq 0) { throw 'No scan routes reported.' }
    foreach ($item in $results) {
        $condition = if ($item.Healthy) { 'OK' } else { ($item.Conditions -join ',') }
        Write-Output ('Route={0}; Status={1}; Pending={2}; OldestMinutes={3}' -f $item.Route,$condition,$item.PendingCount,$item.OldestPendingMinutes)
    }
    if (@($results | Where-Object { -not $_.Healthy }).Count -gt 0) { exit 2 }
    exit 0
} catch {
    Write-Error 'ScanBridge health evaluation failed; inspect restricted local logs.'
    exit 3
}
