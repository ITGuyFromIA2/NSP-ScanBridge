function Read-NSPScanBridgeReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [string]$ReceiptPath = [IO.Path]::ChangeExtension($PdfPath, '.json'),
        [System.Collections.IDictionary]$ExpectedBinding
    )
    $pdf = Get-Item -LiteralPath $PdfPath -ErrorAction Stop
    if ($pdf.Name -cnotmatch '^[0-9a-f]{32}\.pdf$') { throw 'Invalid job filename.' }
    try { $receipt = Get-Content -LiteralPath $ReceiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Delivery receipt is missing or invalid JSON; preserve it for review.' }
    if ($receipt -isnot [pscustomobject] -or $receipt.Version -ne 2 -or
        $receipt.JobId -cne $pdf.BaseName -or
        $receipt.State -cnotin @('Queued','Uploading','Uploaded','Review') -or
        [string]$receipt.Hash -notmatch '^[0-9a-fA-F]{64}$' -or
        [string]$receipt.Size -notmatch '^[0-9]+$' -or
        [decimal]$receipt.Size -ne $pdf.Length -or
        $receipt.Hash -ne (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256 -ErrorAction Stop).Hash -or
        ($receipt.State -eq 'Uploaded' -and [string]::IsNullOrWhiteSpace([string]$receipt.RemoteId))) {
        throw 'Delivery receipt fails version, document integrity or state validation; preserve it for review.'
    }
    Assert-NSPScanBridgeJobBinding -Binding $receipt.Destination -ExpectedBinding $ExpectedBinding
    $receipt
}