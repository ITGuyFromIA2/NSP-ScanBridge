function Test-NSPScanBridgeFileReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1,3600)][int]$MinimumAgeSeconds = 15
    )
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) { return $false }
    $metadata = Get-NSPScanBridgeReadinessDecision -Mode AgeAndExclusive -Length $item.Length -LastWriteTimeUtc $item.LastWriteTimeUtc -IsPdf ($item.Extension -ieq '.pdf') -IsContainer $item.PSIsContainer -MinimumAgeSeconds $MinimumAgeSeconds
    if (-not $metadata.MetadataEligible) { return $false }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($item.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        return $true
    }
    catch [System.IO.IOException] { return $false }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}
