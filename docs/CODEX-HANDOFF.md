# Codex handoff — ScanBridge stabilization

Date: 2026-10-30
Status: Development only. No PHI or tenant testing authorized by this handoff.

## First actions on the owner's Windows workstation
1. Pull latest main from ITGuyFromIA2/NSP-ScanBridge. Do not change GitHub Actions or enable any CI workflow.
2. Inspect working-tree changes before modifying files and follow NSP-PoSHToolkits-Coordination ownership rules.
3. Run these manually under Windows PowerShell 5.1 and PowerShell 7:
   - .\tools\Test-Parsing.ps1
   - .\tools\Test-Repo.ps1
4. Fix failures one by one, preserving minimal synthetic fixtures. Do not publish to PowerShell Gallery or deploy to any customer.
5. Run local NSP.RepoTools privacy scan using the private token list. GitHub-based work cannot access ignored local tokens/configuration.

## Code and design inspection priorities
- Verify syntax and invocation in Private/Save-NSPScanBridgeReceipt.ps1 and Public/Send-NSPScanBridgeAlert.ps1. On 2026-10-30, two conditional hashtable values were parenthesized to avoid PowerShell parsing errors.
- Confirm that Private/Send-NSPScanBridgeUploadSession.ps1 uses the correct Microsoft Graph upload-session contract. Test 320 KiB-multiple chunks and the final completion response under PS 5.1.
- Verify that Invoke-NSPGraphRequest -Method POST serializes @microsoft.graph.conflictBehavior correctly and that the returned uploadUrl is accessible without a bearer token.
- Validate the no-overwrite conflict behavior with synthetic PDFs in an isolated test library.
- Audit receipt state transitions; detect and hold corrupted JSON, missing receipts, changed PDFs, remote upload ambiguities, and post-acknowledgment archive failures.
- Test Resolve-NSPScanBridgeJob for delegated-context rejection, mismatched remote bytes, exact match, and crash recovery.
- Review spooled temporary download ACLs and retention. Keep patient data, source filenames, tenant IDs, and raw Graph exceptions out of shared logs and ticket emails.
- Verify separate app-only Graph identities: SharePoint Sites.Selected for ingestion and mailbox-scoped Mail.Send for alerts.
- Validate Send-NSPScanBridgeAlert with a fake transport before sending any real email. A successful Graph sendMail request does not confirm creation of a dispatch ticket.

## Critical operational constraints
- Dispatch destination must be supplied only through private deployment configuration.
- No GitHub Actions automation: an unapproved workflow produced repeated failure notifications and was deleted in commit f2789e920c3dbecac6d1e5353863f3047d2fd573.
- No production PHI, no customer deployment, and no PowerShell Gallery publish until tests and scope review succeed.
- Work so far was committed using GitHub tools; no local Windows runtime or live tenant validation was performed.

## Completion criteria
PowerShell 5.1/7 manual tests green, code reviewed, Graph test-document upload/readback/reconciliation verified, synthetic alert send tested and deduped, RepoTools privacy check green, PTMaster authorization documented.
