[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [double]$DurationSeconds,
    [int]$PollMilliseconds,
    [double]$QuietSeconds,
    [string]$DeviceName,
    [string]$OutputDirectory,
    [int]$MaximumTrackedFiles,
    [switch]$IncludeFileNames,
    [switch]$PollingOnly
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ScanBridge.psd1') -ErrorAction Stop
Invoke-NSPScanBridgeDeliveryDiscovery @PSBoundParameters
