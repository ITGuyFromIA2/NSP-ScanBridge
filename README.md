# NSP.ScanBridge

Unattended scanner-to-SharePoint ingestion for Windows SMB drop folders.

**Status:** Development prototype with unattended intake and Graph upload code. Not production-ready or HIPAA-certified. Do not route PHI through it until authentication, recovery, permissions, duplicate handling, and operational monitoring have been validated in the target tenant.

## Dependencies

- Windows PowerShell 5.1 or PowerShell 7
- NSP.M365.Graph (app-only sign-in via `Connect-NSPGraphAppOnly`)
- Microsoft.Graph.Authentication
- NSP.Bootstrap for provisioning/deployment
- NSP.RepoTools for release and client-reference sweeps

## Planned flow

Brother MFP -> dedicated SMB drop folder -> unattended scheduled task -> Microsoft Graph -> Teams-backed SharePoint library.

The Teams channel remains a user-facing view; no mailbox or Power Automate flow is required.

## Design principles

- Run without an interactive user or OneDrive sign-in.
- Read only fully written PDFs; periodically reconcile in addition to optional watcher events.
- Retain originals until confirmed remote delivery.
- Persist queue/checkpoint state and recover from interruptions.
- Restrict Graph app permissions to selected sites when feasible.
- Keep credentials, patient data, client names, URLs and tenant IDs out of source control.
- Separate generic module code from deployment-specific configuration.
- Avoid PHI-bearing filenames in ordinary diagnostics.

## Development workflow

Use `NSP.RepoTools` before public commits/releases:

```powershell
Import-Module NSP.RepoTools
Find-NSPClientReference -Path . -IncludeUntracked
.\tools\Test-Repo.ps1
Publish-NSPModule -Path . -WhatIf
```

The publication gate additionally checks full Git history; never check secrets or actual scans into this repository.

## Current implementation

- `Invoke-NSPScanBridge -ConfigurationPath <private-config>` performs one unattended pass: claim old, unlocked PDFs into a same-volume durable spool; attempt SharePoint Graph delivery; archive after acknowledgement.
- `Invoke-NSPScanBridge -ConfigurationPath <private-config> -IntakeOnly` tests disk-only intake with no Graph connection.
- `Test-NSPScanBridgeFileReady` excludes fresh, locked or empty PDFs.
- `scripts/Run-ScanBridge.ps1` provides the scheduled-task entry point.
- `tools/Test-Repo.ps1` includes offline intake persistence checks (not yet executed by this GitHub-only session).
- See `docs/DEPLOYMENT.md` and `config/ScanBridge.example.psd1`.

**Known gaps:** Graph conditional upload and 404 response handling need Windows/tenant validation; binary PDF upload depends on `Invoke-MgGraphRequest -InputFilePath` rather than the JSON-only shared wrapper; ambiguous remote responses require operator reconciliation; automated backoff/alerts and upload sessions remain to be implemented.

## Immediate next milestones

1. Verify the implemented small-file binary upload and overwrite safeguards using synthetic PDFs in a test library.
2. Implement durable file claims / idempotent upload and archive reconciliation.
3. Add permissions-limited tenant setup, health reporting and integration tests.
4. Validate SYSTEM/LocalMachine certificate access on a test host.

**Repository:** `ITGuyFromIA2/NSP-ScanBridge`  
**PowerShell module:** `NSP.ScanBridge`
