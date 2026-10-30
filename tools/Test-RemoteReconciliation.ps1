$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Private/Test-NSPScanBridgeRemoteMatch.ps1')
$script:remoteBytes = [byte[]](37,80,68,70,45,49,46,52)
function Invoke-NSPGraphRequest {
    param($Method,$Uri,$ErrorAction)
    return @{ id='test-remote-id'; size=8; '@microsoft.graph.downloadUrl'='https://example.invalid/content' }
}
function Invoke-WebRequest {
    param($Uri,$OutFile,[switch]$UseBasicParsing,$ErrorAction)
    [IO.File]::WriteAllBytes($OutFile,$script:remoteBytes)
}
$dir = Join-Path ([IO.Path]::GetTempPath()) ('NSPReconcile-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $dir | Out-Null
    $pdf = Join-Path $dir (([guid]::NewGuid().ToString('N'))+'.pdf')
    [IO.File]::WriteAllBytes($pdf,[byte[]](37,80,68,70,45,49,46,52))
    $good = Test-NSPScanBridgeRemoteMatch -PdfPath $pdf -DriveId 'drive' -FolderItemId 'folder'
    if ($good.Status -ne 'Verified' -or $good.RemoteId -ne 'test-remote-id') { throw 'Matching remote bytes not verified.' }
    $script:remoteBytes = [byte[]](37,80,68,70,45,49,46,53)
    $bad = Test-NSPScanBridgeRemoteMatch -PdfPath $pdf -DriveId 'drive' -FolderItemId 'folder'
    if ($bad.Status -ne 'Mismatch' -or $bad.RemoteId) { throw 'Same-length mismatch was incorrectly accepted.' }
    if (@(Get-ChildItem -LiteralPath $dir -Filter 'nsp-reconcile-*').Count) { throw 'Temporary remote copy not cleaned up.' }
    Write-Host 'Passed: remote content match, mismatch and temp cleanup.'
} finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
