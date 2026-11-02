[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [string[]]$RouteName,
    [ValidateSet('AgeAndExclusive','StableWindow','StrictQuiet')][string[]]$Mode,
    [double]$StableQuietSeconds,
    [int]$StableSamples,
    [double]$StrictQuietSeconds,
    [int]$StrictSamples,
    [int]$PollMilliseconds,
    [double]$HeartbeatSeconds,
    [double]$DurationSeconds,
    [int]$MaximumTrackedFiles,
    [switch]$MetadataOnly,
    [switch]$PollingOnly,
    [switch]$PassThru
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ScanBridge.psd1') -ErrorAction Stop
Watch-NSPScanBridgeReadiness @PSBoundParameters
