[CmdletBinding()]
param([ValidateSet('All','Routing','Orphans')][string]$Case = 'All')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($directory in 'Private','Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.ps1' -File) { . $file.FullName }
}
$script:checks = 0
function Assert-Safety([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Import-Module { param($Name,[switch]$PassThru,$ErrorAction) if ($Name -ne 'NSP.M365.Graph') { throw 'Unexpected import.' }; if ($PassThru) { [pscustomobject]@{Name='NSP.M365.Graph';ExportedCommands=@{'Connect-NSPGraphAppOnly'=(Get-Command Connect-NSPGraphAppOnly)}} } }
function Connect-NSPGraphAppOnly { param($TenantId,$ClientId,$CertificateThumbprint,$ContextScope,$ErrorAction) }
function Get-MgContext { param($ErrorAction) @{ AuthType='AppOnly'; ContextScope='Process'; TenantId='test-tenant'; ClientId='test-app' } }
$script:uploads = 0
function Send-NSPScanBridgeUploadSession {
    param($Path,$DriveId,$FolderItemId,$Name)
    $script:uploads++
    @{ id='synthetic'; size=(Get-Item -LiteralPath $Path).Length }
}
function Invoke-NSPGraphRequest { throw 'Network forbidden.' }
function Invoke-WebRequest { throw 'Network forbidden.' }
function Invoke-RestMethod { throw 'Network forbidden.' }
$base = Join-Path ([IO.Path]::GetTempPath()) ('nsp-route-safety-' + [guid]::NewGuid().ToString('N'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($base).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe fixture root.' }
$priorModulePath = $env:PSModulePath
try {
    foreach ($name in 'sourceA','sourceB','spoolA','spoolB','archiveA','archiveB','lock') { [void][IO.Directory]::CreateDirectory((Join-Path $base $name)) }
    $safeBase = $base.Replace("'","''")
    $routeA = "@{ Name='RouteA'; Source='$safeBase\sourceA'; Spool='$safeBase\spoolA'; Archive='$safeBase\archiveA'; DriveId='destination-A'; FolderItemId='folder-A'; MinimumAgeSeconds=1 }"
    $routeB = "@{ Name='RouteB'; Source='$safeBase\sourceB'; Spool='$safeBase\spoolB'; Archive='$safeBase\archiveB'; DriveId='destination-B'; FolderItemId='folder-B'; MinimumAgeSeconds=1 }"
    $config = Join-Path $base 'synthetic.psd1'
    function Set-TestConfig([string[]]$RouteText) {
        $text = "@{ LockPath='$safeBase\lock\worker.lock'; Auth=@{ TenantId='test-tenant'; ClientId='test-app'; CertificateThumbprint='test-cert' }; Alerts=@{ Enabled=`$false }; Routes=@(" + ($RouteText -join ',') + ') }'
        [IO.File]::WriteAllText($config,$text)
    }
    function New-SourcePdf([string]$Directory) {
        $pdf = Join-Path $base ($Directory + '\synthetic.pdf')
        [IO.File]::WriteAllBytes($pdf,[byte[]](37,80,68,70,45,49,46,52,10,37,37,69,79,70,10))
        (Get-Item -LiteralPath $pdf).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-2)
        $pdf
    }
    if ($Case -in @('All','Routing')) {
        Set-TestConfig @($routeB)
        $sourceB = New-SourcePdf sourceB
        $claim = @(Invoke-NSPScanBridge -ConfigurationPath $config -IntakeOnly)
        Assert-Safety ($claim.Count -eq 1 -and $claim[0].Route -eq 'RouteB') 'Could not seed RouteB queued job.'
        $queued = Join-Path $base ('spoolB\' + $claim[0].JobId + '.pdf')
        $receipt = [IO.Path]::ChangeExtension($queued,'.json')
        $pdfHash = (Get-FileHash -LiteralPath $queued).Hash
        $receiptHash = (Get-FileHash -LiteralPath $receipt).Hash
        $sourceA = New-SourcePdf sourceA
        $sourceHash = (Get-FileHash -LiteralPath $sourceA).Hash
        $nestedSpool = Join-Path $base 'sourceA\nested-spool'
        [void][IO.Directory]::CreateDirectory($nestedSpool)
        $invalidRoutes = @(
            @($routeA.Replace("Spool='$safeBase\spoolA'","Spool='$safeBase\spoolB'"),$routeB),
            @($routeA,$routeB.Replace("Source='$safeBase\sourceB'","Source='$safeBase\spoolA'")),
            @($routeA,$routeB.Replace("Archive='$safeBase\archiveB'","Archive='$safeBase\archiveA\'")),
            @($routeA,$routeB.Replace("Source='$safeBase\sourceB'","Source='$safeBase\sourceA'")),
            @($routeA,$routeB.Replace("Spool='$safeBase\spoolB'","Spool='$safeBase\sourceA\nested-spool'")),
            @($routeA,$routeB.Replace("Name='RouteB'","Name='routea'")),
            @($routeA,$routeB.Replace("; FolderItemId='folder-B'",'')),
            @($routeA,$routeB.Replace('MinimumAgeSeconds=1','MinimumAgeSeconds=0'))
        )
        foreach ($routes in $invalidRoutes) {
            Set-TestConfig $routes
            $rejected = $false
            try { Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue | Out-Null } catch { $rejected=$true }
            Assert-Safety ($rejected -and $script:uploads -eq 0) 'Conflicting/invalid routes reached upload instead of failing preflight.'
            Assert-Safety ((Test-Path -LiteralPath $sourceA) -and (Get-FileHash -LiteralPath $sourceA).Hash -eq $sourceHash) 'Preflight failure claimed an earlier route source.'
            Assert-Safety ((Test-Path -LiteralPath $queued) -and (Get-FileHash -LiteralPath $queued).Hash -eq $pdfHash -and (Get-FileHash -LiteralPath $receipt).Hash -eq $receiptHash) 'Preflight failure changed queued RouteB evidence.'
        }
        Set-TestConfig @($routeA,$routeB)
        $good = @(Invoke-NSPScanBridge -ConfigurationPath $config)
        Assert-Safety (@($good | Where-Object State -eq Delivered).Count -eq 2 -and $script:uploads -eq 2) 'Distinct valid routes failed delivery.'
        Assert-Safety ((Test-Path -LiteralPath (Join-Path $base ('archiveB\' + $claim[0].JobId + '.pdf'))) -and -not (Test-Path -LiteralPath (Join-Path $base ('archiveA\' + $claim[0].JobId + '.pdf')))) 'RouteB job archived under wrong route.'
    }
    if ($Case -in @('All','Orphans')) {
        Set-TestConfig @($routeA)
        $fakeModule = Join-Path $base 'modules\NSP.ScanBridge'
        [void][IO.Directory]::CreateDirectory($fakeModule)
        $moduleText = @'
foreach ($directory in 'Private','Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path '__SOURCE__' $directory) -Filter '*.ps1' -File) { . $file.FullName }
}
function Import-Module { param($Name,[switch]$PassThru,$ErrorAction) if ($Name -ne 'NSP.M365.Graph') { throw 'Unexpected import.' }; if ($PassThru) { [pscustomobject]@{Name='NSP.M365.Graph';ExportedCommands=@{'Connect-NSPGraphAppOnly'=(Get-Command Connect-NSPGraphAppOnly)}} } }
function Connect-NSPGraphAppOnly { param($TenantId,$ClientId,$CertificateThumbprint,$ContextScope,$ErrorAction) }
function Get-MgContext { param($ErrorAction) @{ AuthType='AppOnly'; ContextScope='Process'; TenantId='test-tenant'; ClientId='test-app' } }
function Send-NSPScanBridgeUploadSession { throw 'Unexpected upload.' }
function Invoke-NSPGraphRequest { throw 'Network forbidden.' }
function Invoke-WebRequest { throw 'Network forbidden.' }
function Invoke-RestMethod { throw 'Network forbidden.' }
Export-ModuleMember -Function Invoke-NSPScanBridge,Test-NSPScanBridgeHealth
'@
        [IO.File]::WriteAllText((Join-Path $fakeModule 'NSP.ScanBridge.psm1'),$moduleText.Replace('__SOURCE__',$root.Replace("'","''")))
        $env:PSModulePath = (Join-Path $base 'modules') + [IO.Path]::PathSeparator + $priorModulePath
        $hostExecutable = (Get-Process -Id $PID).Path
        function Invoke-ActualRunner([bool]$SkipAlerts) {
            $processInfo = New-Object Diagnostics.ProcessStartInfo
            $processInfo.FileName=$hostExecutable
            $processInfo.Arguments='-NoProfile -File "' + (Join-Path $root 'scripts/Run-ScanBridge.ps1') + '" -ConfigurationPath "' + $config + '"' + $(if($SkipAlerts){' -SkipAlerts'}else{''})
            $processInfo.UseShellExecute=$false; $processInfo.CreateNoWindow=$true
            $processInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
            $processInfo.RedirectStandardOutput=$true; $processInfo.RedirectStandardError=$true
            $process=[Diagnostics.Process]::Start($processInfo)
            try {
                $output=$process.StandardOutput.ReadToEnd(); $errorText=$process.StandardError.ReadToEnd()
                $process.WaitForExit()
                [pscustomobject]@{ Exit=$process.ExitCode; Output=$output; ErrorText=$errorText }
            } finally { $process.Dispose() }
        }
        foreach ($entryName in @(([guid]::NewGuid().ToString('N') + '.json'),'unknown-sensitive-name.pdf','unknown-sensitive-name.json')) {
            $entry = Join-Path $base ('spoolA\' + $entryName)
            [IO.File]::WriteAllText($entry,'{}')
            $entryHash=(Get-FileHash -LiteralPath $entry).Hash
            $result=@(Invoke-NSPScanBridge -ConfigurationPath $config -WarningAction SilentlyContinue)
            $skipResult=Invoke-ActualRunner $true
            $disabledResult=Invoke-ActualRunner $false
            Assert-Safety (@($result | Where-Object State -eq ManualReviewRequired).Count -ge 1 -and $skipResult.Exit -eq 2 -and $disabledResult.Exit -eq 2) ('Worker/runner missed orphan or unknown spool entry; results={0}, skip-exit={1}, disabled-exit={2}' -f $result.Count,$skipResult.Exit,$disabledResult.Exit)
            Assert-Safety ((Get-FileHash -LiteralPath $entry).Hash -eq $entryHash) 'Held spool evidence was changed.'
            Assert-Safety (($skipResult.Output + $skipResult.ErrorText + $disabledResult.Output + $disabledResult.ErrorText) -notmatch 'unknown-sensitive-name') 'Runner exposed unknown spool filename.'
            Remove-Item -LiteralPath $entry -Force
        }
        $clean=Invoke-ActualRunner $true
        Assert-Safety ($clean.Exit -eq 0) 'Empty valid spool should return success.'
    }
    Write-Host ('Passed: {0} route isolation and actual worker/runner checks ({1}).' -f $script:checks,$Case)
} finally {
    $env:PSModulePath=$priorModulePath
    $resolvedBase=[IO.Path]::GetFullPath($base)
    if (-not $resolvedBase.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedBase) -notmatch '^nsp-route-safety-[0-9a-f]{32}$') { throw 'Unsafe cleanup path.' }
    if(Test-Path -LiteralPath $resolvedBase) { Remove-Item -LiteralPath $resolvedBase -Recurse -Force }
}
