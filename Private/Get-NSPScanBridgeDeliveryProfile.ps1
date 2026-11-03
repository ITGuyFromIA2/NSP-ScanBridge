function Get-NSPScanBridgeDeliveryProfile {
    <#
    .SYNOPSIS
        Builds a device delivery profile from classified lifecycles: class, confidence, evidence,
        conservative policy recommendation and simulator replay settings.
    .DESCRIPTION
        Pure. Only Completed files decide the device class; mixed classes become Hybrid and no
        completed file leaves it Unknown. A single file caps confidence at Medium. File names are
        included only with -IncludeFileNames.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Lifecycle,
        [Parameter(Mandatory)][string]$DeviceName,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][double]$PollMilliseconds,
        [Parameter(Mandatory)][double]$QuietSeconds,
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][datetime]$EndUtc,
        [int]$IgnoredExistingFiles=0,
        [bool]$EndedEarly=$false,
        [switch]$IncludeFileNames
    )
    $rank=@{Low=0;Medium=1;High=2}
    $files=foreach ($lifecycle in $Lifecycle) {
        $class=Get-NSPScanBridgeDeliveryClassification -Lifecycle $lifecycle
        $entry=[ordered]@{Key=$lifecycle.Key}
        if ($IncludeFileNames) { $entry.Names=@($lifecycle.Names) }
        $entry.Extensions=(@($lifecycle.Names | ForEach-Object { [IO.Path]::GetExtension($_) }) -join ' > ')
        $entry.Outcome=$lifecycle.Outcome; $entry.Class=$class.Class; $entry.Confidence=$class.Confidence; $entry.Evidence=$class.Evidence
        $entry.Samples=$lifecycle.Samples.Count; $entry.WhileChangingSamples=@($lifecycle.MidWrite).Count
        $entry.FirstSeenUtc=if($lifecycle.Samples.Count){(@($lifecycle.Samples | Sort-Object Ms)[0].Utc).ToString('o')}else{$null}
        $entry.WriteDurationMs=$lifecycle.WriteDurationMs; $entry.LongestPauseMs=$lifecycle.LongestPauseMs
        $entry.FinalBytes=$lifecycle.FinalLength; $entry.BytesPerSecond=$lifecycle.BytesPerSecond
        $entry.Rename=$lifecycle.Rename; $entry.Collision=$lifecycle.Collision
        [pscustomobject]$entry
    }
    $files=@($files)
    $completed=@($files | Where-Object Outcome -eq 'Completed')
    $classes=@($completed | ForEach-Object Class | Select-Object -Unique)
    $evidence=New-Object System.Collections.Generic.List[string]
    $evidence.Add(('{0} file(s) observed, {1} completed; outcomes: {2}.' -f $files.Count,$completed.Count,((@($files | Group-Object Outcome | ForEach-Object { $_.Name+'='+$_.Count }) -join ', '))))
    if (-not $completed.Count) {
        $deviceClass='Unknown'; $confidence='Low'; $evidence.Add('No completed delivery to classify; repeat the capture with a test scan.')
    } elseif ($classes.Count -gt 1 -or $classes[0] -eq 'Hybrid') {
        $deviceClass='Hybrid'; $confidence='Low'
        $evidence.Add(('Completed files disagree: {0}.' -f ((@($completed | Group-Object Class | ForEach-Object { $_.Name+'='+$_.Count }) -join ', '))))
    } else {
        $deviceClass=$classes[0]
        $confidence=($completed | Sort-Object { $rank[$_.Confidence] } | Select-Object -First 1).Confidence
        if ($completed.Count -lt 2 -and $confidence -eq 'High') { $confidence='Medium'; $evidence.Add('Only one completed file; repeat to raise confidence.') }
    }
    $incomplete=@($files | Where-Object { $_.Outcome -in @('Incomplete','TempNotRenamed','NeverAvailable') }).Count
    if ($incomplete) { $evidence.Add(('{0} file(s) never became a complete PDF (cancelled or abandoned); ScanBridge holds such files in Source.' -f $incomplete)) }
    if (@($files | Where-Object Collision).Count) { $evidence.Add('A file name was overwritten or recreated during the capture; check for name collisions.') }
    if ($EndedEarly) { $evidence.Add('The capture was stopped early; results cover only what was seen.') }

    # Conservative policy: never below the ScanBridge default; twice the longest pause plus margin.
    $pause=[double](@($files | ForEach-Object LongestPauseMs) + 0 | Measure-Object -Maximum).Maximum
    $age=[int][math]::Min(3600,[math]::Max(20,[math]::Ceiling(2*$pause/1000)+10))
    $notes=New-Object System.Collections.Generic.List[string]
    $notes.Add('Keep the PDF structure check (header and %%EOF) and the exclusive-open check; both are already on in the worker.')
    $notes.Add('Size stability and a successful exclusive open are signals, not proof the writer finished.')
    switch ($deviceClass) {
        'TempRename' { $notes.Add('The device renames a temporary file to .pdf after writing. ScanBridge ignores non-PDF names, so the PDF appears complete; keep the minimum age as a margin.') }
        'DirectExclusive' { $notes.Add('The device writes the final .pdf name while holding it exclusively; the exclusive-open check detects an active writer.') }
        'DirectReadable' { $notes.Add('The device lets others read while it writes. An exclusive open still fails while its handle is open, but rely on the minimum age and structure check too.') }
        default { $notes.Add('Behavior is ambiguous: keep the defaults and do not lower MinimumAgeSeconds.') }
    }
    $recommendation=[pscustomobject]@{MinimumAgeSeconds=$age;LongestObservedPauseMs=$pause;Basis=('max(20, 2 x longest observed pause + 10 s), sampled every {0} ms' -f $PollMilliseconds);Notes=@($notes)}

    $simulator=$null
    if ($deviceClass -in @('TempRename','DirectExclusive','DirectReadable')) {
        $rates=@($completed | Where-Object { $_.BytesPerSecond -gt 0 } | ForEach-Object BytesPerSecond | Sort-Object)
        $sizes=@($completed | ForEach-Object FinalBytes | Sort-Object)
        $rate=if($rates.Count){$rates[[int][math]::Floor(($rates.Count-1)/2)]}else{$null}
        $simulator=[pscustomobject]@{
            Profile=if($deviceClass -eq 'TempRename'){'Rename'}else{'Normal'}
            FileSharing=if($deviceClass -eq 'DirectReadable'){'Read'}else{'None'}
            ChunkKiB=64
            DelayMs=if($rate){[int][math]::Min(60000,[math]::Round(65536/$rate*1000))}else{0}
            TargetBytes=$sizes[[int][math]::Floor(($sizes.Count-1)/2)]
            Basis='Median completed size and write rate; the delay spreads 64 KiB chunks over the observed rate. Approximate: bounded by the sampling interval.'
        }
    }
    $w32=try { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -Name Type -ErrorAction Stop).Type } catch { $null }
    [pscustomobject][ordered]@{
        SchemaVersion=1; SessionId=$SessionId; DeviceName=$DeviceName
        Classification=$deviceClass; Confidence=$confidence; Override=$null; Evidence=@($evidence)
        Recommendation=$recommendation; SimulatorSettings=$simulator
        Capture=[pscustomobject][ordered]@{StartUtc=$StartUtc.ToString('o');EndUtc=$EndUtc.ToString('o');PollMilliseconds=$PollMilliseconds;QuietSeconds=$QuietSeconds;IgnoredExistingFiles=$IgnoredExistingFiles;EndedEarly=$EndedEarly;FileNamesIncluded=[bool]$IncludeFileNames}
        Clock=[pscustomobject][ordered]@{Computer=[Environment]::MachineName;TimeZone=[TimeZoneInfo]::Local.Id;MonotonicHighResolution=[Diagnostics.Stopwatch]::IsHighResolution;TimeServiceType=$w32;RemoteOffsetMeasured=$false}
        Files=$files
        Limits=@(
            'File observation cannot show SMB CREATE access or share flags, chunk sizes or protocol commands; use SMB server ETW or a packet capture, with consent, for those.'
            ('Sampled every {0} ms: shorter writes and pauses are not seen, and timings are bounded by that interval.' -f $PollMilliseconds)
            'Probes briefly open each new file; a probe handle can delay a writer that reopens the file exclusively.'
            'Timestamps are this computer''s UTC clock plus a local monotonic stopwatch; no remote clock offset is measured here.'
            'Repeat the capture after firmware or scan-profile changes.'
        )
    }
}
