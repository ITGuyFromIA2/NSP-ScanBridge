# Read-only readiness comparison

Run this diagnostic before selecting a completion heuristic or changing scheduling. It reads the
same private settings PSD1 as the worker and uses only selected Routes.Name, Source and
MinimumAgeSeconds. It requires neither Graph setup nor existing spool/archive directories. Route
age defaults to 20 seconds when absent, matching the worker's route configuration default. The
standalone readiness command's existing 15-second parameter default remains unchanged.

```powershell
# From the reviewed ScanBridge checkout, under the account whose source access is being assessed:
powershell.exe -NoProfile -File .\scripts\Watch-ScanBridgeReadiness.ps1 -ConfigurationPath 'C:\Private\ScanBridge.psd1'
pwsh.exe -NoProfile -File .\scripts\Watch-ScanBridgeReadiness.ps1 -ConfigurationPath 'C:\Private\ScanBridge.psd1' -RouteName RouteA -DurationSeconds 120

# Metadata comparison without potentially interfering exclusive-open probes:
.\scripts\Watch-ScanBridgeReadiness.ps1 -ConfigurationPath 'C:\Private\ScanBridge.psd1' -MetadataOnly -PollingOnly

# More frequent observations with explicit diagnostic thresholds:
.\scripts\Watch-ScanBridgeReadiness.ps1 -ConfigurationPath 'C:\Private\ScanBridge.psd1' -PollMilliseconds 250 -HeartbeatSeconds 2 -StableQuietSeconds 5 -StableSamples 3 -StrictQuietSeconds 30 -StrictSamples 5
```

Use a separate session from any production worker to study a synthetic source first. The diagnostic
never invokes intake (including IntakeOnly), claims/moves/deletes a document, writes receipts,
authenticates, uploads, sends mail, registers a task or configures Sysmon. It does not install
dependencies. Worker readiness/scheduling defaults are unchanged. Closing the console/Ctrl+C
stops the observation loop; normal pipeline cancellation unwinds its finally block to unregister
only its own event subscriptions/jobs and dispose watcher/probe handles.

## Policies

| Policy | Eligibility | Default |
| --- | --- | --- |
| AgeAndExclusive | Nonempty PDF, configured minimum age since LastWriteTimeUtc, successful exclusive read-open observation | Configured route age, default 20 seconds |
| StableWindow (diagnostic only) | Nonempty PDF, observed size/modified quiet duration, minimum polling samples, successful exclusive probe | 5 seconds and 3 samples |
| StrictQuiet (diagnostic only) | Same sustained-observation rule, stricter configurable window/sample count | 30 seconds and 5 samples |

Strict thresholds must be at least the stable thresholds. All selected modes use the same sampled
file lifecycle and same brief probe. AgeAndExclusive and the production readiness command share
the metadata predicate. The production command additionally requires a PDF header and `%%EOF`
trailer, which this diagnostic does not yet report. Quiet/sample policies are comparisons, not enabled worker modes.
Metadata-only mode still reports metadataEligible, but holds each policy with LockNotTested;
it never claims lock-verified WOULD PROCEED. Probe Unavailable can mean a conflicting handle,
ACL failure or a race with disappearance; it is not proof of an active writer. Every opened probe
is disposed immediately. Probes can briefly prevent a writer from reopening; use MetadataOnly
when that interference is unacceptable. Polling is a heuristic observation, not completion proof.

## Output and lifecycle

Startup prints effective thresholds. State changes and HeartbeatSeconds print time, route, file,
actual event source, presence status, elapsed observation time, size/modified values and changes,
quiet duration, polling sample count, probe result and each policy's decision/reasons. First ready
decisions remain available for comparison; later changes revoke current readiness and show time
since the first decision, even if an age-only policy immediately becomes eligible again. No final
producer completion time is inferred. Duplicate Changed hints conservatively reset stability;
watcher notifications do not count as stable polling samples.

Illustrative synthetic output excerpt (other per-sample columns abbreviated here):

```text
14:01:02.000 RouteA sample.pdf [FileSystemWatcher.Created] status=Present ... AgeAndExclusive=HOLD(MinimumAge)
14:01:03.000 RouteA sample.pdf [Polling.Sample] ... lock=Unavailable ... HOLD(ExclusiveProbeFailed)
14:01:07.000 RouteA sample.pdf [Polling.Sample] sizeChanged=True quiet=0.00s samples=1 ... HOLD
14:01:28.000 RouteA sample.pdf [Polling.Sample] ... AgeAndExclusive=WOULD PROCEED
14:01:38.000 RouteA sample.pdf [Polling.Sample] ... StrictQuiet=WOULD PROCEED
14:01:42.000 RouteA sample.pdf [FileSystemWatcher.Changed] ... AgeAndExclusive:REVOKED observation 14.00s after first decision
```

FileSystemWatcher.* means a filesystem notification. Polling.Discovery includes pre-existing
candidates and missed-event recovery; Polling.Sample is periodic metadata observation. Neither
is labeled Sysmon; this version reads no Sysmon channel. Watcher errors warn of uncertain
coverage and polling continues. PollingOnly disables watchers. Sources are nonrecursive, matching
current intake. No filename is evaluated as code or treated as a wildcard path for opening.

Rename-away and deletion are displayed separately. Reappearance after absence, changed creation
time or a Created/Renamed notification begins a new generation with no inherited decisions.
This is not a durable file identity: a rapid replace missed by watcher and polling with preserved
metadata may remain indistinguishable. Writes that restore the same size/timestamps between
observations can likewise escape detection. Producers that close between bursts can pass every
heuristic; prefer a supported final-rename/completion-marker contract where available.

Per-file state and the pending notification queue are bounded by MaximumTrackedFiles (default
1,000) and four times that limit respectively. Missing paths are retired from observation after
two polling passes; state is retained only up to the cap. All tracked files are sampled each
cycle, without per-file waiting. At capacity, omitted observations are explicitly warned and
new candidates may remain unobserved until slots become available. Narrow route selection or
increase the bound before drawing coverage conclusions. Event-heavy work can lengthen the
effective polling interval; queued notifications are drained in bounded batches.

Console-only is the default: no log file is created. Filenames, route names and source paths may
be sensitive. Optional PassThru emits structured observations to the caller's pipeline, including
literal paths and per-mode first-decision timestamps. Redirect/store these only to an explicitly
chosen restricted destination; do not post real output in source control, tickets or shared logs.
DurationSeconds=0 watches continuously; a positive duration enables bounded diagnostic runs.

## Validation and proposed shared-helper boundary

tools/Test-ReadinessDiagnostic.ps1 uses synthetic local writers and forbidden processing/network
stubs. It covers baseline equivalence, locked and shared-access writes, empty growth, late bursts
and revocation, rename/delete/recreate, simultaneous routes, metadata-only, missed-event polling,
route filtering, byte preservation and normal event/job cleanup under PowerShell 5.1 and 7.
This does not establish the scanner's longest pause, ultimate completion, real Ctrl+C behavior
in every terminal, production account ACLs or customer-host behavior.

The owner requested offering the watcher to PTMaster as an NSP.Win helper candidate. The private
Watch-NSPScanBridgeFileObservation engine accepts only generic source descriptors and observation
options; it knows nothing about PSD1, readiness policy, receipts, Graph, scheduling or accounts.
The public ScanBridge adapter owns configuration and policy comparison. Keep this implementation
in ScanBridge until PTMaster reviews the contract, naming, privacy, lifecycle and portability for
an appropriate NSP.Win module. No extraction or shared-module change is implied by this document.

References: Microsoft's [FileSystemWatcher](https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher)
and [Register-ObjectEvent](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/register-objectevent)
documentation describe notifications and session event subscriptions; neither establishes producer
completion or lossless observation.
