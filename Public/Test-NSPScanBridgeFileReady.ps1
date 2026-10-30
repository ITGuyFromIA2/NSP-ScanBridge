function Test-NSPScanBridgeFileReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1,3600)][int]$MinimumAgeSeconds = 15
    )
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0 -or $item.Extension -ine '.pdf') { return $false }
    if (((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds -lt $MinimumAgeSeconds) { return $false }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($item.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        return $true
    }
    catch [System.IO.IOException] { return $false }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}
