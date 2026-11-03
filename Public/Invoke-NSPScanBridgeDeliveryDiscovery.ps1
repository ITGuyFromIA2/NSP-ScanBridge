function Invoke-NSPScanBridgeDeliveryDiscovery {
    <#
    .SYNOPSIS
        Observes how a scanner delivers test scans to a dedicated folder and saves a delivery profile.
    .DESCRIPTION
        Read-only: never moves, changes, claims or uploads files, and makes no network call. Files
        already in the folder are ignored. Every new file name is tracked, including temporary
        names, with watcher events, size/modified polling, a shared-read probe, an exclusive probe,
        Win32 error categories and the PDF structure check. Writes an events CSV and a timestamped
        profile JSON with classification, confidence, evidence, a conservative policy
        recommendation and simulator replay settings. -IncludeFileNames also writes a
        Filename,Event,Utc timing CSV for Compare-MfpScanTiming.ps1; without it, files are F1, F2...
    .EXAMPLE
        Invoke-NSPScanBridgeDeliveryDiscovery -Path 'C:\ScanTest' -DeviceName 'Front copier' -DurationSeconds 180
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(5,3600)][double]$DurationSeconds=120,
        [ValidateRange(50,5000)][int]$PollMilliseconds=250,
        [ValidateRange(1,600)][double]$QuietSeconds=10,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$')][string]$DeviceName='Scanner',
        [string]$OutputDirectory,
        [ValidateRange(1,10000)][int]$MaximumTrackedFiles=200,
        [switch]$IncludeFileNames,
        [switch]$PollingOnly
    )
    $folder=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw 'Discovery folder does not exist.' }
    if (-not $OutputDirectory) {
        $base=if($env:LOCALAPPDATA){$env:LOCALAPPDATA}else{[IO.Path]::GetTempPath()}
        $OutputDirectory=Join-Path $base 'NSP\ScanBridge\Discovery'
    }
    $output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
    foreach ($pair in @(@($output,$folder),@($folder,$output))) {
        if ($pair[0] -ieq $pair[1] -or $pair[0].StartsWith($pair[1]+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'The output directory and the discovery folder must not contain each other.' }
    }
    [void][IO.Directory]::CreateDirectory($output)
    $existing=@(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop | ForEach-Object FullName)
    $session=[guid]::NewGuid().ToString('N')
    Write-Host 'Read-only delivery discovery: nothing is moved, changed, claimed or uploaded. Ctrl+C stops early and still saves results.'
    Write-Host 'Use a dedicated test folder, not a live route Source while the ScanBridge task is enabled. Probes briefly open each new file.'
    Write-Host ('Watching for {0}s, sampling every {1} ms; {2} existing file(s) ignored. Send the test scans now.' -f $DurationSeconds,$PollMilliseconds,$existing.Count)
    $observations=New-Object System.Collections.Generic.List[object]
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $start=[datetime]::UtcNow; $finished=$false
    try {
        Watch-NSPScanBridgeFileObservation -Sources @([pscustomobject]@{Name='Discovery';Path=$folder}) -PollMilliseconds $PollMilliseconds -DurationSeconds $DurationSeconds -MaximumTrackedFiles $MaximumTrackedFiles -PollingOnly:$PollingOnly -AllFiles -DeliveryProbe -IgnorePath $existing | ForEach-Object {
            $observations.Add($_)
            if ($_.Status -eq 'Present' -and $seen.Add($_.Path)) {
                $label=if($IncludeFileNames){[IO.Path]::GetFileName($_.Path) -replace '\p{Cc}','?'}else{'file with extension '+[IO.Path]::GetExtension($_.Path)}
                Write-Host ('{0,8:N1}s  new {1}' -f ($_.ElapsedMs/1000),$label)
            }
        }
        $finished=$true
    } finally {
        $end=[datetime]::UtcNow
        # The observer's stopwatch starts after $start; anchor elapsed times to its actual UTC zero.
        $epoch=$start
        if ($observations.Count) {
            $zeros=@($observations | ForEach-Object { $_.ObservedUtc.AddMilliseconds(-[double]$_.ElapsedMs).Ticks } | Sort-Object)
            $epoch=New-Object DateTime ([long]$zeros[[int][math]::Floor(($zeros.Count-1)/2)]),([DateTimeKind]::Utc)
        }
        $endMs=($end-$epoch).TotalMilliseconds
        $built=Get-NSPScanBridgeDeliveryLifecycle -Observation @($observations.ToArray()) -PollMilliseconds $PollMilliseconds -QuietSeconds $QuietSeconds -EndMs $endMs
        $deliveryProfile=Get-NSPScanBridgeDeliveryProfile -Lifecycle @($built.Lifecycles) -DeviceName $DeviceName -SessionId $session -PollMilliseconds $PollMilliseconds -QuietSeconds $QuietSeconds -StartUtc $start -EndUtc $end -IgnoredExistingFiles $existing.Count -EndedEarly (-not $finished) -IncludeFileNames:$IncludeFileNames
        $stamp=$end.ToString('yyyyMMddTHHmmssZ')
        $eventsPath=Join-Path $output ('events_{0}.csv' -f $session)
        $profilePath=Join-Path $output ('profile_{0}_{1}.json' -f ($DeviceName -replace '[ .]','-'),$stamp)
        $rows=for ($i=0; $i -lt $observations.Count; $i++) {
            $o=$observations[$i]; $owner=$built.Owners[$i]
            [pscustomobject][ordered]@{
                SchemaVersion=1; SessionId=$session; Sequence=$i+1; Utc=$o.ObservedUtc.ToString('o'); LocalMonotonicMs=$o.ElapsedMs; Computer=if($IncludeFileNames){[Environment]::MachineName}else{$null}
                FileKey=if($owner){$owner.Key}else{$null}; Name=if($IncludeFileNames){[IO.Path]::GetFileName($o.Path)}else{$null}; Extension=[IO.Path]::GetExtension($o.Path)
                Event=$o.Source; Status=$o.Status; Bytes=$o.Length; LastWriteUtc=if($o.Status -eq 'Present'){$o.LastWriteTimeUtc.ToString('o')}else{$null}
                SharedRead=$o.SharedProbeStatus; SharedReadError=$o.SharedProbeError; Exclusive=$o.ProbeStatus; ExclusiveError=$o.ProbeError; StructureComplete=$o.StructureComplete
            }
        }
        if ($observations.Count) { @($rows) | Export-Csv -LiteralPath $eventsPath -NoTypeInformation -Encoding UTF8 } else { $eventsPath=$null }
        [IO.File]::WriteAllText($profilePath,($deliveryProfile | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))
        $timingPath=$null
        if ($IncludeFileNames -and $built.Lifecycles.Count) {
            $timingPath=Join-Path $output ('timing_{0}.csv' -f $session)
            $timing=foreach ($l in $built.Lifecycles) {
                $name=$l.Names[$l.Names.Count-1]; $at={ param($ms) $epoch.AddMilliseconds($ms).ToString('o') }
                [pscustomobject]@{Filename=$name;Event='DiscoveryFirstSeen';Utc=(& $at $l.FirstMs)}
                if ($l.Rename) { [pscustomobject]@{Filename=$name;Event='DiscoveryRenamed';Utc=(& $at $l.Rename.ElapsedMs)} }
                [pscustomobject]@{Filename=$name;Event='DiscoveryLastChange';Utc=(& $at $l.LastChangeMs)}
                if ($null -ne $l.CompletedMs) { [pscustomobject]@{Filename=$name;Event='DiscoveryComplete';Utc=(& $at $l.CompletedMs)} }
            }
            @($timing) | Export-Csv -LiteralPath $timingPath -NoTypeInformation -Encoding UTF8
        }
        Write-Host ('Classification: {0} ({1} confidence). Suggested MinimumAgeSeconds: {2}.' -f $deliveryProfile.Classification,$deliveryProfile.Confidence,$deliveryProfile.Recommendation.MinimumAgeSeconds)
        foreach ($line in $deliveryProfile.Evidence) { Write-Host ('  {0}' -f $line) }
        Write-Host ('Profile: {0}' -f $profilePath)
        if (-not $IncludeFileNames) { Write-Host 'File names were not recorded; add -IncludeFileNames to correlate with simulator logs.' }
        $deliveryProfile | Add-Member -NotePropertyMembers @{ProfilePath=$profilePath;EventsPath=$eventsPath;TimingPath=$timingPath} -PassThru
    }
}
