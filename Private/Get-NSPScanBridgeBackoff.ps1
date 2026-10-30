function Get-NSPScanBridgeBackoff {
    [CmdletBinding()]
    param(
        [ValidateRange(1,20)][int]$Attempt = 1,
        [ValidateRange(1,3600)][int]$BaseSeconds = 15,
        [ValidateRange(1,86400)][int]$MaxSeconds = 1800
    )
    [int][math]::Min($MaxSeconds, ($BaseSeconds * [math]::Pow(2, [math]::Min(15,$Attempt - 1))))
}
