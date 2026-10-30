[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ConfigurationPath,
  [int]$MaximumPending = 25,
  [int]$MaximumPendingMinutes = 10
)
$ErrorActionPreference = 'Stop'
Import-Module NSP.ScanBridge -ErrorAction Stop
try {
  Send-NSPScanBridgeAlert -ConfigurationPath $ConfigurationPath -MaximumPending $MaximumPending -MaximumPendingMinutes $MaximumPendingMinutes -ErrorAction Stop
} catch {
  Write-Error 'ScanBridge escalation failed; check the restricted monitoring logs.'
  exit 3
}
