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
    $lockPath = [IO.Path]::GetFullPath([string]$config.LockPath)
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $lockPath) -PathType Container)) { throw 'Lock directory does not exist.' }
    $lock = $null
    try {
        try {
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] { throw 'Another ScanBridge process holds the lock.' }
        if (-not $IntakeOnly -and -not $WhatIfPreference) {
            Import-Module NSP.M365.Graph -ErrorAction Stop
            $auth = $config.Auth
            if ($auth -and $auth.TenantId -and $auth.ClientId -and $auth.CertificateThumbprint) {
                Connect-NSPGraphAppOnly -TenantId $auth.TenantId -ClientId $auth.ClientId -CertificateThumbprint $auth.CertificateThumbprint | Out-Null
            }
            $context = Get-MgContext -ErrorAction Stop
            if (-not $context -or [string]$context.AuthType -ne 'AppOnly') { throw 'App-only Graph context required.' }
        }
        foreach ($route in $config.Routes) {
            foreach ($field in 'Name','Source','Spool','Archive','DriveId','FolderItemId') {
                if (-not $route[$field]) { throw "A route is missing $field." }
            }
            $source = [IO.Path]::GetFullPath([string]$route.Source)
            $spool = [IO.Path]::GetFullPath([string]$route.Spool)
            $archive = [IO.Path]::GetFullPath([string]$route.Archive)
            foreach ($directory in @($source,$spool,$archive)) {
                if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Route directory does not exist.' }
            }
            if ([IO.Path]::GetPathRoot($source) -ine [IO.Path]::GetPathRoot($spool)) { throw 'Source and spool must share a drive.' }
            if ($source -ieq $spool -or $source -ieq $archive -or $spool -ieq $archive) { throw 'Route directories must be distinct.' }
            $age = if ($route.ContainsKey('MinimumAgeSeconds')) { [int]$route.MinimumAgeSeconds } else { 20 }
            if ($age -lt 1) { throw 'MinimumAgeSeconds must be positive.' }
            foreach ($candidate in @(Get-ChildItem -LiteralPath $source -Filter '*.pdf' -File -ErrorAction Stop)) {
                if (-not (Test-NSPScanBridgeFileReady -Path $candidate.FullName -MinimumAgeSeconds $age)) { continue }
                $jobId = [guid]::NewGuid().ToString('N')
                $claimedPath = Join-Path $spool ($jobId + '.pdf')
                if ($PSCmdlet.ShouldProcess('Ready PDF', 'Claim into durable spool')) {
                    try {
                        [IO.File]::Move($candidate.FullName, $claimedPath)
                        Save-NSPScanBridgeReceipt -PdfPath $claimedPath -State Queued
                        [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'Queued' }
                    } catch [IO.IOException] {
                        Write-Warning 'A scan could not be claimed; it will be considered in the next pass.'
                    }
                }
            }
            if ($IntakeOnly -or $WhatIfPreference) { continue }
            foreach ($orphanReceipt in @(Get-ChildItem -LiteralPath $spool -Filter '*.json' -File -ErrorAction Stop)) {
                $orphanId = [IO.Path]::GetFileNameWithoutExtension($orphanReceipt.Name)
                if ($orphanId -cnotmatch '^[0-9a-f]{32}$') { continue }
                $spooledPdf = Join-Path $spool ($orphanId + '.pdf')
                $archivedPdf = Join-Path $archive ($orphanId + '.pdf')
                if (-not (Test-Path -LiteralPath $spooledPdf) -and (Test-Path -LiteralPath $archivedPdf)) {
                    try {
                        Complete-NSPScanBridgeArchive -PdfPath $spooledPdf -ArchiveDirectory $archive
                        [pscustomobject]@{ Route = $route.Name; JobId = $orphanId; State = 'ArchiveRecovered' }
                    } catch {
                        Write-Warning ("Archive recovery requires review for job {0}." -f $orphanId)
                    }
                }
            }
            foreach ($job in @(Get-ChildItem -LiteralPath $spool -Filter '*.pdf' -File -ErrorAction Stop)) {
                if ($job.Name -cnotmatch '^[0-9a-f]{32}\.pdf$') { Write-Warning 'Unknown spool entry ignored.'; continue }
                $jobId = [IO.Path]::GetFileNameWithoutExtension($job.Name)
                $receiptPath = [IO.Path]::ChangeExtension($job.FullName, '.json')
                if (-not (Test-Path -LiteralPath $receiptPath)) {
                    Save-NSPScanBridgeReceipt -PdfPath $job.FullName -State Queued
                }
                $receipt = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($receipt.State -in @('Uploading','Review')) {
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'ManualReviewRequired' }
                    continue
                }
                if ($receipt.State -eq 'Uploaded') {
                    Complete-NSPScanBridgeArchive -PdfPath $job.FullName -ArchiveDirectory $archive
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'Archived' }
                    continue
                }
                if ($receipt.State -ne 'Queued') { throw 'Unrecognized receipt state.' }
                try {
                    if ($job.Length -gt 250MB) { throw 'Configured development size limit exceeded.' }
                    Save-NSPScanBridgeReceipt -PdfPath $job.FullName -State Uploading
                    $result = Send-NSPScanBridgeUploadSession -Path $job.FullName -DriveId ([string]$route.DriveId) -FolderItemId ([string]$route.FolderItemId) -Name $job.Name
                    if (-not $result.id -or [long]$result.size -ne [long]$job.Length) {
                        throw 'Upload response failed size or item ID verification.'
                    }
                    Save-NSPScanBridgeReceipt -PdfPath $job.FullName -State Uploaded -RemoteId ([string]$result.id)
                    Complete-NSPScanBridgeArchive -PdfPath $job.FullName -ArchiveDirectory $archive
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'Delivered'; DriveItemId = [string]$result.id }
                } catch {
                    if (Test-Path -LiteralPath $job.FullName) {
                        $current = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($current.State -eq 'Uploading') {
                            Save-NSPScanBridgeReceipt -PdfPath $job.FullName -State Review
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
