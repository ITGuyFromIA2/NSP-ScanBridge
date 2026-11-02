function Invoke-NSPScanBridge {
    <#
    .SYNOPSIS
        Runs one unattended scan intake and delivery pass.
    .DESCRIPTION
        Claims completed PDFs to a same-volume spool. Persists per-job receipts,
        delivers via an app-only Graph upload session, and archives confirmed jobs.
        Ambiguous uploads are held for review rather than blindly retried.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [switch]$IntakeOnly
    )
    $ErrorActionPreference = 'Stop'
    $config = Import-PowerShellDataFile -LiteralPath $ConfigurationPath
    if (-not $config.Routes -or -not $config.LockPath) { throw 'Routes and LockPath are required.' }
    # Validate the complete route set before creating locks, claiming files or connecting.
    $routes = @(Get-NSPScanBridgeValidatedRoutes -Routes $config.Routes)
    $bindings = @{}
    foreach ($route in $routes) { $bindings[$route.Name] = Get-NSPScanBridgeJobBinding -Route $route -Auth $config.Auth }
    $lockPath = [IO.Path]::GetFullPath([string]$config.LockPath)
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $lockPath) -PathType Container)) { throw 'Lock directory does not exist.' }
    $lock = $null
    try {
        try {
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] { throw 'Another ScanBridge process holds the lock.' }
        if (-not $IntakeOnly -and -not $WhatIfPreference) {
            Connect-NSPScanBridgeContext -Auth $config.Auth
        }
        foreach ($route in $routes) {
            $binding = $bindings[$route.Name]
            $source = $route.Source
            $spool = $route.Spool
            $archive = $route.Archive
            $age = $route.MinimumAgeSeconds
            foreach ($candidate in @(Get-ChildItem -LiteralPath $source -Filter '*.pdf' -File -ErrorAction Stop)) {
                if (-not (Test-NSPScanBridgeFileReady -Path $candidate.FullName -MinimumAgeSeconds $age)) { continue }
                $jobId = [guid]::NewGuid().ToString('N')
                $claimedPath = Join-Path $spool ($jobId + '.pdf')
                if ($PSCmdlet.ShouldProcess('Ready PDF', 'Claim into durable spool')) {
                    try {
                        [IO.File]::Move($candidate.FullName, $claimedPath)
                        Save-NSPScanBridgeReceipt -PdfPath $claimedPath -State Queued -Binding $binding
                        [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'Queued' }
                    } catch [IO.IOException] {
                        Write-Warning 'A scan could not be claimed; it will be considered in the next pass.'
                    }
                }
            }
            if ($IntakeOnly -or $WhatIfPreference) { continue }
            foreach ($orphanReceipt in @(Get-ChildItem -LiteralPath $spool -Filter '*.json' -File -ErrorAction Stop)) {
                $orphanId = [IO.Path]::GetFileNameWithoutExtension($orphanReceipt.Name)
                if ($orphanId -cnotmatch '^[0-9a-f]{32}$') {
                    Write-Warning 'Unknown spool receipt requires review.'
                    [pscustomobject]@{ Route = $route.Name; JobId = $null; State = 'ManualReviewRequired' }
                    continue
                }
                $spooledPdf = Join-Path $spool ($orphanId + '.pdf')
                $archivedPdf = Join-Path $archive ($orphanId + '.pdf')
                if (-not (Test-Path -LiteralPath $spooledPdf -PathType Leaf)) {
                    if (-not (Test-Path -LiteralPath $archivedPdf -PathType Leaf)) {
                        Write-Warning ('Orphan receipt requires review for job {0}.' -f $orphanId)
                        [pscustomobject]@{ Route = $route.Name; JobId = $orphanId; State = 'ManualReviewRequired' }
                        continue
                    }
                    try {
                        Complete-NSPScanBridgeArchive -PdfPath $spooledPdf -ArchiveDirectory $archive -ExpectedBinding $binding
                        [pscustomobject]@{ Route = $route.Name; JobId = $orphanId; State = 'ArchiveRecovered' }
                    } catch {
                        Write-Warning ("Archive recovery requires review for job {0}." -f $orphanId)
                        [pscustomobject]@{ Route = $route.Name; JobId = $orphanId; State = 'ManualReviewRequired' }
                    }
                }
            }
            foreach ($job in @(Get-ChildItem -LiteralPath $spool -Filter '*.pdf' -File -ErrorAction Stop)) {
                if ($job.Name -cnotmatch '^[0-9a-f]{32}\.pdf$') {
                    Write-Warning 'Unknown spool document requires review.'
                    [pscustomobject]@{ Route = $route.Name; JobId = $null; State = 'ManualReviewRequired' }
                    continue
                }
                $jobId = [IO.Path]::GetFileNameWithoutExtension($job.Name)
                $receiptPath = [IO.Path]::ChangeExtension($job.FullName, '.json')
                if (-not (Test-Path -LiteralPath $receiptPath)) {
                    # A missing receipt cannot distinguish an interrupted claim from a prior upload.
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'ManualReviewRequired' }
                    continue
                }
                try { $receipt = Read-NSPScanBridgeReceipt -PdfPath $job.FullName -ReceiptPath $receiptPath -ExpectedBinding $binding }
                catch {
                    Write-Warning ('Receipt requires review for job {0}.' -f $jobId)
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'ManualReviewRequired' }
                    continue
                }
                if ($receipt.State -in @('Uploading','Review')) {
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'ManualReviewRequired' }
                    continue
                }
                if ($receipt.State -eq 'Uploaded') {
                    try {
                        Complete-NSPScanBridgeArchive -PdfPath $job.FullName -ArchiveDirectory $archive -ExpectedBinding $binding
                        [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'Archived' }
                    } catch {
                        Write-Warning ('Archive requires review for job {0}.' -f $jobId)
                        [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'ManualReviewRequired' }
                    }
                    continue
                }
                if ($receipt.State -ne 'Queued') { throw 'Unrecognized receipt state.' }
                try {
                    if ($job.Length -gt 250MB) { throw 'Configured development size limit exceeded.' }
                    Save-NSPScanBridgeReceipt -PdfPath $job.FullName -State Uploading -Binding $binding
                    $result = Send-NSPScanBridgeUploadSession -Path $job.FullName -DriveId ([string]$route.DriveId) -FolderItemId ([string]$route.FolderItemId) -Name $job.Name
                    if (-not $result.id -or [long]$result.size -ne [long]$job.Length) {
                        throw 'Upload response failed size or item ID verification.'
                    }
                    if ($route.ContainsKey('VerifyRemoteAfterUpload') -and [bool]$route.VerifyRemoteAfterUpload) {
                        $readback = Test-NSPScanBridgeRemoteMatch -PdfPath $job.FullName -DriveId ([string]$route.DriveId) -FolderItemId ([string]$route.FolderItemId)
                        if ($readback.Status -ne 'Verified' -or $readback.RemoteId -ne [string]$result.id) {
                            throw 'Remote upload readback not verified; job held for review.'
                        }
                    }
                    Save-NSPScanBridgeReceipt -PdfPath $job.FullName -State Uploaded -RemoteId ([string]$result.id) -Binding $binding
                    Complete-NSPScanBridgeArchive -PdfPath $job.FullName -ArchiveDirectory $archive -ExpectedBinding $binding
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'Delivered'; DriveItemId = [string]$result.id }
                } catch {
                    if (Test-Path -LiteralPath $job.FullName) {
                        $current = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($current.State -eq 'Uploading') {
                            Save-NSPScanBridgeReceipt -PdfPath $job.FullName -State Review -Binding $binding
                        }
                    }
                    Write-Warning ("Delivery held for job {0}; inspect in protected environment." -f $jobId)
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'PendingReviewOrRetry' }
                }
            }
        }
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}
