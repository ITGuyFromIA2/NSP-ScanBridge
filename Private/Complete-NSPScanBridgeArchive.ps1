function Complete-NSPScanBridgeArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [Parameter(Mandatory)][string]$ArchiveDirectory
    )
    $name = [IO.Path]::GetFileName($PdfPath)
    $id = [IO.Path]::GetFileNameWithoutExtension($name)
    if ($name -cnotmatch '^[0-9a-f]{32}\.pdf$') { throw 'Invalid job filename.' }
    $sourceReceipt = [IO.Path]::ChangeExtension($PdfPath, '.json')
    $targetPdf = Join-Path $ArchiveDirectory $name
    $targetReceipt = [IO.Path]::ChangeExtension($targetPdf, '.json')
    $pdfInSpool = Test-Path -LiteralPath $PdfPath -PathType Leaf
    $pdfInArchive = Test-Path -LiteralPath $targetPdf -PathType Leaf
    if ($pdfInSpool -and $pdfInArchive) { throw 'Duplicate PDF found in spool and archive. Manual review required.' }
    if (-not $pdfInSpool -and -not $pdfInArchive) { throw 'Neither spool nor archive contains the PDF.' }
    if (-not (Test-Path -LiteralPath $sourceReceipt -PathType Leaf) -and -not (Test-Path -LiteralPath $targetReceipt -PathType Leaf)) {
        throw 'Missing delivery receipt. Do not reupload.'
    }
    if (Test-Path -LiteralPath $targetReceipt) {
        if (Test-Path -LiteralPath $sourceReceipt) { throw 'Duplicate receipts require manual review.' }
        if ($pdfInSpool) { throw 'Archived receipt with spooled PDF requires manual review.' }
        return
    }
    $receipt = Get-Content -LiteralPath $sourceReceipt -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($receipt.JobId -ne $id -or $receipt.State -ne 'Uploaded' -or -not $receipt.RemoteId) {
        throw 'Receipt has no verified uploaded state.'
    }
    $actualPdf = if ($pdfInSpool) { $PdfPath } else { $targetPdf }
    if ($receipt.Hash -ne (Get-FileHash -LiteralPath $actualPdf -Algorithm SHA256).Hash) {
        throw 'Archived document hash mismatch.'
    }
    if ($pdfInSpool) { [IO.File]::Move($PdfPath, $targetPdf) }
    [IO.File]::Move($sourceReceipt, $targetReceipt)
}
