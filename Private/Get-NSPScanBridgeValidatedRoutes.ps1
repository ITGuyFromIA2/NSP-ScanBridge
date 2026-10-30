function Get-NSPScanBridgeValidatedRoutes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Routes)
    $validated = New-Object System.Collections.Generic.List[object]
    $directories = New-Object System.Collections.Generic.List[string]
    $routeNames = @{}
    foreach ($route in $Routes) {
        if ($route -isnot [System.Collections.IDictionary]) { throw 'Each route must be a configuration dictionary.' }
        foreach ($field in 'Name','Source','Spool','Archive','DriveId','FolderItemId') {
            if ([string]::IsNullOrWhiteSpace([string]$route[$field])) { throw "A route is missing $field." }
        }
        $name = [string]$route.Name
        if ($routeNames.ContainsKey($name)) { throw 'Route names must be unique.' }
        $routeNames[$name] = $true
        $prepared = @{}
        foreach ($key in $route.Keys) { $prepared[$key]=$route[$key] }
        foreach ($field in 'Source','Spool','Archive') {
            $directory = [IO.Path]::GetFullPath([string]$route[$field]).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Route directory does not exist.' }
            foreach ($used in $directories) {
                # Compare every directory across the entire route set. Trailing
                # separators keep sibling names distinct while detecting nesting.
                if ($directory.StartsWith($used,[StringComparison]::OrdinalIgnoreCase) -or
                    $used.StartsWith($directory,[StringComparison]::OrdinalIgnoreCase)) {
                    throw 'All route directories must be distinct and must not overlap.'
                }
            }
            [void]$directories.Add($directory)
            $prepared[$field]=$directory
        }
        if ([IO.Path]::GetPathRoot($prepared.Source) -ine [IO.Path]::GetPathRoot($prepared.Spool)) { throw 'Source and spool must share a drive.' }
        $age = if ($prepared.ContainsKey('MinimumAgeSeconds')) { [int]$prepared.MinimumAgeSeconds } else { 20 }
        if ($age -lt 1 -or $age -gt 3600) { throw 'MinimumAgeSeconds must be between 1 and 3600.' }
        $prepared.MinimumAgeSeconds=$age
        [void]$validated.Add($prepared)
    }
    $validated.ToArray()
}