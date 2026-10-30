@{
  # Copy to a private path outside the repository.
  LockPath = 'C:\ProgramData\NSP\ScanBridge\worker.lock'
  Auth = @{
    TenantId = '<tenant-guid>'
    ClientId = '<app-guid>'
    CertificateThumbprint = '<thumbprint>'
  }
  Routes = @(
    @{
      Name = 'RouteA'
      Source = 'C:\ScanBridge\DropA'
      Spool = 'C:\ScanBridge\SpoolA'
      Archive = 'C:\ScanBridge\ArchiveA'
      DriveId = '<drive-id>'
      FolderItemId = '<folder-id>'
      MinimumAgeSeconds = 20
    }
  )
}
