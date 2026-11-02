function Send-NSPScanBridgeAlert {
    <#
    .SYNOPSIS
        Escalates unresolved ScanBridge health conditions to an MSP ticket mailbox.
    .DESCRIPTION
        Uses NSP.M365.Graph Send-NSPGraphMail. No PDFs, paths, patient names or
        source filenames are included. One persistent alert marker per route and
        condition set suppresses repeated tickets. An alert is only marked sent
        after Graph accepts the sendMail request. Graph acceptance is not proof
        of inbox delivery.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [ValidateRange(1,100000)][int]$MaximumPending = 25,
        [ValidateRange(1,10080)][int]$MaximumPendingMinutes = 10,
        [switch]$WorkerFailed,
        [switch]$WorkerSucceeded
    )
    if ($WorkerFailed -and $WorkerSucceeded) { throw 'Worker status flags are mutually exclusive.' }
    $config = Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    if (-not $config.Alerts -or -not $config.Alerts.Enabled) { throw 'Alerting must be explicitly enabled.' }
    $alerts = $config.Alerts
    foreach ($field in 'From','To','StateDirectory') {
        if (-not $alerts[$field]) { throw "Missing Alerts.$field." }
    }
    if ($alerts.To -notmatch '^[A-Za-z0-9.!%+_\-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
        throw 'Invalid alert recipient address.'
    }
    if (-not (Test-Path -LiteralPath $alerts.StateDirectory -PathType Container)) {
        throw 'Alert state directory must already exist.'
    }
    $warningDays = 30
    if ($alerts.ContainsKey('CertificateWarningDays')) {
        $warningDays = $alerts.CertificateWarningDays -as [int]
        if ($null -eq $warningDays -or $warningDays -lt 1 -or $warningDays -gt 365) { throw 'Alerts.CertificateWarningDays must be 1 to 365.' }
    }
    $routeNames = @($config.Routes | ForEach-Object { [string]$_.Name })
    if (@($routeNames | Where-Object { $_ -in @('System','Worker','Certificates') }).Count -gt 0 -or
        @($routeNames | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw 'Alert routes require unique names excluding the reserved System, Worker and Certificates names.'
    }
    $alertLock = $null
    try {
        $alertLock = [IO.File]::Open((Join-Path $alerts.StateDirectory 'alerts.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] { throw 'Another ScanBridge alert process holds the lock.' }
    try {
        if (-not $alerts.Auth -or -not $alerts.Auth.TenantId -or -not $alerts.Auth.ClientId -or -not $alerts.Auth.CertificateThumbprint) {
            throw 'Alerts.Auth requires a dedicated app-only mail identity.'
        }
        if (-not $WhatIfPreference) { Connect-NSPScanBridgeContext -Auth $alerts.Auth }
        $results = @()
        try {
            $results = @(Test-NSPScanBridgeHealth -ConfigurationPath $ConfigurationPath -MaximumPending $MaximumPending -MaximumPendingMinutes $MaximumPendingMinutes)
            if ($results.Count -eq 0) { throw 'No routes returned health.' }
            $results += [pscustomobject]@{ Route = 'System'; Healthy = $true; Conditions = @(); PendingCount = 0; OldestPendingMinutes = $null }
        } catch {
            # Never leak the exception message into the ticket; it may contain a private path.
            $results = @([pscustomobject]@{
                Route = 'System'
                Healthy = $false
                Conditions = @('HealthCheckFailed')
                PendingCount = -1
                OldestPendingMinutes = $null
            })
        }
        if ($WorkerFailed -or $WorkerSucceeded) {
        $results += [pscustomobject]@{
            Route = 'Worker'
            Healthy = (-not $WorkerFailed)
            Conditions = $(if ($WorkerFailed) { @('WorkerFailure') } else { @() })
            PendingCount = 0
            OldestPendingMinutes = $null
        }
        }
        # Proactive notice: the ingestion or alert certificate is near or past expiry.
        $certificateConditions = @()
        $certificateDays = $null
        try {
            foreach ($identity in @(@{ Name = 'Ingestion'; Auth = $config.Auth }, @{ Name = 'Alert'; Auth = $alerts.Auth })) {
                if (-not $identity.Auth -or -not $identity.Auth.CertificateThumbprint) { continue }
                $status = Get-NSPScanBridgeCertificateStatus -Thumbprint ([string]$identity.Auth.CertificateThumbprint) -WarningDays $warningDays -ErrorAction Stop
                if ($status.Status -ne 'Valid') { $certificateConditions += ($identity.Name + 'Certificate' + $status.Status) }
                if ($null -ne $status.DaysRemaining -and ($null -eq $certificateDays -or $status.DaysRemaining -lt $certificateDays)) {
                    $certificateDays = $status.DaysRemaining
                }
            }
        } catch {
            $certificateConditions = @('CertificateCheckFailed')
        }
        $results += [pscustomobject]@{
            Route = 'Certificates'
            Healthy = ($certificateConditions.Count -eq 0)
            Conditions = $certificateConditions
            PendingCount = 0
            OldestPendingMinutes = $null
            CertificateDaysRemaining = $certificateDays
        }
        foreach ($result in $results) {
            $routeId = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$result.Route))
            $routeId = $routeId.TrimEnd('=').Replace('+','-').Replace('/','_')
            $marker = Join-Path $alerts.StateDirectory ($routeId + '.alert.json')
            if ($result.Healthy) {
                if (Test-Path -LiteralPath $marker -PathType Leaf) {
                    $prior = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($prior.Active -ne $false -and $PSCmdlet.ShouldProcess('Alert marker', 'Record recovered health')) {
                        $prior | Add-Member -NotePropertyName Active -NotePropertyValue $false -Force
                        $prior | Add-Member -NotePropertyName ResolvedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                        $resolvedTemp = $marker + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
                        try {
                            [IO.File]::WriteAllText($resolvedTemp, ($prior | ConvertTo-Json -Depth 5))
                            [IO.File]::Replace($resolvedTemp, $marker, [NullString]::Value)
                        } finally {
                            if (Test-Path -LiteralPath $resolvedTemp) { Remove-Item -LiteralPath $resolvedTemp -Force }
                        }
                    }
                }
                continue
            }
            $conditions = @($result.Conditions | Sort-Object -Unique)
            $signature = $conditions -join ','
            $existing = $null
            if (Test-Path -LiteralPath $marker -PathType Leaf) {
                $existing = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
            if ($existing -and $existing.Active -ne $false -and $existing.Signature -eq $signature) { continue }
            if ($result.Route -eq 'Certificates') {
                $subject = '[NSP.ScanBridge] Certificate renewal required'
                $body = @(
                    'A ScanBridge app-only certificate is missing, expired or near expiry.'
                    ('Condition codes: {0}' -f $signature)
                    ('Fewest days remaining: {0}' -f $result.CertificateDaysRemaining)
                    'Renew the certificate on the ScanBridge host and update the app registration and settings.'
                    'No document content or filenames are included.'
                ) -join [Environment]::NewLine
            } else {
                $subject = '[NSP.ScanBridge] Manual intervention required'
                $body = @(
                    'ScanBridge detected an unresolved delivery condition.'
                    ('Route: {0}' -f $result.Route)
                    ('Condition codes: {0}' -f $signature)
                    ('Pending documents: {0}' -f $result.PendingCount)
                    ('Oldest pending (minutes): {0}' -f $result.OldestPendingMinutes)
                    'Investigate the restricted local queue and receipts.'
                    'No document content or filenames are included.'
                ) -join [Environment]::NewLine
            }
            if ($PSCmdlet.ShouldProcess($alerts.To, 'Send ScanBridge ticket escalation')) {
                Send-NSPGraphMail -From $alerts.From -To @($alerts.To) -Subject $subject -Body $body -ErrorAction Stop
                $temp = $marker + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
                $json = @{ Signature = $signature; Active = $true; SentUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
                try {
                    [IO.File]::WriteAllText($temp, $json)
                    if (Test-Path -LiteralPath $marker) {
                        [IO.File]::Replace($temp, $marker, [NullString]::Value)
                    } else {
                        [IO.File]::Move($temp, $marker)
                    }
                } finally {
                    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
                }
                [pscustomobject]@{ Route = $result.Route; Conditions = $signature; AlertSubmitted = $true }
            }
        }
    } finally { $alertLock.Dispose() }
}
