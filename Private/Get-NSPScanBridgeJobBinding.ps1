function Get-NSPScanBridgeJobBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Route, [System.Collections.IDictionary]$Auth)
    $binding = @{
        RouteName = [string]$Route.Name
        TenantId = [string]$Auth.TenantId
        ClientId = [string]$Auth.ClientId
        DriveId = [string]$Route.DriveId
        FolderItemId = [string]$Route.FolderItemId
    }
    Assert-NSPScanBridgeJobBinding -Binding $binding
    $binding
}