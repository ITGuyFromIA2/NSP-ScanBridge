# ScanBridge dispatch escalation

Configure a private deployment copy of `config/ScanBridge.example.psd1` with an `Alerts` block. Set `Enabled = $true`, `To` to the approved dispatch ticketing address, `From` to the sender mailbox, and `StateDirectory` to a restricted, pre-created local folder.

Use `scripts/Send-ScanBridgeAlerts.ps1 -ConfigurationPath <private-config>` as an unattended monitoring task after the ingestion job. Never commit actual customer addresses, tenant identifiers or private configuration.

`Send-NSPScanBridgeAlert` uses existing `NSP.M365.Graph` functions and requires a separate `Alerts.Auth` app-only certificate registration. **Mail.Send application permission can permit broad mailbox access**: scope the sending application through Exchange RBAC for Applications or an appropriate application access policy, and validate that it can send only as the designated mailbox. This is separate from the ingestion app's site-restricted permissions.

Messages contain only generic route labels, condition codes, counts, and age. Never include patient names, document names, PDF attachments, actual local paths or any tenant identifier. Treat route labels as potentially sensitive and choose generic names. On a repeated identical condition, a persistent alert marker suppresses duplicate emails. A changed condition signature can cause a new ticket.

## Certificate renewal notices

Each alert evaluation also checks the ingestion (`Auth`) and alert (`Alerts.Auth`) certificates by thumbprint in `Cert:\LocalMachine\My`, then `Cert:\CurrentUser\My`, of the account running it. A certificate that is missing, expired or within `Alerts.CertificateWarningDays` (1-365, default 30) of expiry raises the `Certificates` incident, with subject `[NSP.ScanBridge] Certificate renewal required`, condition codes such as `IngestionCertificateExpiring` or `AlertCertificateExpired`, and the fewest days remaining. Thumbprints, subjects and tenant details are not included. The notice is sent once per condition set: a daily countdown does not repeat it, expiry after a warning sends again, and renewal resolves the marker. An unreadable store reports `CertificateCheckFailed`. `Certificates` is a reserved route name.

The notice depends on alert mail still working. An expired or missing alert certificate stops the alert sign-in itself, so act on the warning before expiry. External RMM monitoring is still needed for that case.

## Delivery limits

A Graph-accepted send is not confirmation that a ticket was opened. A crash after acceptance but before marker persistence may cause a duplicate. An unsuccessful send is not marked and can be retried. After a healthy check, the marker is retained but marked resolved. A subsequent unhealthy occurrence can therefore produce a new ticket. Transient health flapping can still open repeat tickets; consider an operator-defined stable recovery window before production.

**Status:** Development-only. Run offline tests and then synthetic live mail tests before using for production incidents.

The scheduled ingestion runner calls alert evaluation even after a worker exception. Its WorkerFailure incident remains active until a subsequent successful worker pass; HealthCheckFailed covers unreadable/incomplete queue health. These alerts are not independent of the host: a powered-off machine, broken scheduler, or failed authentication still requires external RMM monitoring. A Graph-accepted email is not a verified dispatch ticket.

## Stabilized local behavior

Alert evaluation holds an exclusive `alerts.lock` file in the configured state directory through health evaluation, sending and marker persistence. A concurrent alert process fails closed. Successful health evaluation resolves the `HealthCheckFailed` marker so a later failure can alert again. Marker replacement uses a true null backup filename in both PowerShell hosts.

Only a caller explicitly reporting `-WorkerSucceeded` resolves an earlier `WorkerFailure`; the ingestion runner supplies this after a pass without an exception. Standalone alert evaluation does not imply worker success. `-WorkerFailed` and `-WorkerSucceeded` are mutually exclusive. Configure unique generic route names; `System` and `Worker` are reserved internal incident names.

`-WhatIf` skips authentication, mail sending and marker updates, but may create/open the serialization lock and read local health. A send failure leaves the incident unmarked. A marker persistence failure is reported, releases the lock and permits retry, which can duplicate a previously accepted message. Exactly-once mail delivery is not guaranteed. Enabled offline tests use fake authentication and mail transports; no real mail is sent.
Enabled alert authentication uses the private ScanBridge connection adapter, selecting a shared connector with ContextScope capability and explicitly requesting Process for Alerts.Auth. Unsupported capability fails before authentication or mail. The dedicated alert identity is still separate from ingestion, and validation requires its expected tenant/application/AppOnly/Process context. WhatIf skips the adapter. This does not grant mail permission, change the shared connector default or prove live ticket delivery.