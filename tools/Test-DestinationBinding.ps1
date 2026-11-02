$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($directory in 'Private','Public') {
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.ps1' -File) { . $file.FullName }
}
$script:checks=0
function Assert-BindingSafety([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message}; $script:checks++ }
function Assert-BindingRejected([scriptblock]$Action,[string]$Message) {
    $rejected=$false
    try { & $Action | Out-Null } catch { $rejected=$true }
    Assert-BindingSafety $rejected $Message
}
function Import-Module { param($Name,[switch]$PassThru,$ErrorAction) if($Name -ne 'NSP.M365.Graph'){throw 'Unexpected import.'}; if ($PassThru) { [pscustomobject]@{Name='NSP.M365.Graph';ExportedCommands=@{'Connect-NSPGraphAppOnly'=(Get-Command Connect-NSPGraphAppOnly)}} } }
$script:context=@{AuthType='AppOnly'; ContextScope='Process';TenantId='test-tenant';ClientId='test-app'}
function Connect-NSPGraphAppOnly { param($TenantId,$ClientId,$CertificateThumbprint,$ContextScope,$ErrorAction) $script:context.TenantId=$TenantId; $script:context.ClientId=$ClientId }
function Get-MgContext { param($ErrorAction) $script:context }
$script:uploads=0; $script:lookups=0; $script:downloads=0
function Send-NSPScanBridgeUploadSession { param($Path,$DriveId,$FolderItemId,$Name) $script:uploads++; @{id='synthetic-item';size=(Get-Item -LiteralPath $Path).Length} }
function Invoke-NSPGraphRequest {
    param($Method,$Uri,$ErrorAction)
    if($Method -ne 'GET'){throw 'Unexpected Graph write.'}
    $script:lookups++
    @{id='synthetic-item';size=8;'@microsoft.graph.downloadUrl'='https://example.invalid/binding-content'}
}
function Invoke-WebRequest {
    param($Uri,$OutFile,[switch]$UseBasicParsing,$ErrorAction)
    if($Uri -ne 'https://example.invalid/binding-content'){throw 'Unexpected download.'}
    $script:downloads++
    [IO.File]::WriteAllBytes($OutFile,[byte[]](37,80,68,70,45,49,46,52))
}
function Invoke-RestMethod { throw 'Network forbidden.' }
$base=Join-Path ([IO.Path]::GetTempPath()) ('nsp-binding-safety-'+[guid]::NewGuid().ToString('N'))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not ([IO.Path]::GetFullPath($base).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase))){throw 'Unsafe fixture root.'}
try {
    foreach($directory in 'source','spool','archive','lock'){[void][IO.Directory]::CreateDirectory((Join-Path $base $directory))}
    $safeBase=$base.Replace("'","''")
    $config=Join-Path $base 'synthetic.psd1'
    $original=@{RouteName='RouteA';TenantId='test-tenant';ClientId='test-app';DriveId='test-drive';FolderItemId='test-folder'}
    function Set-BindingConfig([System.Collections.IDictionary]$Binding) {
        [IO.File]::WriteAllText($config,@"
@{
 LockPath='$safeBase\lock\worker.lock'
 Auth=@{TenantId='$($Binding.TenantId)';ClientId='$($Binding.ClientId)';CertificateThumbprint='test-cert'}
 Routes=@(@{Name='$($Binding.RouteName)';Source='$safeBase\source';Spool='$safeBase\spool';Archive='$safeBase\archive';DriveId='$($Binding.DriveId)';FolderItemId='$($Binding.FolderItemId)';MinimumAgeSeconds=1})
}
"@)
    }
    function New-BoundJob([string]$State='Queued') {
        $pdf=Join-Path $base ('spool\'+[guid]::NewGuid().ToString('N')+'.pdf')
        [IO.File]::WriteAllBytes($pdf,[byte[]](37,80,68,70,45,49,46,52))
        Save-NSPScanBridgeReceipt -PdfPath $pdf -State Queued -Binding $original
        if($State -eq 'Uploaded') {
            Save-NSPScanBridgeReceipt -PdfPath $pdf -State Uploading -Binding $original
            Save-NSPScanBridgeReceipt -PdfPath $pdf -State Uploaded -Binding $original -RemoteId 'synthetic-item'
        } elseif($State -ne 'Queued') {Save-NSPScanBridgeReceipt -PdfPath $pdf -State $State -Binding $original}
        $pdf
    }
    Set-BindingConfig $original
    # Actual intake stamps the expected destination before any upload is possible.
    $source=Join-Path $base 'source\synthetic.pdf'
    [IO.File]::WriteAllBytes($source,[byte[]](37,80,68,70,45,49,46,52))
    (Get-Item -LiteralPath $source).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-2)
    $claim=@(Invoke-NSPScanBridge -ConfigurationPath $config -IntakeOnly)
    $claimedPdf=Join-Path $base ('spool\'+$claim[0].JobId+'.pdf')
    $claimed=Read-NSPScanBridgeReceipt -PdfPath $claimedPdf -ExpectedBinding $original
    Assert-BindingSafety ($claim.Count -eq 1 -and $claimed.Version -eq 2 -and $claimed.Destination.DriveId -eq $original.DriveId) 'Intake did not persist a bound v2 receipt.'
    $null=Invoke-NSPScanBridge -ConfigurationPath $config
    foreach($field in 'RouteName','TenantId','ClientId','DriveId','FolderItemId') {
        $pdf=New-BoundJob
        $receipt=[IO.Path]::ChangeExtension($pdf,'.json')
        $before=(Get-FileHash -LiteralPath $receipt).Hash
        $pdfHash=(Get-FileHash -LiteralPath $pdf).Hash
        $changed=$original.Clone(); $changed[$field]='changed-value'
        Set-BindingConfig $changed
        $uploadsBefore=$script:uploads
        $result=@(Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue)
        Assert-BindingSafety ($script:uploads -eq $uploadsBefore -and @($result|Where-Object State -eq ManualReviewRequired).Count -eq 1) ('Changed binding reached upload: '+$field)
        Assert-BindingSafety ((Get-FileHash -LiteralPath $receipt).Hash -eq $before -and (Get-FileHash -LiteralPath $pdf).Hash -eq $pdfHash) 'Mismatched job evidence changed.'
        Assert-BindingSafety ((Get-NSPScanBridgeHealth -ConfigurationPath $config).InvalidReceiptCount -eq 1) 'Health missed destination mismatch.'
        Assert-BindingRejected {Save-NSPScanBridgeReceipt -PdfPath $pdf -State Uploading -Binding $changed} 'Receipt writer changed immutable binding.'
        Assert-BindingSafety ((Get-FileHash -LiteralPath $receipt).Hash -eq $before) 'Rejected binding write changed receipt.'
        Set-BindingConfig $original
        $delivered=@(Invoke-NSPScanBridge -ConfigurationPath $config)
        Assert-BindingSafety (@($delivered|Where-Object State -eq Delivered).Count -eq 1 -and $script:uploads -eq ($uploadsBefore+1)) ('Restored destination failed: field={0}; states={1}; uploads={2}; prior={3}' -f $field,($delivered.State -join ','),$script:uploads,$uploadsBefore)
    }
    # Review and interrupted Uploading jobs reject all changed bindings before readback.
    foreach($state in 'Review','Uploading') {
        $pdf=New-BoundJob $state
        $id=[IO.Path]::GetFileNameWithoutExtension($pdf)
        $receipt=[IO.Path]::ChangeExtension($pdf,'.json')
        $before=(Get-FileHash -LiteralPath $receipt).Hash
        foreach($field in 'RouteName','TenantId','ClientId','DriveId','FolderItemId') {
            $changed=$original.Clone(); $changed[$field]='changed-value'
            Set-BindingConfig $changed
            $lookupsBefore=$script:lookups; $downloadsBefore=$script:downloads
            Assert-BindingRejected {Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName $changed.RouteName -JobId $id} 'Mismatched reconciliation was accepted.'
            Assert-BindingSafety ($script:lookups -eq $lookupsBefore -and $script:downloads -eq $downloadsBefore -and (Get-FileHash -LiteralPath $receipt).Hash -eq $before) 'Mismatched reconciliation read remote bytes or changed evidence.'
        }
        Set-BindingConfig $original
        $uploadsBefore=$script:uploads
        $resolved=Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName RouteA -JobId $id
        Assert-BindingSafety ($resolved.Archived -and $script:uploads -eq $uploadsBefore) 'Bound reconciliation did not recover without replay.'
    }
    # Uploaded jobs and interrupted archive moves retain the same destination binding.
    foreach($afterMove in @($false,$true)) {
        $pdf=New-BoundJob Uploaded
        $receipt=[IO.Path]::ChangeExtension($pdf,'.json')
        $before=(Get-FileHash -LiteralPath $receipt).Hash
        $archivePdf=Join-Path $base ('archive\'+[IO.Path]::GetFileName($pdf))
        if($afterMove){[IO.File]::Move($pdf,$archivePdf)}
        $changed=$original.Clone(); $changed.DriveId='changed-drive'
        Set-BindingConfig $changed
        $uploadsBefore=$script:uploads
        $result=@(Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue)
        Assert-BindingSafety (@($result|Where-Object State -eq ManualReviewRequired).Count -eq 1 -and (Get-FileHash -LiteralPath $receipt).Hash -eq $before) 'Archive recovery ignored destination mismatch.'
        Set-BindingConfig $original
        $null=Invoke-NSPScanBridge -ConfigurationPath $config
        Assert-BindingSafety ($script:uploads -eq $uploadsBefore -and (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($archivePdf,'.json')))) 'Bound archive recovery replayed or failed.'
        Assert-BindingRejected {Complete-NSPScanBridgeArchive -PdfPath $pdf -ArchiveDirectory (Join-Path $base 'archive') -ExpectedBinding $changed} 'Already archived pair accepted wrong destination binding.'
    }
    # Valid-looking legacy state is never silently assigned the current destination.
    foreach($state in 'Queued','Uploading','Review','Uploaded') {
        $pdf=New-BoundJob $state
        $receipt=[IO.Path]::ChangeExtension($pdf,'.json')
        $legacy=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
        $legacy.Version=1; $legacy.PSObject.Properties.Remove('Destination')
        [IO.File]::WriteAllText($receipt,($legacy|ConvertTo-Json -Depth 5))
        $before=(Get-FileHash -LiteralPath $receipt).Hash; $uploadsBefore=$script:uploads; $lookupsBefore=$script:lookups
        $result=@(Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue)
        Assert-BindingSafety (@($result|Where-Object State -eq ManualReviewRequired).Count -eq 1 -and $script:uploads -eq $uploadsBefore) 'Legacy receipt was uploaded/archived automatically.'
        Assert-BindingSafety ((Get-NSPScanBridgeHealth -ConfigurationPath $config).InvalidReceiptCount -eq 1) 'Legacy receipt was reported valid.'
        Assert-BindingRejected {Save-NSPScanBridgeReceipt -PdfPath $pdf -State Review -Binding $original} 'Legacy receipt was silently upgraded.'
        Assert-BindingRejected {Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName RouteA -JobId ([IO.Path]::GetFileNameWithoutExtension($pdf))} 'Legacy receipt reached reconciliation.'
        Assert-BindingSafety ($script:lookups -eq $lookupsBefore -and (Get-FileHash -LiteralPath $receipt).Hash -eq $before -and (Test-Path -LiteralPath $pdf)) 'Legacy evidence changed or triggered remote lookup.'
        Remove-Item -LiteralPath $pdf,$receipt -Force
    }
    $pdf=New-BoundJob
    $receipt=[IO.Path]::ChangeExtension($pdf,'.json')
    $goodJson=[IO.File]::ReadAllText($receipt)
    foreach($field in 'RouteName','TenantId','ClientId','DriveId','FolderItemId') {
        $damaged=$goodJson|ConvertFrom-Json
        $damaged.Destination.$field=''
        [IO.File]::WriteAllText($receipt,($damaged|ConvertTo-Json -Depth 5))
        $before=(Get-FileHash -LiteralPath $receipt).Hash; $uploadsBefore=$script:uploads
        $result=@(Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue)
        Assert-BindingSafety (@($result|Where-Object State -eq ManualReviewRequired).Count -eq 1 -and $script:uploads -eq $uploadsBefore -and (Get-FileHash -LiteralPath $receipt).Hash -eq $before) 'Incomplete v2 binding was adopted or changed.'
    }
    [IO.File]::WriteAllText($receipt,$goodJson)
    $null=Invoke-NSPScanBridge -ConfigurationPath $config
    # Certificate rotation is allowed when tenant/application/destination stay fixed.
    [IO.File]::WriteAllBytes($source,[byte[]](37,80,68,70,45,49,46,52))
    (Get-Item -LiteralPath $source).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-2)
    $configText=[IO.File]::ReadAllText($config)
    [IO.File]::WriteAllText($config,$configText.Replace("TenantId='test-tenant'", "TenantId=''"))
    Assert-BindingRejected {Invoke-NSPScanBridge -ConfigurationPath $config -IntakeOnly} 'Unbound intake configuration was accepted.'
    Assert-BindingSafety (Test-Path -LiteralPath $source) 'Unbound intake claimed a document.'
    Set-BindingConfig $original
    $claim=@(Invoke-NSPScanBridge -ConfigurationPath $config -IntakeOnly)
    [IO.File]::WriteAllText($config,([IO.File]::ReadAllText($config).Replace("CertificateThumbprint='test-cert'","CertificateThumbprint='rotated-cert'")))
    $result=@(Invoke-NSPScanBridge -ConfigurationPath $config)
    Assert-BindingSafety (@($result|Where-Object State -eq Delivered).Count -eq 1) 'Certificate rotation changed destination binding.'
    Write-Host ('Passed: {0} destination binding, configuration drift and legacy receipt checks.' -f $script:checks)
} finally {
    $resolvedBase=[IO.Path]::GetFullPath($base)
    if(-not $resolvedBase.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedBase) -notmatch '^nsp-binding-safety-[0-9a-f]{32}$'){throw 'Unsafe cleanup path.'}
    if(Test-Path -LiteralPath $resolvedBase){Remove-Item -LiteralPath $resolvedBase -Recurse -Force}
}
