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
    if (-not $config.LockPath) { throw 'LockPath is required.' }
    $lock = $null
    try {
        $lock = [IO.File]::Open([IO.Path]::GetFullPath([string]$config.LockPath), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] { throw 'ScanBridge worker or reconciler already holds the lock.' }
    try {
    $routes = @($config.Routes | Where-Object { $_.Name -eq $RouteName })
    if ($routes.Count -ne 1) { throw 'Route must match exactly one configured entry.' }
    $route = $routes[0]
    $binding = Get-NSPScanBridgeJobBinding -Route $route -Auth $config.Auth
    $pdf = Join-Path $route.Spool ($JobId + '.pdf')
    $receiptPath = [IO.Path]::ChangeExtension($pdf, '.json')
    if (-not (Test-Path -LiteralPath $pdf -PathType Leaf) -or -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'Held PDF and receipt must both exist.'
    }
    $receipt = Read-NSPScanBridgeReceipt -PdfPath $pdf -ReceiptPath $receiptPath -ExpectedBinding $binding
    if ($receipt.State -notin @('Review','Uploading')) { throw 'Job is not awaiting upload reconciliation.' }
    if ($receipt.JobId -ne $JobId -or $receipt.Hash -ne (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash) {
        throw 'Local PDF fails receipt integrity verification.'
    }
    Assert-NSPScanBridgeContext -Auth $config.Auth
    $result = Test-NSPScanBridgeRemoteMatch -PdfPath $pdf -DriveId ([string]$route.DriveId) -FolderItemId ([string]$route.FolderItemId)
    if ($result.Status -ne 'Verified') {
        return [pscustomobject]@{ JobId=$JobId; Status=$result.Status; Archived=$false }
    }
    if ($PSCmdlet.ShouldProcess($JobId,'Record verified remote copy and archive local PDF')) {
        Save-NSPScanBridgeReceipt -PdfPath $pdf -State Uploaded -RemoteId $result.RemoteId -VerifiedReconciliation -Binding $binding
        Complete-NSPScanBridgeArchive -PdfPath $pdf -ArchiveDirectory $route.Archive -ExpectedBinding $binding
        return [pscustomobject]@{ JobId=$JobId; Status='Verified'; Archived=$true }
    }
    } finally { $lock.Dispose() }
}
