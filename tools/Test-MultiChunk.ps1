$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Private/Send-NSPScanBridgeUploadSession.ps1')
$script:chunks = New-Object System.Collections.ArrayList
function Invoke-NSPGraphRequest {
    param($Method,$Uri,$Body)
    if ($Method -ne 'POST' -or $Body.item['@microsoft.graph.conflictBehavior'] -ne 'fail') {
        throw 'Upload session did not use conflict-fail policy.'
    }
    return @{ uploadUrl = 'https://example.invalid/upload-session' }
}
function Invoke-RestMethod {
    param($Method,$Uri,$Body,$Headers,$ContentType,$ErrorAction)
    if ($Method -ne 'PUT' -or $ContentType -ne 'application/octet-stream') { throw 'Incorrect chunk transport.' }
    [void]$script:chunks.Add([pscustomobject]@{ Count=$Body.Length; Range=$Headers['Content-Range'] })
    if ($script:chunks.Count -eq 1) { return @{ nextExpectedRanges = @('5242880-') } }
    return @{ id='final-id'; size=6000000 }
}
$file = Join-Path ([IO.Path]::GetTempPath()) ('nsp-chunks-' + [guid]::NewGuid().ToString('N') + '.pdf')
try {
    $stream = [IO.File]::Create($file)
    try { $stream.SetLength(6000000) } finally { $stream.Dispose() }
    $result = Send-NSPScanBridgeUploadSession -Path $file -DriveId 'test' -FolderItemId 'parent' -Name 'test.pdf'
    if ($result.id -ne 'final-id' -or $script:chunks.Count -ne 2) { throw 'Chunk upload did not complete.' }
    if ($script:chunks[0].Range -ne 'bytes 0-5242879/6000000') { throw 'First range incorrect.' }
    if ($script:chunks[1].Range -ne 'bytes 5242880-5999999/6000000') { throw 'Second range incorrect.' }
    Write-Host 'Passed: synthetic multi-chunk range and acknowledgement.'
} finally {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}
