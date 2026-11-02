function Update-NSPScanBridgeReadinessObservation {
    [CmdletBinding()]
    param($Previous,[Parameter(Mandatory)]$Observation)
    $now=$Observation.ObservedUtc
    $present=$Observation.Status -eq 'Present'
    $generationChanged=$null -eq $Previous -or ($present -and (-not $Previous.Exists -or $Previous.CreationTimeUtc -ne $Observation.CreationTimeUtc)) -or
        $Observation.Source -in @('FileSystemWatcher.Created','FileSystemWatcher.Renamed')
    if ($generationChanged) {
        $previousDecision=if($Previous){$Previous.FirstDecisions}else{@{}}
        $state=@{ Generation=[guid]::NewGuid().ToString('N'); FirstObservedUtc=$now; LastChangedUtc=$now; Samples=0; FirstDecisions=@{}; CurrentDecisions=@{}; LastPrintedUtc=[datetime]::MinValue; Signature=''; PriorGenerationDecisions=$previousDecision }
    } else { $state=$Previous }
    $sizeChanged=$present -and -not $generationChanged -and $state.Length -ne $Observation.Length
    $modifiedChanged=$present -and -not $generationChanged -and $state.LastWriteTimeUtc -ne $Observation.LastWriteTimeUtc
    $hint=$Observation.Source -eq 'FileSystemWatcher.Changed'
    $reset=$generationChanged -or $sizeChanged -or $modifiedChanged -or $hint -or -not $present
    if ($reset) { $state.LastChangedUtc=$now; $state.Samples=0 }
    # Only periodic metadata samples count toward stability, not duplicate event notifications.
    if ($present -and $Observation.Source -like 'Polling.*') { $state.Samples++ }
    $state.Exists=$present
    $state.CreationTimeUtc=$Observation.CreationTimeUtc
    $state.Length=$Observation.Length
    $state.LastWriteTimeUtc=$Observation.LastWriteTimeUtc
    $state.LastObservedUtc=$now
    $state.QuietSeconds=[math]::Max([double]0,($now-$state.LastChangedUtc).TotalSeconds)
    $state.SizeChanged=$sizeChanged; $state.ModifiedChanged=$modifiedChanged
    $state.Reset=$reset; $state.GenerationChanged=$generationChanged
    $state
}
