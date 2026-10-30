$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($name in 'Send-NSPScanBridgeUploadSession','Test-NSPScanBridgeRetrySafe','Get-NSPScanBridgeBackoff') { . (Join-Path $root ('Private/' + $name + '.ps1')) }
$script:mode = ''
$script:sessions = 0
$script:chunks = 0
$script:sleeps = 0
function Start-Sleep { param($Seconds) $script:sleeps++ }
function Invoke-NSPGraphRequest {
    param($Method,$Uri,$Body,$ErrorAction)
    $script:sessions++
    if ($Body.item['@microsoft.graph.conflictBehavior'] -ne 'fail') { throw 'Conflict policy changed.' }
    if ($script:mode -in @('Forbidden','Throttled')) {
        $exception = New-Object System.Exception('Synthetic session failure.')
        $exception | Add-Member -NotePropertyName ResponseStatusCode -NotePropertyValue $(if ($script:mode -eq 'Forbidden') { 403 } else { 429 })
        throw $exception
    }
    if ($script:mode -eq 'BadSession') { return @{ uploadUrl='http://example.invalid/session' } }
    @{ uploadUrl='https://example.invalid/session' }
}
function Invoke-RestMethod {
    param($Method,$Uri,$Body,$Headers,$ContentType,$ErrorAction)
    $script:chunks++
    if ($Headers.ContainsKey('Authorization') -or $Method -ne 'PUT' -or $ContentType -ne 'application/octet-stream') { throw 'Unsafe binary transport.' }
    switch ($script:mode) {
        ChunkFailure { throw 'Synthetic ambiguous transfer failure.' }
        MissingId { return @{ size=$Body.Length } }
        WrongSize { return @{ id='synthetic'; size=1 } }
        WrongRange { return @{ nextExpectedRanges=@('0-') } }
        MissingRange { return @{} }
        ReversedRange { return @{ nextExpectedRanges=@('5242880-1') } }
        ExcessiveRange { return @{ nextExpectedRanges=@('5242880-7000000') } }
        MultipleRanges { return @{ nextExpectedRanges=@('5242880-','1-2') } }
    }
    throw 'Unexpected binary call.'
}
$base = Join-Path ([IO.Path]::GetTempPath()) ('nsp-upload-safety-' + [guid]::NewGuid().ToString('N'))
$resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($base).StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe fixture root.' }
try {
    [void][IO.Directory]::CreateDirectory($base)
    $pdf = Join-Path $base 'synthetic.pdf'
    $checks = 0
    foreach ($case in @('Forbidden','Throttled','BadSession','ChunkFailure','MissingId','WrongSize','WrongRange','MissingRange','MultipleRanges','ReversedRange','ExcessiveRange')) {
        $script:mode = $case
        $script:sessions = 0; $script:chunks = 0; $script:sleeps = 0
        $length = if ($case -in @('WrongRange','MissingRange','MultipleRanges','ReversedRange','ExcessiveRange')) { 6000000 } else { 8 }
        $stream = [IO.File]::Create($pdf)
        try { $stream.SetLength($length) } finally { $stream.Dispose() }
        $rejected = $false
        try { Send-NSPScanBridgeUploadSession -Path $pdf -DriveId test -FolderItemId folder -Name synthetic.pdf | Out-Null } catch { $rejected=$true }
        if (-not $rejected) { throw ('Unsafe upload result accepted: '+$case) }
        $expectedSessions = if ($case -eq 'Throttled') { 3 } else { 1 }
        $expectedChunks = if ($case -in @('Forbidden','Throttled','BadSession')) { 0 } else { 1 }
        $expectedSleeps = if ($case -eq 'Throttled') { 2 } else { 0 }
        if ($script:sessions -ne $expectedSessions -or $script:chunks -ne $expectedChunks -or $script:sleeps -ne $expectedSleeps) { throw ('Unexpected retry/replay counts: '+$case) }
        if (-not (Test-Path -LiteralPath $pdf)) { throw 'Upload failure removed local evidence.' }
        $checks += 3
    }
    Write-Host ('Passed: {0} upload failure checks with no binary replay.' -f $checks)
} finally {
    $resolvedBase = [IO.Path]::GetFullPath($base)
    if (-not $resolvedBase.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedBase) -notmatch '^nsp-upload-safety-[0-9a-f]{32}$') { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolvedBase) { Remove-Item -LiteralPath $resolvedBase -Recurse -Force }
}
