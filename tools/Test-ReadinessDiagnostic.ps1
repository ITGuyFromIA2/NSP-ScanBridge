$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach ($folder in 'Private','Public') {
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $root $folder) -Filter '*.ps1' -File){ . $file.FullName }
}
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
# Any accidental processing, authentication or network call fails the regression.
function Invoke-NSPScanBridge { throw 'Diagnostic reached intake/worker.' }
function Connect-NSPScanBridgeContext { throw 'Diagnostic reached authentication.' }
function Save-NSPScanBridgeReceipt { throw 'Diagnostic wrote receipt.' }
function Send-NSPScanBridgeUploadSession { throw 'Diagnostic reached upload.' }
function Send-NSPGraphMail { throw 'Diagnostic reached mail.' }
function Invoke-NSPGraphRequest { throw 'Diagnostic reached Graph.' }
function Invoke-WebRequest { throw 'Diagnostic reached network.' }
function Invoke-RestMethod { throw 'Diagnostic reached network.' }
$now=[datetime]::UtcNow
foreach($probe in 'Available','Unavailable','NotTested') {
    $decision=Get-NSPScanBridgeReadinessDecision -Length 10 -LastWriteTimeUtc $now.AddSeconds(-20) -NowUtc $now -MinimumAgeSeconds 15 -ProbeStatus $probe
    Check ($decision.Ready -eq ($probe -eq 'Available')) 'Baseline lock gate mismatch.'
}
Check (-not (Get-NSPScanBridgeReadinessDecision -Length 0 -LastWriteTimeUtc $now.AddSeconds(-20) -ProbeStatus Available).Ready) 'Empty file accepted.'
Check (-not (Get-NSPScanBridgeReadinessDecision -Length 10 -LastWriteTimeUtc $now -ProbeStatus Available).Ready) 'Fresh file accepted.'
Check (-not (Get-NSPScanBridgeReadinessDecision -Length 10 -LastWriteTimeUtc $now.AddSeconds(-20) -IsPdf $false -ProbeStatus Available).Ready) 'Non-PDF accepted.'
Check (-not (Get-NSPScanBridgeReadinessDecision -Mode StableWindow -Length 10 -QuietSeconds 10 -StableSamples 1 -ProbeStatus Available).Ready) 'Single stability sample accepted.'
$observation=[pscustomobject]@{ObservedUtc=$now;Status='Present';Source='Polling.Discovery';CreationTimeUtc=$now;Length=10;LastWriteTimeUtc=$now}
$state=Update-NSPScanBridgeReadinessObservation -Observation $observation
$generation=$state.Generation
$observation.ObservedUtc=$now.AddSeconds(1.6); $observation.Source='Polling.Sample'
$state=Update-NSPScanBridgeReadinessObservation -Previous $state -Observation $observation
Check ([math]::Abs($state.QuietSeconds-1.6) -lt 0.001) 'Fractional quiet time was rounded.'
Check (-not (Get-NSPScanBridgeReadinessDecision -Mode StrictQuiet -Length 10 -QuietSeconds $state.QuietSeconds -StableSamples 3 -RequiredQuietSeconds 2 -RequiredSamples 3 -ProbeStatus Available).Ready) 'Quiet policy accepted before its exact threshold.'
$observation.ObservedUtc=$now.AddSeconds(2); $observation.Source='Polling.Sample'
$state=Update-NSPScanBridgeReadinessObservation -Previous $state -Observation $observation
Check ($state.QuietSeconds -eq 2 -and $state.Samples -eq 3) 'Quiet/sample observations not accumulated.'
$observation.Length=20; $observation.ObservedUtc=$now.AddSeconds(3)
$state=Update-NSPScanBridgeReadinessObservation -Previous $state -Observation $observation
Check ($state.QuietSeconds -eq 0 -and $state.SizeChanged -and $state.Samples -eq 1) 'Growth did not reset stability.'
$observation.Source='FileSystemWatcher.Changed'; $observation.ObservedUtc=$now.AddSeconds(4)
$state=Update-NSPScanBridgeReadinessObservation -Previous $state -Observation $observation
Check ($state.QuietSeconds -eq 0 -and $state.Samples -eq 0) 'Changed hint counted as stable sample.'
$observation.Status='Missing'
$state=Update-NSPScanBridgeReadinessObservation -Previous $state -Observation $observation
$observation.Status='Present';$observation.Source='Polling.Sample';$observation.CreationTimeUtc=$now.AddSeconds(5)
$state=Update-NSPScanBridgeReadinessObservation -Previous $state -Observation $observation
Check ($state.Generation -ne $generation -and $state.FirstDecisions.Count -eq 0) 'Recreated path inherited prior lifecycle.'

$base=Join-Path ([IO.Path]::GetTempPath()) ('nsp-readiness-diagnostic-'+[guid]::NewGuid().ToString('N'))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not ([IO.Path]::GetFullPath($base).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase))){throw 'Unsafe fixture root.'}
$writer=$null;$async=$null
$beforeSubscriptions=@(Get-EventSubscriber | Select-Object -ExpandProperty SubscriptionId)
$beforeJobs=@(Get-Job | Select-Object -ExpandProperty Id)
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $base 'drop'))
    [void][IO.Directory]::CreateDirectory((Join-Path $base 'other'))
    $config=Join-Path $base 'synthetic.psd1';$safeBase=$base.Replace("'","''")
    [IO.File]::WriteAllText($config,"@{Routes=@(@{Name='RouteA';Source='$safeBase\drop';MinimumAgeSeconds=1},@{Name='RouteB';Source='$safeBase\other';MinimumAgeSeconds=1})}")
    $preexisting=Join-Path $base 'drop/preexisting [x].pdf'
    [IO.File]::WriteAllBytes($preexisting,[byte[]](37,80,68,70,45,49,46,52,10,37,37,69,79,70,10))
    (Get-Item -LiteralPath $preexisting).LastWriteTimeUtc=$now.AddMinutes(-2)
    $preHash=(Get-FileHash -LiteralPath $preexisting).Hash
    # The real worker and comparison baseline share their metadata evaluator.
    Check (Test-NSPScanBridgeFileReady -Path $preexisting -MinimumAgeSeconds 1) 'Worker baseline preexisting PDF failed.'
    $lock=[IO.File]::Open($preexisting,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Check (-not (Test-NSPScanBridgeFileReady -Path $preexisting -MinimumAgeSeconds 1)) 'Worker baseline ignored open handle.' }
    finally { $lock.Dispose() }
    $writer=[powershell]::Create()
    [void]$writer.AddScript({
        param($Base)
        $ErrorActionPreference='Stop'
        function Write-Synthetic($Path,[byte[]]$Bytes) {
            for($attempt=0;$attempt -lt 100;$attempt++) {
                try {[IO.File]::WriteAllBytes($Path,$Bytes);return}catch [IO.IOException]{Start-Sleep -Milliseconds 10}
            }
            throw 'Synthetic writer could not open fixture.'
        }
        Start-Sleep -Milliseconds 800
        $drop=Join-Path $Base 'drop'; $other=Join-Path $Base 'other'
        $locked=[IO.File]::Open((Join-Path $drop 'locked.pdf'),[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $shared=[IO.File]::Open((Join-Path $drop 'shared.pdf'),[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
        try {
            Write-Synthetic (Join-Path $drop 'burst.pdf') ([byte[]](37,80,68,70,1))
            Write-Synthetic (Join-Path $drop 'empty.pdf') ([byte[]]@())
            Write-Synthetic (Join-Path $other 'parallel.pdf') ([byte[]](37,80,68,70,2))
            Write-Synthetic (Join-Path $drop 'old.pdf') ([byte[]](37,80,68,70,3))
            for($i=0;$i -lt 6;$i++) {
                $locked.WriteByte(65);$locked.Flush();$shared.WriteByte(66);$shared.Flush()
                Start-Sleep -Milliseconds 250
            }
        } finally {$locked.Dispose();$shared.Dispose()}
        [IO.File]::Move((Join-Path $drop 'old.pdf'),(Join-Path $drop 'renamed.pdf'))
        Write-Synthetic (Join-Path $drop 'empty.pdf') ([byte[]](37,80,68,70,4))
        Start-Sleep -Milliseconds 400
        [IO.File]::Delete((Join-Path $drop 'renamed.pdf'))
        Start-Sleep -Milliseconds 400
        Write-Synthetic (Join-Path $drop 'renamed.pdf') ([byte[]](37,80,68,70,5,6))
        Start-Sleep -Milliseconds 900
        Write-Synthetic (Join-Path $drop 'burst.pdf') ([byte[]](37,80,68,70,1,2,3,4,5,6))
    }.ToString()).AddArgument($base)
    $async=$writer.BeginInvoke()
    $rows=@(Watch-NSPScanBridgeReadiness -ConfigurationPath $config -PollMilliseconds 100 -HeartbeatSeconds 1 -StableQuietSeconds 0.4 -StableSamples 3 -StrictQuietSeconds 2 -StrictSamples 4 -DurationSeconds 7 -PassThru 6>$null)
    $writer.EndInvoke($async) | Out-Null
    if($writer.HadErrors){throw 'Synthetic writer failed.'}
    Check (@($rows | Where-Object Source -like 'FileSystemWatcher.*').Count -gt 0) 'Real watcher emitted no notifications.'
    Check (@($rows | Where-Object Source -like 'Polling.*').Count -gt 0) 'Polling observations missing.'
    Check (@($rows | Where-Object {$_.Path -like '*locked.pdf' -and $_.ProbeStatus -eq 'Unavailable'}).Count -gt 0) 'Locked slow writer was not observed.'
    Check (@($rows | Where-Object {$_.Path -like '*shared.pdf' -and $_.ProbeStatus -eq 'Unavailable'}).Count -gt 0) 'Shared-access writer was not observed.'
    Check (@($rows | Where-Object {$_.Path -like '*empty.pdf' -and $_.Length -eq 0}).Count -gt 0) 'Empty stage was not observed.'
    Check (@($rows | Where-Object {$_.Path -like '*empty.pdf' -and $_.Length -gt 0}).Count -gt 0) 'Growth after empty stage was not observed.'
    $burst=@($rows | Where-Object {$_.Path -like '*burst.pdf'})
    Check (@($burst | Where-Object {$_.Revoked.Count -gt 0}).Count -gt 0) 'Late write did not revoke prior readiness.'
    foreach($mode in 'AgeAndExclusive','StableWindow','StrictQuiet') {
        Check (@($burst | ForEach-Object {$_.Decisions} | Where-Object {$_.Mode -eq $mode -and $_.State -eq 'WOULD PROCEED'}).Count -gt 0) ('No decision time observed for '+$mode)
        $firstDecision=$burst | ForEach-Object {$_.Decisions} | Where-Object {$_.Mode -eq $mode -and $_.FirstDecisionUtc} | Select-Object -First 1
        Write-Host ('Synthetic burst first {0} decision: {1:N2}s after initial observation.' -f $mode,($firstDecision.FirstDecisionUtc-$burst[0].ObservedUtc).TotalSeconds)
    }
    Check (@($rows | Where-Object {$_.Route -eq 'RouteB' -and $_.Path -like '*parallel.pdf'}).Count -gt 0) 'Simultaneous second-route file starved.'
    Check (@($rows | Where-Object {$_.Source -eq 'FileSystemWatcher.RenamedAway'}).Count -gt 0) 'Rename-away not distinguished.'
    Check (@($rows | Where-Object {$_.Path -like '*renamed.pdf'} | Select-Object -ExpandProperty Generation -Unique).Count -ge 2) 'Reused renamed path retained stale generation.'
    Check ((Get-FileHash -LiteralPath $preexisting).Hash -eq $preHash) 'Diagnostic altered preexisting source bytes.'
    $finalHashes=@{};Get-ChildItem (Join-Path $base 'drop'),(Join-Path $base 'other') -File | ForEach-Object {$finalHashes[$_.FullName]=(Get-FileHash -LiteralPath $_.FullName).Hash}
    $metadata=@(Watch-NSPScanBridgeReadiness -ConfigurationPath $config -RouteName RouteA -DurationSeconds 0.3 -PollMilliseconds 100 -MetadataOnly -PollingOnly -PassThru 6>$null)
    Check (@($metadata | Where-Object {$_.ProbeStatus -ne 'NotTested'}).Count -eq 0) 'Metadata-only performed lock probe.'
    Check (@($metadata | ForEach-Object {$_.Decisions} | Where-Object State -eq 'WOULD PROCEED').Count -eq 0) 'Metadata-only claimed lock-verified readiness.'
    Check (@($metadata | Where-Object Route -ne RouteA).Count -eq 0) 'Route selection ignored.'
    Check (@($metadata | Where-Object Source -like 'FileSystemWatcher.*').Count -eq 0) 'Polling-only mislabeled event source.'
    foreach($path in $finalHashes.Keys){Check ((Get-FileHash -LiteralPath $path).Hash -eq $finalHashes[$path]) 'Diagnostic modified final writer bytes.'}
    Check (@(Get-ChildItem $base -Filter '*.json' -Recurse -File).Count -eq 0) 'Diagnostic generated receipts/logs.'
    Check (@(Get-EventSubscriber | Where-Object {$_.SubscriptionId -notin $beforeSubscriptions}).Count -eq 0) 'Diagnostic leaked event subscriptions.'
    Check (@(Get-Job | Where-Object {$_.Id -notin $beforeJobs}).Count -eq 0) 'Diagnostic leaked event jobs.'
    Write-Host ('Passed: {0} readiness diagnostic checks with synthetic slow/shared/burst/empty/rename/recreate/parallel writers.' -f $checks)
} finally {
    if($writer){if($async -and -not $async.IsCompleted){$writer.Stop()};$writer.Dispose()}
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
