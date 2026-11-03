$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach ($folder in 'Private','Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $folder) -Filter '*.ps1' -File) { . $file.FullName }
}
$state=@{ Checks=0; Imports=0; Connections=0; Uploads=0; Mail=0; Lookups=0; Mode='Supported'; Scope='Process'; AuthType='AppOnly'; ClientId='test-app'; TenantId='test-tenant' }
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $state.Checks++ }
function Rejected([scriptblock]$Action) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed 'Expected adapter/context rejection.' }
function Connect-SyntheticApproved {
    [CmdletBinding()]param($TenantId,$ClientId,$CertificateThumbprint,[ValidateSet('Process','CurrentUser')]$ContextScope)
    $state.Connections++
    Check ($ContextScope -eq 'Process') 'Adapter failed to explicitly request Process.'
    Check ($TenantId -eq 'test-tenant' -and $ClientId -eq 'test-app' -and $CertificateThumbprint -eq 'test-cert') 'Adapter identity changed.'
}
function Connect-SyntheticOld { [CmdletBinding()]param($TenantId,$ClientId,$CertificateThumbprint) $state.Connections++; throw 'Old connector invoked.' }
function Connect-NSPGraphAppOnly { throw 'Unselected global connector invoked.' }
function Import-Module {
    [CmdletBinding()]param([string]$Name,[version]$MinimumVersion,[switch]$PassThru)
    Check ($Name -eq 'NSP.M365.Graph' -and $PassThru) 'Adapter did not select a module in its scope.'
    Check ($MinimumVersion -eq [version]'0.1.2') 'Adapter did not require the ContextScope connector version.'
    $state.Imports++
    if ($state.Mode -eq 'Missing') { throw 'Synthetic missing dependency.' }
    $commands=@{}
    if ($state.Mode -ne 'NoExport') {
        $commands['Connect-NSPGraphAppOnly']=if ($state.Mode -eq 'Old') { Get-Command Connect-SyntheticOld } else { Get-Command Connect-SyntheticApproved }
    }
    if ($state.Mode -eq 'Ambiguous') {
        [pscustomobject]@{Name='NSP.M365.Graph';ExportedCommands=$commands}
    }
    [pscustomobject]@{Name='NSP.M365.Graph';ExportedCommands=$commands}
}
function Get-MgContext {
    [CmdletBinding()]param()
    if ($state.Mode -eq 'NullContext') { return $null }
    @{AuthType=$state.AuthType; TenantId=$state.TenantId; ClientId=$state.ClientId; ContextScope=$state.Scope}
}
function Send-NSPScanBridgeUploadSession { $state.Uploads++; throw 'Unexpected upload.' }
function Send-NSPGraphMail { $state.Mail++; throw 'Unexpected mail.' }
function Test-NSPScanBridgeRemoteMatch { param($PdfPath,$DriveId,$FolderItemId) $state.Lookups++; @{Status='NotFound'} }
function Invoke-NSPGraphRequest { throw 'Network forbidden.' }
function Invoke-WebRequest { throw 'Network forbidden.' }
function Invoke-RestMethod { throw 'Network forbidden.' }
$auth=@{TenantId='test-tenant';ClientId='test-app';CertificateThumbprint='test-cert'}
Connect-NSPScanBridgeContext -Auth $auth
Check ($state.Connections -eq 1 -and $state.Imports -eq 1) 'Supported adapter did not connect once.'
$before=$state.Connections
Assert-NSPScanBridgeContext -Auth $auth
Check ($state.Connections -eq $before) 'Validation attempted connection.'
foreach ($scope in @('CurrentUser','Unknown',$null)) {
    $state.Scope=$scope
    Rejected { Assert-NSPScanBridgeContext -Auth $auth }
}
$state.Scope='Process'
foreach ($field in 'TenantId','ClientId','AuthType') {
    $prior=$state[$field]; $state[$field]='wrong'
    Rejected { Connect-NSPScanBridgeContext -Auth $auth }
    $state[$field]=$prior
}
$state.Scope='CurrentUser'
Rejected { Connect-NSPScanBridgeContext -Auth $auth }
$state.Scope='Process'; $state.Mode='NullContext'
Rejected { Connect-NSPScanBridgeContext -Auth $auth }
$state.Mode='Supported'
$before=$state.Imports
Rejected { Connect-NSPScanBridgeContext -Auth @{TenantId='test-tenant'} }
Check ($state.Imports -eq $before) 'Incomplete identity reached import.'

$base=Join-Path ([IO.Path]::GetTempPath()) ('nsp-context-adapter-'+[guid]::NewGuid().ToString('N'))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if (-not ([IO.Path]::GetFullPath($base).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe fixture root.' }
try {
    foreach ($name in 'source','spool','archive','lock','alerts') { [void][IO.Directory]::CreateDirectory((Join-Path $base $name)) }
    $source=Join-Path $base 'source/synthetic.pdf'
    [IO.File]::WriteAllBytes($source,[byte[]](37,80,68,70,45,49,46,52,10,37,37,69,79,70,10))
    (Get-Item -LiteralPath $source).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-2)
    $hash=(Get-FileHash -LiteralPath $source).Hash
    $config=Join-Path $base 'synthetic.psd1'; $safeBase=$base.Replace("'","''")
    [IO.File]::WriteAllText($config,@"
@{
 Auth=@{TenantId='test-tenant';ClientId='test-app';CertificateThumbprint='test-cert'}
 LockPath='$safeBase\lock\worker.lock'
 Routes=@(@{Name='RouteA';Source='$safeBase\source';Spool='$safeBase\spool';Archive='$safeBase\archive';DriveId='test-drive';FolderItemId='test-folder';MinimumAgeSeconds=1})
 Alerts=@{Enabled=`$true;From='monitor@example.invalid';To='dispatch@example.invalid';StateDirectory='$safeBase\alerts';Auth=@{TenantId='test-tenant';ClientId='test-app';CertificateThumbprint='test-cert'}}
}
"@)
    foreach ($mode in 'Missing','Old','NoExport','Ambiguous') {
        $state.Mode=$mode; $before=$state.Connections
        Rejected { Invoke-NSPScanBridge -ConfigurationPath $config }
        Check ($state.Connections -eq $before) 'Unsupported dependency reached authentication.'
        Check ((Test-Path -LiteralPath $source) -and (Get-FileHash -LiteralPath $source).Hash -eq $hash) 'Unsupported dependency claimed/changed source.'
        Check (@(Get-ChildItem -LiteralPath (Join-Path $base 'spool') -File).Count -eq 0) 'Unsupported dependency wrote spool.'
        Rejected { Send-NSPScanBridgeAlert -ConfigurationPath $config }
        Check ($state.Connections -eq $before -and $state.Mail -eq 0) 'Alert authenticated or sent with unsupported dependency.'
    }
    $state.Mode='Supported'; $state.Scope='CurrentUser'
    Rejected { Invoke-NSPScanBridge -ConfigurationPath $config }
    Check ((Test-Path -LiteralPath $source) -and (Get-FileHash -LiteralPath $source).Hash -eq $hash) 'Wrong returned scope claimed source.'
    Rejected { Send-NSPScanBridgeAlert -ConfigurationPath $config }
    Check ($state.Mail -eq 0) 'Wrong scope reached mail.'
    $state.Scope='Process'
    # Intake and WhatIf retain their existing no-authentication contracts.
    $before=$state.Imports
    Invoke-NSPScanBridge -ConfigurationPath $config -WhatIf | Out-Null
    Send-NSPScanBridgeAlert -ConfigurationPath $config -WhatIf -WarningAction SilentlyContinue | Out-Null
    Check ($state.Imports -eq $before -and (Test-Path -LiteralPath $source)) 'WhatIf imported/authenticated/claimed.'
    Invoke-NSPScanBridge -ConfigurationPath $config -IntakeOnly | Out-Null
    Check ($state.Imports -eq $before -and -not (Test-Path -LiteralPath $source)) 'IntakeOnly imported/authenticated or failed to claim.'
    $pdf=Get-ChildItem -LiteralPath (Join-Path $base 'spool') -Filter '*.pdf' -File | Select-Object -First 1
    $binding=@{RouteName='RouteA';TenantId='test-tenant';ClientId='test-app';DriveId='test-drive';FolderItemId='test-folder'}
    Save-NSPScanBridgeReceipt -PdfPath $pdf.FullName -State Review -Binding $binding
    $receipt=[IO.Path]::ChangeExtension($pdf.FullName,'.json')
    $receiptHash=(Get-FileHash -LiteralPath $receipt).Hash
    $connectionsBefore=$state.Connections
    $state.Scope='CurrentUser'
    Rejected { Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName RouteA -JobId $pdf.BaseName }
    Check ($state.Lookups -eq 0 -and (Get-FileHash -LiteralPath $receipt).Hash -eq $receiptHash -and (Get-FileHash -LiteralPath $pdf.FullName).Hash -eq $hash) 'Reconciliation with wrong scope touched evidence/readback.'
    $state.Scope='Process'
    $result=Resolve-NSPScanBridgeJob -ConfigurationPath $config -RouteName RouteA -JobId $pdf.BaseName
    Check ($result.Status -eq 'NotFound' -and -not $result.Archived -and $state.Lookups -eq 1) 'Reconciliation did not accept externally established Process context.'
    Check ($state.Imports -eq $before -and $state.Connections -eq $connectionsBefore) 'Reconciliation imported or reconnected.'
    Check ($state.Uploads -eq 0 -and $state.Mail -eq 0) 'Unexpected outbound operation.'
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

# Real module resolution in a child process: an older synthetic Graph earlier on PSModulePath
# must be skipped for the supporting version, not loaded because it is found first.
$paths=Join-Path ([IO.Path]::GetTempPath()) ('nsp-context-paths-'+[guid]::NewGuid().ToString('N'))
if (-not ([IO.Path]::GetFullPath($paths).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe fixture root.' }
try {
    $graphs=@{
        '0.1.0'='function Connect-NSPGraphAppOnly { [CmdletBinding()]param($TenantId,$ClientId,$CertificateThumbprint) throw ''Old synthetic connector invoked.'' }
function Get-MgContext { $null }'
        '0.1.2'='function Connect-NSPGraphAppOnly { [CmdletBinding()]param($TenantId,$ClientId,$CertificateThumbprint,$ContextScope) $script:Context=@{AuthType=''AppOnly'';TenantId=$TenantId;ClientId=$ClientId;ContextScope=$ContextScope} }
function Get-MgContext { [CmdletBinding()]param() $script:Context }'
    }
    $folders=@{ '0.1.0'='first'; '0.1.2'='second' }
    foreach ($version in $graphs.Keys) {
        $moduleBase=Join-Path $paths ('{0}\NSP.M365.Graph\{1}' -f $folders[$version],$version)
        [void][IO.Directory]::CreateDirectory($moduleBase)
        [IO.File]::WriteAllText((Join-Path $moduleBase 'NSP.M365.Graph.psm1'),$graphs[$version])
        New-ModuleManifest -Path (Join-Path $moduleBase 'NSP.M365.Graph.psd1') -RootModule 'NSP.M365.Graph.psm1' -ModuleVersion $version -FunctionsToExport 'Connect-NSPGraphAppOnly','Get-MgContext'
    }
    $probe=Join-Path $paths 'probe.ps1'
    [IO.File]::WriteAllText($probe,@'
param([string]$Manifest,[string]$ModulePath)
$ErrorActionPreference='Stop'
$env:PSModulePath=$ModulePath+';'+(Join-Path $PSHOME 'Modules')
$module=Import-Module $Manifest -PassThru
& $module {
    Connect-NSPScanBridgeContext -Auth @{TenantId='test-tenant';ClientId='test-app';CertificateThumbprint='test-cert'}
    (Get-Module NSP.M365.Graph).Version.ToString()
}
'@)
    $hostPath=(Get-Process -Id $PID).Path
    $resolved=& $hostPath -NoProfile -NonInteractive -File $probe -Manifest (Join-Path $root 'NSP.ScanBridge.psd1') -ModulePath ((Join-Path $paths 'first')+';'+(Join-Path $paths 'second'))
    Check ($LASTEXITCODE -eq 0 -and [string]$resolved -eq '0.1.2') 'Adapter loaded an older Graph found earlier on PSModulePath.'
    # Expected child failure: Windows PowerShell 5.1 turns its redirected stderr into a terminating error under Stop.
    & { $ErrorActionPreference='Continue'; & $hostPath -NoProfile -NonInteractive -File $probe -Manifest (Join-Path $root 'NSP.ScanBridge.psd1') -ModulePath (Join-Path $paths 'first') 2>&1 | Out-Null }
    Check ($LASTEXITCODE -ne 0) 'Adapter accepted a Graph below the supporting version.'
} finally {
    Remove-Item -LiteralPath $paths -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ('Passed: {0} ScanBridge context-adapter checks; all imports/authentication/transports synthetic.' -f $state.Checks)
