function Assert-NSPScanBridgeJobBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Binding, [System.Collections.IDictionary]$ExpectedBinding)
    if ($Binding -isnot [System.Collections.IDictionary] -and $Binding -isnot [pscustomobject]) { throw 'Job destination binding is invalid.' }
    foreach ($field in 'RouteName','TenantId','ClientId','DriveId','FolderItemId') {
        if ($Binding.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Binding.$field)) { throw 'Job destination binding is incomplete.' }
        if ($null -ne $ExpectedBinding -and [string]$Binding.$field -cne [string]$ExpectedBinding[$field]) {
            throw 'Job destination binding differs from configuration; preserve the job for review.'
        }
    }
}