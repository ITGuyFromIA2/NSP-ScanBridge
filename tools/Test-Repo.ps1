$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $root 'NSP.ScanBridge.psd1'
$moduleInfo = Test-ModuleManifest -Path $manifest -ErrorAction Stop
$module = Import-Module $manifest -Force -PassThru -ErrorAction Stop
try {
    $expected = @(Get-ChildItem -Path (Join-Path $root 'Public') -Filter '*.ps1' -File | ForEach-Object BaseName | Sort-Object)
    $actual = @($module.ExportedFunctions.Keys | Sort-Object)
    if (($expected -join ',') -ne ($actual -join ',')) { throw 'Manifest exports and Public function files differ.' }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('NSP-ScanBridge-' + [guid]::NewGuid().ToString('N') + '.pdf')
    try {
        [IO.File]::WriteAllBytes($temp, [byte[]](37,80,68,70,45,49,46,52))
        if (Test-NSPScanBridgeFileReady -Path $temp -MinimumAgeSeconds 1) { throw 'Fresh file passed readiness unexpectedly.' }
        (Get-Item -LiteralPath $temp).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        if (-not (Test-NSPScanBridgeFileReady -Path $temp -MinimumAgeSeconds 1)) { throw 'Old stable file failed readiness.' }
        $stream = [IO.File]::Open($temp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            if (Test-NSPScanBridgeFileReady -Path $temp -MinimumAgeSeconds 1) { throw 'Locked file passed readiness unexpectedly.' }
        }
        finally { $stream.Dispose() }
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    Write-Host "Passed: $($moduleInfo.Name) manifest, exports, file readiness."
}
finally { Remove-Module $module.Name -Force -ErrorAction SilentlyContinue }
