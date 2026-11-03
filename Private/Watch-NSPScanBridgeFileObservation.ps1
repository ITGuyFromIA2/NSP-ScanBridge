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
        [switch]$PollingOnly,
        # Delivery discovery: every file name (temporary names too), a shared-read probe, error
        # categories, PDF structure and monotonic elapsed time. Off by default.
        [switch]$AllFiles,
        [switch]$DeliveryProbe,
        [string[]]$IgnorePath
    )
    $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $signals=[hashtable]::Synchronized(@{Dropped=0})
    $watchers=New-Object System.Collections.Generic.List[object]
    $subscriptions=New-Object System.Collections.Generic.List[object]
    $tracked=@{}; $prefix='ScanBridgeDiagnostic.'+[guid]::NewGuid().ToString('N')
    $ignored=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($IgnorePath)) { if ($path) { [void]$ignored.Add([IO.Path]::GetFullPath($path)) } }
    $pattern=if($AllFiles){'*'}else{'*.pdf'}
    $clock=[diagnostics.stopwatch]::StartNew()
    function Get-ProbeError($ErrorRecord) {
        $exception=$ErrorRecord.Exception; if ($exception.InnerException) { $exception=$exception.InnerException }
        switch ($exception.HResult -band 0xFFFF) { 32 {'SharingViolation'} 33 {'LockViolation'} 5 {'AccessDenied'} 2 {'NotFound'} default {'Other'} }
    }
    function Get-Observation($Source,$Path,$Label,[datetime]$ObservedUtc=[datetime]::UtcNow,$OldPath) {
        $record=[ordered]@{Route=$Source.Name;Path=$Path;Source=$Label;ObservedUtc=$ObservedUtc;Status='Missing';Length=0L;LastWriteTimeUtc=[datetime]::MinValue;CreationTimeUtc=[datetime]::MinValue;ProbeStatus='NotTested'}
        if ($DeliveryProbe) { $record.ElapsedMs=[math]::Round($clock.Elapsed.TotalMilliseconds,3); $record.OldPath=$OldPath; $record.SharedProbeStatus='NotTested'; $record.SharedProbeError=$null; $record.ProbeError=$null; $record.StructureComplete=$null }
        try {
            $item=Get-Item -LiteralPath $Path -Force:$AllFiles -ErrorAction Stop
            if ($item.PSIsContainer) { return }
            $record.Status='Present'; $record.Length=$item.Length; $record.LastWriteTimeUtc=$item.LastWriteTimeUtc; $record.CreationTimeUtc=$item.CreationTimeUtc
            if ($DeliveryProbe) {
                # Opens that permit the writer to keep writing, and to rename or delete, while held.
                $stream=$null
                try { $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]'ReadWrite,Delete'); $record.SharedProbeStatus='Available' }
                catch { $record.SharedProbeStatus='Unavailable'; $record.SharedProbeError=Get-ProbeError $_ }
                finally { if ($null -ne $stream) { $stream.Dispose() } }
                $stream=$null
                try {
                    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Delete); $record.ProbeStatus='Available'
                    if ([IO.Path]::GetExtension($Path) -ieq '.pdf') { $record.StructureComplete=(Test-NSPScanBridgePdfStructure -Stream $stream).Complete }
                }
                catch { $record.ProbeStatus='Unavailable'; $record.ProbeError=Get-ProbeError $_ }
                finally { if ($null -ne $stream) { $stream.Dispose() } }
            } elseif (-not $MetadataOnly) {
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
                if ($hint.OldPath -and -not $ignored.Contains($hint.OldPath) -and ($AllFiles -or [IO.Path]::GetExtension($hint.OldPath) -ieq '.pdf')) {
                    $old=Get-Observation $hint.Source $hint.OldPath 'FileSystemWatcher.RenamedAway'
                    if ($old) { $old.Status='RenamedAway'; $old }
                }
                if (-not $AllFiles -and [IO.Path]::GetExtension($hint.Path) -ine '.pdf') { continue }
                if ($ignored.Contains($hint.Path)) { continue }
                $key=[string]$hint.Source.Name+'|'+$hint.Path
                if (-not $tracked.ContainsKey($key) -and $tracked.Count -ge $MaximumTrackedFiles) { $signals.Dropped++; continue }
                if (-not $tracked.ContainsKey($key)) { $tracked[$key]=@{Source=$hint.Source;Path=$hint.Path;MissingPasses=0;Sampled=$false} }
                $record=Get-Observation $hint.Source $hint.Path $hint.Label -OldPath $hint.OldPath
                if ($record) {
                    if ($hint.Label -eq 'FileSystemWatcher.Deleted') { $record.Status='Deleted' }
                    $record
                }
            }
            foreach ($source in $Sources) {
                try {
                    # All-files mode also sees hidden and system temporary names; the worker's view stays unchanged.
                    Get-ChildItem -LiteralPath $source.Path -Filter $pattern -File -Force:$AllFiles -ErrorAction Stop | ForEach-Object {
                        if ($ignored.Contains($_.FullName)) { return }
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
