$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($directory in 'Private','Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.ps1' -File) { . $file.FullName }
}
$script:testBinding = @{ RouteName='RouteA'; TenantId='test-tenant'; ClientId='test-app'; DriveId='test-drive'; FolderItemId='test-folder' }
$script:checks = 0
function Assert-Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Check $rejected $Message
}
# Every transport and connection entry point below is synthetic. Fail on an unexpected call.
function Import-Module { param($Name,[switch]$PassThru,$ErrorAction) if ($Name -ne 'NSP.M365.Graph') { throw 'Unexpected module import.' }; if ($PassThru) { [pscustomobject]@{Name='NSP.M365.Graph';ExportedCommands=@{'Connect-NSPGraphAppOnly'=(Get-Command Connect-NSPGraphAppOnly)}} } }
$script:context = @{ AuthType='AppOnly'; ContextScope='Process'; TenantId='test-tenant'; ClientId='test-app' }
$script:connections = 0
function Connect-NSPGraphAppOnly { param($TenantId,$ClientId,$CertificateThumbprint,$ContextScope,$ErrorAction) $script:connections++ }
function Get-MgContext { param($ErrorAction) $script:context }
$script:uploads = 0
function Send-NSPScanBridgeUploadSession {
    param($Path,$DriveId,$FolderItemId,$Name)
    $script:uploads++
    @{ id='synthetic-item'; size=(Get-Item -LiteralPath $Path).Length }
}
$script:remoteBytes = [byte[]](37,80,68,70,45,49,46,52)
$script:remoteCalls = 0
function Invoke-NSPGraphRequest {
    param($Method,$Uri,$ErrorAction)
    $script:remoteCalls++
    if ($Method -ne 'GET') { throw 'Unexpected Graph write.' }
    @{ id='synthetic-item'; size=8; '@microsoft.graph.downloadUrl'='https://example.invalid/content' }
}
function Invoke-WebRequest {
    param($Uri,$OutFile,[switch]$UseBasicParsing,$ErrorAction)
    if ($Uri -ne 'https://example.invalid/content') { throw 'Unexpected download URL.' }
    [IO.File]::WriteAllBytes($OutFile, $script:remoteBytes)
}
function Invoke-RestMethod { throw 'Unexpected binary network transport.' }
# Certificate notices are covered by Test-CertificateAlerts; keep the local store out of these counts.
function Get-NSPScanBridgeCertificateStatus { param($Thumbprint,$WarningDays,$ErrorAction) [pscustomobject]@{ Status='Valid'; DaysRemaining=365 } }
$script:archiveImplementation = (Get-Command Complete-NSPScanBridgeArchive).ScriptBlock
$script:archiveFault = ''
function Complete-NSPScanBridgeArchive {
    param($PdfPath,$ArchiveDirectory,[System.Collections.IDictionary]$ExpectedBinding = $script:testBinding)
    if ($script:archiveFault -eq 'BeforeMove') { throw 'Synthetic archive interruption.' }
    if ($script:archiveFault -eq 'AfterPdfMove') {
        [IO.File]::Move($PdfPath,(Join-Path $ArchiveDirectory ([IO.Path]::GetFileName($PdfPath))))
        throw 'Synthetic archive interruption after PDF move.'
    }
    & $script:archiveImplementation -PdfPath $PdfPath -ArchiveDirectory $ArchiveDirectory -ExpectedBinding $ExpectedBinding
}
$script:saveImplementation = (Get-Command Save-NSPScanBridgeReceipt).ScriptBlock
$script:ackFault = $false
function Save-NSPScanBridgeReceipt {
    param($PdfPath,$State,$RemoteId,[switch]$VerifiedReconciliation,[System.Collections.IDictionary]$Binding = $script:testBinding)
    if ($script:ackFault -and $State -eq 'Uploaded') { throw 'Synthetic acknowledgment persistence failure.' }
    & $script:saveImplementation -Binding $Binding -PdfPath $PdfPath -State $State -RemoteId $RemoteId -VerifiedReconciliation:$VerifiedReconciliation
}
$base = Join-Path ([IO.Path]::GetTempPath()) ('nsp-stabilization-' + [guid]::NewGuid().ToString('N'))
$resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($base).StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe fixture root.' }
try {
    foreach ($name in 'source','spool','archive','lock','alerts') { [void](New-Item -ItemType Directory -Path (Join-Path $base $name) -Force) }
    $config = Join-Path $base 'synthetic.psd1'
    $safeBase = $base.Replace("'", "''")
    [IO.File]::WriteAllText($config, @"
@{
 Auth = @{ TenantId='test-tenant'; ClientId='test-app'; CertificateThumbprint='test-cert' }
 LockPath = '$safeBase\lock\worker.lock'
 Routes = @(@{ Name='RouteA'; Source='$safeBase\source'; Spool='$safeBase\spool'; Archive='$safeBase\archive'; DriveId='test-drive'; FolderItemId='test-folder'; MinimumAgeSeconds=1 })
 Alerts = @{ Enabled=`$true; From='monitor@example.com'; To='dispatch@example.com'; StateDirectory='$safeBase\alerts'; Auth=@{ TenantId='test-tenant'; ClientId='test-app'; CertificateThumbprint='test-cert' } }
}
"@)
    function New-Job([string]$State = 'Queued') {
        $pdf = Join-Path $base ('spool\' + [guid]::NewGuid().ToString('N') + '.pdf')
        [IO.File]::WriteAllBytes($pdf,[byte[]](37,80,68,70,45,49,46,52))
        if ($State -ne 'Missing') {
            Save-NSPScanBridgeReceipt -PdfPath $pdf -State Queued
            if ($State -ne 'Queued') { Save-NSPScanBridgeReceipt -PdfPath $pdf -State $State }
        }
        $pdf
    }
    $aliasConfig = Join-Path $base 'alias.psd1'
    $configText = [IO.File]::ReadAllText($config)
    [IO.File]::WriteAllText($aliasConfig, $configText.Replace("Spool='$safeBase\spool'", "Spool='$safeBase\source\'"))
    Assert-Rejected { Invoke-NSPScanBridge -ConfigurationPath $aliasConfig } 'Trailing separator bypassed distinct-directory validation.'
    $reservedConfig = Join-Path $base 'reserved.psd1'
    [IO.File]::WriteAllText($reservedConfig, $configText.Replace("Name='RouteA'", "Name='System'"))
    Assert-Rejected { Send-NSPScanBridgeAlert -ConfigurationPath $reservedConfig } 'Reserved incident route name was accepted.'
    Assert-Rejected { Send-NSPScanBridgeAlert -ConfigurationPath $config -WorkerFailed -WorkerSucceeded } 'Contradictory worker status flags were accepted.'
    $missing = New-Job Missing
    $interrupted = New-Job Uploading
    $corrupt = New-Job
    $corruptReceipt = [IO.Path]::ChangeExtension($corrupt,'.json')
    [IO.File]::WriteAllText($corruptReceipt,'{invalid-json')
    $held = @(Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue)
    Assert-Check ($script:uploads -eq 0 -and $held.Count -eq 3) 'Held jobs reached the upload transport.'
    Assert-Check (-not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($missing,'.json')))) 'Missing receipt was recreated.'
    Assert-Check ([IO.File]::ReadAllText($corruptReceipt) -eq '{invalid-json') 'Corrupt receipt evidence changed.'
    $health = Get-NSPScanBridgeHealth -ConfigurationPath $config
    Assert-Check ($health.MissingReceiptCount -eq 1 -and $health.InvalidReceiptCount -eq 1 -and $health.UploadingCount -eq 1) 'Health missed held receipt anomalies.'
    $interruptedId = [IO.Path]::GetFileNameWithoutExtension($interrupted)
    $script:context.ClientId = 'wrong-app'
    Assert-Rejected { Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName RouteA -JobId $interruptedId } 'Wrong application was accepted.'
    Assert-Check ($script:remoteCalls -eq 0) 'Wrong application reached readback.'
    $script:context.ClientId = 'test-app'
    $script:context.TenantId = 'wrong-tenant'
    Assert-Rejected { Invoke-NSPScanBridge -ConfigurationPath $config } 'Wrong tenant was accepted by worker.'
    $script:context.TenantId = 'test-tenant'
    $connectionCount = $script:connections
    Assert-Rejected { Connect-NSPScanBridgeContext -Auth @{ TenantId='test-tenant' } } 'Incomplete authentication was accepted.'
    Assert-Check ($script:connections -eq $connectionCount) 'Incomplete configuration attempted authentication.'
    $script:remoteBytes = [byte[]](37,80,68,70,45,49,46,53)
    $result = Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName RouteA -JobId $interruptedId
    Assert-Check ($result.Status -eq 'Mismatch' -and (Test-Path -LiteralPath $interrupted)) 'Uploading mismatch lost evidence.'
    $script:remoteBytes = [byte[]](37,80,68,70,45,49,46,52)
    $result = Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName RouteA -JobId $interruptedId
    Assert-Check ($result.Archived -and $script:uploads -eq 0) 'Interrupted upload was replayed instead of reconciled.'
    $archived = Join-Path $base ('archive\' + $interruptedId + '.pdf')
    $archivedReceipt = [IO.Path]::ChangeExtension($archived,'.json')
    $archivedJson = [IO.File]::ReadAllText($archivedReceipt)
    [IO.File]::WriteAllText($archivedReceipt,'null')
    Assert-Rejected { Complete-NSPScanBridgeArchive -PdfPath $interrupted -ArchiveDirectory (Join-Path $base 'archive') } 'Already archived corrupt receipt was accepted.'
    [IO.File]::WriteAllText($archivedReceipt,$archivedJson)
    $duplicate = $interrupted
    [IO.File]::WriteAllBytes($duplicate,[byte[]](1,2,3))
    Assert-Rejected { Complete-NSPScanBridgeArchive -PdfPath $duplicate -ArchiveDirectory (Join-Path $base 'archive') } 'Duplicate spool/archive PDF accepted.'
    Remove-Item -LiteralPath $duplicate -Force
    $valid = New-Job
    $validReceipt = [IO.Path]::ChangeExtension($valid,'.json')
    $originalJson = [IO.File]::ReadAllText($validReceipt)
    foreach ($badJson in @('null','[]','{}','{bad')) {
        [IO.File]::WriteAllText($validReceipt,$badJson)
        Assert-Rejected { Save-NSPScanBridgeReceipt -PdfPath $valid -State Uploading } 'Invalid receipt was overwritten.'
        Assert-Check ([IO.File]::ReadAllText($validReceipt) -eq $badJson) 'Invalid receipt evidence was modified.'
    }
    foreach ($field in @('Size','JobId','Hash','State','Version')) {
        $damaged = $originalJson | ConvertFrom-Json
        switch ($field) { Size { $damaged.Size=999 }; JobId { $damaged.JobId='wrong' }; Hash { $damaged.Hash=('0'*64) }; State { $damaged.State='MissingReceipt' }; Version { $damaged.Version=3 } }
        [IO.File]::WriteAllText($validReceipt,($damaged | ConvertTo-Json))
        Assert-Rejected { Read-NSPScanBridgeReceipt -PdfPath $valid } ('Receipt field accepted: '+$field)
    }
    [IO.File]::WriteAllText($validReceipt,$originalJson)
    $script:archiveFault = 'BeforeMove'
    $null = Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue
    Assert-Check ((Read-NSPScanBridgeReceipt -PdfPath $valid).State -eq 'Uploaded') 'Archive failure lost acknowledgment.'
    $uploadCount = $script:uploads
    $script:archiveFault = ''
    $null = Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue
    Assert-Check ($script:uploads -eq $uploadCount -and -not (Test-Path -LiteralPath $valid)) 'Archive recovery replayed upload.'
    $afterMove = New-Job
    $script:archiveFault = 'AfterPdfMove'
    $null = Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue
    Assert-Check (-not (Test-Path -LiteralPath $afterMove) -and (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($afterMove,'.json')))) 'Injected PDF move did not retain spool receipt.'
    $uploadCount = $script:uploads
    $script:archiveFault = ''
    $null = Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue
    Assert-Check ($script:uploads -eq $uploadCount -and -not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($afterMove,'.json')))) 'Orphan receipt recovery replayed or lost evidence.'
    $ackJob = New-Job
    $script:ackFault = $true
    $null = Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue
    Assert-Check ((Read-NSPScanBridgeReceipt -PdfPath $ackJob).State -eq 'Review') 'Failed acknowledgment persistence did not hold job.'
    $uploadCount = $script:uploads
    $script:ackFault = $false
    $null = Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue
    Assert-Check ($script:uploads -eq $uploadCount) 'Unknown acknowledgment outcome was replayed.'
    $result = Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName RouteA -JobId ([IO.Path]::GetFileNameWithoutExtension($ackJob))
    Assert-Check $result.Archived 'Acknowledgment failure could not be reconciled.'
    $transitionJob = New-Job
    Assert-Rejected { Save-NSPScanBridgeReceipt -PdfPath $transitionJob -State Uploaded -RemoteId 'synthetic' } 'Queued job bypassed Uploading state.'
    Save-NSPScanBridgeReceipt -PdfPath $transitionJob -State Review
    Assert-Rejected { Save-NSPScanBridgeReceipt -PdfPath $transitionJob -State Queued } 'Review job was automatically requeued.'
    Assert-Rejected { Save-NSPScanBridgeReceipt -PdfPath $transitionJob -State Uploaded -RemoteId 'synthetic' } 'Unverified reconciliation was accepted.'
    Save-NSPScanBridgeReceipt -PdfPath $transitionJob -State Uploaded -RemoteId 'synthetic' -VerifiedReconciliation
    Assert-Rejected { Save-NSPScanBridgeReceipt -PdfPath $transitionJob -State Uploaded -RemoteId 'changed' } 'Acknowledged remote ID changed.'
    # Exercise enabled alerting with fake authentication, health and mail transport.
    $script:healthMode = 'Unhealthy'
    function Test-NSPScanBridgeHealth {
        param($ConfigurationPath,$MaximumPending,$MaximumPendingMinutes)
        if ($script:healthMode -eq 'Error') { throw 'Synthetic private transport detail.' }
        [pscustomobject]@{ Route='RouteA'; Healthy=($script:healthMode -eq 'Healthy'); Conditions=@('ManualReview'); PendingCount=1; OldestPendingMinutes=1 }
    }
    $script:mails = 0
    $script:mailFault = $false
    $script:markerFault = $false
    $marker = Join-Path $base 'alerts\Um91dGVB.alert.json'
    function Send-NSPGraphMail {
        param($From,$To,$Subject,$Body,$ErrorAction)
        if ($script:mailFault) { throw 'Synthetic send failure.' }
        Assert-Check ($Body -notmatch 'private transport detail|\.pdf|test-tenant|test-app') 'Alert leaked sensitive test detail.'
        $script:mails++
        if ($script:markerFault) { [void][IO.Directory]::CreateDirectory($marker) }
    }
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails -eq 1) 'Identical alert was not deduplicated.'
    $lockFile = Join-Path $base 'alerts\alerts.lock'
    $alertLock = [IO.File]::Open($lockFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Assert-Rejected { Send-NSPScanBridgeAlert -ConfigurationPath $config } 'Concurrent alert process was admitted.' }
    finally { $alertLock.Dispose() }
    Assert-Check ($script:mails -eq 1) 'Concurrent alert attempt sent mail.'
    $script:healthMode = 'Healthy'
    $beforeWhatIf = [IO.File]::ReadAllText($marker)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config -WhatIf
    Assert-Check ([IO.File]::ReadAllText($marker) -eq $beforeWhatIf) 'WhatIf resolved an alert marker.'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    $script:healthMode = 'Unhealthy'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails -eq 2) 'Recurrent alert was suppressed after recovery.'
    $script:healthMode = 'Error'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    $script:healthMode = 'Healthy'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    $script:healthMode = 'Error'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails -eq 4) 'Health-check error recurrence was suppressed.'
    $script:healthMode = 'Healthy'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config -WorkerFailed
    $workerMarker = Join-Path $base 'alerts\V29ya2Vy.alert.json'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check (Get-Content -LiteralPath $workerMarker -Raw | ConvertFrom-Json).Active 'Standalone check resolved worker failure without a worker pass.'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config -WorkerSucceeded
    Assert-Check (-not (Get-Content -LiteralPath $workerMarker -Raw | ConvertFrom-Json).Active) 'Successful worker pass did not resolve worker failure.'
    $script:healthMode = 'Unhealthy'
    $script:mailFault = $true
    Assert-Rejected { Send-NSPScanBridgeAlert -ConfigurationPath $config } 'Send failure was ignored.'
    Assert-Check (-not (Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json).Active) 'Failed send was marked active.'
    $script:mailFault = $false
    Remove-Item -LiteralPath $marker -Force
    $script:markerFault = $true
    Assert-Rejected { Send-NSPScanBridgeAlert -ConfigurationPath $config } 'Marker persistence failure was ignored.'
    Assert-Check (-not (Test-Path -LiteralPath $marker -PathType Leaf)) 'Failed marker persistence claimed delivery.'
    $script:markerFault = $false
    [IO.Directory]::Delete($marker)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check (Test-Path -LiteralPath $marker -PathType Leaf) 'Alert did not retry after persistence failure.'
    Write-Host ('Passed: {0} stabilization checks using synthetic local fixtures and fake transports.' -f $script:checks)
} finally {
    $resolvedBase = [IO.Path]::GetFullPath($base)
    if (-not $resolvedBase.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedBase) -notmatch '^nsp-stabilization-[0-9a-f]{32}$') { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolvedBase) { Remove-Item -LiteralPath $resolvedBase -Recurse -Force }
}
