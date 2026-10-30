[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigurationPath)
$ErrorActionPreference = 'Stop'
Import-Module NSP.ScanBridge -ErrorAction Stop
Invoke-NSPScanBridge -ConfigurationPath $ConfigurationPath -ErrorAction Stop
