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
