$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$base = Join-Path ([IO.Path]::GetTempPath()) ('nsp-runner-safety-' + [guid]::NewGuid().ToString('N'))
$resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($base).StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe fixture root.' }
$priorModulePath = $env:PSModulePath
$priorMode = $env:NSP_SCANBRIDGE_TEST_MODE
$hostExecutable = (Get-Process -Id $PID).Path
try {
    $fakeModule = Join-Path $base 'modules\NSP.ScanBridge'
    [void][IO.Directory]::CreateDirectory($fakeModule)
    [IO.File]::WriteAllText((Join-Path $fakeModule 'NSP.ScanBridge.psd1'), "@{ RootModule='NSP.ScanBridge.psm1'; ModuleVersion='99.0.0'; GUID='9ff32db2-de28-4438-9525-778832da142b'; FunctionsToExport=@('*') }")
    [IO.File]::WriteAllText((Join-Path $fakeModule 'NSP.ScanBridge.psm1'), @'
function Invoke-NSPScanBridge {
    [CmdletBinding()]param($ConfigurationPath,[switch]$IntakeOnly)
    switch ($env:NSP_SCANBRIDGE_TEST_MODE) {
        WorkerFailure { throw 'Synthetic private worker detail.' }
        Held { [pscustomobject]@{ Route='RouteA'; State='ManualReviewRequired' }; return }
        Pending { [pscustomobject]@{ Route='RouteA'; State='PendingReviewOrRetry' }; return }
    }
    [pscustomobject]@{ Route='RouteA'; State='Delivered' }
}
function Test-NSPScanBridgeHealth {
    [CmdletBinding()]param($ConfigurationPath,$MaximumPending,$MaximumPendingMinutes)
    if ($env:NSP_SCANBRIDGE_TEST_MODE -eq 'HealthFailure') { throw 'Synthetic private health detail.' }
    if ($env:NSP_SCANBRIDGE_TEST_MODE -eq 'EmptyHealth') { return }
    [pscustomobject]@{ Route='RouteA'; Healthy=($env:NSP_SCANBRIDGE_TEST_MODE -ne 'Held'); Conditions=@('ManualReview'); PendingCount=1; OldestPendingMinutes=1 }
}
function Send-NSPScanBridgeAlert {
    [CmdletBinding()]param($ConfigurationPath,$MaximumPending,$MaximumPendingMinutes,[switch]$WorkerFailed,[switch]$WorkerSucceeded)
    if ($env:NSP_SCANBRIDGE_TEST_MODE -eq 'AlertFailure') { throw 'Synthetic private alert detail.' }
}
'@)
    $config = Join-Path $base 'config.psd1'
    [IO.File]::WriteAllText($config,'@{ Alerts=@{ Enabled=$true } }')
    $env:PSModulePath = (Join-Path $base 'modules') + [IO.Path]::PathSeparator + $priorModulePath
    $cases = @(
        @('Run-ScanBridge.ps1','Healthy',0), @('Run-ScanBridge.ps1','WorkerFailure',2),
        @('Run-ScanBridge.ps1','Held',2), @('Run-ScanBridge.ps1','Pending',2), @('Run-ScanBridge.ps1','AlertFailure',3),
        @('Test-ScanBridgeHealth.ps1','Healthy',0), @('Test-ScanBridgeHealth.ps1','Held',2),
        @('Test-ScanBridgeHealth.ps1','HealthFailure',3), @('Test-ScanBridgeHealth.ps1','EmptyHealth',3),
        @('Send-ScanBridgeAlerts.ps1','Healthy',0), @('Send-ScanBridgeAlerts.ps1','AlertFailure',3)
    )
    foreach ($case in $cases) {
        $env:NSP_SCANBRIDGE_TEST_MODE = $case[1]
        $runner = Join-Path $root ('scripts/' + $case[0])
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $hostExecutable
        $processInfo.Arguments = '-NoProfile -File "' + $runner + '" -ConfigurationPath "' + $config + '"'
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($processInfo)
        try {
            $output = $process.StandardOutput.ReadToEnd()
            $errorText = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        } finally { $process.Dispose() }
        if ($exitCode -ne $case[2]) { throw ('Runner exit mismatch: {0}/{1}, got {2}, expected {3}' -f $case[0],$case[1],$exitCode,$case[2]) }
        if (($output -join "`n") -match 'Synthetic private' -or $errorText -match 'Synthetic private') { throw 'Runner leaked raw exception detail.' }
    }
    Write-Host ('Passed: {0} runner exit and sanitized-output scenarios using an isolated fake module.' -f $cases.Count)
} finally {
    $env:PSModulePath = $priorModulePath
    $env:NSP_SCANBRIDGE_TEST_MODE = $priorMode
    $resolvedBase = [IO.Path]::GetFullPath($base)
    if (-not $resolvedBase.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedBase) -notmatch '^nsp-runner-safety-[0-9a-f]{32}$') { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolvedBase) { Remove-Item -LiteralPath $resolvedBase -Recurse -Force }
}
