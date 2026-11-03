function Get-NSPScanBridgeHealth {
    <#
    .SYNOPSIS
        Reports scan queue health without disclosing PDF filenames.
    .DESCRIPTION
        Reads local source and spool directories. Never accesses Graph or changes files.
        Counts reflect a snapshot and can change during ingestion.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    $config = Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    if (-not $config.Routes) { throw 'No routes configured.' }
    foreach ($route in $config.Routes) {
        foreach ($required in 'Name','Source','Spool','Archive') {
            if (-not $route[$required]) { throw "A route is missing $required." }
        }
        $source = @(Get-ChildItem -LiteralPath $route.Source -File -Filter '*.pdf' -ErrorAction Stop)
        $pending = @(Get-ChildItem -LiteralPath $route.Spool -File -Filter '*.pdf' -ErrorAction Stop)
        $archive = @(Get-ChildItem -LiteralPath $route.Archive -File -Filter '*.pdf' -ErrorAction Stop)
        $stateCounts = @{ Queued = 0; Uploading = 0; Uploaded = 0; Review = 0; MissingReceipt = 0; InvalidReceipt = 0 }
        foreach ($file in $pending) {
            $receiptPath = [IO.Path]::ChangeExtension($file.FullName, '.json')
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
                $stateCounts.MissingReceipt++
                continue
            }
            try {
                $binding = Get-NSPScanBridgeJobBinding -Route $route -Auth $config.Auth
                $receipt = Read-NSPScanBridgeReceipt -PdfPath $file.FullName -ReceiptPath $receiptPath -ExpectedBinding $binding
                $state = [string]$receipt.State
                if ($receipt.JobId -ne [IO.Path]::GetFileNameWithoutExtension($file.Name) -or $state -notin @('Queued','Uploading','Uploaded','Review')) {
                    $stateCounts.InvalidReceipt++
                } else {
                    $stateCounts[$state]++
                }
            } catch {
                $stateCounts.InvalidReceipt++
            }
        }
        $orphanReceipts = @(
            Get-ChildItem -LiteralPath $route.Spool -File -Filter '*.json' -ErrorAction Stop |
            Where-Object { -not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName, '.pdf')) -PathType Leaf) }
        ).Count
        $oldest = $null
        if ($pending.Count -gt 0) {
            $oldest = ($pending | Sort-Object CreationTimeUtc | Select-Object -First 1).CreationTimeUtc
        }
        # Source age uses the last write, the same clock readiness uses; unclaimed old files are held there.
        $oldestSource = $null
        if ($source.Count -gt 0) {
            $oldestSource = ($source | Sort-Object LastWriteTimeUtc | Select-Object -First 1).LastWriteTimeUtc
        }
        [pscustomobject]@{
            Route = [string]$route.Name
            SourceCount = $source.Count
            PendingCount = $pending.Count
            ArchivedCount = $archive.Count
            QueuedCount = $stateCounts.Queued
            UploadingCount = $stateCounts.Uploading
            UploadedAwaitingArchiveCount = $stateCounts.Uploaded
            ReviewCount = $stateCounts.Review
            MissingReceiptCount = $stateCounts.MissingReceipt
            InvalidReceiptCount = $stateCounts.InvalidReceipt
            OrphanReceiptCount = $orphanReceipts
            OldestPendingUtc = $oldest
            OldestPendingMinutes = if ($null -eq $oldest) { $null } else { [math]::Round(([datetime]::UtcNow - $oldest).TotalMinutes,1) }
            OldestSourceMinutes = if ($null -eq $oldestSource) { $null } else { [math]::Round(([datetime]::UtcNow - $oldestSource).TotalMinutes,1) }
        }
    }
}
