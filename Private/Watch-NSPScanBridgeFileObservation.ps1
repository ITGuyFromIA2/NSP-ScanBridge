function Watch-NSPScanBridgeFileObservation {
    <#
    .SYNOPSIS
        Bounded read-only file observations; independent of configuration, Graph and readiness policies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Sources,
        [ValidateRange(50,60000)][int]$PollMilliseconds=500,
        [ValidateRange(0,86400)][double]$DurationSeconds=0,
        [ValidateRange(1,100000)][int]$MaximumTrackedFiles=1000,
        [switch]$MetadataOnly,
        [switch]$PollingOnly
    )
    $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $signals=[hashtable]::Synchronized(@{Dropped=0})
    $watchers=New-Object System.Collections.Generic.List[object]
    $subscriptions=New-Object System.Collections.Generic.List[object]
    $tracked=@{}; $prefix='ScanBridgeDiagnostic.'+[guid]::NewGuid().ToString('N')
    $clock=[diagnostics.stopwatch]::StartNew()
    function Get-Observation($Source,$Path,$Label,[datetime]$ObservedUtc=[datetime]::UtcNow) {
        $record=[ordered]@{Route=$Source.Name;Path=$Path;Source=$Label;ObservedUtc=$ObservedUtc;Status='Missing';Length=0L;LastWriteTimeUtc=[datetime]::MinValue;CreationTimeUtc=[datetime]::MinValue;ProbeStatus='NotTested'}
        try {
            $item=Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($item.PSIsContainer) { return }
            $record.Status='Present'; $record.Length=$item.Length; $record.LastWriteTimeUtc=$item.LastWriteTimeUtc; $record.CreationTimeUtc=$item.CreationTimeUtc
            if (-not $MetadataOnly) {
                $stream=$null
                try { $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None); $record.ProbeStatus='Available' }
                catch { $record.ProbeStatus='Unavailable' }
                finally { if ($null -ne $stream) { $stream.Dispose() } }
            }
        } catch [System.Management.Automation.ItemNotFoundException] { }
        catch { $record.Status='Unobservable' }
        [pscustomobject]$record
    }
    try {
        if (-not $PollingOnly) {
            foreach ($source in $Sources) {
                try {
                    $watcher=New-Object IO.FileSystemWatcher
                    $watchers.Add($watcher)
                    $watcher.Path=$source.Path; $watcher.Filter='*'; $watcher.IncludeSubdirectories=$false
                    $watcher.NotifyFilter=[IO.NotifyFilters]'FileName,LastWrite,Size,CreationTime'
                    foreach ($eventName in 'Created','Changed','Renamed','Deleted','Error') {
                        $identifier=$prefix+'.'+$subscriptions.Count
                        $data=@{Queue=$queue;Signals=$signals;Limit=$MaximumTrackedFiles*4;Source=$source;Label='FileSystemWatcher.'+$eventName}
                        $job=Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $identifier -MessageData $data -Action {
                            $data=$event.MessageData
                            if ($data.Queue.Count -ge $data.Limit) { $data.Signals.Dropped++; return }
                            $path=$null; $oldPath=$null
                            if ($data.Label -ne 'FileSystemWatcher.Error') {
                                $path=$event.SourceEventArgs.FullPath
                                if ($data.Label -eq 'FileSystemWatcher.Renamed') { $oldPath=$event.SourceEventArgs.OldFullPath }
                            }
                            $data.Queue.Enqueue([pscustomobject]@{Source=$data.Source;Label=$data.Label;Path=$path;OldPath=$oldPath})
                        }
                        $subscriptions.Add([pscustomobject]@{Identifier=$identifier;Job=$job})
                    }
                    $watcher.EnableRaisingEvents=$true
                } catch { Write-Warning ('Watcher unavailable for route {0}; polling continues.' -f $source.Name) }
            }
        }
        do {
            $hint=$null
            $drained=0
            while ($drained -lt ($MaximumTrackedFiles*4) -and $queue.TryDequeue([ref]$hint)) {
                $drained++
                if ($hint.Label -eq 'FileSystemWatcher.Error') {
                    Write-Warning ('FileSystemWatcher.Error for route {0}; coverage uncertain, polling continues.' -f $hint.Source.Name)
                    continue
                }
                if ($hint.OldPath -and [IO.Path]::GetExtension($hint.OldPath) -ieq '.pdf') {
                    $old=Get-Observation $hint.Source $hint.OldPath 'FileSystemWatcher.RenamedAway'
                    if ($old) { $old.Status='RenamedAway'; $old }
                }
                if ([IO.Path]::GetExtension($hint.Path) -ine '.pdf') { continue }
                $key=[string]$hint.Source.Name+'|'+$hint.Path
                if (-not $tracked.ContainsKey($key) -and $tracked.Count -ge $MaximumTrackedFiles) { $signals.Dropped++; continue }
                if (-not $tracked.ContainsKey($key)) { $tracked[$key]=@{Source=$hint.Source;Path=$hint.Path;MissingPasses=0;Sampled=$false} }
                $record=Get-Observation $hint.Source $hint.Path $hint.Label
                if ($record) {
                    if ($hint.Label -eq 'FileSystemWatcher.Deleted') { $record.Status='Deleted' }
                    $record
                }
            }
            foreach ($source in $Sources) {
                try {
                    Get-ChildItem -LiteralPath $source.Path -Filter '*.pdf' -File -ErrorAction Stop | ForEach-Object {
                        $key=[string]$source.Name+'|'+$_.FullName
                        if (-not $tracked.ContainsKey($key)) {
                            if ($tracked.Count -lt $MaximumTrackedFiles) { $tracked[$key]=@{Source=$source;Path=$_.FullName;MissingPasses=0;Sampled=$false} }
                            else { $signals.Dropped++ }
                        }
                    }
                } catch { Write-Warning ('Polling discovery failed for route {0}; coverage uncertain.' -f $source.Name) }
            }
            # Every tracked file is sampled each cycle; no per-file waiting or retained open handle.
            foreach ($key in @($tracked.Keys)) {
                $entry=$tracked[$key]
                $label=if($entry.Sampled){'Polling.Sample'}else{'Polling.Discovery'}
                $observation=Get-Observation $entry.Source $entry.Path $label
                $entry.Sampled=$true
                if ($observation) {
                    $observation
                    if ($observation.Status -ne 'Present') { $entry.MissingPasses++ } else { $entry.MissingPasses=0 }
                }
                if ($entry.MissingPasses -ge 2) { $tracked.Remove($key) }
            }
            if ($signals.Dropped) { Write-Warning ('Diagnostic capacity/queue limit: {0} observations omitted; increase MaximumTrackedFiles or narrow routes. Polling continues.' -f $signals.Dropped); $signals.Dropped=0 }
            if ($DurationSeconds -gt 0 -and $clock.Elapsed.TotalSeconds -ge $DurationSeconds) { break }
            Start-Sleep -Milliseconds $PollMilliseconds
        } while ($true)
    } finally {
        foreach ($watcher in $watchers) { $watcher.EnableRaisingEvents=$false }
        foreach ($subscription in $subscriptions) {
            Unregister-Event -SourceIdentifier $subscription.Identifier -ErrorAction SilentlyContinue
            $subscription.Job | Remove-Job -Force -ErrorAction SilentlyContinue
            Get-Event -SourceIdentifier $subscription.Identifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        }
        foreach ($watcher in $watchers) { $watcher.Dispose() }
        $clock.Stop()
    }
}
