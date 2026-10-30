$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Private/Get-NSPScanBridgeBackoff.ps1')
. (Join-Path $root 'Private/Test-NSPScanBridgeRetrySafe.ps1')
if ((Get-NSPScanBridgeBackoff -Attempt 1) -ne 15) { throw 'First delay incorrect.' }
if ((Get-NSPScanBridgeBackoff -Attempt 3) -ne 60) { throw 'Third delay incorrect.' }
if ((Get-NSPScanBridgeBackoff -Attempt 20) -ne 1800) { throw 'Maximum delay not enforced.' }
if (-not (Test-NSPScanBridgeRetrySafe -Phase BeforeSession -StatusCode 429)) { throw 'Transient pre-session retry rejected.' }
if (Test-NSPScanBridgeRetrySafe -Phase Uploading -StatusCode 503) { throw 'Ambiguous upload retry incorrectly allowed.' }
if (Test-NSPScanBridgeRetrySafe -Phase BeforeSession -StatusCode 403) { throw 'Permission failure incorrectly retryable.' }
Write-Host 'Passed: bounded backoff and ambiguous-outcome retry restrictions.'
