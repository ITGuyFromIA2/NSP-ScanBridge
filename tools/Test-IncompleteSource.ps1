$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $root 'NSP.ScanBridge.psd1') -Force -PassThru -ErrorAction Stop
$script:checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Get-Structure([byte[]]$Bytes) {
    $stream = New-Object IO.MemoryStream (,$Bytes)
    try { & $module { param($s) Test-NSPScanBridgePdfStructure -Stream $s } $stream } finally { $stream.Dispose() }
}
$ascii = [Text.Encoding]::ASCII
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('NSPScanBridge-Incomplete-' + [guid]::NewGuid().ToString('N'))
try {
    # Structure heuristic: header within the first 1024 bytes, end-of-file marker within the last 1024.
    Check (Get-Structure $ascii.GetBytes("%PDF-1.4`n%%EOF`n")).Complete 'Minimal complete PDF rejected.'
    $binary = [byte[]](@(37,80,68,70,45,49,46,55,10,37,226,227,207,211,10) + @(0..255 | ForEach-Object { [byte]$_ }) * 8 + @(37,37,69,79,70,13,10))
    Check (Get-Structure $binary).Complete 'Binary content with high bytes rejected.'
    $incremental = $ascii.GetBytes("%PDF-1.4`n%%EOF`n" + ('%' + ('X' * 3000) + "`n") + "%%EOF`n")
    Check (Get-Structure $incremental).Complete 'Incremental update with a final end-of-file marker rejected.'
    $truncated = Get-Structure $ascii.GetBytes("%PDF-1.4`n1 0 obj`n" + ('%' + ('X' * 3000) + "`n"))
    Check (-not $truncated.Complete -and $truncated.HasHeader -and $truncated.Reasons -contains 'MissingEndOfFile') 'Truncated PDF accepted or misreported.'
    $earlyEof = Get-Structure $ascii.GetBytes("%PDF-1.4`n%%EOF`n" + ('%' + ('X' * 3000) + "`n"))
    Check (-not $earlyEof.Complete) 'Interrupted incremental write accepted on an earlier end-of-file marker.'
    $headerless = Get-Structure $ascii.GetBytes(('X' * 1100) + "%PDF-1.4`n%%EOF`n")
    Check (-not $headerless.Complete -and $headerless.Reasons -contains 'MissingHeader') 'PDF without a leading header accepted.'
    Check (-not (Get-Structure ([byte[]]@())).Complete) 'Empty stream accepted.'

    foreach ($folder in 'source','spool','archive','lock') { New-Item -ItemType Directory -Path (Join-Path $testRoot $folder) -Force | Out-Null }
    $safeRoot = $testRoot.Replace("'", "''")
    $configPath = Join-Path $testRoot 'config.psd1'
    [IO.File]::WriteAllText($configPath, @"
@{
 Auth = @{ TenantId='test-tenant'; ClientId='test-app'; CertificateThumbprint='test-cert' }
 LockPath = '$safeRoot\lock\worker.lock'
 Routes = @(@{ Name='Test'; Source='$safeRoot\source'; Spool='$safeRoot\spool'; Archive='$safeRoot\archive'; DriveId='test-drive'; FolderItemId='test-folder'; MinimumAgeSeconds=1 })
}
"@)
    # What a cancelled direct-write scan leaves: aged, closed, header present, no trailer.
    $pdf = Join-Path $testRoot 'source\cancelled.pdf'
    [IO.File]::WriteAllBytes($pdf, $ascii.GetBytes("%PDF-1.4`n1 0 obj`n<< /Type /Catalog >>`nendobj`n" + ('%' + ('X' * 4093) + "`r`n") * 4))
    (Get-Item -LiteralPath $pdf).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-45)
    $hash = (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash
    $result = @(Invoke-NSPScanBridge -ConfigurationPath $configPath -IntakeOnly)
    Check ($result.Count -eq 0) 'Worker claimed an incomplete PDF.'
    Check ((Test-Path -LiteralPath $pdf) -and (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash -eq $hash) 'Incomplete source PDF was moved or changed.'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'spool') -File).Count -eq 0) 'Spool received an incomplete PDF or receipt.'
    $health = @(Get-NSPScanBridgeHealth -ConfigurationPath $configPath)
    Check ($health[0].SourceCount -eq 1 -and $health[0].OldestSourceMinutes -ge 44 -and $health[0].PendingCount -eq 0) 'Health did not report the held source PDF.'
    $alert = @(Test-NSPScanBridgeHealth -ConfigurationPath $configPath)
    Check (-not $alert[0].Healthy -and $alert[0].Conditions -contains 'SourceAge' -and $alert[0].Conditions.Count -eq 1) 'SourceAge was not raised at the default threshold.'
    Check (($alert[0] | Out-String) -notmatch 'cancelled') 'Health output disclosed the source filename.'
    $relaxed = @(Test-NSPScanBridgeHealth -ConfigurationPath $configPath -MaximumSourceMinutes 60)
    Check ($relaxed[0].Healthy) 'SourceAge raised below the configured threshold.'

    # The writer finishes later: the same file becomes claimable with no operator action.
    $stream = [IO.File]::Open($pdf, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $tail = $ascii.GetBytes("trailer`n<< /Root 1 0 R >>`n%%EOF`n"); $stream.Write($tail, 0, $tail.Length) } finally { $stream.Dispose() }
    (Get-Item -LiteralPath $pdf).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
    $result = @(Invoke-NSPScanBridge -ConfigurationPath $configPath -IntakeOnly)
    Check ($result.Count -eq 1 -and $result[0].State -eq 'Queued' -and -not (Test-Path -LiteralPath $pdf)) 'Completed PDF was not claimed.'
    $alert = @(Test-NSPScanBridgeHealth -ConfigurationPath $configPath)
    Check ($alert[0].Conditions -notcontains 'SourceAge' -and $null -eq $alert[0].OldestSourceMinutes) 'SourceAge persisted after the source emptied.'

    # A fresh drop is not reported as held.
    $fresh = Join-Path $testRoot 'source\fresh.pdf'
    [IO.File]::WriteAllBytes($fresh, $ascii.GetBytes("%PDF-1.4`n"))
    Check ((@(Test-NSPScanBridgeHealth -ConfigurationPath $configPath))[0].Conditions -notcontains 'SourceAge') 'Fresh source file raised SourceAge.'
    Write-Host "Passed: $script:checks incomplete-source checks using synthetic local fixtures."
} finally {
    if ($testRoot -like '*NSPScanBridge-Incomplete-*') { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
}
