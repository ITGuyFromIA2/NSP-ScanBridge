function Get-NSPScanBridgeHealth {
    <#
    .SYNOPSIS
        Reports scan queue health without disclosing PDF filenames.
    .DESCRIPTION
        Reads local source and spool directories. Never accesses Graph or changes files.
        Counts reflect a snapshot and can change during ingestion.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    $config = Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    if (-not $config.Routes) { throw 'No routes configured.' }
    foreach ($route in $config.Routes) {
        foreach ($required in 'Name','Source','Spool','Archive') {
            if (-not $route[$required]) { throw "A route is missing $required." }
        }
        $source = @(Get-ChildItem -LiteralPath $route.Source -File -Filter '*.pdf' -ErrorAction Stop)
        $pending = @(Get-ChildItem -LiteralPath $route.Spool -File -Filter '*.pdf' -ErrorAction Stop)
        $archive = @(Get-ChildItem -LiteralPath $route.Archive -File -Filter '*.pdf' -ErrorAction Stop)
        $oldest = $null
        if ($pending.Count -gt 0) {
            $oldest = ($pending | Sort-Object CreationTimeUtc | Select-Object -First 1).CreationTimeUtc
        }
        [pscustomobject]@{
            Route = [string]$route.Name
            SourceCount = $source.Count
            PendingCount = $pending.Count
            ArchivedCount = $archive.Count
            OldestPendingUtc = $oldest
            OldestPendingMinutes = if ($null -eq $oldest) { $null } else { [math]::Round(([datetime]::UtcNow - $oldest).TotalMinutes,1) }
        }
    }
}
