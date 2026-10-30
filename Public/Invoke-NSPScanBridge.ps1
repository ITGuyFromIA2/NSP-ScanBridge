function Invoke-NSPScanBridge {
    <#
    .SYNOPSIS
        Performs one unattended scan intake and SharePoint delivery pass.
    .DESCRIPTION
        All spool, archive, and source paths must exist. Source and spool must share
        a drive. Jobs receive opaque GUID filenames and are never deleted by this
        function. Requires existing app-only Graph context unless -IntakeOnly.
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
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $lockPath) -PathType Container)) { throw 'Lock directory is missing.' }
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
            foreach ($dir in @($source,$spool,$archive)) {
                if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'A route directory is missing.' }
            }
            if ([IO.Path]::GetPathRoot($source) -ine [IO.Path]::GetPathRoot($spool)) { throw 'Source and spool must share a drive.' }
            if ($source -ieq $spool -or $source -ieq $archive -or $spool -ieq $archive) { throw 'Route directories must differ.' }
            $age = if ($route.ContainsKey('MinimumAgeSeconds')) { [int]$route.MinimumAgeSeconds } else { 20 }
            if ($age -lt 1) { throw 'MinimumAgeSeconds must be positive.' }
            foreach ($candidate in @(Get-ChildItem -LiteralPath $source -Filter '*.pdf' -File)) {
                if (-not (Test-NSPScanBridgeFileReady -Path $candidate.FullName -MinimumAgeSeconds $age)) { continue }
                $jobId = [guid]::NewGuid().ToString('N')
                if ($PSCmdlet.ShouldProcess('Ready PDF', 'Claim to durable spool')) {
                    try {
                        [IO.File]::Move($candidate.FullName, (Join-Path $spool ($jobId + '.pdf')))
                        [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'Queued' }
                    } catch [IO.IOException] {
                        Write-Warning 'PDF could not be claimed; retry on next pass.'
                    }
                }
            }
            if ($IntakeOnly -or $WhatIfPreference) { continue }
            foreach ($job in @(Get-ChildItem -LiteralPath $spool -File -Filter '*.pdf')) {
                if ($job.Name -cnotmatch '^[0-9a-f]{32}\.pdf$') { Write-Warning 'Unknown spool entry ignored.'; continue }
                $jobId = [IO.Path]::GetFileNameWithoutExtension($job.Name)
                $drive = [uri]::EscapeDataString([string]$route.DriveId)
                $folder = [uri]::EscapeDataString([string]$route.FolderItemId)
                $name = [uri]::EscapeDataString($job.Name)
                $baseUri = "https://graph.microsoft.com/v1.0/drives/$drive/items/$($folder):/$name"
                try {
                    if ($job.Length -gt 250MB) { throw 'Oversized file: upload session required.' }
                    # Reject ambiguous retries, rather than accidentally replacing an existing file.
                    $remote = $null
                    try { $remote = Invoke-MgGraphRequest -Method GET -Uri ($baseUri + ':') -OutputType PSObject -ErrorAction Stop }
                    catch {
                        $status = $_.Exception.ResponseStatusCode
                        if ($null -eq $status -or [int]$status -ne 404) { throw }
                    }
                    if ($remote) { throw 'Remote file already exists; manual reconciliation required.' }
                    $result = Send-NSPScanBridgeUploadSession -Path $job.FullName -DriveId ([string]$route.DriveId) -FolderItemId ([string]$route.FolderItemId) -Name $job.Name
                    if (-not $result.id -or [long]$result.size -ne [long]$job.Length) {
                        throw 'No matching remote upload acknowledgement.'
                    }
                    $target = Join-Path $archive $job.Name
                    if (Test-Path -LiteralPath $target) { throw 'Archive conflict.' }
                    [IO.File]::Move($job.FullName, $target)
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'Delivered'; DriveItemId = [string]$result.id }
                } catch {
                    Write-Warning ("Delivery held for job {0}; inspect in protected environment." -f $jobId)
                    [pscustomobject]@{ Route = $route.Name; JobId = $jobId; State = 'PendingReviewOrRetry' }
                }
            }
        }
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}
