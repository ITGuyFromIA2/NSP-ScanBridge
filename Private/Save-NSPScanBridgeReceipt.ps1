function Save-NSPScanBridgeReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [Parameter(Mandatory)][ValidateSet('Queued','Uploading','Uploaded','Review')][string]$State,
        [string]$RemoteId
    )
    $pdf = Get-Item -LiteralPath $PdfPath -ErrorAction Stop
    $id = [IO.Path]::GetFileNameWithoutExtension($pdf.Name)
    if ($id -notmatch '^[0-9a-f]{32}$') { throw 'Invalid job ID.' }
    $receiptPath = [IO.Path]::ChangeExtension($pdf.FullName, '.json')
    $previous = $null
    if (Test-Path -LiteralPath $receiptPath) {
        $previous = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    }
    $hash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash
    if ($previous -and ($previous.JobId -ne $id -or $previous.Hash -ne $hash)) {
        throw 'Job receipt does not match the PDF.'
    }
    if ($previous) {
        $allowed = @{
            Queued = @('Queued','Uploading','Review')
            Uploading = @('Uploading','Uploaded','Review')
            Uploaded = @('Uploaded')
            Review = @('Review')
        }
        if (-not $allowed.ContainsKey([string]$previous.State) -or $State -notin $allowed[[string]$previous.State]) {
            throw 'Invalid receipt state transition.'
        }
        if ($previous.State -eq 'Uploaded' -and $RemoteId -ne $previous.RemoteId) {
            throw 'An acknowledged remote item ID cannot change.'
        }
    }
    if ($State -eq 'Uploaded' -and -not $RemoteId) {
        throw 'Uploaded state requires remote item ID.'
    }
    $receipt = @{
        Version = 1
        JobId = $id
        State = $State
        Hash = $hash
        Size = [long]$pdf.Length
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        RemoteId = $RemoteId
    }
    $temp = $receiptPath + '.new'
    try {
        [IO.File]::WriteAllText($temp, ($receipt | ConvertTo-Json -Compress))
        if (Test-Path -LiteralPath $receiptPath) {
            [IO.File]::Replace($temp, $receiptPath, $null)
        } else {
            [IO.File]::Move($temp, $receiptPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}
