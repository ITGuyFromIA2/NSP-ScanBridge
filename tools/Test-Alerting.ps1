$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $root 'NSP.ScanBridge.psd1') -Force -PassThru
try {
    if (-not $module.ExportedFunctions.ContainsKey('Send-NSPScanBridgeAlert')) { throw 'Escalation function not exported.' }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('nsp-alert-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $config = Join-Path $temp 'test.psd1'
        Set-Content -LiteralPath $config -Value '@{ Alerts = @{ Enabled = $false }; Routes = @() }'
        $failed = $false
        try { Send-NSPScanBridgeAlert -ConfigurationPath $config -ErrorAction Stop } catch { $failed = $true }
        if (-not $failed) { throw 'Disabled alerting did not fail closed.' }
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
    Write-Host 'Passed: alert export and disabled-by-default guard.'
} finally { Remove-Module $module.Name -Force -ErrorAction SilentlyContinue }
