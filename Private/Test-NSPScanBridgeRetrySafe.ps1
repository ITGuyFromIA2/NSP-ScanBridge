function Test-NSPScanBridgeRetrySafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('BeforeSession','SessionCreated','Uploading','Unknown')][string]$Phase,
        [ValidateRange(0,599)][int]$StatusCode = 0
    )
    # Once the remote session could exist, the result is ambiguous.
    # Do not automatically replay an upload on an uncertain outcome.
    if ($Phase -ne 'BeforeSession') { return $false }
    return ($StatusCode -in @(408,429,500,502,503,504))
}
