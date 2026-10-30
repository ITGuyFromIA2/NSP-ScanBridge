# Changelog

## 0.1.0

- Initial public module scaffold.
- Add stable-file preflight for scanner PDF output.

- Add upload-session based, conflict-fail binary transfers and an offline contract test.
- Add read-only, PHI-minimizing queue health reporting.

- Add persisted SHA-256 per-job receipts and conservative upload/crash recovery states.

- Correct the upload receipt persistence path and recover interrupted two-file archive moves.

- Add private bounded backoff and retry-phase classifiers with offline tests; automatic retries are intentionally not yet enabled.
- Enforce receipt state transition restrictions and immutable remote IDs after upload acknowledgement.
- Add PHI-minimizing queue health thresholds for monitoring integrations.
