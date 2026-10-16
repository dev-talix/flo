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
