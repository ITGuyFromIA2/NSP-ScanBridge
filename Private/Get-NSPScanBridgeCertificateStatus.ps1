function Get-NSPScanBridgeCertificateStatus {
    <#
    .SYNOPSIS
        Reports remaining validity of an app-only certificate without exposing its identity.
    .DESCRIPTION
        Self-contained: reads only the local certificate stores and uses no ScanBridge state,
        so it can move to a shared module. Looks in Cert:\LocalMachine\My, then
        Cert:\CurrentUser\My. Returns Valid, Expiring (within WarningDays), Expired or Missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{40}$')][string]$Thumbprint,
        [ValidateRange(1,365)][int]$WarningDays = 30,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )
    $certificate = $null
    foreach ($store in 'Cert:\LocalMachine\My','Cert:\CurrentUser\My') {
        $certificate = Get-Item -LiteralPath (Join-Path $store $Thumbprint) -ErrorAction SilentlyContinue
        if ($certificate) { break }
    }
    if (-not $certificate) { return [pscustomobject]@{ Status = 'Missing'; DaysRemaining = $null } }
    $remaining = $certificate.NotAfter.ToUniversalTime() - $NowUtc
    $status = if ($remaining.Ticks -le 0) { 'Expired' } elseif ($remaining.TotalDays -le $WarningDays) { 'Expiring' } else { 'Valid' }
    [pscustomobject]@{ Status = $status; DaysRemaining = [int][math]::Floor($remaining.TotalDays) }
}
