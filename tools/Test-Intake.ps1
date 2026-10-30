$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'NSP.ScanBridge.psd1') -Force -ErrorAction Stop
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('NSPScanBridge-' + [guid]::NewGuid().ToString('N'))
$folders = @('source','spool','archive','lock')
try {
    foreach ($folder in $folders) { New-Item -ItemType Directory -Path (Join-Path $testRoot $folder) -Force | Out-Null }
    $pdf = Join-Path $testRoot 'source\synthetic.pdf'
    [IO.File]::WriteAllBytes($pdf, [byte[]](37,80,68,70,45,49,46,52,10))
    (Get-Item -LiteralPath $pdf).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
    $configPath = Join-Path $testRoot 'config.psd1'
    $safeRoot = $testRoot.Replace("'", "''")
    $configText = @"
@{
 LockPath = '$safeRoot\lock\worker.lock'
 Routes = @(
  @{
   Name = 'Test'
   Source = '$safeRoot\source'
   Spool = '$safeRoot\spool'
   Archive = '$safeRoot\archive'
   DriveId = 'test-drive'
   FolderItemId = 'test-folder'
   MinimumAgeSeconds = 1
  }
 )
}
"@
    [IO.File]::WriteAllText($configPath, $configText)
    $result = @(Invoke-NSPScanBridge -ConfigurationPath $configPath -IntakeOnly)
    if ($result.Count -ne 1 -or $result[0].State -ne 'Queued') { throw 'Expected exactly one queued job.' }
    if (Test-Path -LiteralPath $pdf) { throw 'Source was not moved to spool.' }
    $spoolFiles = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'spool') -Filter '*.pdf' -File)
    if ($spoolFiles.Count -ne 1 -or $spoolFiles[0].Name -cnotmatch '^[0-9a-f]{32}\.pdf$') { throw 'Opaque spool name missing.' }
    $health = @(Get-NSPScanBridgeHealth -ConfigurationPath $configPath)
    if ($health.Count -ne 1 -or $health[0].PendingCount -ne 1 -or $health[0].SourceCount -ne 0 -or $health[0].QueuedCount -ne 1 -or $health[0].ReviewCount -ne 0) { throw 'Health snapshot did not reflect the queued job.' }
    $receiptPath = [IO.Path]::ChangeExtension($spoolFiles[0].FullName, '.json')
    if (-not (Test-Path -LiteralPath $receiptPath)) { throw 'Missing persistent receipt.' }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.State -ne 'Queued' -or $receipt.Hash -ne (Get-FileHash $spoolFiles[0].FullName -Algorithm SHA256).Hash) {
        throw 'Receipt does not match queued PDF.'
    }
    $again = @(Invoke-NSPScanBridge -ConfigurationPath $configPath -IntakeOnly)
    if ($again.Count -ne 0) { throw 'Second pass unexpectedly claimed another job.' }
    if (-not (Test-Path -LiteralPath $spoolFiles[0].FullName)) { throw 'Second pass lost the queued PDF.' }
    Write-Host 'Passed: isolated intake, collision-safe spool naming, and repeat pass.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
