$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($directory in 'Private','Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.ps1' -File) { . $file.FullName }
}
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
$ingestionThumbprint = 'A' * 40
$alertThumbprint = 'B' * 40
$now = [DateTime]::UtcNow
# Synthetic certificate store. Only Cert: lookups are faked; every other Get-Item is real.
$script:store = @{}
$script:storeFault = $false
function Get-Item {
    param([string]$LiteralPath, $ErrorAction)
    if ($LiteralPath -notlike 'Cert:\*') { return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -ErrorAction $ErrorAction }
    if ($script:storeFault) { throw 'Synthetic store failure with private detail.' }
    $script:store[$LiteralPath]
}
function Set-Certificate([string]$Store, [string]$Thumbprint, $NotAfterUtc) {
    $path = Join-Path $Store $Thumbprint
    if ($null -eq $NotAfterUtc) { $script:store.Remove($path); return }
    $script:store[$path] = [pscustomobject]@{ NotAfter = ([DateTime]$NotAfterUtc).ToLocalTime() }
}
# Every transport and connection entry point below is synthetic. Fail on an unexpected call.
function Import-Module { param($Name,[switch]$PassThru,$ErrorAction) if ($Name -ne 'NSP.M365.Graph') { throw 'Unexpected module import.' }; if ($PassThru) { [pscustomobject]@{Name='NSP.M365.Graph';ExportedCommands=@{'Connect-NSPGraphAppOnly'=(Get-Command Connect-NSPGraphAppOnly)}} } }
$script:context = @{ AuthType='AppOnly'; ContextScope='Process'; TenantId='alert-tenant'; ClientId='alert-app' }
function Connect-NSPGraphAppOnly { param($TenantId,$ClientId,$CertificateThumbprint,$ContextScope,$ErrorAction) }
function Get-MgContext { param($ErrorAction) $script:context }
function Invoke-NSPGraphRequest { throw 'Unexpected Graph request.' }
function Invoke-RestMethod { throw 'Unexpected network transport.' }
function Invoke-WebRequest { throw 'Unexpected network transport.' }
function Test-NSPScanBridgeHealth {
    param($ConfigurationPath,$MaximumPending,$MaximumPendingMinutes)
    [pscustomobject]@{ Route='RouteA'; Healthy=$true; Conditions=@(); PendingCount=0; OldestPendingMinutes=$null }
}
$script:mails = @()
function Send-NSPGraphMail {
    param($From,$To,$Subject,$Body,$ErrorAction)
    $script:mails += [pscustomobject]@{ Subject = $Subject; Body = $Body }
}

# Status function: store order, thresholds and input validation.
$status = { param($Thumbprint, $Days = 30) Get-NSPScanBridgeCertificateStatus -Thumbprint $Thumbprint -WarningDays $Days -NowUtc $now }
Assert-Check ((& $status $ingestionThumbprint).Status -eq 'Missing') 'Absent certificate was not reported missing.'
Assert-Check ($null -eq (& $status $ingestionThumbprint).DaysRemaining) 'Missing certificate reported days remaining.'
Set-Certificate 'Cert:\CurrentUser\My' $ingestionThumbprint $now.AddDays(10)
Assert-Check ((& $status $ingestionThumbprint).Status -eq 'Expiring') 'Current-user certificate was not found.'
Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(200)
Assert-Check ((& $status $ingestionThumbprint).Status -eq 'Valid') 'Computer store did not take precedence over current user.'
Set-Certificate 'Cert:\CurrentUser\My' $ingestionThumbprint $null
Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(31)
Assert-Check ((& $status $ingestionThumbprint).Status -eq 'Valid') 'Certificate with 31 days left was flagged.'
Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(30)
Assert-Check ((& $status $ingestionThumbprint).Status -eq 'Expiring') 'Certificate with exactly 30 days left was not flagged.'
Assert-Check ((& $status $ingestionThumbprint).DaysRemaining -eq 30) 'Days remaining is wrong.'
Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(45)
Assert-Check ((& $status $ingestionThumbprint 60).Status -eq 'Expiring') 'Custom warning window was ignored.'
Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddMinutes(-1)
Assert-Check ((& $status $ingestionThumbprint).Status -eq 'Expired') 'Expired certificate was not reported expired.'
Assert-Rejected { & $status 'test-cert' } 'Malformed thumbprint was accepted.'
Assert-Rejected { & $status ('..\' + ('A' * 37)) } 'Path-like thumbprint was accepted.'
Assert-Rejected { & $status $ingestionThumbprint 0 } 'Zero-day warning window was accepted.'

$base = Join-Path ([IO.Path]::GetTempPath()) ('nsp-certalerts-' + [guid]::NewGuid().ToString('N'))
$resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($base).StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe fixture root.' }
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $base 'alerts') -Force)
    $safeBase = $base.Replace("'", "''")
    $template = @"
@{
 Auth = @{ TenantId='ingest-tenant'; ClientId='ingest-app'; CertificateThumbprint='$ingestionThumbprint' }
 LockPath = '$safeBase\worker.lock'
 Routes = @(@{ Name='RouteA' })
 Alerts = @{ Enabled=`$true; From='monitor@example.invalid'; To='dispatch@example.invalid'; StateDirectory='$safeBase\alerts'; Auth=@{ TenantId='alert-tenant'; ClientId='alert-app'; CertificateThumbprint='$alertThumbprint' }__EXTRA__ }
}
"@
    function New-Config([string]$Name, [string]$Extra = '', [string]$RouteName = 'RouteA') {
        $path = Join-Path $base $Name
        [IO.File]::WriteAllText($path, $template.Replace('__EXTRA__', $Extra).Replace("Name='RouteA'", "Name='$RouteName'"))
        $path
    }
    $config = New-Config 'default.psd1'
    $marker = Join-Path $base 'alerts\Q2VydGlmaWNhdGVz.alert.json'

    Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(300)
    Set-Certificate 'Cert:\LocalMachine\My' $alertThumbprint $now.AddDays(300)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails.Count -eq 0) 'Valid certificates produced an alert.'

    Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(20)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails.Count -eq 1) 'Expiring ingestion certificate did not alert.'
    $mail = $script:mails[0]
    Assert-Check ($mail.Subject -eq '[NSP.ScanBridge] Certificate renewal required') 'Certificate notice used the wrong subject.'
    Assert-Check ($mail.Body -match 'IngestionCertificateExpiring') 'Certificate notice lacks its condition code.'
    Assert-Check ($mail.Body -match 'Fewest days remaining: 19') 'Certificate notice lacks days remaining.'
    Assert-Check ($mail.Body -notmatch "$ingestionThumbprint|$alertThumbprint|tenant|-app|\\") 'Certificate notice leaked identity or path detail.'
    Assert-Check ((Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json).Active) 'Certificate marker was not recorded.'

    Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(19)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails.Count -eq 1) 'Daily countdown repeated the certificate notice.'

    Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(-1)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails.Count -eq 2) 'Expiry after a warning did not escalate.'
    Assert-Check ($script:mails[1].Body -match 'IngestionCertificateExpired') 'Escalation lacks the expired condition.'

    Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(365)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails.Count -eq 2) 'Renewal sent mail.'
    Assert-Check (-not (Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json).Active) 'Renewal did not resolve the certificate marker.'

    Set-Certificate 'Cert:\LocalMachine\My' $alertThumbprint $now.AddDays(5)
    Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $null
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails.Count -eq 3) 'Alert-certificate expiry after recovery did not alert.'
    Assert-Check ($script:mails[2].Body -match 'AlertCertificateExpiring' -and $script:mails[2].Body -match 'IngestionCertificateMissing') 'Combined certificate conditions were not reported.'
    Assert-Check ($script:mails[2].Body -match 'Fewest days remaining: 4') 'Days remaining ignored the alert certificate.'

    $script:storeFault = $true
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    $script:storeFault = $false
    Assert-Check ($script:mails.Count -eq 4 -and $script:mails[3].Body -match 'CertificateCheckFailed') 'Certificate check failure did not alert.'
    Assert-Check ($script:mails[3].Body -notmatch 'private detail') 'Certificate check failure leaked exception text.'

    Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(45)
    Set-Certificate 'Cert:\LocalMachine\My' $alertThumbprint $now.AddDays(300)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config
    Assert-Check ($script:mails.Count -eq 4) 'Default 30-day window flagged a 45-day certificate.'
    $wide = New-Config 'wide.psd1' '; CertificateWarningDays=60'
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $wide
    Assert-Check ($script:mails.Count -eq 5) 'Configured 60-day window was ignored.'

    Assert-Rejected { Send-NSPScanBridgeAlert -ConfigurationPath (New-Config 'zero.psd1' '; CertificateWarningDays=0') } 'Zero-day warning window was accepted.'
    Assert-Rejected { Send-NSPScanBridgeAlert -ConfigurationPath (New-Config 'text.psd1' "; CertificateWarningDays='soon'") } 'Non-numeric warning window was accepted.'
    Assert-Rejected { Send-NSPScanBridgeAlert -ConfigurationPath (New-Config 'reserved.psd1' '' 'Certificates') } 'Reserved Certificates route name was accepted.'
    Assert-Check ($script:mails.Count -eq 5) 'Rejected configuration sent mail.'

    # A new signature that would send without -WhatIf.
    Set-Certificate 'Cert:\LocalMachine\My' $ingestionThumbprint $now.AddDays(-2)
    $before = [IO.File]::ReadAllText($marker)
    $null = Send-NSPScanBridgeAlert -ConfigurationPath $config -WhatIf
    Assert-Check ($script:mails.Count -eq 5 -and [IO.File]::ReadAllText($marker) -eq $before) 'WhatIf sent a certificate notice or changed its marker.'
    Write-Host ('Passed: {0} certificate-expiry alert checks using a synthetic store and fake transports.' -f $script:checks)
} finally {
    $resolvedBase = [IO.Path]::GetFullPath($base)
    if (-not $resolvedBase.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedBase) -notmatch '^nsp-certalerts-[0-9a-f]{32}$') { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolvedBase) { Remove-Item -LiteralPath $resolvedBase -Recurse -Force }
}
