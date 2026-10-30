# Scanner ingestion deployment

**Development only:** No production deployment or sensitive-document processing is approved by this guide. Offline results use synthetic fixtures and mocked transports; live Graph behavior remains unverified.

## Prerequisites for a separately authorized synthetic test

1. Select an isolated SharePoint test library/folder, intended Windows account, app registration, certificate, and explicitly approved upload/readback/reconciliation actions. Record the exact destination and identity privately.
2. Review current Microsoft documentation and tenant policy before selecting permissions. Validate the smallest approved site grant; do not infer effective access from local mocks. No app registrations, grants, package installation or certificate changes are performed by the test suite.
3. Provide NSP.ScanBridge, NSP.M365.Graph and Microsoft.Graph.Authentication through a separately approved provisioning process. Verify certificate access under the actual unattended identity.
4. Pre-create source, spool, archive, lock and optional alert-state directories. Restrict NTFS/share access, review encryption and retention, and verify sufficient disk space for spool-local remote readback. Source and spool must be on the same actual volume; lexical drive-root checks do not prove physical-volume identity or resolve junctions. Ensure configured directories/routes do not alias each other.
5. Copy the example configuration outside Git. Supply complete `Auth.TenantId`, `Auth.ClientId`, and `Auth.CertificateThumbprint`. The worker connects and validates the active tenant/application. Reconciliation requires a previously connected, matching app-only context. Incomplete authentication fails closed.
6. Use a synthetic PDF to test intake, then one upload with remote readback, an interrupted-upload reconciliation, and local archive recovery. Validate the conflict-fail policy against an existing synthetic destination item. Check that repeated passes do not upload acknowledged or held jobs again.
7. Test optional alerts separately with an approved sender/recipient and restricted mail identity. Confirm actual ticket receipt independently of Graph acceptance.
8. Only after separate approval, evaluate scheduling under the intended account, overlap prevention, external monitoring, recovery and rollback. The old scanner process remains recoverable until cutover is explicitly approved.

The upload-session contract is reviewed against [Microsoft Graph createUploadSession documentation](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0). This does not prove tenant permission, conflict or service behavior. No-overwrite behavior and unattended certificate access require live synthetic validation.

## Receipt and archive recovery

- `Queued`: an upload may be attempted after receipt integrity checks.
- `Uploading` or `Review`: never automatically replay. Use `Resolve-NSPScanBridgeJob` for explicit byte-verified remote reconciliation. A failed lookup is not proof of absence; unknown or mismatched remote content leaves the job held.
- `Uploaded`: archive without uploading again. Persist the acknowledgement before moving the PDF, then move the receipt. A later pass verifies and recovers an orphan receipt after an interrupted PDF move.
- Missing, invalid, changed or conflicting PDF/receipt state: retain both copies and require operator investigation. A missing receipt is not enough evidence to recreate a `Queued` job. Reconciliation requires an intact matching receipt; missing-receipt remediation needs protected external evidence and an operator decision.

Receipt validation checks version 2, immutable destination binding, job ID, legal state, size, SHA-256 and the remote ID for `Uploaded`. Already-archived pairs are revalidated when archive recovery is requested. These checks detect inconsistency; they do not authenticate receipts against a malicious writer. Directory ACLs remain essential.

Optional `VerifyRemoteAfterUpload = $true` downloads the remote PDF again and compares SHA-256 and remote item ID before marking the receipt `Uploaded`. It increases disk/network load and may hold a job if a newly uploaded item is not yet readable. Readback temporaries are spool-local and removed on normal completion; abrupt process termination can leave files needing protected operator review. Do not bulk-delete spool evidence.

## Monitoring and runner exits

Run `scripts/Test-ScanBridgeHealth.ps1` only under an approved local monitoring identity. It reports generic route, condition codes, queue count and age. Pending receipt validation hashes local PDFs; plan polling frequency and disk access accordingly.

| Runner | 0 | 2 | 3 |
| --- | --- | --- | --- |
| `Run-ScanBridge.ps1` | Pass completed without reported held jobs | Worker exception or held job | Alert evaluation/submission failed |
| `Test-ScanBridgeHealth.ps1` | Healthy | Queue/review/receipt condition | Health check could not complete |
| `Send-ScanBridgeAlerts.ps1` | Evaluation/submission completed | Unused | Alert evaluation/submission failed |

An alert runner exit of zero does not prove a ticket exists. Unknown spool entries and orphan receipts still require health monitoring even if the ingestion pass has no deliverable jobs. External RMM checks must detect host/scheduler/authentication failure. Generic warnings do not create a protected diagnostic log automatically; operators must define restricted diagnostics and retention separately.

Run the two-host manual suite in the README before any approved deployment. No GitHub Actions, package publication, tenant testing or production installation is implied by these instructions.
## Route isolation and spool anomalies

The worker validates the complete route set before opening its lock, connecting to Graph, or claiming/processing documents. Route names must be unique. All source, spool and archive directories must be distinct and non-nested across every route; sharing a spool or archive between routes is rejected. This is lexical path validation; operators must still verify actual volumes, junctions and other aliases during deployment.

A receipt whose PDF exists in neither spool nor archive produces a held result and remains unchanged. Unknown PDF or JSON names also produce generic held results without exposing their names. The ingestion runner returns 2 for those results even when alerts are disabled or skipped. Interrupted-archive recovery remains available for valid GUID receipts with matching archived PDFs.

Version 2 receipts bind each job to its original route name, tenant ID, application ID, drive ID and folder item ID when it is claimed. Every worker state change, upload, explicit reconciliation and archive recovery checks the configured destination against that stored binding. A changed binding holds the document and receipt unchanged. Health reports it as a receipt anomaly. Returning configuration to the original binding allows normal processing/recovery; it never resets an ambiguous upload to Queued. Values compare exactly, so changing identifier spelling/case or renaming a route can also require operator review. Certificate thumbprints are not bound, allowing certificate rotation for the same application and destination.

Even `-IntakeOnly` requires expected tenant/app and destination metadata to create a bound receipt; it makes no Graph connection. Receipt metadata now includes private deployment identifiers and belongs only in restricted spool/archive storage, not central monitoring, public examples or ticket bodies.

Legacy version 1 receipts lack destination provenance. They remain untouched and held regardless of their recorded state, including Uploaded. Neither the worker, writer nor reconciler silently upgrades or rebinds them. Preserve these documents/receipts and establish original destination identity from protected records before a separately reviewed per-job migration/recovery plan. There is no automatic migration/rebind command; do not bulk relabel or replay legacy jobs. These consistency checks still depend on ACLs and do not authenticate a receipt against a malicious writer.