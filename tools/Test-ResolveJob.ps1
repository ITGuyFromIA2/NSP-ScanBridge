$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($file in @('Save-NSPScanBridgeReceipt.ps1','Complete-NSPScanBridgeArchive.ps1','Test-NSPScanBridgeRemoteMatch.ps1')) {
    . (Join-Path (Join-Path $root 'Private') $file)
}
. (Join-Path $root 'Public/Resolve-NSPScanBridgeJob.ps1')
$script:remoteBytes = [byte[]](37,80,68,70,45,49,46,52)
$script:authType = 'AppOnly'
function Get-MgContext { param($ErrorAction) return @{ AuthType = $script:authType } }
function Invoke-NSPGraphRequest {
    param($Method,$Uri,$ErrorAction)
    return @{ id='remote-confirmed'; size=8; '@microsoft.graph.downloadUrl'='https://example.invalid/file' }
}
function Invoke-WebRequest {
    param($Uri,$OutFile,$UseBasicParsing,$ErrorAction)
    [IO.File]::WriteAllBytes($OutFile,$script:remoteBytes)
}
$base = Join-Path ([IO.Path]::GetTempPath()) ('nsp-reconcile-endtoend-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($d in @('spool','archive','lock')) { New-Item -ItemType Directory -Path (Join-Path $base $d) -Force | Out-Null }
    $id = [guid]::NewGuid().ToString('N')
    $pdf = Join-Path $base ('spool\' + $id + '.pdf')
    [IO.File]::WriteAllBytes($pdf,[byte[]](37,80,68,70,45,49,46,52))
    Save-NSPScanBridgeReceipt -PdfPath $pdf -State Queued
    Save-NSPScanBridgeReceipt -PdfPath $pdf -State Review
    $safeBase = $base.Replace("'", "''")
    $config = Join-Path $base 'config.psd1'
    $text = "@{ LockPath = '$safeBase\lock\worker.lock'; Routes = @( @{ Name = 'Test'; Spool = '$safeBase\spool'; Archive = '$safeBase\archive'; DriveId = 'drive'; FolderItemId = 'folder' } ) }"
    [IO.File]::WriteAllText($config,$text)
    $script:authType = 'Delegated'
    $denied = $false
    try { Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName Test -JobId $id -ErrorAction Stop | Out-Null } catch { $denied = $true }
    if (-not $denied) { throw 'Delegated reconciliation was not rejected.' }
    $script:authType = 'AppOnly'
    $script:remoteBytes = [byte[]](37,80,68,70,45,49,46,53)
    $mismatch = Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName Test -JobId $id
    if ($mismatch.Status -ne 'Mismatch' -or -not (Test-Path $pdf)) { throw 'Mismatch failed to preserve spool.' }
    $script:remoteBytes = [byte[]](37,80,68,70,45,49,46,52)
    $matched = Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName Test -JobId $id
    if ($matched.Status -ne 'Verified' -or -not $matched.Archived) { throw 'Verified item was not archived.' }
    $archived = Join-Path $base ('archive\' + $id + '.pdf')
    if (-not (Test-Path $archived)) { throw 'Archived PDF missing.' }
    $receipt = Get-Content -LiteralPath ([IO.Path]::ChangeExtension($archived,'.json')) -Raw | ConvertFrom-Json
    if ($receipt.State -ne 'Uploaded' -or $receipt.RemoteId -ne 'remote-confirmed') { throw 'Archived receipt incorrect.' }
    Write-Host 'Passed: held-job mismatch preserved; verified content recovered and archived.'
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
