# ScanBridge dispatch escalation

Configure a private deployment copy of `config/ScanBridge.example.psd1` with an `Alerts` block. Set `Enabled = $true`, `To` to the approved dispatch ticketing address, `From` to the sender mailbox, and `StateDirectory` to a restricted, pre-created local folder.

Use `scripts/Send-ScanBridgeAlerts.ps1 -ConfigurationPath <private-config>` as an unattended monitoring task after the ingestion job. Never commit actual customer addresses, tenant identifiers or private configuration.

`Send-NSPScanBridgeAlert` uses existing `NSP.M365.Graph` functions and requires a separate `Alerts.Auth` app-only certificate registration. **Mail.Send application permission can permit broad mailbox access**: scope the sending application through Exchange RBAC for Applications or an appropriate application access policy, and validate that it can send only as the designated mailbox. This is separate from the ingestion app's site-restricted permissions.

Messages contain only generic route labels, condition codes, counts, and age. Never include patient names, document names, PDF attachments, actual local paths or any tenant identifier. Treat route labels as potentially sensitive and choose generic names. On a repeated identical condition, a persistent alert marker suppresses duplicate emails. A changed condition signature can cause a new ticket.

A Graph-accepted send is not confirmation that a ticket was opened. A crash after acceptance but before marker persistence may cause a duplicate. An unsuccessful send is not marked and can be retried. After a healthy check, the marker is retained but marked resolved. A subsequent unhealthy occurrence can therefore produce a new ticket. Transient health flapping can still open repeat tickets; consider an operator-defined stable recovery window before production.

**Status:** Development-only. Run offline tests and then synthetic live mail tests before using for production incidents.

The scheduled ingestion runner calls alert evaluation even after a worker exception. Its WorkerFailure incident remains active until a subsequent successful worker pass; HealthCheckFailed covers unreadable/incomplete queue health. These alerts are not independent of the host: a powered-off machine, broken scheduler, or failed authentication still requires external RMM monitoring. A Graph-accepted email is not a verified dispatch ticket.
