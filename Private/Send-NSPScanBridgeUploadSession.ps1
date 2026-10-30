function Send-NSPScanBridgeUploadSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$FolderItemId,
        [Parameter(Mandatory)][string]$Name
    )
    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($info.Length -eq 0) { throw 'Cannot upload an empty file.' }
    $drive = [uri]::EscapeDataString($DriveId)
    $parent = [uri]::EscapeDataString($FolderItemId)
    $encodedName = [uri]::EscapeDataString($Name)
    $uri = "drives/$drive/items/$($parent):/$($encodedName):/createUploadSession"
    $session = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $session = Invoke-NSPGraphRequest -Method POST -Uri $uri -Body @{
                item = @{ '@microsoft.graph.conflictBehavior' = 'fail'; name = $Name }
            } -ErrorAction Stop
            break
        } catch {
            # Only retry documented transient HTTP responses before bytes are sent.
            $status = 0
            if ($null -ne $_.Exception.ResponseStatusCode) {
                $status = [int]$_.Exception.ResponseStatusCode
            } elseif ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            if ($attempt -eq 3 -or -not (Test-NSPScanBridgeRetrySafe -Phase BeforeSession -StatusCode $status)) {
                throw
            }
            Start-Sleep -Seconds (Get-NSPScanBridgeBackoff -Attempt $attempt)
        }
    }
    if (-not $session.uploadUrl -or $session.uploadUrl -notmatch '^https://') {
        throw 'Graph did not provide an HTTPS upload URL.'
    }
    $chunkSize = 327680 * 16
    $stream = [IO.File]::Open($info.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $position = [long]0
        while ($position -lt $stream.Length) {
            $count = [int][math]::Min($chunkSize, $stream.Length - $position)
            $bytes = New-Object byte[] $count
            $read = 0
            while ($read -lt $count) {
                $n = $stream.Read($bytes, $read, $count - $read)
                if ($n -eq 0) { throw 'Unexpected end of file during upload.' }
                $read += $n
            }
            $end = $position + $count - 1
            $headers = @{ 'Content-Range' = "bytes $position-$end/$($stream.Length)" }
            $args = @{ Method = 'PUT'; Uri = $session.uploadUrl; Body = $bytes; ContentType = 'application/octet-stream'; Headers = $headers; ErrorAction = 'Stop' }
            $response = Invoke-RestMethod @args
            $position += $count
            if ($position -lt $stream.Length) {
                $ranges = @($response.nextExpectedRanges)
                # This worker does not resume or replay chunks. Hold any unexpected range.
                if ($ranges.Count -ne 1 -or [string]$ranges[0] -notmatch ('^' + $position + '-(?:[0-9]+)?$')) {
                    throw 'Graph did not acknowledge the sequential upload position.'
                }
                if ([string]$ranges[0] -match '-([0-9]+)$' -and
                    ([decimal]$Matches[1] -lt $position -or [decimal]$Matches[1] -ge $stream.Length)) {
                    throw 'Graph returned an invalid remaining byte range.'
                }
            }
        }
        if (-not $response.id -or [long]$response.size -ne $stream.Length) {
            throw 'Final upload response did not confirm drive item and byte size.'
        }
        return $response
    } finally { $stream.Dispose() }
}
