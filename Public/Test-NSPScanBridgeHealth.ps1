function Test-NSPScanBridgeHealth {
    <#
    .SYNOPSIS
        Generates alert conditions from queue health without displaying filenames.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [ValidateRange(1,100000)][int]$MaximumPending = 25,
        [ValidateRange(1,10080)][int]$MaximumPendingMinutes = 10
    )
    foreach ($health in @(Get-NSPScanBridgeHealth -ConfigurationPath $ConfigurationPath)) {
        $issues = @()
        if ($health.PendingCount -ge $MaximumPending) { $issues += 'QueueDepth' }
        if ($null -ne $health.OldestPendingMinutes -and $health.OldestPendingMinutes -ge $MaximumPendingMinutes) { $issues += 'QueueAge' }
        if ($health.ReviewCount -gt 0) { $issues += 'ManualReview' }
        if ($health.UploadingCount -gt 0) { $issues += 'IncompleteUpload' }
        if ($health.InvalidReceiptCount -gt 0 -or $health.MissingReceiptCount -gt 0 -or $health.OrphanReceiptCount -gt 0) {
            $issues += 'ReceiptAnomaly'
        }
        [pscustomobject]@{
            Route = $health.Route
            Healthy = ($issues.Count -eq 0)
            Conditions = @($issues)
            PendingCount = $health.PendingCount
            OldestPendingMinutes = $health.OldestPendingMinutes
        }
    }
}
