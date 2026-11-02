function Get-NSPScanBridgeReadinessDecision {
    [CmdletBinding()]
    param(
        [ValidateSet('AgeAndExclusive','StableWindow','StrictQuiet')][string]$Mode='AgeAndExclusive',
        [long]$Length,
        [datetime]$LastWriteTimeUtc=[datetime]::MinValue,
        [datetime]$NowUtc=[datetime]::UtcNow,
        [bool]$IsPdf=$true,
        [bool]$IsContainer=$false,
        [bool]$Exists=$true,
        [double]$MinimumAgeSeconds=15,
        [double]$QuietSeconds=0,
        [int]$StableSamples=0,
        [double]$RequiredQuietSeconds=5,
        [int]$RequiredSamples=3,
        [ValidateSet('Available','Unavailable','NotTested')][string]$ProbeStatus='NotTested'
    )
    $reasons=New-Object System.Collections.Generic.List[string]
    if (-not $Exists) { $reasons.Add('MissingOrUnobservable') }
    if (-not $IsPdf -or $IsContainer) { $reasons.Add('NotPdf') }
    if ($Length -le 0) { $reasons.Add('Empty') }
    $age=($NowUtc-$LastWriteTimeUtc).TotalSeconds
    if ($Mode -eq 'AgeAndExclusive') {
        if ($age -lt $MinimumAgeSeconds) { $reasons.Add('MinimumAge') }
    } else {
        if ($QuietSeconds -lt $RequiredQuietSeconds) { $reasons.Add('QuietWindow') }
        if ($StableSamples -lt $RequiredSamples) { $reasons.Add('SampleCount') }
    }
    $metadataEligible=$reasons.Count -eq 0
    if ($ProbeStatus -ne 'Available') { $reasons.Add($(if($ProbeStatus -eq 'NotTested'){'LockNotTested'}else{'ExclusiveProbeFailed'})) }
    [pscustomobject]@{ Mode=$Mode; Ready=($reasons.Count -eq 0); MetadataEligible=$metadataEligible; Reasons=@($reasons); AgeSeconds=$age }
}
