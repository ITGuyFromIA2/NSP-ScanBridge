$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testBinding = @{ RouteName='Test'; TenantId='test-tenant'; ClientId='test-app'; DriveId='test-drive'; FolderItemId='test-folder' }
. (Join-Path $root 'Private/Assert-NSPScanBridgeJobBinding.ps1')
. (Join-Path $root 'Private/Get-NSPScanBridgeJobBinding.ps1')
. (Join-Path $root 'Private/Read-NSPScanBridgeReceipt.ps1')
. (Join-Path $root 'Private/Save-NSPScanBridgeReceipt.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) (([guid]::NewGuid().ToString('N')) + '.pdf')
try {
    [IO.File]::WriteAllBytes($temp, [byte[]](37,80,68,70,45,49,46,52))
    Save-NSPScanBridgeReceipt -Binding $testBinding -PdfPath $temp -State Queued
    Save-NSPScanBridgeReceipt -Binding $testBinding -PdfPath $temp -State Uploading
    Save-NSPScanBridgeReceipt -Binding $testBinding -PdfPath $temp -State Uploaded -RemoteId 'synthetic-remote'
    $receipt = Get-Content ([IO.Path]::ChangeExtension($temp, '.json')) -Raw | ConvertFrom-Json
    if ($receipt.State -ne 'Uploaded' -or $receipt.RemoteId -ne 'synthetic-remote') { throw 'Receipt transition failed.' }
    $invalid = $false
    try { Save-NSPScanBridgeReceipt -Binding $testBinding -PdfPath $temp -State Queued } catch { $invalid = $true }
    if (-not $invalid) { throw 'Uploaded state reverted unexpectedly.' }
    [IO.File]::AppendAllText($temp, 'modified')
    $rejected = $false
    try { Save-NSPScanBridgeReceipt -Binding $testBinding -PdfPath $temp -State Review } catch { $rejected = $true }
    if (-not $rejected) { throw 'Modified PDF was not rejected.' }
    Write-Host 'Passed: durable receipt transitions and hash mismatch rejection.'
} finally {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    Remove-Item ([IO.Path]::ChangeExtension($temp, '.json')) -Force -ErrorAction SilentlyContinue
}
