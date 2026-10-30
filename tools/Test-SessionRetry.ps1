$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Private/Send-NSPScanBridgeUploadSession.ps1')
. (Join-Path $root 'Private/Test-NSPScanBridgeRetrySafe.ps1')
. (Join-Path $root 'Private/Get-NSPScanBridgeBackoff.ps1')
$script:sessionCalls = 0
$script:sleeps = 0
function Start-Sleep { param([int]$Seconds) $script:sleeps++ }
function Invoke-NSPGraphRequest {
    param($Method,$Uri,$Body,$ErrorAction)
    $script:sessionCalls++
    if ($script:sessionCalls -eq 1) {
        $ex = New-Object System.Exception('Synthetic throttle')
        $ex | Add-Member -NotePropertyName ResponseStatusCode -NotePropertyValue 429
        throw $ex
    }
    return @{ uploadUrl = 'https://example.invalid/session' }
}
function Invoke-RestMethod {
    param($Method,$Uri,$Body,$Headers,$ContentType,$ErrorAction)
    return @{ id='synthetic-item'; size=$Body.Length }
}
$file = Join-Path ([IO.Path]::GetTempPath()) ('nsp-retry-' + [guid]::NewGuid().ToString('N') + '.pdf')
try {
    [IO.File]::WriteAllBytes($file, [byte[]](37,80,68,70,45,49,46,52))
    $outcome = Send-NSPScanBridgeUploadSession -Path $file -DriveId 'drive' -FolderItemId 'parent' -Name 'test.pdf'
    if ($outcome.id -ne 'synthetic-item' -or $script:sessionCalls -ne 2 -or $script:sleeps -ne 1) {
        throw 'Transient pre-session retry did not recover correctly.'
    }
    Write-Host 'Passed: transient upload-session retry before binary transfer.'
} finally {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}
