# Changelog

## Unreleased

- Send a certificate renewal notice when the ingestion or alert certificate is missing, expired or within `Alerts.CertificateWarningDays` (default 30) of expiry, as its own `Certificates` incident with the existing send-once and resolve-on-recovery markers. `Certificates` becomes a reserved route name.

## 0.1.0

- Require NSP.M365.Graph 0.1.2 or later when selecting the connector, so an older copy earlier on PSModulePath is skipped rather than loaded; exclude agent/handoff documents from the Gallery package.

- Add a read-only source readiness diagnostic comparing the existing age/open baseline with sustained-observation policies, including late-change revocation and bounded watcher cleanup.

- Separate ScanBridge connection from context validation; require a capable shared connector and explicitly request Process scope before worker claims or alert mail.

- Preserve conflict-annotation order in upload-session JSON to prevent SharePoint HTTP 400 responses.

- Initial public module scaffold.
- Add stable-file preflight for scanner PDF output.

- Add upload-session based, conflict-fail binary transfers and an offline contract test.
- Add read-only, PHI-minimizing queue health reporting.

- Add persisted SHA-256 per-job receipts and conservative upload/crash recovery states.

- Correct the upload receipt persistence path and recover interrupted two-file archive moves.

- Add private bounded backoff and retry-phase classifiers with offline tests; automatic retries are intentionally not yet enabled.
- Enforce receipt state transition restrictions and immutable remote IDs after upload acknowledgement.
- Add PHI-minimizing queue health thresholds for monitoring integrations.

- Add optional Graph-based dispatch escalation with persistent duplicate suppression, a scheduled monitoring entry point, and a fail-closed configuration test.

- Escalate worker and queue-health evaluation failures through the optional dispatch handler without exposing exception contents.
- Add synthetic multi-chunk upload range and response contract test.

- Wire limited transient retry/backoff into pre-transfer upload-session creation, with a simulated throttling test.

- Implement explicit held-job remote SHA-256 reconciliation, local receipt verification, a worker lock, and repository-wide PowerShell parse gate.

- Stabilize Windows PowerShell 5.1/PowerShell 7 receipt and alert marker replacement using a true null backup filename.
- Hold missing/corrupt/inconsistent receipts, validate archived pairs, and reconcile interrupted Uploading jobs without replay.
- Require complete configured app-only identity and verify tenant/application context in worker, reconciliation and alerts.
- Serialize alerts; repair health-error recurrence and explicit worker recovery; preserve WhatIf marker state.
- Report held work with runner exit 2 and retain exit 3 for failed health/alert evaluation.
- Reject unexpected chunk acknowledgements and add synthetic recovery, upload-failure, enabled-alert and isolated runner tests.
- Correct reconciliation mocks and fail fast on parser errors; reconcile operational documentation with verified offline behavior.
- Validate all route directories and names before any processing to prevent cross-route spool delivery.
- Report missing-PDF orphan receipts and unknown spool PDF/JSON names as held work; add regressions using the actual worker and runner with network blocked.

- Introduce version 2 receipts with immutable route, tenant, app, drive and folder binding. Enforce binding in intake, upload, reconciliation, health and archive recovery; hold legacy v1 receipts without automatic migration or rebinding.
- Add synthetic destination-drift, legacy-state preservation and certificate-rotation regressions.
