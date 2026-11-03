# Scanner delivery discovery

Scanners deliver to SMB in different ways. Some write the final `.pdf` name while holding it
exclusively; some let others read while they write; some write a temporary name and rename it
when done. `Invoke-NSPScanBridgeDeliveryDiscovery` observes real test scans and records which
pattern a device uses, so the simulator profile and the readiness policy can match it. It is
read-only: it never moves, changes, claims or uploads a file, and makes no network call.

```powershell
pwsh.exe -NoProfile -File .\scripts\Invoke-ScanBridgeDeliveryDiscovery.ps1 -Path 'C:\ScanTest' -DeviceName 'Front copier' -DurationSeconds 180
# Correlate with simulator logs (records file names):
Invoke-NSPScanBridgeDeliveryDiscovery -Path 'C:\ScanTest' -DeviceName 'Lab simulator' -IncludeFileNames
```

Point the scanner at a **dedicated, empty test folder** on the receiving computer and send a few
test scans of different lengths during the capture window. Do not use a live route Source while
the ScanBridge task is enabled; the worker would claim files mid-observation. Files already in the
folder are ignored. The output directory (default `%LOCALAPPDATA%\NSP\ScanBridge\Discovery`) must
be outside the observed folder.

## What is observed

Every new file name, including temporary names, through FileSystemWatcher events (Created,
Changed, Renamed, Deleted) and polling of size and modified time every `-PollMilliseconds`
(default 250). Each sample probes the file twice and closes each handle immediately:

- **Shared read:** read access that lets the writer keep writing, renaming and deleting. A writer
  that opened the file exclusively refuses it with a sharing violation.
- **Exclusive:** read access that allows only rename and delete. It fails while any writer handle
  is open. When it succeeds on a `.pdf`, the PDF structure check (header and `%%EOF`) runs.

Error categories are recorded as SharingViolation, LockViolation, AccessDenied, NotFound or Other.
`-PollingOnly` disables the watcher; a temporary name that vanishes as a same-length PDF appears is
then recorded as an inferred rename.

## Classification

Each file gets a lifecycle that follows renames, and an outcome: Completed, Incomplete (no
`%%EOF`, as a cancelled scan leaves it), StillChanging, NeverAvailable, TempNotRenamed, Deleted or
Replaced (a name reused during the capture). Only samples taken while the file was still changing
count as evidence.

| Class | Evidence |
| --- | --- |
| TempRename | A temporary name renamed to `.pdf`, with no change after the rename |
| DirectExclusive | Growth at the `.pdf` name; shared reads refused by sharing violations |
| DirectReadable | Growth at the `.pdf` name; shared reads allowed |
| Hybrid | Shared reads alternated, growth continued after a rename, or completed files disagree |
| Unknown | No sample while changing, or probes failed for other reasons, such as access denied |

Confidence is High with three or more consistent samples, Medium with one or two, and Low
otherwise. A device profile with one completed file is capped at Medium. Uncertain behavior stays
Unknown or Hybrid rather than being forced into a class.

## Output

- `events_<session>.csv`: one row per observation, with UTC, local monotonic milliseconds,
  sequence, computer, file key (F1, F2...), extension, event, size, probe results and errors.
- `profile_<device>_<UTC>.json`: classification, confidence, evidence, per-file summaries,
  recommendation, simulator settings, capture and clock metadata, and limits. `Override` is
  reserved for an operator's manual classification. Each capture writes a new timestamped file.
- With `-IncludeFileNames` only: file names in both files, plus `timing_<session>.csv` in the
  `Filename,Event,Utc` form that `Compare-MfpScanTiming.ps1` reads. Its events are
  DiscoveryFirstSeen, DiscoveryRenamed, DiscoveryLastChange and DiscoveryComplete. Without the
  switch, no file names or paths are written.

## Recommendation and simulator settings

The suggested `MinimumAgeSeconds` is never below the ScanBridge default of 20: it is twice the
longest pause observed between writes, plus 10 seconds. Ambiguous profiles keep the defaults. The
worker's exclusive-open and structure checks stay on in every case. Size stability and a
successful exclusive open are signals, not proof the writer finished.

For a classified device, `SimulatorSettings` gives `Invoke-MfpSmbSimulator.ps1` values:
`-Profile Rename` or `Normal`, `-FileSharing Read` or `None`, `-ChunkKiB 64`, a `-DelayMs` that
spreads 64 KiB chunks over the median observed write rate, and the median completed size. These
are approximate and bounded by the sampling interval.

## Limits

File observation cannot reveal SMB CREATE access or share flags, chunk sizes, write patterns or
protocol commands. Use SMB server ETW or a packet capture, with consent, when those matter. Writes
or pauses shorter than one sampling interval are not seen. Probe handles are brief, but one can
delay a writer that reopens the file exclusively. Timestamps are this computer's UTC clock plus a
local monotonic stopwatch; comparing with another computer needs a measured clock offset, such as
the simulator's WinRM probe, and its uncertainty. Repeat the capture after firmware or scan-profile
changes.

`tools/Test-DeliveryDiscovery.ps1` covers lifecycle, classification and profile rules with synthetic
observations. It also runs real local exclusive, readable, temporary-rename, aborted and
polling-only writers against the observer, with processing and network calls forbidden. It does
not establish any real scanner's behavior.
