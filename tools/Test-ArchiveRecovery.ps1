$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testBinding = @{ RouteName='Test'; TenantId='test-tenant'; ClientId='test-app'; DriveId='test-drive'; FolderItemId='test-folder' }
. (Join-Path $root 'Private/Assert-NSPScanBridgeJobBinding.ps1')
. (Join-Path $root 'Private/Get-NSPScanBridgeJobBinding.ps1')
. (Join-Path $root 'Private/Read-NSPScanBridgeReceipt.ps1')
. (Join-Path $root 'Private/Save-NSPScanBridgeReceipt.ps1')
. (Join-Path $root 'Private/Complete-NSPScanBridgeArchive.ps1')
$base = Join-Path ([IO.Path]::GetTempPath()) ('NSP-Archive-' + [guid]::NewGuid().ToString('N'))
try {
    $spool = Join-Path $base 'spool'
    $archive = Join-Path $base 'archive'
    [void](New-Item -ItemType Directory -Path $spool, $archive -Force)
    $id = [guid]::NewGuid().ToString('N')
    $pdf = Join-Path $spool ($id + '.pdf')
    [IO.File]::WriteAllBytes($pdf, [byte[]](37,80,68,70,45,49,46,52))
    Save-NSPScanBridgeReceipt -Binding $testBinding -PdfPath $pdf -State Uploaded -RemoteId 'synthetic-id'
    # Simulate crash between PDF move and receipt move.
    $archivedPdf = Join-Path $archive ($id + '.pdf')
    [IO.File]::Move($pdf, $archivedPdf)
    Complete-NSPScanBridgeArchive -ExpectedBinding $testBinding -PdfPath $pdf -ArchiveDirectory $archive
    $receipt = [IO.Path]::ChangeExtension($archivedPdf, '.json')
    if (-not (Test-Path -LiteralPath $receipt)) { throw 'Archive receipt was not recovered.' }
    if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($pdf, '.json'))) { throw 'Orphan spool receipt remains.' }
    Complete-NSPScanBridgeArchive -ExpectedBinding $testBinding -PdfPath $pdf -ArchiveDirectory $archive
    if (-not (Test-Path -LiteralPath $archivedPdf)) { throw 'Idempotent recovery removed PDF.' }
    Write-Host 'Passed: interrupted archive recovery and repeat pass.'
} finally {
    Remove-Item -LiteralPath $base -Force -Recurse -ErrorAction SilentlyContinue
}
