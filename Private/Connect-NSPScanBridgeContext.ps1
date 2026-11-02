function Connect-NSPScanBridgeContext {
    <#
    .SYNOPSIS
        Selects the shared connector and establishes ScanBridge's process-scoped app context.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Auth)
    foreach ($field in 'TenantId','ClientId','CertificateThumbprint') {
        if ([string]::IsNullOrWhiteSpace([string]$Auth[$field])) { throw 'Complete expected app-only identity configuration is required.' }
    }
    # Resolve inside ScanBridge's module scope; a global source import is not sufficient.
    # MinimumVersion skips an older copy earlier on PSModulePath instead of loading the first found.
    $modules = @(Import-Module NSP.M365.Graph -MinimumVersion 0.1.2 -PassThru -ErrorAction Stop | Where-Object Name -eq 'NSP.M365.Graph')
    if ($modules.Count -ne 1) { throw 'ScanBridge requires one resolved NSP.M365.Graph module.' }
    $connector = $modules[0].ExportedCommands['Connect-NSPGraphAppOnly']
    if (-not $connector -or -not $connector.Parameters.ContainsKey('ContextScope')) {
        throw 'ScanBridge requires an approved NSP.M365.Graph connector supporting ContextScope. Provision that dependency before running the worker.'
    }
    # Invoke the command belonging to the selected module, rather than a global namesake.
    & $connector -TenantId $Auth.TenantId -ClientId $Auth.ClientId -CertificateThumbprint $Auth.CertificateThumbprint -ContextScope Process -ErrorAction Stop | Out-Null
    Assert-NSPScanBridgeContext -Auth $Auth
}
