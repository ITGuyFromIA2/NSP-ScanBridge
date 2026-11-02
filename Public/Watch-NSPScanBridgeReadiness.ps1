function Watch-NSPScanBridgeReadiness {
    <#
    .SYNOPSIS
        Observes source PDFs and compares diagnostic readiness policies without processing files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [string[]]$RouteName,
        [ValidateSet('AgeAndExclusive','StableWindow','StrictQuiet')][string[]]$Mode=@('AgeAndExclusive','StableWindow','StrictQuiet'),
        [ValidateRange(0.1,3600)][double]$StableQuietSeconds=5,
        [ValidateRange(2,1000)][int]$StableSamples=3,
        [ValidateRange(0.1,7200)][double]$StrictQuietSeconds=30,
        [ValidateRange(2,1000)][int]$StrictSamples=5,
        [ValidateRange(50,60000)][int]$PollMilliseconds=500,
        [ValidateRange(1,3600)][double]$HeartbeatSeconds=5,
        [ValidateRange(0,86400)][double]$DurationSeconds=0,
        [ValidateRange(1,100000)][int]$MaximumTrackedFiles=1000,
        [switch]$MetadataOnly,
        [switch]$PollingOnly,
        [switch]$PassThru
    )
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    if (-not $config.Routes) { throw 'Configuration requires Routes.' }
    if ($StrictQuietSeconds -lt $StableQuietSeconds -or $StrictSamples -lt $StableSamples) { throw 'StrictQuiet thresholds must be at least StableWindow thresholds.' }
    $sources=New-Object System.Collections.Generic.List[object]; $names=@{}
    foreach ($route in $config.Routes) {
        if ($route -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$route.Name)) { throw 'Every route requires a name.' }
        if ($names.ContainsKey([string]$route.Name)) { throw 'Route names must be unique.' }
        $names[[string]$route.Name]=$true
        if ($RouteName -and $route.Name -notin $RouteName) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$route.Source)) { throw 'Selected route requires Source.' }
        $path=[IO.Path]::GetFullPath([string]$route.Source)
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Selected route source directory does not exist.' }
        $age=if($route.ContainsKey('MinimumAgeSeconds')){[int]$route.MinimumAgeSeconds}else{20}
        if ($age -lt 1 -or $age -gt 3600) { throw 'MinimumAgeSeconds must be between 1 and 3600.' }
        $sources.Add([pscustomobject]@{Name=[string]$route.Name;Path=$path;MinimumAgeSeconds=$age})
    }
    if ($RouteName -and @($RouteName | Where-Object {-not $names.ContainsKey($_)}).Count) { throw 'Requested route not found.' }
    if (-not $sources.Count) { throw 'No selected routes.' }
    $modes=@($Mode | Select-Object -Unique)
    Write-Host 'Read-only diagnostic; no claims, receipts, authentication, uploads, mail or task changes. Ctrl+C stops observation.'
    Write-Host ('StableWindow diagnostic-only: quiet>={0}s samples>={1}; StrictQuiet diagnostic-only: quiet>={2}s samples>={3}; polling={4}ms heartbeat={5}s; selected={6}' -f $StableQuietSeconds,$StableSamples,$StrictQuietSeconds,$StrictSamples,$PollMilliseconds,$HeartbeatSeconds,($modes -join ','))
    foreach ($source in $sources) { Write-Host ('Route {0}: AgeAndExclusive baseline age>={1}s, nonempty PDF and exclusive-open observation.' -f $source.Name,$source.MinimumAgeSeconds) }
    if ($MetadataOnly) { Write-Host 'Metadata-only: lock NOT TESTED. Metadata eligibility is shown; WOULD PROCEED requires a tested successful probe.' }
    else { Write-Host 'Exclusive probes close immediately. A failed probe is not proof of a writer lock; even a successful probe may briefly interfere with a writer reopening. Quiet is a heuristic, not completion.' }
    Write-Host 'Sources are FileSystemWatcher notifications and polling, not Sysmon events. Local console/PassThru filenames may be sensitive; no log file is created.'
    $states=@{}; $ages=@{}; foreach($source in $sources){$ages[$source.Name]=$source.MinimumAgeSeconds}
    Watch-NSPScanBridgeFileObservation -Sources @($sources.ToArray()) -PollMilliseconds $PollMilliseconds -DurationSeconds $DurationSeconds -MaximumTrackedFiles $MaximumTrackedFiles -MetadataOnly:$MetadataOnly -PollingOnly:$PollingOnly | ForEach-Object {
        $observation=$_
        $key=[string]$observation.Route+'|'+$observation.Path
        $previous=$states[$key]
        if (-not $previous -and $states.Count -ge $MaximumTrackedFiles) {
            $oldest=$states.Keys | Sort-Object { $states[$_].LastObservedUtc } | Select-Object -First 1
            $states.Remove($oldest)
            Write-Warning 'Diagnostic state evicted at capacity; a later observation starts a new lifecycle.'
        }
        $previousCurrent=if($previous){$previous.CurrentDecisions.Clone()}else{@{}}
        $previousFirst=if($previous){$previous.FirstDecisions.Clone()}else{@{}}
        $state=Update-NSPScanBridgeReadinessObservation -Previous $previous -Observation $observation
        $states[$key]=$state
        $decisions=New-Object System.Collections.Generic.List[object]
        $revoked=New-Object System.Collections.Generic.List[string]
        foreach ($selected in $modes) {
            $quiet=if($selected -eq 'StrictQuiet'){$StrictQuietSeconds}else{$StableQuietSeconds}
            $samples=if($selected -eq 'StrictQuiet'){$StrictSamples}else{$StableSamples}
            $decision=Get-NSPScanBridgeReadinessDecision -Mode $selected -Length $observation.Length -LastWriteTimeUtc $observation.LastWriteTimeUtc -NowUtc $observation.ObservedUtc -Exists $state.Exists -MinimumAgeSeconds $ages[$observation.Route] -QuietSeconds $state.QuietSeconds -StableSamples $state.Samples -RequiredQuietSeconds $quiet -RequiredSamples $samples -ProbeStatus $observation.ProbeStatus
            if ($previousCurrent[$selected] -and ($state.Reset -or -not $decision.Ready)) {
                $interval=($observation.ObservedUtc-$previousFirst[$selected]).TotalSeconds
                $revoked.Add(('{0}:REVOKED observation {1:N2}s after first decision' -f $selected,$interval))
            }
            if ($decision.Ready -and -not $state.FirstDecisions.ContainsKey($selected)) { $state.FirstDecisions[$selected]=$observation.ObservedUtc }
            $state.CurrentDecisions[$selected]=$decision.Ready
            $first=if($state.FirstDecisions.ContainsKey($selected)){$state.FirstDecisions[$selected]}else{$null}
            $decisions.Add([pscustomobject]@{Mode=$selected;State=$(if($decision.Ready){'WOULD PROCEED'}else{'HOLD'});Reasons=$decision.Reasons;MetadataEligible=$decision.MetadataEligible;FirstDecisionUtc=$first})
        }
        $signature=$observation.Status+'|'+$observation.ProbeStatus+'|'+$state.Generation+'|'+(($decisions | ForEach-Object {$_.Mode+':'+$_.State+':'+($_.Reasons -join ',')}) -join '|')
        $print=$signature -ne $state.Signature -or $state.Reset -or $revoked.Count -gt 0 -or ($observation.ObservedUtc-$state.LastPrintedUtc).TotalSeconds -ge $HeartbeatSeconds
        if ($print) {
            $file=[IO.Path]::GetFileName($observation.Path) -replace '\p{Cc}','?'
            $summary=($decisions | ForEach-Object { $_.Mode+'='+$_.State+'('+($_.Reasons -join ',')+';metadataEligible='+$_.MetadataEligible+')' }) -join ' '
            Write-Host ('{0:HH:mm:ss.fff} {1} {2} [{3}] status={4} elapsed={5:N2}s size={6} modifiedUtc={7:o} sizeChanged={8} modifiedChanged={9} quiet={10:N2}s samples={11} lock={12} {13} {14}' -f $observation.ObservedUtc.ToLocalTime(),$observation.Route,$file,$observation.Source,$observation.Status,($observation.ObservedUtc-$state.FirstObservedUtc).TotalSeconds,$observation.Length,$observation.LastWriteTimeUtc,$state.SizeChanged,$state.ModifiedChanged,$state.QuietSeconds,$state.Samples,$observation.ProbeStatus,$summary,($revoked -join '; '))
            $state.LastPrintedUtc=$observation.ObservedUtc; $state.Signature=$signature
        }
        if ($PassThru) {
            [pscustomobject]@{ObservedUtc=$observation.ObservedUtc;Route=$observation.Route;Path=$observation.Path;Source=$observation.Source;Status=$observation.Status;Generation=$state.Generation;Length=$observation.Length;LastWriteTimeUtc=$observation.LastWriteTimeUtc;SizeChanged=$state.SizeChanged;ModifiedChanged=$state.ModifiedChanged;QuietSeconds=$state.QuietSeconds;Samples=$state.Samples;ProbeStatus=$observation.ProbeStatus;Decisions=@($decisions.ToArray());Revoked=@($revoked.ToArray())}
        }
    }
}
