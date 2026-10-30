$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Private/Send-NSPScanBridgeUploadSession.ps1')
$script:sessionRequest = $null
$script:uploadedHeaders = $null
function Invoke-NSPGraphRequest {
    param($Method,$Uri,$Body)
    $script:sessionRequest = @{ Method=$Method; Uri=$Uri; Body=$Body }
    return @{ uploadUrl = 'https://upload.example.invalid/session' }
}
function Invoke-RestMethod {
    param($Method,$Uri,$Body,$ContentType,$Headers,$ErrorAction)
    $script:uploadedHeaders = $Headers
    if ($Method -ne 'PUT' -or $Uri -ne 'https://upload.example.invalid/session') { throw 'Invalid upload request.' }
    if ($ContentType -ne 'application/octet-stream') { throw 'Expected binary content.' }
    return @{ id='synthetic-item'; size=$Body.Length }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('nsp-upload-' + [guid]::NewGuid().ToString('N') + '.pdf')
try {
    [IO.File]::WriteAllBytes($temp, [byte[]](37,80,68,70,45,49,46,52,10))
    $result = Send-NSPScanBridgeUploadSession -Path $temp -DriveId 'drive' -FolderItemId 'parent' -Name '123.pdf'
    if ($result.id -ne 'synthetic-item') { throw 'Missing completed result.' }
    if ($script:sessionRequest.Method -ne 'POST') { throw 'Session did not start with POST.' }
    if ($script:sessionRequest.Body.item['@microsoft.graph.conflictBehavior'] -ne 'fail') { throw 'Conflict policy must be fail.' }
    if ($script:uploadedHeaders['Content-Range'] -ne 'bytes 0-8/9') { throw 'Incorrect content range.' }
    Write-Host 'Passed: synthetic upload-session contract.'
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
