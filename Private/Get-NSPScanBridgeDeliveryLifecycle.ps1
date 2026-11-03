function Get-NSPScanBridgeDeliveryLifecycle {
    <#
    .SYNOPSIS
        Groups delivery-probe observations into one lifecycle per delivered file, following renames.
    .DESCRIPTION
        Pure: works on observation objects only. A watcher rename moves the lifecycle to its new
        name. Without a watcher, a temporary file that vanishes just before a PDF of the same length
        appears is merged as an inferred rename. A file recreated or shrinking at the same name
        starts a new lifecycle marked as a collision. Returns the lifecycles and, for each input
        observation, the lifecycle it belongs to (or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Observation,
        [Parameter(Mandatory)][double]$PollMilliseconds,
        [Parameter(Mandatory)][double]$QuietSeconds,
        [Parameter(Mandatory)][double]$EndMs
    )
    $all=New-Object System.Collections.Generic.List[object]
    $current=@{}; $closed=@{}
    $owners=New-Object 'object[]' $Observation.Count
    function New-Lifecycle($Path,$Ms) {
        $lifecycle=[pscustomobject]@{Key=$null;Path=$Path;Names=(New-Object System.Collections.Generic.List[string]);Samples=(New-Object System.Collections.Generic.List[object]);FirstMs=$Ms;EndStatus='Present';EndMs=$null;Rename=$null;Collision=$false}
        $lifecycle.Names.Add([IO.Path]::GetFileName($Path))
        $all.Add($lifecycle); $current[$Path.ToLowerInvariant()]=$lifecycle
        $lifecycle
    }
    for ($i=0; $i -lt $Observation.Count; $i++) {
        $o=$Observation[$i]; $path=[string]$o.Path; $key=$path.ToLowerInvariant()
        if ($o.Status -eq 'RenamedAway') { if ($current.ContainsKey($key)) { $owners[$i]=$current[$key] }; continue }
        if ($o.Source -eq 'FileSystemWatcher.Renamed' -and $o.OldPath) {
            $oldKey=([string]$o.OldPath).ToLowerInvariant()
            $moved=if($current.ContainsKey($oldKey)){$current[$oldKey]}elseif($closed.ContainsKey($oldKey) -and $closed[$oldKey].EndStatus -eq 'Missing'){$closed[$oldKey]}else{$null}
            if ($moved -and -not $moved.Rename) {
                $current.Remove($oldKey); $closed.Remove($oldKey)
                # Polling may have found the new name before the rename notification arrived.
                $early=$current[$key]
                if ($early -and $early -ne $moved) {
                    foreach ($s in $early.Samples) { $moved.Samples.Add($s) }
                    [void]$all.Remove($early)
                    for ($j=0; $j -lt $i; $j++) { if ($owners[$j] -eq $early) { $owners[$j]=$moved } }
                }
                $moved.EndStatus='Present'; $moved.EndMs=$null; $moved.Path=$path; $moved.Names.Add([IO.Path]::GetFileName($path))
                $moved.Rename=[pscustomobject]@{Method='Watcher';ElapsedMs=$o.ElapsedMs;FromExtension=[IO.Path]::GetExtension([string]$o.OldPath);ToExtension=[IO.Path]::GetExtension($path)}
                $current[$key]=$moved
            }
        }
        if ($o.Status -eq 'Present') {
            $lifecycle=$current[$key]
            if ($lifecycle -and $lifecycle.Samples.Count) {
                $last=$lifecycle.Samples[$lifecycle.Samples.Count-1]
                if ($o.Length -lt $last.Length -or $o.CreationTimeUtc -ne $last.CreationTimeUtc) {
                    $lifecycle.EndStatus='Replaced'; $lifecycle.EndMs=$o.ElapsedMs
                    $lifecycle=New-Lifecycle $path $o.ElapsedMs; $lifecycle.Collision=$true
                }
            }
            if (-not $lifecycle) { $lifecycle=New-Lifecycle $path $o.ElapsedMs }
            $lifecycle.Samples.Add([pscustomobject]@{Ms=[double]$o.ElapsedMs;Utc=$o.ObservedUtc;Extension=[IO.Path]::GetExtension($path);Length=[long]$o.Length;LastWriteTimeUtc=$o.LastWriteTimeUtc;CreationTimeUtc=$o.CreationTimeUtc;Shared=$o.SharedProbeStatus;SharedError=$o.SharedProbeError;Exclusive=$o.ProbeStatus;ExclusiveError=$o.ProbeError;Structure=$o.StructureComplete})
            $owners[$i]=$lifecycle
        } elseif ($o.Status -in @('Missing','Deleted') -and $current.ContainsKey($key)) {
            $lifecycle=$current[$key]; $current.Remove($key)
            $lifecycle.EndStatus=$o.Status; $lifecycle.EndMs=$o.ElapsedMs; $closed[$key]=$lifecycle
            $owners[$i]=$lifecycle
        }
    }
    # Polling-only rename inference: a temporary name vanishes and a PDF of the same length appears.
    $window=2*$PollMilliseconds+1000
    foreach ($pdf in @($all | Where-Object { -not $_.Rename -and $_.Samples.Count -and $_.Samples[0].Extension -ieq '.pdf' })) {
        $first=$pdf.Samples[0]
        $temp=$all | Where-Object {
            $_ -ne $pdf -and -not $_.Rename -and $_.Samples.Count -and $_.EndStatus -in @('Missing','Deleted') -and
            $_.Samples[$_.Samples.Count-1].Extension -ine '.pdf' -and $_.Samples[$_.Samples.Count-1].Length -eq $first.Length -and
            ($first.Ms-$_.Samples[$_.Samples.Count-1].Ms) -ge -$PollMilliseconds -and ($first.Ms-$_.Samples[$_.Samples.Count-1].Ms) -le $window
        } | Select-Object -First 1
        if (-not $temp) { continue }
        $pdf.Samples.InsertRange(0,$temp.Samples); $pdf.Names.InsertRange(0,$temp.Names)
        $pdf.FirstMs=$temp.FirstMs
        $pdf.Rename=[pscustomobject]@{Method='Inferred';ElapsedMs=$first.Ms;FromExtension=$temp.Samples[0].Extension;ToExtension='.pdf'}
        [void]$all.Remove($temp)
        for ($i=0; $i -lt $owners.Count; $i++) { if ($owners[$i] -eq $temp) { $owners[$i]=$pdf } }
    }
    $ordinal=0
    foreach ($lifecycle in @($all | Sort-Object FirstMs)) {
        $ordinal++; $lifecycle.Key='F'+$ordinal
        $samples=@($lifecycle.Samples | Sort-Object Ms)
        $changes=New-Object System.Collections.Generic.List[double]
        if ($samples.Count) { $changes.Add($samples[0].Ms) }
        for ($j=1; $j -lt $samples.Count; $j++) {
            if ($samples[$j].Length -ne $samples[$j-1].Length -or $samples[$j].LastWriteTimeUtc -ne $samples[$j-1].LastWriteTimeUtc) { $changes.Add($samples[$j].Ms) }
        }
        $lastChange=if($changes.Count){$changes[$changes.Count-1]}else{$lifecycle.FirstMs}
        $pause=0.0; for ($j=1; $j -lt $changes.Count; $j++) { $pause=[math]::Max($pause,$changes[$j]-$changes[$j-1]) }
        $final=if($samples.Count){$samples[$samples.Count-1]}else{$null}
        $after=@($samples | Where-Object { $_.Ms -ge $lastChange -and $_.Exclusive -eq 'Available' })
        $complete=@($after | Where-Object { $_.Structure -eq $true } | Select-Object -First 1)
        $end=if($null -ne $lifecycle.EndMs){$lifecycle.EndMs}else{$EndMs}
        $outcome=if($lifecycle.EndStatus -in @('Missing','Deleted')){'Deleted'}
            elseif($lifecycle.EndStatus -eq 'Replaced'){'Replaced'}
            elseif(-not $final -or $final.Extension -ine '.pdf'){'TempNotRenamed'}
            elseif(($end-$lastChange) -lt $QuietSeconds*1000){'StillChanging'}
            elseif(-not $after.Count){'NeverAvailable'}
            elseif($after[$after.Count-1].Structure -ne $true){'Incomplete'}
            else{'Completed'}
        $rate=$null
        if ($samples.Count -and $lastChange -gt $samples[0].Ms -and $final.Length -gt $samples[0].Length) { $rate=[math]::Round(($final.Length-$samples[0].Length)/(($lastChange-$samples[0].Ms)/1000),1) }
        $lifecycle | Add-Member -NotePropertyMembers ([ordered]@{
            LastChangeMs=$lastChange; LongestPauseMs=[math]::Round($pause,1); WriteDurationMs=[math]::Round($lastChange-$lifecycle.FirstMs,1)
            MidWrite=@($samples | Where-Object { $_.Ms -lt $lastChange }); FinalLength=if($final){$final.Length}else{0L}
            FinalExtension=if($final){$final.Extension}else{$null}; CompletedMs=if($complete.Count){$complete[0].Ms}else{$null}
            BytesPerSecond=$rate; Outcome=$outcome })
    }
    [pscustomobject]@{ Lifecycles=@($all | Sort-Object FirstMs); Owners=$owners }
}
