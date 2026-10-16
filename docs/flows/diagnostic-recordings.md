# Diagnostic recording and replay

## Requirement and ownership

The user requested retained audio and raw transcripts on September 10, 2026,
after a dictation silently lost its ending. Owner: Flo maintainers.
Capture enough evidence to distinguish audio capture, recognition, formatting,
cleanup, and dispatch failures. Recognition accuracy and decoder settings are
unchanged. The separate daily transcript log keeps its existing behavior.

## Flow and stored evidence

`AppDelegate.beginDictationSession` snapshots the opt-in
`Settings.saveDiagnosticRecordings` preference and creates a
`DictationDiagnosticStore.Recording`. Default is off. A manual menu retry creates
another archive if enabled. Command mode and CLI replay do not create archives.

`DictationSessionPipeline` owns the archive for that generation. At release,
`DictationDelivery.release` saves audio before the voice gate and silence trimming.
`release` also saves audio for sessions started by manual retry. The first save
wins, so a trimmed request cannot overwrite the original capture.

The archive directory name is the timing trace UUID. Each contains:

- `metadata.json`: schema version, start time, build identity, selected models,
  microphone setting, effective vocabulary, cleanup/style settings, corrections,
  and snippets. Actual recognition/cleanup models and capture device events
  also appear in the events below.
- `environment.txt`: the existing content-free environment record, including
  macOS, chip, memory, build configuration, and full bundled commit identity.
- `original.wav`: captured 16 kHz mono Float32 PCM after microphone conversion,
  before silence trimming. This is not the microphone's native hardware format.
- `inference-<UUID>.wav`: exact trimmed samples submitted to each Whisper call.
- `events.jsonl`: ordered recognition requests/results, raw Whisper text and
  segment timestamps, postprocessed recognition output, assembled transcript,
  cleanup input, backend cleanup candidates, cleanup result, final transcript,
  and empty/error/cancellation outcomes. Empty strings are retained.
- `timing.jsonl`: structured events from session start onward, including chunk
  boundaries, retries, model identities, capture device, and paste dispatch.
  Paste dispatch success does not prove visible insertion in the target app.

`Transcriber.transcribe(samples:)` records the exact inference input and raw
results before filtering. `LocalTextModelPolicy` records Apple/Ollama cleanup
candidates before validation. Task-local archive context keeps overlapping
sessions separate. Archive writes run on one utility queue, outside capture and
inference threads. Normal shutdown drains that queue.

## Retention and failures

Storage is under `Application Support/<app name>/DiagnosticRecordings`, with
0700 directories and 0600 files. The setting affects newly started dictations;
an existing archive may finish after it is turned off. Archive deletion is
serialized with writes. Late results do not recreate deleted directories.

Pruning removes folders older than 7 days, then oldest folders until the stored
file bytes total at most 1 GB. It runs at launch, after writes, and hourly while
open. A write can temporarily exceed the cap before its immediate pruning pass.
The app cannot expire files while closed. The quota applies only to managed UUID
folders, not unrelated files placed in the root. Move a case outside this folder
before expiry if it needs longer investigation.

A write or pruning failure leaves dictation delivery unchanged, logs a
content-free warning, and displays an error in History settings. Archives can be
incomplete after disk failure or abrupt process termination. Audio is persisted
at release, so this does not recover an in-progress recording after a crash.
The ordinary menu retry queue still lives in memory.

## Replay

Use a local release binary from this checkout and an explicit saved file:

```bash
swift build -c release --disable-automatic-resolution
.build/release/LocalFlow --replay /absolute/path/to/original.wav --runs 1 --no-cleanup
.build/release/LocalFlow --transcribe /absolute/path/to/inference-UUID.wav --no-cleanup
```

`--replay` reruns incremental scheduling; `--transcribe` sends a file through
recognition without that scheduling. The second command isolates a failed chunk
or full-utterance retry. Compare raw Whisper text, `assembledTranscript`,
`cleanupInput`, `cleanupCandidate`, and `finalTranscript` to identify the first
stage missing the reported words. Keep a human reference transcript alongside
the case when available. The archive cannot infer words never captured.

Replay uses current settings unless overridden; it does not automatically restore
`metadata.json`. Match the saved model with `--whisper-model` on `--replay` and
check the saved vocabulary, corrections, snippets, cleanup model, and style when
comparing outputs. Model names and build metadata are recorded, but model weight
hashes are not. Do not treat a changed model or settings as an identical replay.

## Verification

Verified against base commit `aa5278631c15cbc21d878a460234a002eaa17a6c`
plus the uncommitted diagnostic retention changes. Diff artifact:
`/tmp/localflow-diagnostic-retention.diff`. Environment: macOS 26.6.2,
arm64, Apple Swift 6.3.3.

- PASS: `swift test --disable-automatic-resolution --filter
  'DictationDiagnostic|SettingsApplicationRoutingTests|DictationSessionPipelineTests|DictationTraceTests|LocalTextModelPolicy'`,
  62 tests. Evidence: `/tmp/localflow-diagnostic-focused-tests.log`.
- PASS: `swift test -c release --disable-automatic-resolution`, 228 tests,
  zero failures. Evidence: `/tmp/localflow-diagnostic-release-tests.log`.
  This includes exact Float32 WAV recovery through WhisperKit's replay loader,
  0700/0600 permissions, age/size pruning, deletion with late writes, empty and
  failed recognition, preserved transcript stages, and the default-off setting.
- PASS: `swift build -c release --disable-automatic-resolution` and
  `git diff --check`. Evidence: `/tmp/localflow-diagnostic-release-build.log`.
- PASS: independent read-only review. Its timeout-outcome and trimmed-retry
  findings were fixed and rechecked. `DictationSessionStallTests` now asserts
  the archived timeout message. The new assertions failed before the fix,
  as recorded in `/tmp/localflow-diagnostic-timeout-red.log`, and pass in the
  final 228-test release run. A build interrupted by a concurrent test edit
  was rerun successfully after edits finished.
- NOT RUN: installed-app settings interactions, microphone recording, real
  Whisper/cleanup inference with archive capture, and target-app insertion.

Tests use isolated temporary folders and synthetic audio. They do not establish
actual microphone quality or Whisper accuracy. Two existing release-test compiler
warnings remain in `InjectionCoordinatorTests` and `StartupModelSequenceTests`.
The invalid-root test intentionally emits the content-free archive failure
warning. The initial implementation did not replace or relaunch the running
application.

## Local installation

The user subsequently requested a local build, commit, and push. On September
10, 2026, `./scripts/local-app.sh install` built and installed LocalFlow Local
1.4.1, preserved the previous local bundle, and observed speech recognition ready
in 0.98 seconds. Installed-app signature verification passed. Evidence:
`/tmp/localflow-diagnostic-install.log`.

Diagnostic retention is enabled in the local app's preferences. Production
preferences are unchanged. The bundle was built from the pre-commit working tree,
including the existing local theme-icon edit, and reports its base revision with
a modified-tree flag. The commit excludes that unrelated edit and `.claude`.
No microphone dictation or target-app insertion was performed during installation;
the next live recording remains the end-to-end archive check.

## E4: bounded retained WAV buffers

Requirement source: authorized efficiency report item E4. Owner: Flo maintainers.
`RetainedAudioFile.writePCM` allocates one Float32 mono PCM buffer capped at
16,384 frames, or 64 KiB, and reuses it for exact frame writes. The final partial
write sets its own `frameLength`, so stale buffer contents cannot become extra
audio. Sample rates and Float32 values are unchanged. Empty input publishes a
readable zero-frame WAV without allocating a PCM buffer.

The shared diagnostic and personal-voice writer still creates a private 0600
sibling staging file, closes and finalizes its header, then atomically moves or
replaces the destination. Input and file errors throw; the existing defer removes
staging on failure. Retention callers keep their existing error handling.

`Tests/LocalFlowTests/RetainedAudioFileTests.swift` checks exact 16 kHz and 48 kHz
round-trips over three full buffers plus 137 frames, replacement, permissions,
empty input, and every sample of a 310-second synthetic 48 kHz recording plus a
seven-frame tail. It also checks invalid rates preserving an existing file,
failure under a missing parent, and failed publication without leftover staging.
The integration selection exercises original retention, diagnostic failure,
personal voice, retry, and quiet-tail contracts.

PASS: five writer tests in `/tmp/flo-e4-focused.log` and 147 integration tests in
`/tmp/flo-e4-integration.log`, with zero failures and command exit 0. Exact
commands, environment, verified base/diff, and final release results are in
[E4 capture verification](dictation-recovery.md#e4-bounded-capture-snapshots).
Disk-full and mid-write device failures were NOT RUN; AVAudioFile write errors
still propagate through the existing throwing call. No user recordings or model
downloads were used. Runtime speedup and peak process memory were not measured.

## E5: diagnostic accounting and typed timing writes, October 15, 2026

Owner: Flo maintainers. Requirement source: the authorized efficiency report E5,
against preview foundation commit `47f1bb906e8f3b2291a617f13dd9bb0b11300e74`.
Reduce repeated diagnostic and idle audio work. Quotas, expiry, content filtering,
serial ordering, recording opt-in, error reporting, and model defaults remain
required. Capture recovery and ranged snapshots belong to other items.

`DictationDiagnosticStore` keeps queue-owned file sizes, archive creation dates,
and an oldest-first index. Beginning an archive, launch/hourly maintenance,
explicit `prune`, and the next write after failed I/O reconcile disk state.
Ordinary event appends stat their changed file instead of enumerating all
archives. Audio replacement accounts for the actual closed WAV, including its
header, and subtracts the previous file size. Every successful write checks
expiry and the total byte quota immediately. Expired folders are removed before
content enumeration during reconciliation. Pruned/deleted recordings cannot
recreate their folders through late event or audio writes. Successful deletion
clears accounting; failed deletion invalidates it.

The directory is owned by this store, which serializes mutations on its existing
utility queue. Changes made outside the store to other files or archive folders
are discovered at the next full reconciliation. External growth of the file
being appended is included by its post-write stat. This does not provide a
filesystem watcher or coordination between multiple store instances writing to
the same root.

`DiagnosticsArchive.record` now sanitizes typed events through
`DiagnosticsSnapshot.sanitized`, also used by legacy parsing, then encodes once.
Schema/ordinal validation and the field/environment whitelists are shared.
New trace files keep atomic publication and sanitize environment metadata once.
Appends keep the original environment. Nonfinite retained metrics still throw. Second-resolution filenames
match the existing ISO8601 archive format even for fractional live timestamps,
so restarting does not split one trace into two files.

Acceptance examples are covered by `DiagnosticsArchiveTests` for typed/private
field filtering, invalid schema/ordinal rejection, encoding failures, 200 ordered
events across restart, migration, expiry, export, and permissions.
`DictationDiagnosticStoreTests` covers growing events, immediate quota eviction,
closed WAV replacement accounting, expiry without maintenance, restart/external
reconciliation, external growth of the appended file, failed-write recovery,
240 concurrent complete event writes with
per-producer ordering, deletion before late writes, unmanaged neighbors, and
private permissions. All fixtures are synthetic.

The audio demand/cadence change and warm-start contract are recorded in the
[E5 recovery section](dictation-recovery.md#e5-idle-audio-analysis-and-spectrum-demand-october-15-2026).
No runtime speedup is claimed. These checks measure behavior and callback counts,
not CPU, power, end-to-end latency, or recognition accuracy.

Verification environment: macOS 27.0.1, arm64, Apple Swift 6.4. Commands ran in
this isolated worktree with its own `.build-e5` scratch directory. After the
checks, build artifacts were moved under the ignored `.build/e5` directory. Evidence covers
the baseline above plus the E5 diff at `/tmp/flo-e5.diff`; the handoff includes the
final local commit. No app installation, model download, microphone capture,
clipboard interaction, or typing was performed.

- PASS, exit 0: `swift test --scratch-path .build-e5 --disable-automatic-resolution --filter 'DiagnosticsArchiveTests|DictationDiagnosticStoreTests|AudioCaptureLifecycleTests'`, 20 baseline tests. Evidence: `/tmp/flo-e5-baseline.log`.
- PASS, exit 0: `swift test --scratch-path .build-e5 --disable-automatic-resolution --filter 'DiagnosticsArchiveTests|DictationDiagnosticStoreTests|AudioCaptureLifecycleTests|DiagnosticsSnapshotTests|WaveformOverlayTests'`, 56 tests. Evidence: `/tmp/flo-e5-focused.log`. Initial runs exited 1 because new fixtures assumed a nil synthetic device identity matched the system default and underestimated the WAV header size. Those fixture assumptions were corrected; one failed-run log is `/tmp/flo-e5-fixture-adjustments.log`.
- EXPECTED FAIL, exit 1: `swift test --scratch-path .build-e5 --disable-automatic-resolution --filter 'AudioCaptureLifecycleTests.testSpectrumDemandAndRendererCadenceDoNotDropCapturedAudio'`, with demand/cadence gates temporarily removed and then restored. Five assertions detected 50 spectrum callbacks where the bounded fixture requires two. Evidence: `/tmp/flo-e5-metering-red.log`.
- PASS, exit 0: `swift test --scratch-path .build-e5 --disable-automatic-resolution --filter 'Diagnostics|DictationDiagnostic|AudioCaptureLifecycle|AudioRecorder|NativeAudio|DictationSession|DictationDelivery|DictationTrace|WaveformOverlay'`, 135 tests. Evidence: `/tmp/flo-e5-regressions.log`.
- PASS, exit 0: the same 135-test selection with `swift test -c release --scratch-path .build-e5 --disable-automatic-resolution --filter 'Diagnostics|DictationDiagnostic|AudioCaptureLifecycle|AudioRecorder|NativeAudio|DictationSession|DictationDelivery|DictationTrace|WaveformOverlay'`. Evidence: `/tmp/flo-e5-release.log`.
- PASS, exit 0: `git diff --check`, repeated after implementation.
- NOT RUN: full suite, real-device audio/converter continuity, real speech recognition, live HUD appearance, CPU/power profiling, app installation, and external publication. Flo maintainers own these checks after integration. Existing compiler warnings were also present in the baseline.

## R6 recovery-independent expiry, October 16, 2026

Owner: Flo maintainers. The R6 request requires retained-audio expiry to start
even when legacy timing recovery or personal voice import fails. It also requires
late diagnostic transcript stages to reach existing personal clips while user
review decisions survive. The import policy and its acceptance cases are in
[the R6 personal voice record](personal-voice.md#r6-diagnostic-import-reconciliation-october-16-2026).

`AppDelegate.applicationDidFinishLaunching` calls `DiagLog.startSession`, which
attempts timing recovery on its serial queue before invoking the existing
retained-audio maintenance callback. The callback now runs after every attempt,
including failure. The storage-injected `startSession` overload is shared by
production startup and synthetic recovery tests. It preserves the legacy log
and privacy migration version after failed ingest, including logs over 5 MB.
A successful later attempt permits privacy cleanup and size rotation. Recovery
failure still makes timing history reads/exports report failure.

`DictationDiagnosticStore.startMaintenance` runs its first reconciliation/prune
on the existing utility queue before scheduling hourly passes. Expiry does not
parse event or metadata contents. E5 byte accounting, reconciliation, quota,
private writes, and serialized deletion remain in use. Recovery still precedes
expiry so successful ingest can archive timing sidecars before removal. After a
failed recovery, expired diagnostic folders remain subject to the seven-day and
1 GB policies, while the legacy log is kept for retry. A malformed source cannot
disable that retention. Personal voice has no automatic expiry; its permanent
copies survive diagnostic source deletion.

`DiagnosticsArchiveTests.testFailedLegacyRecoveryStillStartsExpiryAndKeepsLogForSuccessfulRetry`
uses malformed synthetic sidecars and an oversized legacy log to verify failure,
maintenance invocation, expiry, retained log evidence, and successful retry.
`testSuccessfulRecoveryPrecedesExpiryAndUnbundledStartupStillCallsMaintenance`
verifies log and sidecar ingest before expiry and the unbundled callback path.
No live app, microphone, clipboard, real diagnostic archive, or personal voice
data was inspected or deleted.

Verification source: foundation `47f1bb906e8f3b2291a617f13dd9bb0b11300e74`,
unchanged E5 patch `fd2e38336b8c451dff16d03ab69b80735b57ea52` cherry-picked as
`412f574`, plus the R6 diff at `/tmp/flo-r6.diff`. The implementation handoff
supplies the final local R6 commit. Environment: macOS 27.0.1, arm64, Apple Swift
6.4. Dependencies were copied from the existing E5 cache into this worktree's
ignored `.build`. Initial baseline preparation failed because copied artifact
paths referenced E5's old scratch location; correcting only the copied metadata
resolved that build failure. No dependency installation was needed.

- PASS, exit 0: `swift test --disable-automatic-resolution --filter 'DiagnosticsArchiveTests|PersonalVoiceStoreTests|DictationDiagnosticStoreTests'`,
  41 baseline tests. Evidence: `/tmp/flo-r6-baseline.log`.
- EXPECTED FAIL, exit 1: `swift test --disable-automatic-resolution --filter 'PersonalVoiceStoreTests.testDiagnosticImportReconcilesLate|PersonalVoiceStoreTests.testDiagnosticReconciliation|PersonalVoiceStoreTests.testInterruptedImport'`,
  three new tests against the original import implementation, 13 failed
  assertions. Evidence: `/tmp/flo-r6-import-red.log`.
- EXPECTED FAIL, exit 1: `env CFFIXED_USER_HOME=/tmp/flo-r6-test-home swift test --disable-automatic-resolution --filter 'DiagnosticsArchiveTests.testFailedLegacyRecoveryStillStartsExpiry'`,
  one test with the historical recovery callback gate temporarily restored,
  six failed assertions. Evidence: `/tmp/flo-r6-recovery-red.log`.
- EXPECTED FAIL, exit 1: the same recovery command with premature legacy-log
  purging temporarily restored, one test with three failures, including the
  missing-log read. Evidence: `/tmp/flo-r6-legacy-preservation-red.log`.
  Both seeded changes were restored before final verification.
- PASS, exit 0: `env CFFIXED_USER_HOME=/tmp/flo-r6-test-home swift test --disable-automatic-resolution --filter 'DiagnosticsArchiveTests|PersonalVoiceStoreTests|DictationDiagnosticStoreTests'`,
  47 tests. Evidence: `/tmp/flo-r6-focused.log`. The synthetic home also redirects
  incidental diagnostic logging and test preferences away from the user home.
- PASS, exit 0: `env CFFIXED_USER_HOME=/tmp/flo-r6-test-home swift test --disable-automatic-resolution --filter 'Diagnostics|DictationDiagnostic|PersonalVoice|NativeAudioRecording|DictationSession|DictationTrace|DictationDelivery'`,
  129 tests. Evidence: `/tmp/flo-r6-regressions.log`.
- PASS, exit 0: `env CFFIXED_USER_HOME=/tmp/flo-r6-test-home swift test -c release --disable-automatic-resolution --filter 'Diagnostics|DictationDiagnostic|PersonalVoice|NativeAudioRecording|DictationSession|DictationTrace|DictationDelivery'`,
  129 tests. Evidence: `/tmp/flo-r6-release.log`. Compiler warnings about capture
  ownership and concurrency were also present in the baseline.
- PASS, exit 0: `git diff --check`.
- NOT RUN: full suite, app packaging/installation, live startup, microphone
  capture, clipboard interaction, real speech recognition, and UI review/export.
  These are maintainer integration checks. No latency or runtime resource claim
  follows from the synthetic tests. No push, PR, merge, or publication was done.
