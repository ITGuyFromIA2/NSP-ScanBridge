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
        [ValidateRange(1,10080)][int]$MaximumPendingMinutes = 10
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
    foreach ($result in @(Test-NSPScanBridgeHealth -ConfigurationPath $ConfigurationPath -MaximumPending $MaximumPending -MaximumPendingMinutes $MaximumPendingMinutes)) {
        $routeId = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$result.Route))
        $routeId = $routeId.TrimEnd('=').Replace('+','-').Replace('/','_')
        $marker = Join-Path $alerts.StateDirectory ($routeId + '.alert.json')
        if ($result.Healthy) {
            # Preserve historical marker for human review; do not automatically
            # delete it and create repeated tickets if the condition flaps.
            continue
        }
        $conditions = @($result.Conditions | Sort-Object -Unique)
        $signature = $conditions -join ','
        $existing = $null
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $existing = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        if ($existing -and $existing.Signature -eq $signature) { continue }
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
            $json = @{ Signature = $signature; SentUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
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
