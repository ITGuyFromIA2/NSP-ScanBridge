# NSP.ScanBridge

Unattended scanner-to-SharePoint ingestion for Windows SMB drop folders.

**Status:** Development version 0.1.0. Synthetic offline tests do not establish production readiness, tenant compatibility, or approval to process sensitive documents.

The scanner retains its SMB drop workflow. ScanBridge claims stable PDFs into a durable spool using opaque GUID names, sends binary chunks through Graph upload sessions, persists delivery receipts, and archives acknowledged documents. It runs without an interactive OneDrive session. Implementation stays in this repository; shared authentication and JSON transport belong to NSP.M365.Graph.

## Dependencies

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- NSP.M365.Graph and Microsoft.Graph.Authentication for authorized tenant operations.
- NSP.Bootstrap for separately approved provisioning; runtime tests install nothing.
- NSP.RepoTools for privacy and release review.

## Local development checks

Run each command in a fresh process from the source root:

```powershell
powershell.exe -NoProfile -File .\tools\Test-Parsing.ps1
powershell.exe -NoProfile -File .\tools\Test-Repo.ps1
pwsh.exe -NoProfile -File .\tools\Test-Parsing.ps1
pwsh.exe -NoProfile -File .\tools\Test-Repo.ps1
```

The suite validates manifest/import/exports, file readiness, intake, receipts, archive recovery, upload contracts and failures, readback reconciliation, identity checks, enabled fake-mail alerting, and runner exit codes. Fixtures use synthetic bytes and mocked transports. Runner tests load an isolated fake module in child processes. There is no GitHub Actions workflow. PSScriptAnalyzer is optional and is not installed by these commands.

Before public delivery, run the local privacy gate with an available, nonempty private token list:

```powershell
Import-Module NSP.RepoTools
Find-NSPClientReference -Path . -IncludeUntracked -History
```

Inspect results privately: do not print matched client text into shared logs. A clean current snapshot does not clear historical findings. Commit, push, PR, package publication, and tenant tests require their applicable owner approvals.

## Commands and recovery

- `Invoke-NSPScanBridge -ConfigurationPath <private-config>` performs one intake/delivery pass. Complete expected app-only authentication is required; the active tenant and application must match it.
- `Invoke-NSPScanBridge ... -IntakeOnly` uses local disk only. Configure expected tenant/app and destination metadata even in this mode so new receipts are bound from intake; no Graph login occurs. Only use approved synthetic fixtures during development.
- `Get-NSPScanBridgeHealth` reports counts, pending age and the age of the oldest unclaimed source PDF. It validates pending receipt metadata and SHA-256, so its disk cost grows with the spool.
- `Test-NSPScanBridgeHealth` reports queue thresholds, held uploads, receipt anomalies and `SourceAge` for a source PDF left unclaimed past `-MaximumSourceMinutes` (default 30).
- `Test-NSPScanBridgeFileReady` also requires a `%PDF-` header in the first 1024 bytes and `%%EOF` in the last 1024, read under its exclusive handle. A cancelled direct-write scan therefore stays in Source, unclaimed and unchanged, until it is completed or removed by an operator; `SourceAge` makes it visible. This is a completeness heuristic, not proof that the document renders.
- `Resolve-NSPScanBridgeJob ... -RouteName RouteA -JobId <opaque-guid>` accepts both `Uploading` and `Review` jobs. It requires an existing context matching the configured ingestion identity, downloads remote bytes into restricted spool storage, compares exact SHA-256, then archives only a match. It never replays an upload. `-WhatIf` still performs readback but skips receipt/archive changes.
- `Send-NSPScanBridgeAlert` uses a separately configured app-only mail identity and persistent, serialized alert markers. See [alerting](docs/ALERTING.md).

Version 2 receipts contain an immutable destination binding (route name, tenant ID, app ID, drive ID and folder item ID), opaque job ID, SHA-256, size, state, timestamp and acknowledged remote ID. Upload, reconciliation and archive recovery reject mismatches. Certificate changes with the same identity/destination do not alter the binding. `Queued` permits an upload attempt; `Uploading` and `Review` remain held until explicit reconciliation; `Uploaded` permits archive recovery without reupload. Missing, corrupt or inconsistent receipts are preserved for review and never recreated automatically. Legacy version 1 receipts are unbound and remain held; there is no automatic migration or rebinding. Back up PDFs and receipts together, and restrict access because destination metadata includes private deployment identifiers.

Session creation retries recognized transient HTTP failures at most three times before binary transfer. Binary transfer is sequential, uses 320 KiB-multiple chunks, and checks the next expected position and final item ID/size. An ambiguous transfer is held. Optional `VerifyRemoteAfterUpload` adds full remote readback before acknowledgement. The development per-file limit remains 250 MB.

See [deployment and evidence limits](docs/DEPLOYMENT.md) and the placeholder-only [configuration](config/ScanBridge.example.psd1). Real configuration, document content, filenames, addresses, tenant identifiers and credentials stay outside Git.
For read-only comparison of readiness decisions against live file lifecycles, see [the readiness diagnostic](docs/READINESS-DIAGNOSTIC.md). It uses the existing settings file and never claims or uploads documents.
