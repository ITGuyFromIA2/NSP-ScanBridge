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
        [switch]$WorkerFailed
    )
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
    Import-Module NSP.M365.Graph -ErrorAction Stop
    if (-not $alerts.Auth -or -not $alerts.Auth.TenantId -or -not $alerts.Auth.ClientId -or -not $alerts.Auth.CertificateThumbprint) {
        throw 'Alerts.Auth requires a dedicated app-only mail identity.'
    }
    Connect-NSPGraphAppOnly -TenantId $alerts.Auth.TenantId -ClientId $alerts.Auth.ClientId -CertificateThumbprint $alerts.Auth.CertificateThumbprint | Out-Null
    $results = @()
    try {
        $results = @(Test-NSPScanBridgeHealth -ConfigurationPath $ConfigurationPath -MaximumPending $MaximumPending -MaximumPendingMinutes $MaximumPendingMinutes)
        if ($results.Count -eq 0) { throw 'No routes returned health.' }
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
    $results += [pscustomobject]@{
        Route = 'Worker'
        Healthy = (-not $WorkerFailed)
        Conditions = if ($WorkerFailed) { @('WorkerFailure') } else { @() }
        PendingCount = 0
        OldestPendingMinutes = $null
    }
    foreach ($result in $results) {
        $routeId = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$result.Route))
        $routeId = $routeId.TrimEnd('=').Replace('+','-').Replace('/','_')
        $marker = Join-Path $alerts.StateDirectory ($routeId + '.alert.json')
        if ($result.Healthy) {
            if (Test-Path -LiteralPath $marker -PathType Leaf) {
                $prior = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($prior.Active -ne $false) {
                    $prior | Add-Member -NotePropertyName Active -NotePropertyValue $false -Force
                    $prior | Add-Member -NotePropertyName ResolvedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                    $resolvedTemp = $marker + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
                    try {
                        [IO.File]::WriteAllText($resolvedTemp, ($prior | ConvertTo-Json -Depth 5))
                        [IO.File]::Replace($resolvedTemp, $marker, $null)
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
        if ($PSCmdlet.ShouldProcess($alerts.To, 'Send ScanBridge ticket escalation')) {
            Send-NSPGraphMail -From $alerts.From -To @($alerts.To) -Subject $subject -Body $body -ErrorAction Stop
            $temp = $marker + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            $json = @{ Signature = $signature; Active = $true; SentUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
            try {
                [IO.File]::WriteAllText($temp, $json)
                if (Test-Path -LiteralPath $marker) {
                    [IO.File]::Replace($temp, $marker, $null)
                } else {
                    [IO.File]::Move($temp, $marker)
                }
            } finally {
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
            }
            [pscustomobject]@{ Route = $result.Route; Conditions = $signature; AlertSubmitted = $true }
        }
    }
}
