function Test-NSPScanBridgeRemoteMatch {
    <#
    .SYNOPSIS
        Conservatively compares a spooled PDF with the remote drive item.
    .DESCRIPTION
        Never changes remote items or local receipts. A matching name and size
        alone are not sufficient. Downloads the remote content to a disposable
        private file and checks SHA-256 equality. Requires existing Graph access.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$FolderItemId
    )
    $file = Get-Item -LiteralPath $PdfPath -ErrorAction Stop
    if ($file.Name -cnotmatch '^[0-9a-f]{32}\.pdf$') { throw 'Invalid job name.' }
    $localHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $drive = [uri]::EscapeDataString($DriveId)
    $folder = [uri]::EscapeDataString($FolderItemId)
    $name = [uri]::EscapeDataString($file.Name)
    $uri = "drives/$drive/items/$($folder):/$($name):"
    $remote = $null
    try {
        $remote = Invoke-NSPGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    } catch {
        # A lookup failure is not proof the object is absent.
        return [pscustomobject]@{ Status = 'Unknown'; RemoteId = $null }
    }
    if (-not $remote -or -not $remote.id -or [long]$remote.size -ne [long]$file.Length) {
        return [pscustomobject]@{ Status = 'Unverified'; RemoteId = $null }
    }
    $downloadUrl = $remote.'@microsoft.graph.downloadUrl'
    if (-not $downloadUrl -or $downloadUrl -notmatch '^https://') {
        return [pscustomobject]@{ Status = 'Unverified'; RemoteId = $null }
    }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($file.FullName)) ('nsp-reconcile-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        # Do not include the preauthenticated URL in exceptions, receipts or logs.
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $temporary -UseBasicParsing -ErrorAction Stop | Out-Null
        } catch {
            return [pscustomobject]@{ Status = 'Unknown'; RemoteId = $null }
        }
        $remoteFile = Get-Item -LiteralPath $temporary -ErrorAction Stop
        if ($remoteFile.Length -ne $file.Length) {
            return [pscustomobject]@{ Status = 'Mismatch'; RemoteId = $null }
        }
        $remoteHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        if ($remoteHash -ne $localHash) {
            return [pscustomobject]@{ Status = 'Mismatch'; RemoteId = $null }
        }
        return [pscustomobject]@{ Status = 'Verified'; RemoteId = [string]$remote.id }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}
