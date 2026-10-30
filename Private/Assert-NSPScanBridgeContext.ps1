function Assert-NSPScanBridgeContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Auth, [switch]$Connect)
    foreach ($field in 'TenantId','ClientId','CertificateThumbprint') {
        if ([string]::IsNullOrWhiteSpace([string]$Auth[$field])) { throw 'Complete expected app-only identity configuration is required.' }
    }
    if ($Connect) {
        Connect-NSPGraphAppOnly -TenantId $Auth.TenantId -ClientId $Auth.ClientId -CertificateThumbprint $Auth.CertificateThumbprint -ErrorAction Stop | Out-Null
    }
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context -or [string]$context.AuthType -ne 'AppOnly' -or
        [string]$context.TenantId -ne [string]$Auth.TenantId -or
        [string]$context.ClientId -ne [string]$Auth.ClientId) {
        throw 'Graph context does not match the configured app-only identity.'
    }
}