function Resolve-NSPScanBridgeJob {
    <#
    .SYNOPSIS
        Verifies a held job against SharePoint before archival.
    .DESCRIPTION
        Read-back comparison uses actual remote bytes and SHA-256 rather than
        trusting filename or size. Does not retry the upload or overwrite files.
        Requires a previously established app-only Graph context.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [Parameter(Mandatory)][string]$RouteName,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$JobId
    )
    $config = Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $routes = @($config.Routes | Where-Object { $_.Name -eq $RouteName })
    if ($routes.Count -ne 1) { throw 'Route must match exactly one configured entry.' }
    $route = $routes[0]
    $pdf = Join-Path $route.Spool ($JobId + '.pdf')
    $receiptPath = [IO.Path]::ChangeExtension($pdf, '.json')
    if (-not (Test-Path -LiteralPath $pdf -PathType Leaf) -or -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'Held PDF and receipt must both exist.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($receipt.State -notin @('Review','Uploading')) { throw 'Job is not awaiting upload reconciliation.' }
    if ($receipt.State -eq 'Uploading') { throw 'Run worker first to classify interrupted Uploading state.' }
    $result = Test-NSPScanBridgeRemoteMatch -PdfPath $pdf -DriveId ([string]$route.DriveId) -FolderItemId ([string]$route.FolderItemId)
    if ($result.Status -ne 'Verified') {
        return [pscustomobject]@{ JobId=$JobId; Status=$result.Status; Archived=$false }
    }
    if ($PSCmdlet.ShouldProcess($JobId,'Record verified remote copy and archive local PDF')) {
        Save-NSPScanBridgeReceipt -PdfPath $pdf -State Uploaded -RemoteId $result.RemoteId -VerifiedReconciliation
        Complete-NSPScanBridgeArchive -PdfPath $pdf -ArchiveDirectory $route.Archive
        return [pscustomobject]@{ JobId=$JobId; Status='Verified'; Archived=$true }
    }
}
