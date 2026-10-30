# Scanner ingestion deployment

**Development status:** Not approved for PHI or production deployment. The upload path and Graph conditional-write semantics need live validation using synthetic PDFs.

1. Install NSP.ScanBridge, NSP.M365.Graph, and Microsoft.Graph.Authentication for the scheduled-task identity.
2. Register an app-only Entra application with a protected machine certificate. Prefer Sites.Selected with access limited to the designated SharePoint site. Confirm tenant grants separately.
3. Find the destination document-library DriveId and existing FolderItemId.
4. Create dedicated source, spool, archive, and lock directories. Source and spool **must** be on the same drive. Restrict NTFS and share ACLs; ensure BitLocker is enabled.
5. Copy config/ScanBridge.example.psd1 outside Git and set real values. Restrict ACLs on the configuration and certificate private key.
6. Test intake locally with synthetic PDF files: Invoke-NSPScanBridge -ConfigurationPath '<private-config>' -IntakeOnly
7. Test Graph upload in an isolated non-PHI library under the intended scheduled-task account.
8. Schedule scripts/Run-ScanBridge.ps1 to run as SYSTEM whether or not a user is logged on, at startup and every minute; disable overlapping task instances.
9. Monitor spool age and job results. Never automatically delete or replay ambiguous uploads. Keep old process recoverable until full cutover validation.

## Recovery and limitations

Jobs receive opaque GUID names when claimed into the spool. A confirmed upload moves the source into Archive. Existing remote names and ambiguous responses are held for manual reconciliation and the spool item is retained. A power loss before archive may result in an intentionally held job, not automatic overwrite.

The initial implementation still restricts files to 250 MB although it now uses conflict-fail upload sessions, and does not implement full receipts, backoff scheduling, content hash verification, Windows event logging, or alerting. Validate Microsoft Graph conflict behavior and failure handling before real use.
