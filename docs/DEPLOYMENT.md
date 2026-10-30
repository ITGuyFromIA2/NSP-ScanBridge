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

## Recovery workflow (development)

- `Queued`: safe to attempt upload in the next pass.
- `Uploading`: an interruption means the remote outcome may be unknown; subsequent passes leave the PDF in place for operator review.
- `Review`: manual investigation required; do not flip back to Queued unless the remote outcome has been independently verified.
- `Uploaded`: remote acknowledgment was obtained and persisted; archive locally without another upload.
- Job state lives in a sibling JSON receipt beside the GUID-named PDF. Back up spool and receipts together, restrict folder ACLs, and never bulk-delete either.

**Known recovery gap:** interruption between moving an uploaded PDF to Archive and moving its JSON receipt can leave an orphan receipt in Spool. No automated repair for orphan receipts exists yet. Include this in local integration tests.

## Archive crash recovery update

The worker now scans spool receipts for completed PDF moves whose receipt still remains in spool. It verifies that the receipt records a successful upload and validates the archived PDF's SHA-256 before moving the receipt to Archive. Conflicting or incomplete states remain held for human review; the worker does not reupload these files. A synthetic offline test exercises the interrupted move and an idempotent rerun. No automatic cloud-side reconciliation is implemented.

Health reporting now surfaces held/review and invalid/orphan receipt counts, not just total pending files. A racy remote GET preflight was removed; conflict handling is delegated to the Graph upload-session fail policy, subject to live validation.

## Monitoring

Run `Test-NSPScanBridgeHealth -ConfigurationPath <private-config> -MaximumPending 25 -MaximumPendingMinutes 10` as a read-only health check. Inspect `Healthy` and `Conditions`; do not record PDF names or content in central monitoring. This currently evaluates local state only and does not send alerts. Automatic transient retry policy is not wired into the worker, to avoid replaying ambiguous upload sessions without cloud reconciliation.
