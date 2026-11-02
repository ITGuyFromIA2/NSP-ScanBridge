function Assert-NSPScanBridgeContext {
    <#
    .SYNOPSIS
        Validates an existing ScanBridge identity and Process scope without connecting.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Auth)
    foreach ($field in 'TenantId','ClientId','CertificateThumbprint') {
        if ([string]::IsNullOrWhiteSpace([string]$Auth[$field])) { throw 'Complete expected app-only identity configuration is required.' }
    }
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context -or [string]$context.AuthType -ne 'AppOnly' -or
        [string]$context.TenantId -ne [string]$Auth.TenantId -or
        [string]$context.ClientId -ne [string]$Auth.ClientId -or
        [string]$context.ContextScope -ne 'Process') {
        throw 'Graph context does not match the configured app-only identity and required Process scope.'
    }
}
