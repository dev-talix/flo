# Dictation recovery

## Requirement and owner

Owner: Flo maintainers. Requested September 9, 2026 after the user confirmed
speaking during a recording whose final recognition result was empty. Recover
empty dictations before discarding audio. Command mode, decoder settings, voice
gates, model selection, and audio persistence are outside this change.

## Behavior and path

`AppDelegate.beginDictationSession` snapshots settings and optional recording
retention into `DictationDelivery.Configuration`. `DictationDelivery` allocates
the dictation generation and owns its pipeline session. At release, AppDelegate
passes the recorder's paired audio result to `DictationDelivery.release`.

`DictationSessionPipeline.release` retains original audio before applying
`DictationAudioPreparation`. Captures with less than 0.3 seconds of detected
voice produce `insufficientVoice` without recognition or retry. That outcome
returns immediately even while an earlier dictation is waiting. The UI reports
heard-nothing, and archives keep the existing cancelled status. Command mode and
CLI replay use the same preparation rules; replay rejects silence before model
loading. Voiced time uses the existing analysis windows, not total clip duration.

The pipeline retries an empty full result once when the supplied audio has at
least 0.3 seconds of detected voice. Chunk/tail fallback consumes the same recovery
attempt. Requests contain prepared samples and the low-energy decision, so live
and replay callers do not repeat trimming or energy checks. Recovered text goes
through formatting and cleanup once. A second empty result emits `emptyTranscript`;
a thrown error emits `failed`. An unchanged decode can return empty again.

`DictationDelivery` correlates pipeline generations with mixed-mode injection
sequences. Success records transcript history and recent text before dispatch.
Empty and failed results skip injection and retain the latest three originals
in memory. `retryFailedDictations` drains them oldest first through the same
pipeline with current settings. Failed manual attempts are retained again;
manual retries never create personal voice clips. Quitting loses retry audio.
Optional [diagnostic recordings](diagnostic-recordings.md) keep independent disk
copies and do not restore the retry queue.

## Live transcript latency, October 15, 2026

Owner: Flo maintainers. The user reported a roughly ten-second wait for the
transcript panel, followed by updates in similar bursts. The requirement is
early, repeated previews during speech, including speech without pauses.
Final recognition, cleanup, delivery, and safe chunk boundaries retain their
existing contracts.

Timing-only inspection of 31 recent Whisper Turbo dictations on the installed
1.11.1 release found no preview requests. The first incremental result arrived
after a median 8.507 seconds, ranging from 8.402 to 12.689 seconds. Inference
took a median 446 ms across 88 calls. The eight-second timer sometimes fired
before eight seconds of audio existed, deferring recognition another four
seconds. Missing silence boundaries also deferred updates. These traces measure
result availability, not the moment AppKit displays text.

`AppDelegate.captureDictationContext` now selects previews for either speech
engine when live transcript is enabled. `IncrementalCadence` schedules snapshots
from one second and every second thereafter. A snapshot just below the initial
audio threshold retries on the next tick. `startPreviewIfNeeded` runs one preview
at a time and drops busy ticks. Preview text never advances committed audio or
enters final recognition, cleanup, history, or delivery.

Preview inputs cover at most the last 15 seconds after the committed boundary.
Long continuous holds show recent speech without joining text across omitted
audio. Release still recognizes every uncommitted sample. Chunk completion
updates the panel if it catches up with the displayed preview, or if no preview
succeeded. It preserves a preview covering newer words. Disabling live transcript
removes preview inference and retains the previous chunk schedule.

Release and Escape discard late preview output without interrupting running
inference. Explicit interruption and the existing release deadline cancel a
stalled preview, allowing Transcriber to quarantine its engine. Retrying can
then load a replacement engine instead of waiting behind the abandoned preview.

Acceptance checks are `TranscriptionModelTests` for cadence and disabled
previews, `DictationSessionPipelineTests` for repeated continuous-speech previews,
busy ticks, bounded input, full final audio, displayed coverage, and cancellation,
and `DictationSessionStallTests.testStalledPreviewReleasesDictationAndAllowsModelRecoveryAfterDeadline`
for recovery through the real Transcriber gate with a suspended fake engine.
The first preview regression run failed before the cadence change. The stall
regression separately reproduced the engine remaining loaded and retry failing.

Verified on macOS 27.0.1, Apple M5 Pro, Swift 6.4, base
`045683cec7d56fa2936ec0dfe742f46474e3b022` plus the uncommitted fix.
Evidence files use the `/tmp/flo-live-transcript-` prefix.

- PASS: `swift test --disable-automatic-resolution` and
  `swift test -c release --disable-automatic-resolution`, each with 386 tests,
  zero failures, and one optional HUD render test skipped. Logs are `tests.log`
  and `release-tests.log` under the evidence prefix. Red evidence is `red.log`
  and `stall-red.log`; the latter reproduced three recovery failures.
- PASS: `python3 -B Tests/StartupReadinessTests.py`, four tests;
  `git diff --check`; `LOCAL_BUILD=1 SKIP_PREWARM=1 ./scripts/make-app.sh`;
  `codesign --verify --deep --strict 'build/Flo Local.app'`. The signed local
  bundle is built, with installation and switching the running app NOT RUN.
- PASS: generated Samantha speech, 12.46 seconds, replayed through installed
  1.11.1 once and the new local bundle twice using `--replay
  /tmp/flo-live-transcript-fixture.aiff --runs N --no-cleanup --whisper-model
  openai_whisper-large-v3-v20240930_turbo`. The baseline had no live result
  before release. New first preview results arrived at 1.481 and 1.467 seconds,
  with median update intervals of 1.044 and 1.061 seconds. All 39 final words
  matched the baseline after case normalization. Release-to-result time was
  1.140 and 1.203 seconds versus 1.321 seconds before. Logs and outputs are
  `baseline.log`, `baseline.out`, `candidate.log`, and `candidate.out` under the
  evidence prefix. The new local identity needed 65.9 seconds of Core ML model
  preparation before replay; session timings exclude model loading.
- NOT RUN: live microphone capture, actual panel visibility timing, and insertion
  into the focused app. Replay checks recognition availability without opening
  the HUD, microphone, or injection path. Maintainers own this live check after
  installing the local bundle. Full source evidence is
  `/tmp/flo-live-transcript-final.diff`. No new abstraction was introduced.

The user subsequently requested rebuilding the local app. PASS:
`./scripts/local-app.sh install` rebuilt and installed Flo Local 1.11.1 from
the modified working tree. The installed executable matches the packaged
executable, and post-launch `codesign --verify --deep --strict` passed. The
previous local bundle is preserved in `/Applications/.flo-local.7ErchD`.
The running production app used a relative executable path, which the install
script's process matcher missed. After checking that its session had no
unresolved dictations, a normal Quit request through its bundle ID stopped it.
Launching the installed local app then completed readiness with a 0.13-second
Parakeet load, preserving the local channel's saved model selection. This
supersedes the earlier installation NOT RUN status.
Evidence is `/tmp/flo-live-transcript-install.log`. Live microphone dictation
and visible panel timing still require a user check.

## Near-silent recording latency

On September 13, 2026, the user reported slow results after release, especially
when holding the trigger without speaking. The local timing log showed two
near-silent captures taking 3.54 and 5.66 seconds, each with two Whisper calls.
Microphone handoff took milliseconds. Separately, one spoken dictation spent
1.31 seconds in recognition and 2.72 seconds in Ollama cleanup. Across that day's
95 completed sessions, median release-to-result time was 1.29 seconds.

Low-energy sample decoding now uses temperature zero without WhisperKit's five
temperature fallback attempts. Normal-energy decoding keeps its previous options.
An unexplained empty result still gets the pipeline's existing full-audio retry.
A canonical hallucination already filtered from low-energy audio instead returns
`TranscriberError.noSpeech`, which completes full dictation or command handling
as heard-nothing without another full attempt. Chunk/tail failures still allow
full-recording recovery so a partial decision cannot reject the entire utterance.

After a committed speech chunk, only an empty or all-zero tail skips recognition.
Nonzero quiet tails remain eligible even when their energy falls below the
full-recording admission threshold. This protects softly spoken final words.
Original recordings remain retained before these decisions. Replay reports
runtime no-speech outcomes per run, while its initial energy gate still rejects
unadmitted input before loading the model.

Verification used base `082025a` plus the latency fix on macOS 26.6.2, arm64,
Swift 6.3.3. Diff evidence: `/tmp/localflow-silence-fix.diff`.

- PASS: `swift test -c release --disable-automatic-resolution`, 293 tests.
  Evidence: `/tmp/localflow-silence-release-tests.log`.
- PASS: `DictationAudioPreparationTests` covers digital silence after committed
  speech, nonzero final words below -50 dBFS, filtered non-speech without retry
  or cleanup, and the existing quiet-empty recovery path. The new silent-tail
  test failed on the old behavior in `/tmp/localflow-silence-tail-red.log`.
- PASS: independent read-only review and follow-up review of the quiet-tail fix,
  cancellation, gate release, command handling, and diagnostic outcomes.
- PASS: two saved ambient candidates replayed through the cached 626 MB Whisper
  model improved from 4.27-5.00 seconds and 4.44 seconds to 1.36-1.39 seconds.
  They still used two pipeline calls, each with no temperature fallback.
  One baseline run of the second candidate produced variable text instead.
- PASS: a quiet speech candidate reproduced its 62-character baseline exactly
  in both runs, at 0.86-0.90 seconds. A separate recording known to need recovery
  still produced text after an initially empty result.
- LIMIT: another ambiguous low-energy clip changed from variable short outputs
  to empty. Its archived output matched the vocabulary prompt prefix, but it
  has no human-verified transcript. These checks do not prove accuracy for all
  quiet speech. Reducing temperature fallback is an accuracy/latency tradeoff.
- Replay evidence is private under `/tmp/localflow-silence-baseline-<traceID>`
  and `/tmp/localflow-silence-candidate-<traceID>`, with `.out` and `.log` suffixes.
  Each command used the app bundle's `--replay <original.wav> --runs 2
  --no-cleanup --whisper-model openai_whisper-large-v3-v20240930_626MB`.

The fixed energy floor can still admit background noise and prevent incremental
pause detection. This change does not add a speech classifier or change those
thresholds. Cleanup remains enabled and can add variable latency. Live microphone
behavior and human-verified quiet-speech accuracy still need user validation.

The pipeline and injection coordinator retain their distinct stall rules.
Injection-side cancellation removes the correlated dictation and cancels its
pipeline work; late outcomes cannot write history, refill retry audio, or inject
text. Pipeline timeout remains a recoverable failure. Commands share injection
ordering and their completion is accepted once.

Delivery remains busy until the text injector's completion callback, including
clipboard restoration. AppDelegate also refuses Quit during recording and queued
audio handoff. A dispatch callback alone does not make delivery idle and does
not establish visible insertion in the target app.

## Architecture implementation verification

The user requested implementation of all four architecture-review candidates on
September 10, 2026. Owner: Flo maintainers. Base: `4f4526a`, with uncommitted
changes. This refactor preserves recognition settings, retry limits, ordering,
retention policies, login/update policy, and microphone implementation.

- `DictationDeliveryTests` covers delayed delivery completion, duplicate callbacks,
  bounded FIFO retry with current corrections, failed manual retry, immediate
  silence rejection, both stall paths, and late results after cancellation.
- `DictationAudioPreparationTests` exercises admission and low-energy decisions,
  exact original retention, prepared retry audio, incremental requests, and an
  empty tail through the pipeline's transcription interface.
- `AudioCaptureLifecycleTests` exercises queued samples and native audio through
  the recorder's real start/stop path using a synthetic input adapter.
- Settings routing checks cover window/menu effects, no-op suppression, rollback,
  login failure/retry, and correction identity. See [settings](settings.md).

Verified on macOS 26.6.2, arm64, Apple Swift 6.3.3:

- PASS: `swift test --disable-automatic-resolution --filter
  'DictationDeliveryTests|DictationAudioPreparationTests|AudioCaptureLifecycleTests|DictationSession|DictationDiagnosticPipelineTests|DictationTraceTests|SettingsApplication|RemainingSettings|SettingsModelCorrection|UpdateController|AppTerminationTests'`,
  70 tests before the additional runtime-error capture test.
- PASS: `swift test -c release --disable-automatic-resolution`, 282 tests with
  zero failures, including the added runtime-error recovery/stale-input test.
  This command also built the changed application in release mode.
- PASS: `python3 -B Tests/LocalAppIdleTests.py`, six tests;
  `python3 -B Tests/StartupReadinessTests.py`, four tests; `git diff --check`.
- PASS: fresh independent source review found no blocking regression. Its
  runtime-error test gap was covered by the added capture test and release run.
- NOT RUN: live microphone capture, actual model inference, target-app insertion,
  installed settings interactions, packaging, or installation. Tests use
  synthetic input and isolated recording folders. No commit or push was made.

Logs are `localflow-architecture-implementation-focused.log` and
`localflow-architecture-release-tests.log` in the OS temporary directory.
The final source and documentation diff is
`/tmp/localflow-architecture-implementation-20260910.diff`.
Two existing compiler warnings remain in StartupModelSequenceTests and
InjectionCoordinatorTests.

The domain names are recorded in [CONTEXT.md](../../CONTEXT.md). Audio admission
uses trimmed analysis windows; empty-result retry and tail fallback retain their
original-window rules. A regression test covers the half-frame alignment case.

## Review fixes, September 30, 2026

Owner: Flo maintainers. The user requested fixes for six reproduced
review findings on base `a353f358d5c540c66575f7193dedd1176dec78d9`.

Each released dictation starts its own 90-second processing deadline. It does
not need a completed follower to time out, and recording time is excluded.
Timeout emits a recoverable failure, retains original retry audio, and removes
the delivery busy state. Commands have independent 90-second deadlines from
processing start. Late results cannot inject text, record history, or restore
retry entries. Metadata traces can still report when cancelled work returns.

`TranscriptionGate` removes cancelled waiters without releasing the active
engine's permit. If active inference ignores cancellation, Transcriber isolates
its engine and keeps its original gate held until inference actually returns.
Manual Retry loads a fresh engine before draining retained recordings, using
the existing model-load deadline. Reload failure preserves the recordings.
At most two abandoned engine generations may remain outstanding; further reload
attempts report a retry-later error until one returns. A normal model switch
continues to serve queued requests through the replacement engine and gate.

Command selection reads Accessibility selected text, removing the competing
clipboard save/restore path. Unsupported selection access reports a failure;
empty selection in a supported field permits generation. Marker filtering now
removes known Whisper and non-speech labels while preserving `Array<String>`,
HTML tags, `[API]`, and other ordinary bracketed text.

The `--transcribe` CLI keeps the main run loop available for MainActor cleanup.
`Tests/TranscribeCLITests.py` compiles the actual entry point with inert backends
and checks cleanup, no-cleanup, saved cleanup disabled, raw fallback, and error
exit statuses in bounded child processes. CI runs this check alongside Swift
tests. The original semaphore version reproduced the cleanup deadlock with
the same backends before the fix.

Verification uses synthetic recognition, isolated settings, temporary disk
folders, and injected selection attributes. Live microphone capture, real model
inference, and insertion into target apps remain separate runtime checks.

Final verification passed:

- `swift test --disable-automatic-resolution`: 317 tests, zero failures.
- `swift test -c release --disable-automatic-resolution`: 317 tests, zero
  failures, including compilation of the changed application.
- `python3 -B Tests/TranscribeCLITests.py`: two tests covering six CLI cases;
  idle and startup-readiness checks: ten tests.
- `bash Tests/ReleaseContractTests.sh`: 63 checks; `git diff --check`.

An initial full run caught missing cancellation-return metadata; the repair
preserves the existing trace contract and passed both final suites. Logs are
`final-debug-tests.log`, `final-release-tests.log`, and `release-contract.log`
under `/tmp/localflow-fixes.N7UJy9`. No app installation or personal data
modification was performed.

### Live selection follow-up

The user confirmed ordinary dictation preserved their clipboard and command
editing worked in iMessage. T3 Code initially reported unreadable selection.
Read-only inspection found its `AXManualAccessibility` flag disabled and the
system-wide focused-application query failing. Enabling the documented Electron
flag made its focused `AXTextArea` and selected-text attribute readable through
the application-specific interface. No text contents were exported.

`TextInjector.prepareSelectionAccess` now requests this tree at command-key
press, allowing Electron to construct it while the instruction is recorded.
Selection reading obtains the frontmost application from NSWorkspace, then
reads its focused element directly. Native apps without the Electron attribute
and trees already enabled are left alone. Neither path uses the clipboard.
See [Electron's Accessibility documentation](https://www.electronjs.org/docs/latest/tutorial/accessibility).

The focused 11-test TextInjector suite passed. Tests cover disabled and enabled
trees, unsupported attributes, preparation failure, missing focus, and the
existing clipboard-free selection behavior. Direct inspection read T3's focused
field successfully. A standalone extracted-source harness could not read it
after focus moved to another app; first-command behavior remains a user check.

PASS: the complete release suite, 320 tests; `git diff --check`; local installation,
signature verification, and model readiness in 0.89 seconds. Evidence is
`t3-selection-full-release.log` and `t3-selection-install.log` under
`/tmp/localflow-fixes.N7UJy9`. The running local build was replaced after a clean
quit and its previous bundle was retained. T3's tree flag was reset to its
original disabled state for the user's first-command retest. That retest remains
NOT RUN until the user confirms the selected text is edited successfully.


## Acceptance and verification

Base commit: `2102c80b9644b1dc1509d4068994bdd762446d4e`, with the uncommitted
recovery diff in `/tmp/localflow-empty-recovery.diff`. macOS 26.6.2, Apple M5 Pro,
Swift 6.3.3. Evidence paths are local temporary files.

Tests in `Tests/LocalFlowTests/DictationSessionPipelineTests.swift` cover:

- `testEmptyFullUtteranceRetriesOnceAndCleansOnlyRecoveredText`: same audio retried,
  recovered text delivered, cleanup receives only recovered text.
- `testRepeatedEmptyFullUtteranceStopsAndUnblocksLaterDictation`: two attempts,
  one empty outcome, subsequent dictation delivered in order.
- `testFailedAutomaticRetryEmitsFailureWithoutFurtherAttempts`: a thrown retry
  emits failure after two calls, without cleanup.
- `testEmptySilentFullUtteranceDoesNotRetry`: silence adds no retry.
- `testEmptyChunkRecoveryDoesNotRetryFullUtteranceAgain`: chunk fallback uses
  the recovery budget.
- `testCancelledEmptyResultRetryCannotDeliverLateText`: cancelled retry output
  cannot reach cleanup or delivery; the next dictation proceeds.

Results on September 9, 2026:

- PASS: new regression tests failed against the prior implementation, with five
  assertions exposing the missing full-result retry. Evidence:
  `/tmp/localflow-empty-recovery-red.log`.
- PASS: `swift test --disable-automatic-resolution --filter
  'DictationSessionPipelineTests|DictationSessionStallTests|DictationTraceTests'`,
  20 tests before the additional thrown-retry test. Evidence:
  `/tmp/localflow-empty-recovery-focused.log`.
- PASS: `swift test --disable-automatic-resolution`, 213 tests, zero failures.
  Evidence: `/tmp/localflow-empty-recovery-tests.log`. This command also built
  the changed application source and tests.
- PASS: independent source review and `git diff --check`.
- NOT RUN: installed-app menu retry, microphone capture, target-app insertion,
  and real Whisper recovery. The tests substitute recognition results and do
  not establish decoder accuracy or actual menu behavior. Maintainers should
  verify the installed retry flow in a designated test document when the app
  can be replaced. The running app was not rebuilt or relaunched by this task.

## Installed follow-up

The user subsequently requested all usage-review follow-ups, including local
installation and a live microphone check. The recovery change is now installed
in LocalFlow Local 1.3.0. `scripts/local-app.sh install` observed model readiness
in 0.98 seconds; code-signature verification passed. The installed executable
matches the packaged executable before its embedded signature. The existing
runtime theme-icon rebake changes the signature after launch.

PASS: final follow-up release suite, 215 tests, zero failures, in
`/tmp/localflow-usage-release-tests.log`. This supersedes the earlier note that
the running app had not been updated. The application retains the same source
base plus uncommitted changes. See the [usage review](../usage-review-2026-09-09.md)
for controlled replay results, new diagnostic context, paste warning semantics,
and remaining real-device checks. No test forces the installed app to produce
an empty decoder result; manual retry UI remains a separate verification gap.

The later install-safety fix refuses Quit across recording, audio handoff,
processing, and injection completion. It was prompted by an interrupted recording
during the first rebuild. The final release suite contains 217 passing tests;
the installer preflight has six passing Python tests. Details and limitations
are recorded in the usage review.

## Architecture local installation

The user subsequently requested rebuilding the local app, then committing and
pushing these changes. On September 10, 2026, `./scripts/local-app.sh install`
built and installed LocalFlow Local 1.5.0. The installer passed its idle check,
preserved the previous local bundle, and observed speech recognition ready in
0.97 seconds. Post-launch `codesign --verify --deep --strict` passed, and the
installed local executable was running.

The app was built before the commit, as requested. Its metadata reports base
revision `4f4526a` with a modified tree and build time
`2026-09-11T02:49:36Z`. The source matched the reviewed implementation diff and
the 282-test release run. Installation evidence is
`localflow-architecture-install-20260910.log` in the OS temporary directory.
No live microphone dictation or target-app insertion was performed during
installation. This installation supersedes the earlier not-installed status.

### Preview window continuity repair

Independent source review found that a rolling 15-second preview replaced words
already displayed during continuous speech. The bounded preview now freezes its
HUD prefix before opening another window. Later hypotheses update that window
while retaining the prefix. Committed chunks can replace a preview once they
cover its latest words. The displayed prefix never enters final recognition,
cleanup, diagnostics, or delivery.

The new `DisplayedPreview` value keeps the sample range, prefix, and current
text together inside the pipeline. The regression covers continuous speech
with and without an already committed prefix, repeated updates after advancing
the window, and bounded input sizes. It failed four assertions before repair.
Evidence: `/tmp/flo-preview-continuity-red.log` (exit 1) and
`/tmp/flo-preview-continuity-focused.log` (46 tests, exit 0). The full debug
suite passed 387 tests, zero failures and one optional HUD render skip:
`/tmp/flo-preview-continuity-debug.log` (exit 0). Live model/device timing was
not rerun for this repair.
The full release suite also passed 387 tests, zero failures and the same optional
HUD render skip: `/tmp/flo-preview-continuity-release.log` (exit 0).

## E4: bounded capture snapshots

Requirement source: authorized efficiency report item E4, based on
`47f1bb906e8f3b2291a617f13dd9bb0b11300e74`. Owner: Flo maintainers.
Bound temporary audio copies while preserving original capture, recognition
defaults, quiet-speech recovery, cancellation, retry, and retention. Device
watchdogs, archive cleanup, and preview decoder policy are outside E4.

`AudioRecorder.snapshot(range:completion:)` drains the existing control and
conversion queues, resolves an absolute range against the captured count, clamps
it to available audio, and copies only that range into independent storage.
`AudioRecorder.Snapshot` carries samples and their absolute `sampleOffset`.
Retained snapshots cannot share the growing capture array's storage. Its
main-queue callback leaves full recognition and native capture intact for stop.

`DictationSessionPipeline.incrementalSnapshotRange` captures immutable session
values for the recorder's selector. Due chunk ticks request unsubmitted audio
plus the preceding pause as context, aligned to the original 20 ms frame grid.
Other ticks request the existing preview window, at most 15 seconds and starting
after completed audio. The pause context protects half-frame cuts and silence
continuing across snapshots. Without a usable boundary, due chunk ticks can
still require all unsubmitted audio. E4 adds no truncation policy.

`AppDelegate.runIncrementalTick`, `DictationDelivery`, and file replay pass those
ranges and offsets through the same pipeline. Cadence, submitted/completed
positions, preview invalidation, and release tails use absolute sample indices.
A delayed range missing the next chunk's beginning cannot submit a shortened
chunk. Existing generation and release guards discard late work. Complete release
audio remains available for diagnostics, personal voice, fallback, and retry.

Acceptance evidence:

- `AudioCaptureLifecycleTests.testDelayedBoundedSnapshotDrainsLongCaptureAndPreservesReleaseTail`
  checks a delayed 64-sample snapshot of 300 seconds of synthetic capture, a
  later absolute range, immutable samples, and complete dual-format release.
- `testSnapshotsClampRangesAndDetachEvenFullCaptureStorage` checks range limits,
  idle snapshots, and distinct storage for two retained full snapshots.
- `DictationSessionPipelineTests.testLongCaptureRequestsOnlyPreviewWindowBetweenChunkTicks`
  checks preview bounds and due-chunk ranges against absolute counts.
- `testRangedChunksPreserveAbsoluteHalfFrameBoundariesPausesAndReleaseTail`
  checks exact chunk/tail inputs, submitted/completed offsets during release,
  and preserved paragraph breaks.
- `testRangedAnalysisKeepsTheWholePauseWhenSilenceContinuesAcrossSnapshots`
  compares ranged and full-array cut and pause analysis for continuing silence.
- `testDelayedPreviewRangeCannotSubmitTruncatedChunkOrSurviveRelease` checks
  delayed range rejection and late-preview suppression with full release audio.

Verification environment: macOS 27.0.1, arm64, Apple Swift 6.4. Builds use this
isolated worktree's `.build` and locked dependencies, without model downloads.
Verified source is the base above plus `/tmp/flo-e4.diff`, committed with this
section. Exact commands and results:

- PASS, exit 0: `swift test --disable-automatic-resolution --filter
  'AudioCaptureLifecycleTests|IncrementalCutPointTests|DictationSessionPipelineTests|DictationAudioPreparationTests|DictationDiagnosticStoreTests|PersonalVoiceStoreTests'`.
  Baseline: 66 tests, zero failures. Log: `/tmp/flo-e4-baseline.log`.
- PASS, exit 0: `swift test --disable-automatic-resolution --filter
  'AudioCaptureLifecycleTests|IncrementalCutPointTests|DictationSessionPipelineTests|DictationAudioPreparationTests|RetainedAudioFileTests'`.
  Initial focused coverage: 51 tests, zero failures. Log: `/tmp/flo-e4-focused.log`.
- PASS, exit 0: `swift test --disable-automatic-resolution --filter
  'AudioCaptureLifecycleTests|IncrementalCutPointTests|Dictation|RetainedAudioFileTests|PersonalVoice|NativeAudioRecordingTests'`.
  Final integration coverage: 147 tests, zero failures. Log:
  `/tmp/flo-e4-integration.log`.
- PASS, exit 0: `swift test -c release --disable-automatic-resolution --filter
  'AudioCaptureLifecycleTests|IncrementalCutPointTests|Dictation|RetainedAudioFileTests|PersonalVoice|NativeAudioRecordingTests'`.
  Final release coverage: 147 tests, zero failures, including compilation of the
  application. Log: `/tmp/flo-e4-release.log`. No selected tests were skipped.
- PASS, exit 0: `git diff --check`. Log: `/tmp/flo-e4-diff-check.log`.

Two development attempts failed to compile new test fixtures and were corrected.
A subsequent run failed two assertions because macOS accepts replacing a
directory with a file. The corrected publication-error fixture uses an overlong
final filename and passes. Earlier log:
`/tmp/flo-e4-publication-fixture-failure.log`.
Existing compiler warnings in diagnostic retention, text injection, and test
fixtures remain. No new warning was introduced in the changed implementation.

NOT RUN: live microphone capture, clipboard or typing, real-model inference,
app packaging/installation, and performance measurement. Tests use synthetic
audio and temporary folders. They establish buffer bounds and content contracts,
not a measured speedup. See [E4 WAV verification](diagnostic-recordings.md#e4-bounded-retained-wav-buffers).

Stack integration retains bounded-preview continuity using absolute sample
offsets. The continuity regression now feeds ranges selected by the capture
policy, including preview-only ticks after the window advances.
E4 integration passed `swift test --disable-automatic-resolution`: 398 tests,
zero failures, one optional HUD render skip. Evidence:
`/tmp/flo-capture-stack-e4-debug-final.log` (exit 0). The first assembled run
failed one input-size expectation that assumed the old rolling window. The
repaired preview decodes one new second after freezing its full window; the
assertion now checks that input. Earlier displayed words are covered by the
continuity regression. Initial evidence: `/tmp/flo-capture-stack-e4-debug.log`
(exit 1). Live capture and measured performance remain unverified.

## E1: Prepare each released recording once

Owner: Flo maintainers. The October 15, 2026 efficiency report E1 authorizes
reusing full-recording preparation across delivery and the session pipeline.
Base commit: `47f1bb906e8f3b2291a617f13dd9bb0b11300e74`.
Preview scheduling, snapshot ranges, cleanup budgets, model defaults, and
decoder rules are outside this item.

`DictationAudioPreparation` in `Sources/LocalFlow/DictationSessionPipeline.swift`
now keeps immutable `originalSamples` alongside trimmed samples and the existing
separate raw-window retry and trimmed admission metrics. `DictationDelivery.release`
passes that preparation to `DictationSessionPipeline.release(generation:audio:tailSamples:)`.
The raw-sample release overload remains available and retains capture before
preparing it. `DictationReplay.run` reuses its admission preparation for releases
across replay runs. Delivery still retains the original for manual retry and
passes native audio to the first-save-wins recording retention path.

Release reuses the full preparation for an unused tail when no chunk was
submitted, when incremental recognition already failed, or when the derived
tail is the whole original. `nextChunkIndex` tracks submitted chunks, including
queued work and the first in-flight chunk while `chunkCount` is still zero.
Release waits for that work and derives a separate tail from original sample
indices. Trace sample counts still describe the raw recording and tail.
Successful chunks keep nonzero quiet endings eligible; failed chunks use the
prepared full recording for the existing single recovery attempt.

Acceptance coverage uses synthetic samples and temporary retention folders:

- `DictationAudioPreparationTests.testPreparedReleaseKeepsOriginalSamplesAndHalfFrameRetryMetrics`
  verifies exact originals and a 280 ms raw-window result that passes 300 ms
  trimmed admission without earning an empty-result retry. The existing quiet
  archive/retry test now exercises prepared release and exact WAV retention.
- `DictationDeliveryTests.testPreparedReleaseAndManualRetryKeepOriginalWindowMetrics`
  verifies delivery duration, inference samples, and retention of the raw
  recording for manual retry rather than a trimmed request.
- The two prepared-release tests in `DictationSessionPipelineTests` verify an
  in-flight first chunk, the correct quiet tail after leading-silence trimming,
  and full fallback without another retry when that chunk fails.
- `PersonalVoicePipelineTests.testDeliveryRetainsOriginalFallbackOnceAcrossManualRetry`
  reads every persisted Float32 sample and verifies one unchanged personal clip
  across manual retry. Existing native-audio, silence, cancellation, output-order,
  diagnostic-stage, capture, and stall checks remain in the selected suites.

Verified on macOS 27.0.1, Apple M5 Pro, Swift 6.4, with worktree-local `.build`.
Evidence prefix: `/tmp/flo-e1-`. The final patch is `final.diff` under that
prefix, applied to the base commit above. No new abstraction was introduced;
the existing prepared type is reused by delivery, pipeline, and replay.

Exact test commands and results:

```sh
swift test --disable-automatic-resolution --filter 'DictationAudioPreparationTests|DictationSessionPipelineTests|DictationDeliveryTests|DictationDiagnosticPipelineTests|PersonalVoicePipelineTests'
swift test --disable-automatic-resolution --filter 'DictationAudioPreparationTests|DictationSessionPipelineTests|DictationDeliveryTests|DictationDiagnosticPipelineTests|PersonalVoicePipelineTests|DictationReplayTests|DictationSessionStallTests'
swift test --disable-automatic-resolution --filter 'DictationSessionPipelineTests.testPreparedReleaseDerivesQuietTailFromOriginalWhileFirstChunkIsInFlight'
swift test --disable-automatic-resolution --filter 'DictationAudioPreparationTests|DictationSessionPipelineTests|DictationDeliveryTests|DictationDiagnostic|PersonalVoice|DictationReplayTests|DictationSessionStallTests|NativeAudioRecordingTests|AudioRecorderTests|AudioCaptureLifecycleTests|DictationTraceTests'
swift test -c release --disable-automatic-resolution --filter 'DictationAudioPreparationTests|DictationSessionPipelineTests|DictationDeliveryTests|DictationDiagnostic|PersonalVoice|DictationReplayTests|DictationSessionStallTests|NativeAudioRecordingTests|AudioRecorderTests|AudioCaptureLifecycleTests|DictationTraceTests'
git diff --check
```

- PASS, exit 0: baseline command, 46 tests, `baseline-tests.log`.
- FAIL, exit 1: first expanded focused build used a nonexistent `Clip.status`
  field in the new test, `focused-tests.log`. Corrected to the persisted failure
  reason and transcript fields. PASS, exit 0: rerun, 66 tests,
  `focused-tests-rerun.log`.
- EXPECTED FAIL, exit 1: the single in-flight test with a temporary mutation
  selecting full audio from `chunkCount == 0`, `inflight-mutation-tests.log`.
  It caught a 28,000-sample full recording replacing the 8,000-sample quiet
  tail. Submitted-chunk tracking was restored before final checks.
- PASS, exit 0: expanded debug selection, 120 tests, `final-tests.log`.
- PASS, exit 0: the same selection in release, 120 tests, `release-tests.log`.
- PASS, exit 0: `git diff --check`, `diff-check.log`.
- NOT RUN: full Swift suite, live microphone, installed-app replay, panel
  timing, clipboard/typing, packaging, installation, or model inference.
  Maintainers own live acceptance and assembled-item integration. No runtime
  speedup was measured or claimed.

## E3: bounded optional cleanup

Owner: Flo maintainers. The October 15, 2026 efficiency request includes a
separate cleanup budget and an explicit fast path. Recognition and deterministic
corrections, voice formatting, and snippets still run before optional cleanup.
Settings offers Fast and Polished choices using the existing cleanup preference.
Fast skips text-model processing; Polished enables it. Existing saved choices
keep the same behavior, and the model's availability still selects the backend.

`DictationSessionPipeline.finalize` retains the composed transcript and gives
cleanup three seconds. The cleanup deadline returns that transcript without
waiting for a backend that ignores cancellation. If the original release
deadline expires after recognition finished, it also delivers the retained
transcript instead of failing the dictation. Normal recognition timeouts keep
their existing failure and retry behavior. The completion helper is shared by
normal cleanup, its own deadline, and release-deadline fallback. It emits one
cleanup result and preserves spoken-order delivery. Cancellation removes the
deadline, and late backend results cannot produce another outcome.

`DictationCleanupDeadlineTests` covers an uncooperative backend, late output,
the shorter release deadline, successful cleanup, cleanup disabled, cancellation,
and a completed follower waiting behind a stalled cleanup. The initial six-test
run reproduced six assertions failing before the deadline implementation.

PASS: `swift test --disable-automatic-resolution`, 392 tests with zero failures
and one optional render skip, on macOS 27.0.1, arm64, Swift 6.4. Focused pipeline,
delivery, diagnostics, and stall checks passed 53 tests. Evidence is
`/tmp/flo-e3-cleanup-red.log`, `focused.log`, and `tests.log` under the same
`/tmp/flo-e3-cleanup-` prefix. Base is preview commit `47f1bb9` plus this change.
Live model cleanup, rendered Settings help, microphone input, and target-app
insertion were NOT RUN. No new settings key or public model policy was added.

The explicit Fast/Polished picker was compiled and checked with
`swift test --disable-automatic-resolution --filter 'DictationCleanupDeadlineTests|SettingsPaneTests'`,
six cleanup tests passed, exit 0. There is no `SettingsPaneTests` class in this
checkout, so that filter added no UI test coverage. Evidence:
`/tmp/flo-e3-explicit-modes.log`. Rendered Settings interaction remains NOT RUN.

## E2: Preview inference budget, October 15, 2026

Owner: Flo maintainers. Requirement source: the authorized efficiency report E2,
against preview foundation `47f1bb906e8f3b2291a617f13dd9bb0b11300e74`.
Give disposable previews their own inference budget without changing final
recognition, release audio preparation, retry, quiet-tail, or delivery contracts.
This section belongs to E2; other efficiency and reliability items have separate
owners and PRs.

`DictationSessionPipeline.startPreviewIfNeeded` attaches `TranscriptionPurpose`
and a per-request `PreviewLifetime`. Both `AppDelegate` and `DictationReplay`
forward the complete request through `Transcriber.transcribe(_:)`. Existing
sample/file callers remain authoritative by default. `SpeechEngine` supplies
adapters for engines that retain their existing preview decoder, including
Parakeet.

`WhisperEngine.decodingOptions(lowEnergy:purpose:)` keeps the temperature-zero
pass and sets `temperatureFallbackCount` to zero for previews. The pinned
WhisperKit 1.1.0 `TranscribeTask` builds attempts with
`0...temperatureFallbackCount`, so zero means one attempt. Final options,
vocabulary prompts, timestamps, VAD chunking, and the low-energy policy retain
their existing values. No new model or dependency is required.

`TranscriptionGate` gives waiting authoritative requests priority over disposable
previews and keeps FIFO arrival order within each purpose. It cannot preempt
active inference. Release and cancellation invalidate the preview lifetime,
remove its waiter, and reject a stale permit handoff without cancelling active
inference. The existing generation and audio-coverage checks still drop late
text. Routine Escape leaves the model loaded. Explicit interruption and the
release deadline still cancel active inference and quarantine its engine.

`Transcriber` measures preview inference with a monotonic clock, excluding gate
waits. After a preview taking duration D, that model's next preview becomes
eligible D seconds after completion. Requests during this interval skip rather
than queue or sleep. Budgets are keyed by the loaded model ID, so measurements
from a slow model do not throttle another model. Finals never consult this
budget. Cancelled or superseded engine generations do not update it. Capture
still schedules one-second ticks, permits one active preview per session, and
bounds preview audio to 15 seconds. The complete original release audio still
determines final recognition. Preview text does not enter cleanup, history,
delivery, personal voice labels, or diagnostic audio archives.

Acceptance examples target the real gate with fake engines in
`PreviewInferenceBudgetTests`: final precedence with FIFO finals; queued-preview
removal during release and Escape before active inference returns; active-preview
release and Escape without unloading; explicit interruption with quarantine;
model-specific observed-duration backoff that leaves finals eligible; stale
work rejection at an idle gate; and preview-only Whisper option changes.
Existing `DictationSessionStallTests` now use the same request adapter as live
and replay, including the stalled-preview deadline and engine recovery case.
Existing pipeline, audio-preparation, diagnostic, delivery, model, and replay
suites cover bounded audio, original final audio, quiet tails, retries, and
preview side-effect isolation.

Verified on macOS 27.0.1, arm64, Swift 6.4, from baseline
`47f1bb906e8f3b2291a617f13dd9bb0b11300e74` plus the E2 diff on
`perf/preview-inference-budget`. The reviewed source/test diff is saved at
`/tmp/flo-e2-final.diff`; the handoff names the final local commit. All SwiftPM
commands used this worktree's isolated `.build-e2` scratch directory and the
existing lockfile. Generated build artifacts were moved to ignored `.build/e2`
after validation, without touching another worktree's output.

Executed checks, with final results:

- PASS, exit 0: `swift test --scratch-path .build-e2 --disable-automatic-resolution --filter TranscriberTests`,
  13 tests. Evidence: `/tmp/flo-e2-transcriber-tests.log`.
- PASS, exit 0: `swift test --scratch-path .build-e2 --disable-automatic-resolution --filter 'PreviewInferenceBudgetTests|TranscriberTests|DictationSessionPipelineTests|DictationSessionStallTests|DictationAudioPreparationTests|DictationReplayTests|DictationDiagnosticPipelineTests|TranscriptionModelTests|ParakeetEngineTests'`,
  97 tests, including all nine E2 tests. Evidence: `/tmp/flo-e2-focused-tests.log`.
- PASS, exit 0: `swift test --scratch-path .build-e2 --disable-automatic-resolution`,
  395 tests, zero failures. Evidence: `/tmp/flo-e2-full-tests.log`.
  SKIPPED: one optional `HudRenderSnapshots.testRenderOverlayStates`, which
  requires `LOCALFLOW_RENDER_DIR`.
- PASS, exit 0: `python3 -B Tests/TranscribeCLITests.py`, two tests.
  Evidence: `/tmp/flo-e2-cli-tests.log`.
- PASS, exit 0: `python3 -B Tests/StartupReadinessTests.py`, four tests.
  Evidence: `/tmp/flo-e2-startup-tests.log`.
- PASS, exit 0: `git diff --check` and `git diff --cached --check`.

Earlier test iterations were corrected before the passing checks above.
`swift test --scratch-path .build-e2 --disable-automatic-resolution --filter PreviewInferenceBudgetTests`
initially exited 1 with eight passing tests and one failure caused by comparing
JSON objects with unsorted keys. Evidence: `/tmp/flo-e2-budget-tests.log`.
The comparison now sorts keys. The first focused build also exited 1 because
an async assertion used an autoclosure that cannot await; the assertion now
uses an explicit guard. Neither was an engine behavior failure. The initial
build also emitted existing warnings in untouched diagnostic, injection, and
startup-test code; those warnings remain outside E2.

NOT RUN: real-model replay, preview-quality comparison, latency/power benchmarks,
release packaging, installation, microphone capture, clipboard access, or typing.
No model downloads or dependency upgrades were performed. Speedup and real-model
preview quality remain unmeasured. Maintainers own those checks after integrating
E1 and the other authorized items. Active previews remain nonpreemptible.

Stack integration keeps queued-preview invalidation in the prepared-audio release
overload shared by live delivery and raw-sample callers. The queued-preview
regression now exercises prepared-audio release; other release tests retain the
raw-sample path. Assembled-stack validation is recorded separately.

## R1: Bounded abandoned inference and model-switch recovery, October 15, 2026

Owner: Flo maintainers. Requirement source: the authorized reliability report R1
and implementation brief. Foundation: `47f1bb906e8f3b2291a617f13dd9bb0b11300e74`.
Prerequisite E2 was cherry-picked unchanged as
`ee1bf8b2f4d976707efd6e7564fe9e66d308bb00`, from
`be83e19d79c868f25dffb214659b4c343da179cb`. The R1 commit follows it on
`fix/abandoned-inference-recovery`. Target selection, clipboard delivery R3,
other report items, and proposed features are outside this change.

Escape still reaches `DictationSessionPipeline.cancel` through AppDelegate and
DictationDelivery with `interruptInference: false`. Each `runTranscription`
request now carries a lifetime. Cancelling or completing a session invalidates
its outstanding requests. The existing E2 observer implementation is renamed
`TranscriptionLifetime` and reused for session abandonment and preview
obsolescence. Those signals remain separate: release invalidates a queued
preview without treating active preview inference as explicitly cancelled.
Both AppDelegate and DictationReplay already forward the complete request.

`TranscriptionGate.acquire` removes abandoned queued requests immediately.
`Transcriber.runInference` owns an active request's abandonment deadline, even
after the session drops its task handles. The default grace is 90 seconds,
injected as `abandonedInferenceGrace` for tests. Completion during grace cancels
the deadline and keeps the model warm. Expiry quarantines a still-active holder;
its engine and old gate remain isolated until it returns. A per-call identity
prevents a delayed deadline or cancellation callback from affecting another
inference on the same engine. Abandoned results cannot return text or update
the preview budget.

Replacing or quarantining an engine retires its gate. Retirement wakes queued
acquirers, which re-evaluate the current engine rather than wait for the old
holder. A loaded replacement serves them; without one, authoritative requests
fail and retain retry audio through the existing delivery path. Manual Retry
uses the existing AppDelegate model-load path before retrying retained audio.
Replacement loads count all unresolved engine holders, including work inside
grace, against the existing two-engine recovery limit. A third replacement
fails with `recoveryBusy` until one holder returns. Explicit interruption and
release deadlines still quarantine immediately.

`Transcriber.load` advances its load generation before the warm-model shortcut.
For warm A, suspended loading B, then request A, B's late load cannot publish.
The warm A request does not construct another engine.

Fake suspended engines in `DictationSessionStallTests` verify these acceptance
examples through the real Transcriber and gate:

- `testEscapeAbandonedFinalExpiresAndQueuedFollowerRetriesOnReplacement` and
  `testEscapeAbandonedPreviewExpiresAndQueuedFollowerRetriesOnReplacement` check
  grace, follower failure, retained retry audio, replacement success, and no late
  original delivery or history after its transcription callback finishes.
- `testEscapeRemovesQueuedFinalWithoutQuarantiningUnrelatedHolder` checks that
  abandoning a waiter does not quarantine the active request.
- `testFinishedAbandonmentDeadlineCannotQuarantineNextInferenceOnSameEngine`,
  `testKeyboardCancelLeavesRunningInferenceAndModelLoaded`, and the existing E2
  Escape tests check warm reuse without another load.
- `testAbandonedOldInferenceGraceCannotQuarantineReplacement` checks that an
  old generation's expired deadline and late result leave its replacement usable.
- `testWarmRequestInvalidatesBlockedDifferentModelLoad` covers A-B-A;
  `testQueuedRequestUsesReplacementAfterOrdinaryModelSwitch` now requires the
  follower to finish before the original holder returns.
- `testAbandonmentCapsQuarantinedEnginesUntilOldInferenceReturns`,
  `testRecoveryCapsQuarantinedEnginesUntilOldInferenceReturns`, and
  `testModelSwitchDuringAbandonmentGraceCannotBypassEngineBound` check the cap
  for abandoned, explicitly cancelled, and still-in-grace holders.

Verified on macOS 27.0.1, arm64, Apple Swift 6.4, using isolated scratch output
`.build/r1` and the unchanged lockfile. Evidence identifies the prerequisite
plus the R1 diff saved at `/tmp/flo-r1-final.diff`; the implementation handoff
provides the final R1 commit SHA.

- RED, exit 1: `swift test --scratch-path .build/r1 --disable-automatic-resolution --filter 'TranscriberTests|DictationSessionStallTests|PreviewInferenceBudgetTests'`,
  34 tests, three failed assertions exposing A-B-A and the stuck old-gate waiter
  before the source repair. Log: `/tmp/flo-r1-baseline.log`.
- RED, exit 1: `swift test --scratch-path .build/r1 --disable-automatic-resolution --filter testModelSwitchDuringAbandonmentGraceCannotBypassEngineBound`,
  one test, two failed assertions exposing replacement during grace bypassing
  the cap. Log: `/tmp/flo-r1-grace-bound-red.log`.
- PASS, exit 0: `swift test --scratch-path .build/r1 --disable-automatic-resolution --filter 'TranscriberTests|DictationSessionStallTests|PreviewInferenceBudgetTests|DictationSessionPipelineTests|DictationAudioPreparationTests|DictationDeliveryTests|DictationReplayTests|DictationDiagnosticPipelineTests|DictationTraceTests|TranscriptionModelTests|ParakeetEngineTests'`,
  119 tests, zero failures. Log: `/tmp/flo-r1-recovery-final.log`.
- PASS, exit 0: `swift test --scratch-path .build/r1 --disable-automatic-resolution --skip TextInjectorTests`,
  382 tests, zero failures, one optional HUD render skipped because
  `LOCALFLOW_RENDER_DIR` was unset. All 21 TextInjector tests were excluded to
  respect the task's no-clipboard boundary, including private pasteboards.
  Log: `/tmp/flo-r1-broad-tests.log`.
- PASS, exit 0: `python3 -B Tests/StartupReadinessTests.py`, four tests.
  Log: `/tmp/flo-r1-startup-tests.log`.
- PASS, exit 0: `git diff --check` and `git diff --cached --check`.
  Log: `/tmp/flo-r1-diff-check.log`.

NOT RUN: actual Whisper or Parakeet inference, runtime menu interaction,
microphone capture, clipboard access, target-app insertion, release packaging,
installation, or performance measurement. Tests use synthetic audio and fake
engines, delivery, and history callbacks. Existing compiler warnings in
untouched diagnostic, injection, and startup-test code remain. The parent
integration owner must assemble the stack and perform any authorized runtime
validation. This task creates local commits only.

## R3: Pace delivery by clipboard reads and retain command identity

Owner: Flo maintainers. The October 15, 2026 reliability report R3 authorizes
clipboard-aware queue pacing and command target/selection identity. The isolated
base is `47f1bb906e8f3b2291a617f13dd9bb0b11300e74`; E1
`dc5df59821180d6ca224b282eb65ae6f0eefc656` was cherry-picked unchanged as
`b0873cd980a8211a29a9ba758dbb4263501f00d8`. Other efficiency and reliability
items, model policy, installed apps, and live input are outside this change.

Intended and implemented path:

- `InjectionCoordinator.drain` retains FIFO ownership until the injector calls
  its readiness callback. It no longer advances after a fixed 400 ms. Delivery
  UUIDs ignore duplicate callbacks; synchronous failures continue draining
  without recursive delivery. Existing command and stalled-head deadlines stay.
- `TextInjector.inject` uses the existing `PasteReceipt` first-read signal to
  release the next delivery on the next main-queue turn, after the provider
  returns its bytes. Restoration still follows the existing floor/grace/ceiling
  timing. Receipt timeout, external provider finish, empty input, event failure,
  and completed typing also release queue ownership. Provider finish uses the
  generation and change count to distinguish external copies from Flo's writes.
- `DictationDelivery` passes readiness separately from final completion. Its
  existing active-injection tracking keeps Quit blocked through restoration.
  A following paste still preserves the first clipboard snapshot unless the
  user copied something in between. History records output before delivery.
- `AppDelegate.commandKeyPressed` prepares AX access and captures a
  `TextInjector.CommandTarget` before recording. Release latches that immutable
  value across audio handoff, STT, rewrite, and the delivery queue. The rewrite
  uses its captured selection. `TextInjector.validateCommandTarget` compares
  AX application/process identity, focused element, focused window when exposed,
  selected text, and range after reading the clipboard snapshot and before any
  clipboard write or dispatch. Reading another clipboard provider can block,
  so validation must follow that read. Cursor-only commands
  require the same field and zero-length range. Unreadable identity, secure
  input, or an outstanding promised paste safely refuses capture. Cancellation
  and recording startup failure clear the held snapshot.
- A changed or unreadable target produces `InjectionResult.targetChanged` with
  an explicit warning and no paste, typing, or clipboard write. The generated
  result remains in Recent Dictations and history. Ordinary dictation retains
  its focused-app policy. A command target that changes and returns to the same
  observable identity passes validation; this is a current-state guard.

This checkout had AX selection readers but no existing target identity/range
helpers. `selectedText` is shared by the old selection reader and target capture.
`CommandTarget` is the new immutable value carried by command flow and the
existing queue. `InjectionClipboard` is a narrow boundary implemented by
`NSPasteboard` and the in-memory test fake. Tests reuse the actual `PasteReceipt`;
there is no additional receipt type or scheduler.

Acceptance checks are in `Tests/LocalFlowTests/TargetedDeliveryTests.swift`.
They use in-memory clipboard receipts, local AX identity objects and attribute
readers, a fake clock/scheduler, fake typing, and stubbed paste events. No test
requires a system pasteboard, AX server requests, model inference, or microphone.
The delayed-reader case waits 550 ms, checks the first receipt is still present,
then verifies FIFO delivery after reads and restoration as a separate completion.
Other cases cover timeout, changed clipboard, cancellation, duplicate signals,
empty input, paste failure, typing success/failure, target changes during
recognition/rewrite/queue wait, unchanged replacement, cursor-only commands,
unavailable identity, a target change while reading the previous clipboard,
and ordinary dictation focus policy. Existing
`TextInjectorTests` now use the same in-memory clipboard boundary.

Verification limits: the receipt observes the first reader, which need not be
the target app. The existing transient marker asks compliant clipboard managers
to skip these items. The target guard compares current AX state before event
dispatch; it cannot make focus and event delivery atomic or prove insertion.
Command phase tests simulate recognition/rewrite completion at the delivery
boundary. Real AppDelegate hotkey/STT/model wiring is compiled but not exercised
end to end. Flo maintainers own live AX, clipboard-manager, target-app,
installation, and assembled-stack acceptance.

Verified on macOS 27.0.1, arm64, Swift 6.4, in this worktree. The local `.build`
was copied from the completed E1 worktree, then SwiftPM rebuilt for this path
with automatic resolution disabled. Evidence prefix: `/tmp/flo-r3-`. The patch
artifact `final.diff` is relative to the unchanged E1 cherry-pick above; the R3
commit SHA is returned in the implementation handoff.

Exact final commands:

```sh
swift test --disable-automatic-resolution --filter 'InjectionCoordinatorTests|TextInjectorTests|TargetedDeliveryTests|DictationDeliveryTests|DictationTraceTests|DictationSessionPipelineTests|DictationSessionStallTests|DictationAudioPreparationTests|DictationDiagnosticPipelineTests|PersonalVoicePipelineTests|AppTerminationTests|AudioCaptureLifecycleTests|UserFacingIssueTests'
swift test -c release --disable-automatic-resolution --filter 'InjectionCoordinatorTests|TextInjectorTests|TargetedDeliveryTests|DictationDeliveryTests|DictationTraceTests|DictationSessionPipelineTests|DictationSessionStallTests|DictationAudioPreparationTests|DictationDiagnosticPipelineTests|PersonalVoicePipelineTests|AppTerminationTests|AudioCaptureLifecycleTests|UserFacingIssueTests'
git diff --check
git diff --exit-code dc5df59821180d6ca224b282eb65ae6f0eefc656 b0873cd980a8211a29a9ba758dbb4263501f00d8
```

- PASS, exit 0: final debug selection, 123 tests, zero failures or skips,
  `final-debug.log`. This includes 16 new `TargetedDeliveryTests` and one new
  coordinator callback/FIFO test.
- PASS, exit 0: the same final selection in release, 123 tests, zero failures
  or skips, `final-release.log`.
- PASS, exit 0: the earlier focused selection, 54 tests, `focused-final.log`.
  Earlier expanded debug/release selections each passed 122 tests in
  `expanded-debug.log` and `expanded-release.log` before the snapshot-read case.
- EXPECTED FAIL, exit 1: temporarily replacing readiness pacing with the former
  400 ms timer, one delayed-reader test and four failed assertions,
  `pacing-mutation.log`. It caught the second dictation replacing the unread first.
- EXPECTED FAIL, exit 1: temporarily bypassing target validation, four tests and
  13 failed assertions, zero unexpected failures, `target-mutation-final.log`.
  Recognition, rewrite, queued delivery, and clipboard-snapshot changes all
  caught forbidden events. Both mutations were restored before final checks.
- PASS, exit 0: whitespace/diff check, `diff-check.log`; identical E1 tree check,
  `prerequisite-check.log`.
- NOT RUN: full Swift suite, shell/Python checks for unrelated packaging/startup,
  live app, system clipboard, AX requests, microphone, installed-app replay,
  model inference, packaging, installation, push, PR, merge, or delegation.

Initial diagnostics are retained rather than counted as passed checks.
`baseline-tests.log` was interrupted during compilation before tests ran to avoid
its old private-pasteboard harness. `focused-tests.log` and `focused-rerun.log`
failed to compile new actor-isolated default closures. `focused-pass.log`
reached tests and exposed an unowned fake-harness lifetime during teardown.
Actor annotations/default construction and harness teardown retention were fixed
before `focused-final.log`. `target-mutation.log` is an earlier validation-bypass
run with a secondary unread-paste failure; `target-mutation-final.log` supersedes
it. Existing compiler concurrency/capture warnings remain visible in build logs.

R3 integration with R1 updates the abandonment-retry fixture to the new delivery
callback's separate queue-ready and restoration-complete signals. The initial
combined build exposed its old two-argument signature and removed interval
argument; production code compiled. The corrected fixture passed 39 focused
stall, target, and queue tests, exit 0. Evidence:
`/tmp/flo-session-stack-through-r4-debug.log` (initial compile failure) and
`/tmp/flo-r3-r1-fixture-integration.log` (pass). Full assembled validation follows.

## R4: verbatim snippets and literal formatting

Owner: Flo maintainers. The October 16, 2026 R4 request authorizes exact snippet
insertion and a literal-formatting preference. Per-app preferences and other
feature proposals are outside this change.

`AppDelegate.captureDictationContext` and `DictationReplay.run` snapshot the new
`literalFormatting` preference into `DictationSessionContext`. It defaults to
false, preserving spoken command formatting. Settings > Dictation exposes the
switch through `SettingsModel` and `SettingsApplication`. When enabled, the
pipeline skips both spoken commands and automatic ordinal lists. Corrections
and optional prose cleanup still apply. This is a formatting preference, not a
promise of verbatim recognition or verbatim prose from a text model.

`Snippets.parts` matches the original assembled transcript before corrections
or voice formatting. Matching remains case-insensitive, uses word boundaries,
accepts flexible spaces, and consumes at most one trailing punctuation mark.
Earlier positions win. At one position the longest trimmed saved trigger wins,
measured in UTF-16 units, then saved order breaks ties. Accepted matches consume
that original range once. Overlapping occurrences are considered even within
one trigger. Empty triggers and empty expansions are ignored. Repeated original
matches expand independently; saved expansions and correction-created trigger
phrases are never searched again.

`Snippets.Part` distinguishes prose from verbatim text. The existing expansion
API, pipeline, and VoiceFormatter reuse it. Only prose receives corrections,
voice formatting, or cleanup. Explicit list state and line-break commands carry
across snippets without trimming or capitalizing saved content. Automatic
ordinal-list detection stays within each prose span. With no snippets, the
existing formatter and whole-transcript cleanup behavior remain unchanged.
Polished cleans prose spans sequentially, preserving their boundary whitespace,
then joins them with untouched expansions in spoken order. No placeholders enter
a model. One E3 deadline covers all spans. Its fallback retains the entire
pre-cleanup composition, including after partial cleanup; the release deadline
uses the same `completeCleanup` boundary. Late results cannot deliver twice or
start cleanup of later spans after completion or cancellation. Diagnostics keep
`cleanupInput` as the composed pre-cleanup transcript, rather than one event per
model request.

The Settings snippet editor no longer strips expansion whitespace. The public
snippet API and legacy string-array preference remain unchanged. When tabs or
backslashes require lossless storage, `verbatimSnippets` saves exact pairs plus
the legacy array they encode. The reader uses those pairs only while that array
still matches, so external or older-app edits cannot restore stale content.
Simple entries retain the original encoding without a companion value. Older
versions retain their previous interpretation of the public array, including its
existing limitations with tabs and literal backslash-n. Already-lost content
cannot be reconstructed. Tests verify UTF-8 bytes after persistence, including
outer whitespace, multiline code, URLs, tabs, and literal backslash-n. They also
verify legacy edits invalidate the companion value.

Verification uses macOS 27.0.1, arm64, Swift 6.4. The base is `47f1bb9` plus
unchanged prerequisite cherry-picks `2574a72` and `3d7f8e7`. Their patch IDs match
originals `673876a` and `debf9fc`. R4 is the local commit containing this section;
its SHA is recorded in `/tmp/flo-r4-commit.txt`, and the reviewed patch is
`/tmp/flo-r4-final.diff`.

- FAIL, expected regression evidence: `swift test --disable-automatic-resolution --filter VerbatimSnippetPipelineTests`,
  exit 1, three tests with three assertion failures before pipeline protection.
  Log: `/tmp/flo-r4-pipeline-red.log`.
- PASS: `swift test --disable-automatic-resolution --filter 'VerbatimSnippet|DictationCleanupDeadlineTests|VoiceFormatterTests|DictationDiffTests|SettingsModelCorrectionTests'`,
  exit 0, 56 tests. Log: `/tmp/flo-r4-focused-final.log`. Cases cover overlaps,
  recursive expansion, trigger/correction ordering, code preservation, rewriting
  and failed cleaners, both deadlines, partial-cleanup fallback, late results,
  literal spoken commands, default formatting, persistence, and session snapshots.
- PASS: `env -u LOCALFLOW_RENDER_DIR swift test --disable-automatic-resolution --skip TextInjectorTests`,
  exit 0, 387 tests, one optional HUD render skip, zero failures.
  Log: `/tmp/flo-r4-broad-final.log`. The 21-test clipboard class is excluded
  under this task's no-clipboard restriction.
- PASS: `python3 Tests/TranscribeCLITests.py`, exit 0, two tests;
  `python3 -B Tests/StartupReadinessTests.py`, exit 0, four tests.
  Logs: `/tmp/flo-r4-cli.log` and `/tmp/flo-r4-startup.log`.
- PASS: `git diff --check`, exit 0. Log: `/tmp/flo-r4-diff-check.log`.
- NOT RUN: rendered Settings interaction, real models, audio replay, microphone,
  clipboard, target-app insertion, release packaging, installation, or deployment.
  The maintainer owns assembled-stack and live verification. Dependency cache
  files were copied into this worktree; no package installation was performed.

## R2: terminal capture cleanup and ongoing stream health

Requirement source: authorized reliability report R2 on
`47f1bb906e8f3b2291a617f13dd9bb0b11300e74`. Owner: Flo maintainers.
Prerequisite E4 is cherry-picked unchanged from
`aa579364df074dbfd4a7cbd00b77b4b9df521c42` as `3d60fe9`.
R2 extends the existing recorder lifecycle. E5 idle work and RMS changes,
decoder defaults, feature ideas, installation, and live-device checks are
outside this change.

### Capture and failure path

Each `AudioRecorder.start` installs a recording UUID and its own runtime failure
callback on the control queue. `RuntimeFailure` identifies that recording and
capture generation. The watchdog validates both identities; runtime callbacks
validate the capture generation and the recording present when the error
arrived. An old timer, stopped input, or delayed app callback cannot clear a
new hold.

`AudioRecorder.failRecording` owns terminal cleanup, including failed setup.
Under the sample lock it clears recording/live state, invalidates capture
callbacks, and releases recognition samples, parked first-syllable samples,
optional native audio, trace, and per-recording callbacks. It cancels warm
teardown and releases the capture session. Native teardown removes the error
observer and output delegate, stops capture, then releases the forwarder and its
converter/buffer storage. Sample callbacks cannot refill audio while hardware
shutdown blocks. Setup reports through start completion only; later terminal
failure reports through the runtime callback once. Both leave a failure in the
existing `Recording.startError` field for an already queued stop.

`AppDelegate.hotkeyPressed` captures the UUID and UI/dictation generations in
its per-start failure callback. `handleCaptureFailure` consumes the matching UI
generation once, clears command/recording/trace/HUD ownership, cancels that
held or released dictation and its incremental timer, and reports failure.
Recorder cleanup needs no extra app-side stop. Incremental ticks carry the
recording UUID, and queued live cues and snapshot callbacks consult
`AudioRecorder.isCaptureActive` before recognition or UI work, including while
hardware teardown blocks and the UI failure is still queued. E4 detached
snapshot contents remain intact. Hotkey release after failure is safe. A stop
already queued returns empty audio and an error, so its existing guard cancels
delivery before `process` or final recognition. Release after a
runtime error before the live cue also discards its parked/native prefix and
reports failure. A stale failure cannot stop, cancel, or hide the next recording.

### Health policy and recovery

The recorder checks every 1.2 seconds throughout a hold, using monotonic time.
`HealthPolicy`, clock, and check scheduler are injectable for bounded fake tests.
Startup retains two rebuild attempts, the existing per-open retry and built-in
fallback, and eight further checks for flowing digital-zero Bluetooth wakeup
audio. Runtime errors before live capture share that finite startup budget.
A rebuild invalidates the old route while holding the same lock that proves
capture live, so newly live audio wins before a replacement decision.

After live capture, 3.6 seconds without raw delivery or converted output, five
consecutive failed/empty conversions, a stopped session, or a runtime error
fails the hold. `SampleForwarder` reports missing output through the existing
PCM callback as nil and resets a failed converter for its next bounded attempt.
Deadline gaps and conversion-limit failures remain latched even if a late buffer
arrives before the next timer. Release checks the same health rules after
queued conversion drains. A failed live stream is discarded rather than joined
to a replacement route across missing speech; the next press starts fresh.

Ordinary silence after live capture advances both progress clocks and stays
healthy. Startup audible gating, digital-zero wakeup allowance, parked first
syllables, and RMS/spectrum calculations retain their existing behavior. E4
ranged snapshots still carry absolute offsets and detach independent storage;
healthy release returns all original recognition and optional native samples.

### R2 verification

Verified source: the E4 prerequisite above plus the R2 diff saved at
`/tmp/flo-r2.diff`, committed with this section. Environment: macOS 27.0.1,
arm64, Apple Swift 6.4. Dependencies were copied from the existing local cache
into this isolated worktree; commands disable automatic resolution.

- PASS, exit 0: baseline `swift test --disable-automatic-resolution --filter
  AudioCaptureLifecycleTests`, 7 tests. Log: `/tmp/flo-r2-baseline.log`.
- PASS, exit 0: initial focused recorder suite, 19 tests, zero failures. Log:
  `/tmp/flo-r2-focused.log`. Cases cover failed setup/rebuild, terminal cleanup,
  one notification, stale timers/callbacks, missing buffers, failed or stalled
  conversion, late buffer recovery attempts, healthy silence, first syllables,
  release racing health checks, and complete E4 snapshots/release tails.
  Final integration runs below include 21 recorder lifecycle tests, adding
  queued snapshot suppression and release after a runtime error before live.
- PASS, exit 0: `swift test --disable-automatic-resolution --filter
  '^LocalFlowTests\.(AudioCaptureLifecycleTests|AudioRecorderTests|VoicedAudioTests|IncrementalCutPointTests|Dictation[A-Za-z]*Tests|RetainedAudioFileTests|PersonalVoice[A-Za-z]*Tests|NativeAudioRecordingTests|AppTerminationTests)/'`,
  166 tests, zero failures. Log: `/tmp/flo-r2-integration-final.log`.
  Exit status: `/tmp/flo-r2-integration-final.exit`.
- PASS, exit 0: `python3 -B Tests/CaptureFailureBoundaryTests.py`, five tests.
  Log: `/tmp/flo-r2-boundary.log`. The harness compiles the actual AppDelegate
  failure, release, command-release, incremental-tick, and HUD-dismiss methods
  with inert UI, capture, and delivery dependencies. It checks one UI transition, no final
  recognition after failed release or a delayed snapshot, and protection of a
  newer hold. CI runs it. Exit status: `/tmp/flo-r2-boundary.exit`.
- PASS: a regression added before its release-check fix failed four assertions
  for a runtime error before the live cue. It exposed retained native prefix,
  missing capture error, and missing failure notification. The same test passes
  in the final debug suite. Red run exit 1 and log:
  `/tmp/flo-r2-release-before-live-red.exit` and
  `/tmp/flo-r2-release-before-live-red.log`.

- PASS, exit 0: `swift test -c release --disable-automatic-resolution --filter
  '^LocalFlowTests\.(AudioCaptureLifecycleTests|AudioRecorderTests|VoicedAudioTests|IncrementalCutPointTests|Dictation[A-Za-z]*Tests|RetainedAudioFileTests|PersonalVoice[A-Za-z]*Tests|NativeAudioRecordingTests|AppTerminationTests)/'`,
  166 tests, zero failures, including compilation of the changed application.
  Log: `/tmp/flo-r2-release.log`. Exit status: `/tmp/flo-r2-release.exit`.
  No tests in either final selected suite were skipped.
- PASS, exit 0: `git diff --check` and `git diff --cached --check`.
  Evidence: `/tmp/flo-r2-diff-check.log` and `/tmp/flo-r2-diff-check.exit`.

Existing compiler warnings in diagnostic retention and text injection remain.
No warning was reported in the changed recorder, AppDelegate, or capture tests.

An intermediate run failed nine assertions in the previous test that expected
live runtime recovery to join partial speech across sessions. R2 replaces that
contract with terminal discard and tests bounded recovery before live capture.
Log: `/tmp/flo-r2-first.log`. The first broader integration filter also matched
one private named-pasteboard fixture with stubbed paste. It did not use the
system clipboard. Final selections above exclude TextInjector tests.

NOT RUN: live microphone, physical hotplug/Bluetooth wakeup, real-model inference,
installed UI, target-app insertion, packaging, installation, or performance
measurement. Synthetic progress tests establish lifecycle contracts, not
hardware-specific threshold tuning. Boundary tests substitute UI effects and
recognition dispatch. Earlier incremental inference can have run before a later
capture failure; cancellation rejects its eventual output. Full-suite execution
is omitted to keep validation within the task's device and clipboard boundary.

R2 stack integration also clears the captured command target on the matching
terminal failure, while stale failures leave a newer target intact. The compiled
AppDelegate boundary harness includes R3 command-target parameters.


### R2 repair handoff, October 16, 2026

Owner: Flo maintainers. The user authorized repair of independently confirmed
CS1 and CS2 from `/Users/nikhlkapadia/Talix/flo-pr-work/review-r2-result.json`
and `verify-r2-engine-result.txt` / `verify-r2-detachment-result.txt` in that
directory. This section supersedes the earlier R2 verification for cancellation
and release ordering. Base: `4f428f6dd5e2e45ea0bfce8cbca9747948690d71`, local
`pr/r2-capture-failure-health`, including E4, R1, and session/R3/R4 prerequisites.
Implementation branch: `fix/capture-handoff-recovery` in
`/Users/nikhlkapadia/.t3/worktrees/localflow/t3-8c3d22f1`.

#### Capture failure and engine ownership

`AppDelegate.handleCaptureFailure` cancels matching held or released dictations
with `interruptInference: false`. The failed `hotkeyReleased` handoff uses the
same policy, including when it arrives before the UI failure notification.
Generation checks, immediate session invalidation, and timer cancellation reject
stale recognition, HUD updates, history, retry audio, and delivery. Startup and
terminal errors consume the UI generation once; stale errors leave a newer hold
and command target intact. The boundary fixture now uses the actual
`TextInjector.CommandTarget?` shape and extracts the real cancellation helper.

A healthy inference can finish warm while its rejected result releases the gate
for the next recording. R1's `TranscriptionLifetime` remains the sole owner of
abandoned inference and its default 90-second grace. Capture failure itself
never requests immediate quarantine. If inference remains stuck past grace,
R1 quarantines it and wakes followers; authoritative follower failures retain
complete retry audio. Existing `AppDelegate.retryFailedDictation` synchronizes
`modelLoaded`, runs the bounded model-load path, and then retries. This repair
adds no automatic reload policy or second abandonment deadline.

`AudioCaptureLifecycleTests.testCaptureFailureDuringPreviewKeepsEngineWarmAndNextRecordingUsable`
and `testCaptureFailureDuringChunkKeepsEngineWarmAndNextRecordingUsable` use the
real recorder, delivery, pipeline, Transcriber, and gate with synthetic capture
and a suspended fake engine. They fail capture during active inference, reject a
late release, queue the next healthy recording behind the old call, then finish
that call. Only the new recording reaches history and inert delivery. Both
complete on the original engine with one load. The Python boundary separately
checks the actual AppDelegate policy in all three cancellation locations.
Existing `DictationSessionStallTests` cover grace expiry, replacement, queued
followers, stale callbacks, and bounded engine ownership.

#### Atomic paired audio release

`AudioRecorder.stop` validates and detaches recognition and native originals
inside one `sampleQueue.sync` block under the recorder lock. Whole raw/converted
callbacks serialize with detachment. A failure decision leaves that block with
its recording UUID and error; terminal teardown runs on the control queue after
leaving `sampleQueue`. The decision latches runtime failure before unlocking,
so later callbacks cannot append before cleanup. Startup gating, first syllables,
ongoing health, generation checks, warm capture, E4 ranges, and native retention
keep their existing contracts. No new production abstraction or test hook was
introduced. Tests reuse the existing capture factory and session-running closure;
`CaptureRecoveryEngine` is a test-only `SpeechEngine` implementation.

`testStopSerializesDetachmentWithCallbackArrivingDuringSessionValidation` launches
a new callback from the fake session-running getter after the old empty drain
barrier. It pauses between raw and converted delivery. Stop must wait and return
both tails with complete native audio. The red run returned a native tail while
recognition omitted it. `testReleaseChecksHealthBeforeTimerAndNeverHandsOffIncompleteAudio`
now makes teardown drain the sample queue, exercising the failure decision outside
that queue. Existing lifecycle tests cover failed/stale release, delayed snapshots,
terminal cleanup, first syllables, silence, startup budgets, and complete originals.

#### Verification and review state

Implementation ran directly in this Codex context, using `gpt-6.1-sol`; no child
agents or alternate model subprocesses were used. One local R2 commit is
authorized. Push, PR creation, merge, install, network access, live app, microphone,
clipboard, and Accessibility operations are outside authorization. Independent
repair review belongs to the parent. No material product decisions remain open.
Only these five tracked files changed: `Sources/LocalFlow/AppDelegate.swift`,
`Sources/LocalFlow/AudioRecorder.swift`, `Tests/CaptureFailureBoundaryTests.py`,
`Tests/LocalFlowTests/AudioCaptureLifecycleTests.swift`, and this flow record.
No unrelated dirty files were present. The final commit SHA is in the implementation
handoff; `/tmp/flo-r2-repair-final.diff` identifies the verified diff against base.

Environment: macOS 27.0.1, arm64, Swift 6.4. The existing dependency cache was
cloned locally into ignored `.build`, with the lockfile unchanged. Swift checks
run inside a network-denying `sandbox-exec` wrapper. `--disable-sandbox` avoids
nested SwiftPM manifest sandbox failure while the outer network denial remains.
Broader debug and release checks use `CFFIXED_USER_HOME=/tmp/flo-r2-repair-home`
and deny writes to personal logs and reads/writes to production app data.
Tests use synthetic capture, inert injection, and temporary persistence fixtures.

- RED, exit 1: actual-handler Python boundary before repair, three failed cases
  exposing immediate interruption. Log: `/tmp/flo-r2-repair-boundary-red.log`.
- RED, exit 1: deterministic release race before recorder repair, two assertions
  exposing missing converted tail and premature handoff. Log and exit status:
  `/tmp/flo-r2-repair-race-red.log` and `.exit`.
- RED, exit 1: the new preview/chunk integrations replaying the original default
  interrupting policy, 12 failed assertions including engine quarantine and
  next-hold `notLoaded`. Log: `/tmp/flo-r2-repair-engine-red.log` and `.exit`.
- PASS, exit 0: `python3 -B Tests/CaptureFailureBoundaryTests.py`, seven cases.
  Log: `/tmp/flo-r2-repair-boundary-green.log`.
- PASS, exit 0: `swift test --disable-sandbox --disable-automatic-resolution --filter
  'AudioCaptureLifecycleTests|DictationSessionStallTests|PreviewInferenceBudgetTests|TranscriberTests'`,
  65 tests, zero failures. Log: `/tmp/flo-r2-repair-focused.log` and `.exit`.
- PASS, exit 0: `swift test --disable-sandbox --disable-automatic-resolution --filter
  '^LocalFlowTests\.(AudioCaptureLifecycleTests|AudioRecorderTests|VoicedAudioTests|IncrementalCutPointTests|Dictation[A-Za-z]*Tests|RetainedAudioFileTests|PersonalVoice[A-Za-z]*Tests|NativeAudioRecordingTests|AppTerminationTests|TranscriberTests|PreviewInferenceBudgetTests|TranscriptionModelTests)/'`,
  221 tests, zero failures, no skips. Log: `/tmp/flo-r2-repair-debug.log` and `.exit`.
- PASS, exit 0: the same selection with `-c release`, 221 tests, zero failures,
  no skips, including compilation of the production application. Log:
  `/tmp/flo-r2-repair-release.log` and `.exit`.
- PASS, exit 0: final Python boundary, seven cases. Log:
  `/tmp/flo-r2-repair-boundary-final.log` and `.exit`.
- PASS, exit 0: `python3 -B Tests/StartupReadinessTests.py`, four cases. Log:
  `/tmp/flo-r2-repair-startup.log` and `.exit`.
- PASS, exit 0: `git diff --check` and `git diff --cached --check`. Log:
  `/tmp/flo-r2-repair-diff-check.log` and `.exit`.

NOT RUN: full suite, TextInjector/TargetedDelivery fixtures, live devices, real
recognition, actual UI visibility or insertion, packaging, installation, and
external Git operations. The selected suites avoid clipboard and Accessibility.
A first integration-fixture attempt used synchronous XCTest waits from an async
MainActor test and timed out; async bounded expectations replaced those waits
before the behavioral red run. Nested manifest and boundary macro sandbox
attempts were blocked by `sandbox_apply: Operation not permitted`. Swift checks
use the outer sandbox with SwiftPM's nested sandbox disabled. The standalone
boundary command passes without an outer sandbox and has no network operations.
Its blocked wrapper log is `/tmp/flo-r2-repair-boundary-nested-sandbox.log`.
Release compilation reports inherited diagnostic/text-injection warnings and
relocated-cache warnings. No changed production code or capture test warning
was reported.

Next reviewer: compare the commit with base, inspect `handleCaptureFailure`,
the failed-release guard, and `AudioRecorder.stop`, then run the named tests.
Review CS1 and CS2 independently. Suggested skills: unslop, code-review,
review-finished-work, and workflow-capture. Parent integration should preserve
its separately owned command-lifetime changes when applying this one R2 commit.
