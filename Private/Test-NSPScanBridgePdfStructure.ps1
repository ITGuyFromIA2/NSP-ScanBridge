function Test-NSPScanBridgePdfStructure {
    <#
    .SYNOPSIS
        Checks for a PDF header near the start and an end-of-file marker near the end.
    .DESCRIPTION
        A structural completeness heuristic, not a parser: it does not prove the document renders.
        Reads at most two 1024-byte windows from a caller-owned seekable stream and leaves it open.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $window = 1024
    $length = $Stream.Length
    $headLength = [int][math]::Min([long]$window, $length)
    $head = New-Object byte[] $headLength
    [void]$Stream.Seek(0, [IO.SeekOrigin]::Begin)
    $read = 0
    while ($read -lt $headLength) { $n = $Stream.Read($head, $read, $headLength - $read); if ($n -le 0) { break }; $read += $n }
    $tailLength = [int][math]::Min([long]$window, $length)
    $tail = New-Object byte[] $tailLength
    [void]$Stream.Seek($length - $tailLength, [IO.SeekOrigin]::Begin)
    $read = 0
    while ($read -lt $tailLength) { $n = $Stream.Read($tail, $read, $tailLength - $read); if ($n -le 0) { break }; $read += $n }
    # Latin-1 maps every byte to one character, so offsets survive binary content.
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $hasHeader = $latin1.GetString($head).Contains('%PDF-')
    $hasTrailer = $latin1.GetString($tail).Contains('%%EOF')
    $reasons = @()
    if (-not $hasHeader) { $reasons += 'MissingHeader' }
    if (-not $hasTrailer) { $reasons += 'MissingEndOfFile' }
    [pscustomobject]@{ Complete = ($reasons.Count -eq 0); HasHeader = $hasHeader; HasEndOfFile = $hasTrailer; Reasons = $reasons }
}
