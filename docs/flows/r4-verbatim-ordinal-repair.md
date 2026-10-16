# Automatic ordinal lists around verbatim snippets

## Requirement source, owner, and non-goals

Owner: Flo maintainers. The October 16, 2026 R4 repair request and confirmed CS2
finding require default ordinal lists to retain their structure around snippets.
Parent: `c280b530845912099e18166d455d81fed44ef30d`, including the failing pipeline
regression. This record covers that repair only. R1, R2, R3, and R6 are separate.
It supersedes the prose-span-only ordinal limitation in the earlier R4 section
of `docs/flows/dictation-recovery.md`.

## Intended behavior and concrete acceptance examples

With `insert code` expanding to `code`, default formatting of
`First, insert code. Second, get eggs.` must produce `1. code\n2. Get eggs.`.
Fast, Polished with identity cleanup, and whole-cleanup deadline fallback must
agree. Matching must still use only original transcript occurrences and retain
earliest, longest, then saved-order precedence. Saved bytes must never receive
corrections, command formatting, ordinal formatting, or model cleanup.

Ordinal cues and consumed punctuation in the transcript determine list structure.
Expansion length and embedded ordinal or command phrases must not change it.
Single or distant ordinal cues remain prose. Literal formatting remains off by
default and, when enabled, still bypasses both commands and automatic lists.
Explicit commands, list state, punctuation, and ordering must remain compatible.

## Observed path and checks before implementation

`DictationSessionPipeline.finalize` calls `Snippets.parts`, corrects only prose,
then calls `VoiceFormatter.apply` unless literal formatting is enabled. The parent
formats each prose span independently, losing both the consumed period and the
two-cue run across the snippet. The pipeline stores the deterministic composition
before sequential prose cleanup. One three-second cleanup deadline restores that
whole composition, including after partial cleanup, and rejects late results.

Use the existing `VerbatimSnippetPipelineTests` regression as the pre-fix red
check. Extend `VerbatimSnippetTests` and pipeline tests for source punctuation,
long multiline saved text, hidden cues and commands, single/distant cues,
Polished prose-only input, and partial-cleanup fallback. Reuse
`VoiceFormatterTests` and `DictationCleanupDeadlineTests` for compatibility.

Commands use `swift test --disable-automatic-resolution --skip-update --filter`
with each test name or class expression. Dependency checkouts, artifacts, and
repository caches were cloned locally into this worktree. No package download,
installation, live app, microphone, clipboard, AX, or model inference is allowed.

## Implemented composition

`Snippets.Part.verbatim` retains the consumed original source alongside the
saved expansion. `Snippets.parts` still owns matching and precedence. Its
`text` accessor still exposes only the expansion. The pipeline's only change
uses that accessor while reassembling protected parts.

`VoiceFormatter.apply` processes explicit commands with shared list state, then
passes all parts to the existing ordinal parser. The parser uses prose plus
matched source for punctuation and distance. It excludes cues inside protected
source ranges, then rewrites only prose ranges. Rendering resets capitalization
at each protected part and keeps its saved bytes intact. Both whole-string
formatter entry points reuse this path. There is no second expander, copied
ordinal parser, placeholder, or model-visible source marker.

## Verified behavior and gaps

Environment: macOS 27.0.1, arm64, Apple Swift 6.4. Repair branch:
`fix/verbatim-ordinal-lists`. The verified patch is the local commit containing
this record. Its SHA is recorded in `/tmp/flo-r4-ordinal-repair-commit.txt`;
the complete staged patch is `/tmp/flo-r4-ordinal-repair-final.diff`.

All Swift commands below use `swift test --disable-automatic-resolution
--skip-update --filter` followed by the exact filter shown. Each command's
actual process exit was captured. No dependency resolution or download ran.

- EXPECTED FAIL, exit 1: pre-fix
  `VerbatimSnippetPipelineTests.testAutomaticNumberedListKeepsItsStructureAcrossASnippet`,
  one test and one assertion failure. Log:
  `/tmp/flo-r4-ordinal-repair-red.log`. The observed result was
  `First, code Second, get eggs.`, confirming the supplied parent red evidence.
- PASS, exit 0: first implementation check, `VerbatimSnippet|VoiceFormatterTests`,
  40 tests. Log: `/tmp/flo-r4-ordinal-repair-first.log`.
- PASS, exit 0: `VerbatimSnippet|DictationCleanupDeadlineTests|VoiceFormatterTests|DictationDiffTests|SettingsModelCorrectionTests`,
  66 tests. Log: `/tmp/flo-r4-ordinal-repair-focused.log`. The original Fast
  regression and Polished identity case produce `1. code\n2. Get eggs.`.
  The additional tests cover exact UTF-8 multiline code, repeated snippets,
  source-based distance, consumed punctuation, hidden ordinals and commands,
  single cues, literal mode, explicit list state, prose-only cleaner input,
  default-off persistence, both deadlines, and late results. The new default
  three-second deadline case restores the entire ordinal list after a previous
  prose span was rewritten and prevents cleanup of later spans.
- PASS, exit 0: `DictationSessionPipelineTests|DictationDiagnosticPipelineTests|PersonalVoicePipelineTests|SegmentJoinTests`,
  37 adjacent tests. Log: `/tmp/flo-r4-ordinal-repair-pipeline.log`. These check
  finalization, chunk ordering, diagnostics, archive transcript stages, and
  paragraph joins through the shared formatter.
- PASS, exit 0: `git diff --cached --check`. Log:
  `/tmp/flo-r4-ordinal-repair-diff-check.log`.
- NOT RUN: full suite, unrelated packaging checks, live app, real models,
  microphone, clipboard, AX, installation, publication, and independent repair
  review. Focused tests compile the app and test target. The maintainer owns
  independent review and assembled-stack verification before publication.

The offline build emits existing concurrency/capture and trailing-closure
warnings. Swift also reports that `--skip-update` is deprecated. No check failed
after the repair.
