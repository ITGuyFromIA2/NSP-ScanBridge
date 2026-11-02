@{
  # Copy to a private path outside the repository.
  LockPath = 'C:\ProgramData\NSP\ScanBridge\worker.lock'
  Auth = @{
    TenantId = '<tenant-guid>'
    ClientId = '<app-guid>'
    CertificateThumbprint = '<thumbprint>'
  }
  Alerts = @{
    Enabled = $false
    From = '<monitoring-mailbox@example.com>'
    To = '<dispatch-address@example.com>'
    StateDirectory = 'C:\ProgramData\NSP\ScanBridge\AlertState'
    CertificateWarningDays = 30 # Optional, 1-365. Notice when the ingestion or alert certificate is this close to expiry.
    Auth = @{
      TenantId = '<tenant-guid>'
      ClientId = '<dedicated-mail-app-guid>'
      CertificateThumbprint = '<monitoring-cert-thumbprint>'
    }
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
      VerifyRemoteAfterUpload = $false # Enable after synthetic tenant validation; downloads PDF again.
    }
  )
}
