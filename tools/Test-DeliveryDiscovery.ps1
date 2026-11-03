$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach ($folder in 'Private','Public') {
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $root $folder) -Filter '*.ps1' -File){ . $file.FullName }
}
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
# Discovery is read-only: any processing, authentication or network call fails the regression.
function Invoke-NSPScanBridge { throw 'Discovery reached intake/worker.' }
function Connect-NSPScanBridgeContext { throw 'Discovery reached authentication.' }
function Save-NSPScanBridgeReceipt { throw 'Discovery wrote receipt.' }
function Send-NSPScanBridgeUploadSession { throw 'Discovery reached upload.' }
function Send-NSPGraphMail { throw 'Discovery reached mail.' }
function Invoke-NSPGraphRequest { throw 'Discovery reached Graph.' }
function Invoke-WebRequest { throw 'Discovery reached network.' }
function Invoke-RestMethod { throw 'Discovery reached network.' }

$t0=[datetime]::UtcNow; $created=$t0.AddMinutes(-1)
function Obs($Path,[double]$Ms,[long]$Length,$Shared='Available',$SharedError=$null,$Exclusive='Available',$Structure=$null,$Source='Polling.Sample',$Status='Present',$OldPath=$null,$Creation=$created,$ExclusiveError=$null) {
    [pscustomobject]@{Path=$Path;Source=$Source;Status=$Status;ObservedUtc=$t0.AddMilliseconds($Ms);ElapsedMs=$Ms;Length=$Length;LastWriteTimeUtc=$t0.AddMilliseconds($Length);CreationTimeUtc=$Creation;SharedProbeStatus=$Shared;SharedProbeError=$SharedError;ProbeStatus=$Exclusive;ProbeError=$ExclusiveError;StructureComplete=$Structure;OldPath=$OldPath}
}
# A writer growing a file at 0..750 ms, then a quiet completed file sampled until 12 s.
function Write-Growth($Path,$Shared,$SharedError,[double]$Offset=0,[bool]$Complete=$true) {
    foreach($i in 0..3){ Obs $Path ($Offset+250*$i) (100*($i+1)) $Shared $SharedError 'Unavailable' $null -ExclusiveError 'SharingViolation' }
    foreach($ms in 1000,1250,6000,12000){ Obs $Path ($Offset+$ms) 400 'Available' $null 'Available' $Complete }
}
function Build([object[]]$Observations,[double]$EndMs=12000){ Get-NSPScanBridgeDeliveryLifecycle -Observation $Observations -PollMilliseconds 250 -QuietSeconds 10 -EndMs $EndMs }

$exclusive=(Build @(Write-Growth 'C:\d\a.pdf' 'Unavailable' 'SharingViolation')).Lifecycles
Check ($exclusive.Count -eq 1 -and $exclusive[0].Outcome -eq 'Completed') 'Exclusive writer lifecycle not completed.'
$c=Get-NSPScanBridgeDeliveryClassification -Lifecycle $exclusive[0]
Check ($c.Class -eq 'DirectExclusive' -and $c.Confidence -eq 'High') 'Exclusive writer misclassified.'
$readable=(Build @(Write-Growth 'C:\d\b.pdf' 'Available' $null)).Lifecycles
Check ((Get-NSPScanBridgeDeliveryClassification -Lifecycle $readable[0]).Class -eq 'DirectReadable') 'Readable writer misclassified.'

$temp=@(foreach($i in 0..3){ Obs 'C:\d\c.pdf.uploading' (250*$i) (100*($i+1)) 'Unavailable' 'SharingViolation' 'Unavailable' $null })
$temp+=Obs 'C:\d\c.pdf.uploading' 1000 400 -Status 'RenamedAway' -Source 'FileSystemWatcher.RenamedAway'
$temp+=Obs 'C:\d\c.pdf' 1000 400 'Available' $null 'Available' $true 'FileSystemWatcher.Renamed' -OldPath 'C:\d\c.pdf.uploading'
$temp+=Obs 'C:\d\c.pdf.uploading' 1250 0 -Status 'Missing'
$temp+=foreach($ms in 1250,6000,12000){ Obs 'C:\d\c.pdf' $ms 400 'Available' $null 'Available' $true }
$renamed=(Build $temp).Lifecycles
Check ($renamed.Count -eq 1 -and $renamed[0].Rename.Method -eq 'Watcher' -and $renamed[0].Outcome -eq 'Completed') 'Watcher rename not followed into one lifecycle.'
$c=Get-NSPScanBridgeDeliveryClassification -Lifecycle $renamed[0]
Check ($c.Class -eq 'TempRename' -and $c.Confidence -eq 'High') 'Watcher temp-rename misclassified.'

# Polling found the PDF before the rename notification arrived: still one lifecycle.
$early=@(foreach($i in 0..3){ Obs 'C:\d\e.tmp' (250*$i) (100*($i+1)) 'Unavailable' 'SharingViolation' 'Unavailable' $null })
$early+=Obs 'C:\d\e.pdf' 1000 400 'Available' $null 'Available' $true 'Polling.Discovery'
$early+=Obs 'C:\d\e.pdf' 1100 400 'Available' $null 'Available' $true 'FileSystemWatcher.Renamed' -OldPath 'C:\d\e.tmp'
$early+=foreach($ms in 6000,12000){ Obs 'C:\d\e.pdf' $ms 400 'Available' $null 'Available' $true }
$built=Build $early
Check ($built.Lifecycles.Count -eq 1 -and $built.Lifecycles[0].Rename -and @($built.Owners | Where-Object { $_ -ne $built.Lifecycles[0] }).Count -eq 0) 'Early-polled rename target split into two lifecycles.'

# Polling only: a temporary name vanishes as a same-length PDF appears.
$inferred=@(foreach($i in 0..3){ Obs 'C:\d\f.pdf.part' (250*$i) (100*($i+1)) 'Unavailable' 'SharingViolation' 'Unavailable' $null })
$inferred+=Obs 'C:\d\f.pdf.part' 1000 0 -Status 'Missing'
$inferred+=Obs 'C:\d\f.pdf.part' 1250 0 -Status 'Missing'
$inferred+=foreach($ms in 1000,1250,6000,12000){ Obs 'C:\d\f.pdf' $ms 400 'Available' $null 'Available' $true }
$life=(Build $inferred).Lifecycles
Check ($life.Count -eq 1 -and $life[0].Rename.Method -eq 'Inferred' -and $life[0].Rename.FromExtension -eq '.part') 'Polling-only rename not inferred.'
Check ((Get-NSPScanBridgeDeliveryClassification -Lifecycle $life[0]).Class -eq 'TempRename') 'Inferred rename misclassified.'

# A temporary name that already ends in .pdf is visible to the worker while written: never a clean class.
$pdfTemp=@(foreach($i in 0..3){ Obs 'C:\d\~p.tmp.pdf' (250*$i) (100*($i+1)) 'Unavailable' 'SharingViolation' 'Unavailable' $null })
$pdfTemp+=Obs 'C:\d\p.pdf' 1000 400 'Available' $null 'Available' $true 'FileSystemWatcher.Renamed' -OldPath 'C:\d\~p.tmp.pdf'
$pdfTemp+=foreach($ms in 6000,12000){ Obs 'C:\d\p.pdf' $ms 400 'Available' $null 'Available' $true }
$pdfLife=(Build $pdfTemp).Lifecycles
$c=Get-NSPScanBridgeDeliveryClassification -Lifecycle $pdfLife[0]
Check ($pdfLife.Count -eq 1 -and $c.Class -eq 'Hybrid' -and @($c.Evidence | Where-Object { $_ -like '*already ends in .pdf*' }).Count -eq 1) 'A .pdf-to-.pdf rename was classified as a clean pattern.'
$pdfProfile=Get-NSPScanBridgeDeliveryProfile -Lifecycle $pdfLife -DeviceName 'Test' -SessionId 's' -PollMilliseconds 250 -QuietSeconds 10 -StartUtc $t0 -EndUtc $t0.AddSeconds(12)
Check (@($pdfProfile.Recommendation.Notes | Where-Object { $_ -like '*temporary name ending in .pdf*' }).Count -eq 1 -and $null -eq $pdfProfile.SimulatorSettings) 'The .pdf temporary-name risk was not called out.'
$mismatch=@($inferred | ForEach-Object { if($_.Path -like '*f.pdf' -and $_.Status -eq 'Present'){ $o=$_.PSObject.Copy(); $o.Length=999; $o } else { $_ } })
Check ((Build $mismatch).Lifecycles.Count -eq 2) 'Rename inferred across different lengths.'

$instant=(Build @(foreach($ms in 0,250,6000,12000){ Obs 'C:\d\g.pdf' $ms 400 'Available' $null 'Available' $true })).Lifecycles
$c=Get-NSPScanBridgeDeliveryClassification -Lifecycle $instant[0]
Check ($instant[0].Outcome -eq 'Completed' -and $c.Class -eq 'Unknown' -and $c.Confidence -eq 'Low') 'Instant delivery was force-fitted into a class.'
$aborted=(Build @(Write-Growth 'C:\d\h.pdf' 'Unavailable' 'SharingViolation' -Complete $false)).Lifecycles
Check ($aborted[0].Outcome -eq 'Incomplete') 'Aborted PDF not reported Incomplete.'
$alternating=(Build @($(foreach($i in 0..3){ Obs 'C:\d\i.pdf' (250*$i) (100*($i+1)) $(if($i%2){'Available'}else{'Unavailable'}) $(if($i%2){$null}else{'SharingViolation'}) 'Unavailable' $null }) + $(foreach($ms in 1000,12000){ Obs 'C:\d\i.pdf' $ms 400 'Available' $null 'Available' $true }))).Lifecycles
Check ((Get-NSPScanBridgeDeliveryClassification -Lifecycle $alternating[0]).Class -eq 'Hybrid') 'Alternating sharing not Hybrid.'
$denied=(Build @(Write-Growth 'C:\d\j.pdf' 'Unavailable' 'AccessDenied')).Lifecycles
Check ((Get-NSPScanBridgeDeliveryClassification -Lifecycle $denied[0]).Class -eq 'Unknown') 'Access-denied probes were treated as sharing evidence.'
$collision=(Build @((Write-Growth 'C:\d\k.pdf' 'Unavailable' 'SharingViolation') + (Obs 'C:\d\k.pdf' 12100 50 -Creation $created.AddMinutes(1)))).Lifecycles
Check ($collision.Count -eq 2 -and $collision[0].Outcome -eq 'Replaced' -and $collision[1].Collision) 'Recreated name not reported as a collision.'
$changing=(Build @(Write-Growth 'C:\d\l.pdf' 'Unavailable' 'SharingViolation') -EndMs 1500).Lifecycles
Check ($changing[0].Outcome -eq 'StillChanging') 'A file changing at capture end was reported finished.'
$deleted=(Build @((Write-Growth 'C:\d\m.pdf' 'Unavailable' 'SharingViolation') + (Obs 'C:\d\m.pdf' 12100 0 -Status 'Deleted' -Source 'FileSystemWatcher.Deleted'))).Lifecycles
Check ($deleted[0].Outcome -eq 'Deleted') 'Deleted delivery not reported.'

$profileArgs=@{DeviceName='Test';SessionId='s';PollMilliseconds=250;QuietSeconds=10;StartUtc=$t0;EndUtc=$t0.AddSeconds(12)}
$two=(Build @((Write-Growth 'C:\d\n1.pdf' 'Unavailable' 'SharingViolation') + (Write-Growth 'C:\d\n2.pdf' 'Unavailable' 'SharingViolation' -Offset 20))).Lifecycles
$p=Get-NSPScanBridgeDeliveryProfile -Lifecycle $two @profileArgs
Check ($p.Classification -eq 'DirectExclusive' -and $p.Confidence -eq 'High' -and $p.SimulatorSettings.Profile -eq 'Normal' -and $p.SimulatorSettings.FileSharing -eq 'None') 'Consistent exclusive device profile wrong.'
Check ($p.Recommendation.MinimumAgeSeconds -ge 20 -and $p.SimulatorSettings.TargetBytes -eq 400 -and $p.SimulatorSettings.DelayMs -gt 0) 'Recommendation or replay settings missing.'
$json=$p | ConvertTo-Json -Depth 8
Check ($json -notmatch 'n1\.pdf' -and $json -notmatch [regex]::Escape('C:\\d')) 'Profile disclosed file names or paths without -IncludeFileNames.'
Check (((Get-NSPScanBridgeDeliveryProfile -Lifecycle $two @profileArgs -IncludeFileNames) | ConvertTo-Json -Depth 8) -match 'n1\.pdf') 'File names missing with -IncludeFileNames.'
Check ((Get-NSPScanBridgeDeliveryProfile -Lifecycle $exclusive @profileArgs).Confidence -eq 'Medium') 'Single-file confidence not capped.'
$mixed=Get-NSPScanBridgeDeliveryProfile -Lifecycle @($exclusive[0],$readable[0]) @profileArgs
Check ($mixed.Classification -eq 'Hybrid' -and $mixed.Confidence -eq 'Low' -and $null -eq $mixed.SimulatorSettings) 'Mixed device not Hybrid.'
$none=Get-NSPScanBridgeDeliveryProfile -Lifecycle $aborted @profileArgs
Check ($none.Classification -eq 'Unknown' -and @($none.Evidence | Where-Object { $_ -like '*never became a complete PDF*' }).Count -eq 1) 'No-completion profile wrong.'
Check ($none.Recommendation.Notes -match 'do not lower').Count 'Ambiguous profile did not keep defaults.'
$slow=(Build @(@(Obs 'C:\d\o.pdf' 0 100 'Unavailable' 'SharingViolation' 'Unavailable' $null) + $(foreach($ms in 30000,31000,45000){ Obs 'C:\d\o.pdf' $ms 400 'Available' $null 'Available' $true })) -EndMs 45000).Lifecycles
Check ((Get-NSPScanBridgeDeliveryProfile -Lifecycle $slow @profileArgs).Recommendation.MinimumAgeSeconds -eq 70) 'Long pause did not raise the suggested minimum age.'
Check (@($p.Limits | Where-Object { $_ -like '*SMB CREATE*' }).Count -eq 1 -and $p.Clock.RemoteOffsetMeasured -eq $false) 'Profile limits missing.'

# Real synthetic writers against the real observer.
$base=Join-Path ([IO.Path]::GetTempPath()) ('nsp-discovery-'+[guid]::NewGuid().ToString('N'))
$drop=Join-Path $base 'drop'; $out=Join-Path $base 'out'
$beforeSubscriptions=@(Get-EventSubscriber | ForEach-Object SubscriptionId); $beforeJobs=@(Get-Job | ForEach-Object Id)
$writer=$null; $async=$null
try {
    [void][IO.Directory]::CreateDirectory($drop)
    $existing=Join-Path $drop 'existing.pdf'
    [IO.File]::WriteAllBytes($existing,[Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n%%EOF`n"))
    $existingHash=(Get-FileHash -LiteralPath $existing).Hash
    $threw=$false; try { Invoke-NSPScanBridgeDeliveryDiscovery -Path $drop -OutputDirectory (Join-Path $drop 'out') -DurationSeconds 5 6>$null | Out-Null } catch { $threw=$true }
    Check $threw 'Output inside the observed folder was allowed.'
    $writer=[powershell]::Create()
    [void]$writer.AddScript({
        param($Drop)
        $ErrorActionPreference='Stop'
        $ascii=[Text.Encoding]::ASCII
        function Send-Synthetic($Path,[IO.FileShare]$Share,[bool]$Finish) {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,$Share)
            try {
                $head=$ascii.GetBytes("%PDF-1.4`n"); $stream.Write($head,0,$head.Length)
                for($i=0;$i -lt 8;$i++){ $chunk=$ascii.GetBytes(('%'+('X'*4093)+"`r`n")); $stream.Write($chunk,0,$chunk.Length); $stream.Flush(); Start-Sleep -Milliseconds 150 }
                if($Finish){ $tail=$ascii.GetBytes("%%EOF`n"); $stream.Write($tail,0,$tail.Length) }
            } finally { $stream.Dispose() }
        }
        Start-Sleep -Milliseconds 800
        Send-Synthetic (Join-Path $Drop 'exclusive.pdf') ([IO.FileShare]::None) $true
        Start-Sleep -Milliseconds 300
        Send-Synthetic (Join-Path $Drop 'readable.pdf') ([IO.FileShare]::Read) $true
        Start-Sleep -Milliseconds 300
        Send-Synthetic (Join-Path $Drop 'renamed.pdf.uploading') ([IO.FileShare]::None) $true
        [IO.File]::Move((Join-Path $Drop 'renamed.pdf.uploading'),(Join-Path $Drop 'renamed.pdf'))
        Start-Sleep -Milliseconds 300
        Send-Synthetic (Join-Path $Drop 'aborted.pdf') ([IO.FileShare]::None) $false
    }.ToString()).AddArgument($drop)
    $async=$writer.BeginInvoke()
    $result=Invoke-NSPScanBridgeDeliveryDiscovery -Path $drop -OutputDirectory $out -DeviceName 'Synthetic device' -DurationSeconds 9 -PollMilliseconds 100 -QuietSeconds 1 -IncludeFileNames 6>$null
    $writer.EndInvoke($async) | Out-Null
    if($writer.HadErrors){ throw ('Synthetic writer failed: '+$writer.Streams.Error[0]) }
    $byName=@{}; foreach($f in $result.Files){ $byName[$f.Names[$f.Names.Count-1]]=$f }
    Check ($byName.Count -eq 4 -and -not $byName.ContainsKey('existing.pdf')) ('Expected four new deliveries, saw: '+(($byName.Keys) -join ','))
    Check ($byName['exclusive.pdf'].Class -eq 'DirectExclusive' -and $byName['exclusive.pdf'].Outcome -eq 'Completed') ('Real exclusive writer: '+$byName['exclusive.pdf'].Class+'/'+$byName['exclusive.pdf'].Outcome)
    Check ($byName['readable.pdf'].Class -eq 'DirectReadable' -and $byName['readable.pdf'].Outcome -eq 'Completed') ('Real readable writer: '+$byName['readable.pdf'].Class+'/'+$byName['readable.pdf'].Outcome)
    Check ($byName['renamed.pdf'].Class -eq 'TempRename' -and $byName['renamed.pdf'].Rename.Method -eq 'Watcher' -and $byName['renamed.pdf'].Extensions -eq '.uploading > .pdf') ('Real temp-rename writer: '+$byName['renamed.pdf'].Class)
    Check ($byName['aborted.pdf'].Outcome -eq 'Incomplete') ('Real aborted writer: '+$byName['aborted.pdf'].Outcome)
    Check ($result.Classification -eq 'Hybrid') 'Mixed real deliveries not Hybrid.'
    Check ((Test-Path -LiteralPath $result.ProfilePath) -and (Test-Path -LiteralPath $result.EventsPath) -and (Test-Path -LiteralPath $result.TimingPath)) 'Discovery outputs missing.'
    $saved=Get-Content -LiteralPath $result.ProfilePath -Raw | ConvertFrom-Json
    Check ($saved.Classification -eq 'Hybrid' -and $saved.SchemaVersion -eq 1 -and @($saved.Files).Count -eq 4) 'Saved profile does not match.'
    $events=@(Import-Csv -LiteralPath $result.EventsPath)
    Check ($saved.Clock.Computer -eq [Environment]::MachineName -and $events[0].Computer -eq [Environment]::MachineName) 'Computer name missing although names were requested.'
    Check (@($events | Where-Object { $_.SharedRead -eq 'Unavailable' -and $_.SharedReadError -eq 'SharingViolation' }).Count -gt 0 -and @($events | Where-Object { [double]$_.LocalMonotonicMs -gt 0 }).Count -gt 0) 'Events CSV lacks probe or monotonic evidence.'
    $sequence=@($events | ForEach-Object { [double]$_.LocalMonotonicMs })
    Check ((($sequence | Sort-Object) -join ',') -eq ($sequence -join ',')) 'Events are not in monotonic order.'
    $timing=@(Import-Csv -LiteralPath $result.TimingPath)
    Check (($timing[0].PSObject.Properties.Name -join ',') -eq 'Filename,Event,Utc' -and @($timing | Where-Object { $_.Filename -eq 'renamed.pdf' -and $_.Event -eq 'DiscoveryRenamed' }).Count -eq 1) 'Timing CSV not in the simulator comparison format.'
    # Timing must use the observer's clock: first-seen equals the file's first observed event row.
    foreach ($f in $result.Files) {
        $seen=[DateTimeOffset]::Parse(($timing | Where-Object { $_.Filename -eq $f.Names[$f.Names.Count-1] -and $_.Event -eq 'DiscoveryFirstSeen' }).Utc,[Globalization.CultureInfo]::InvariantCulture)
        $row=$events | Where-Object { $_.FileKey -eq $f.Key -and $_.Status -eq 'Present' } | Select-Object -First 1
        $gap=[math]::Abs(($seen-[DateTimeOffset]::Parse($row.Utc,[Globalization.CultureInfo]::InvariantCulture)).TotalMilliseconds)
        Check ($gap -le 2) ('Timing first-seen differs from the event log by {0:N1} ms for {1}.' -f $gap,$f.Key)
    }
    Check ((Get-FileHash -LiteralPath $existing).Hash -eq $existingHash) 'Discovery changed a pre-existing file.'
    Check ((@(Get-ChildItem -LiteralPath $drop -File | ForEach-Object Name | Sort-Object) -join ',') -eq 'aborted.pdf,exclusive.pdf,existing.pdf,readable.pdf,renamed.pdf') 'Discovery moved, removed or created files in the observed folder.'
    Check ((Get-Item (Join-Path $drop 'renamed.pdf')).Length -eq (9+8*4096+6)) 'Delivered bytes were altered.'

    # Polling only, without file names: a hidden temporary file, an inferred rename and anonymous output.
    $writer.Dispose(); $writer=[powershell]::Create()
    [void]$writer.AddScript({
        param($Drop)
        Start-Sleep -Milliseconds 600
        $stream=[IO.File]::Open((Join-Path $Drop 'quiet.tmp'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        [IO.File]::SetAttributes((Join-Path $Drop 'quiet.tmp'),[IO.FileAttributes]::Hidden)
        try { $b=[Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n"+('%'+('Y'*4093)+"`r`n")*6+"%%EOF`n"); for($i=0;$i -lt $b.Length;$i+=4096){ $stream.Write($b,$i,[math]::Min(4096,$b.Length-$i)); $stream.Flush(); Start-Sleep -Milliseconds 150 } } finally { $stream.Dispose() }
        [IO.File]::Move((Join-Path $Drop 'quiet.tmp'),(Join-Path $Drop 'quiet.pdf'))
    }.ToString()).AddArgument($drop)
    $async=$writer.BeginInvoke()
    $anonymous=Invoke-NSPScanBridgeDeliveryDiscovery -Path $drop -OutputDirectory $out -DurationSeconds 5 -PollMilliseconds 100 -QuietSeconds 1 -PollingOnly 6>$null
    $writer.EndInvoke($async) | Out-Null
    Check (@($anonymous.Files).Count -eq 1 -and $anonymous.Files[0].Class -eq 'TempRename' -and $anonymous.Files[0].Rename.Method -eq 'Inferred') ('Polling-only rename: '+(@($anonymous.Files | ForEach-Object { $_.Class+'/'+$_.Outcome }) -join ';'))
    Check ($anonymous.Capture.IgnoredExistingFiles -eq 5 -and $null -eq $anonymous.TimingPath) 'Second capture did not ignore earlier files or wrote timing without names.'
    $raw=(Get-Content -LiteralPath $anonymous.ProfilePath -Raw)+(Get-Content -LiteralPath $anonymous.EventsPath -Raw)
    Check ($raw -notmatch 'quiet\.(tmp|pdf)' -and $raw -notmatch [regex]::Escape($drop.Replace('\','\\')) -and $raw -notmatch [regex]::Escape($drop)) 'Anonymous capture disclosed names or paths.'
    Check ($raw -notmatch [regex]::Escape([Environment]::MachineName)) 'Anonymous capture disclosed the computer name.'
    Check (@(Get-EventSubscriber | Where-Object {$_.SubscriptionId -notin $beforeSubscriptions}).Count -eq 0) 'Discovery leaked event subscriptions.'
    Check (@(Get-Job | Where-Object {$_.Id -notin $beforeJobs}).Count -eq 0) 'Discovery leaked event jobs.'
    Write-Host ('Passed: {0} delivery discovery checks with synthetic lifecycles and exclusive/readable/rename/abort writers.' -f $checks)
} finally {
    if($writer){ if($async -and -not $async.IsCompleted){ $writer.Stop() }; $writer.Dispose() }
    if($base -like '*nsp-discovery-*'){ Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
