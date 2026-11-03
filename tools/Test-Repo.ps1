$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Test-Parsing.ps1')
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
        [IO.File]::WriteAllBytes($temp, [byte[]](37,80,68,70,45,49,46,52,10,37,37,69,79,70,10))
        if (Test-NSPScanBridgeFileReady -Path $temp -MinimumAgeSeconds 1) { throw 'Fresh file passed readiness unexpectedly.' }
        (Get-Item -LiteralPath $temp).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        if (-not (Test-NSPScanBridgeFileReady -Path $temp -MinimumAgeSeconds 1)) { throw 'Old stable file failed readiness.' }
        # A cancelled direct-write scan: aged and unlocked, but without its end-of-file marker.
        [IO.File]::WriteAllBytes($temp, [Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n1 0 obj`n" + ('%' + ('X' * 1500) + "`n") * 3))
        (Get-Item -LiteralPath $temp).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        if (Test-NSPScanBridgeFileReady -Path $temp -MinimumAgeSeconds 1) { throw 'Truncated PDF passed readiness unexpectedly.' }
        [IO.File]::WriteAllBytes($temp, [Text.Encoding]::ASCII.GetBytes(('X' * 2048) + "%PDF-1.4`n%%EOF`n"))
        (Get-Item -LiteralPath $temp).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        if (Test-NSPScanBridgeFileReady -Path $temp -MinimumAgeSeconds 1) { throw 'PDF without a leading header passed readiness unexpectedly.' }
        [IO.File]::WriteAllBytes($temp, [Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n%%EOF`n" + (' ' * 900)))
        (Get-Item -LiteralPath $temp).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        if (-not (Test-NSPScanBridgeFileReady -Path $temp -MinimumAgeSeconds 1)) { throw 'Trailing whitespace after end-of-file marker failed readiness.' }
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

& (Join-Path $PSScriptRoot 'Test-Intake.ps1')

& (Join-Path $PSScriptRoot 'Test-IncompleteSource.ps1')

& (Join-Path $PSScriptRoot 'Test-UploadSession.ps1')

& (Join-Path $PSScriptRoot 'Test-Receipts.ps1')

& (Join-Path $PSScriptRoot 'Test-ArchiveRecovery.ps1')

& (Join-Path $PSScriptRoot 'Test-RetryPolicy.ps1')

& (Join-Path $PSScriptRoot 'Test-Alerting.ps1')

& (Join-Path $PSScriptRoot 'Test-FailureEscalation.ps1')

& (Join-Path $PSScriptRoot 'Test-CertificateAlerts.ps1')

& (Join-Path $PSScriptRoot 'Test-MultiChunk.ps1')

& (Join-Path $PSScriptRoot 'Test-SessionRetry.ps1')

& (Join-Path $PSScriptRoot 'Test-RemoteReconciliation.ps1')

& (Join-Path $PSScriptRoot 'Test-ResolveJob.ps1')

& (Join-Path $PSScriptRoot 'Test-Stabilization.ps1')

& (Join-Path $PSScriptRoot 'Test-UploadSafety.ps1')
& (Join-Path $PSScriptRoot 'Test-Runners.ps1')

& (Join-Path $PSScriptRoot 'Test-RouteSafety.ps1')

& (Join-Path $PSScriptRoot 'Test-DestinationBinding.ps1')

& (Join-Path $PSScriptRoot 'Test-ContextAdapter.ps1')

& (Join-Path $PSScriptRoot 'Test-ReadinessDiagnostic.ps1')
