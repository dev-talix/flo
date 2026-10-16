# Changelog

## [1.10.0](https://github.com/dev-talix/flo/compare/v1.12.0...v1.10.0) (2026-10-16)


### Features

* add local dictation and Whisper startup timing diagnostics ([4d3ca41](https://github.com/dev-talix/flo/commit/4d3ca410d949cfcba8d74f4dc8cfd4e68353f092))
* add monochrome light and dark Flo app icons ([#42](https://github.com/dev-talix/flo/issues/42)) ([99b75e0](https://github.com/dev-talix/flo/commit/99b75e0a2666bfab79b72c849ed2a70bc12d4631))
* add native settings and local diagnostics ([3966f32](https://github.com/dev-talix/flo/commit/3966f321422b1ec92d36825ad4316daf4f2d26e7))
* add Parakeet TDT 0.6B v3 engine through FluidAudio ([86b65ac](https://github.com/dev-talix/flo/commit/86b65acd590fad17c1da775bbaa94d49aa187d3c))
* add production diagnostics with 30-day retention and export ([2201626](https://github.com/dev-talix/flo/commit/2201626466629327c0849554ee2dafaddd79d899))
* add Show live transcript in the HUD setting ([219efb5](https://github.com/dev-talix/flo/commit/219efb53ebe225c3eb2c74d971a11cdce5105b00))
* dot-wave app and menu bar icons for Flo ([645047e](https://github.com/dev-talix/flo/commit/645047e8dec59920b1c9bdc50a1205156e6b9b79))
* draw a live transcript strip under the HUD capsule ([d88b012](https://github.com/dev-talix/flo/commit/d88b012bd5cd90918e8b5a23978b7fede3b9acac))
* Escape cancels an in-progress dictation ([33c1c9c](https://github.com/dev-talix/flo/commit/33c1c9c57e9e2c78379cd3b8a6d689c5c54ff70d))
* expose Fast and Polished dictation choices ([b60dcb7](https://github.com/dev-talix/flo/commit/b60dcb75122e4468b693b0fd2177e2ddd33a44a0))
* give Liquid Glass its own app icon ([cd22291](https://github.com/dev-talix/flo/commit/cd2229179e00c9fc6bdb184e2813c767d6200fe7))
* offer Parakeet in the Model menu and Settings ([63a743a](https://github.com/dev-talix/flo/commit/63a743a94b161f12d9c78a357542485bd0c23118))
* one app icon for every theme, with light and dark variants ([ffa14e1](https://github.com/dev-talix/flo/commit/ffa14e1b2203662ab15042ba85d4fc61ff2106b7))
* pick the live-text chunk cadence from the speech engine ([48d5c81](https://github.com/dev-talix/flo/commit/48d5c8149546ccf973d1d6264cf5f815efc6ecd9))
* plain lit screen on the walkie-talkie app icon ([fe188d3](https://github.com/dev-talix/flo/commit/fe188d335ef4730d537306ac7fc5bfe898577800))
* recover empty dictations and protect active recordings ([0d91b1b](https://github.com/dev-talix/flo/commit/0d91b1bd102ed5af42e53e0e70cef56215087429))
* rename LocalFlow to Walkie ([ad726e1](https://github.com/dev-talix/flo/commit/ad726e1ab78e1fc591a6a357a246f0769c05af31))
* rename Walkie to Flo ([ccc784c](https://github.com/dev-talix/flo/commit/ccc784c7ee283adcf0ea5ddb41e8a4539d228c48))
* report raw partial transcripts from the dictation pipeline ([dcf12e2](https://github.com/dev-talix/flo/commit/dcf12e2cc03998c3d36e30d22783d3b7dcf78baf))
* restore clipboard after the paste is read, not on a fixed timer ([bb9ffae](https://github.com/dev-talix/flo/commit/bb9ffaeab7a4afd9ccbac77f083d12f76d0e5b55))
* retain and review local personal voice recordings ([f635daf](https://github.com/dev-talix/flo/commit/f635daf109ef096cae3a55cd509a54e66fb2c81d))
* retain local audio and transcript stages for diagnostics ([7c12e64](https://github.com/dev-talix/flo/commit/7c12e64355a739cc3a16100c3a8c51e09a676f5f))
* show live transcript text in the HUD while dictating ([3bdb301](https://github.com/dev-talix/flo/commit/3bdb301f6db0a89d47ffe2cb701ae87e3cad8d6c))
* show Parakeet preview text in the HUD every second ([d104f5c](https://github.com/dev-talix/flo/commit/d104f5c7b77cfda55a57b5834494f7eba3db78f3))
* show the live transcript in a Handy-style panel above the HUD ([fd81fb6](https://github.com/dev-talix/flo/commit/fd81fb64ad7312a5d5b90180483301a230975d37))
* speed up dictation and compact status feedback ([9c7be1d](https://github.com/dev-talix/flo/commit/9c7be1d8c5e2f5892a2741766da3e24c54fb2e32))
* speed up local dictation and compact feedback ([df8822f](https://github.com/dev-talix/flo/commit/df8822fc8aec45fefd17f44d1a535edbc78b34c4))
* walkie-talkie app icon in every listening theme ([2938147](https://github.com/dev-talix/flo/commit/29381475da4b629f6be3000890cd60ab2bc73335))
* walkie-talkie menubar icon that animates while you talk ([56f5ac7](https://github.com/dev-talix/flo/commit/56f5ac731a26275c0f0eda5c05e9b6335df18e12))


### Fixes

* apply correction replacements atomically ([161e6b5](https://github.com/dev-talix/flo/commit/161e6b5ba6cd73031eba44be93a7bfb88e83dba7))
* arm stalled dictation timeout ([1f50eda](https://github.com/dev-talix/flo/commit/1f50edab989eeeadbe9800968d1dbe5b1b9974e8))
* bind releases to trusted state ([f95603f](https://github.com/dev-talix/flo/commit/f95603f44d58d33f38d1b11b9893b7cff3389513))
* block stale release publication ([524b1d0](https://github.com/dev-talix/flo/commit/524b1d059dbe182e21b6bf5c808514aeaa365e9b))
* bound abandoned inference recovery ([9094828](https://github.com/dev-talix/flo/commit/9094828c8efcecdf5c655575aaa43816ae89c574))
* cancel stalled mixed-mode injections ([c59a458](https://github.com/dev-talix/flo/commit/c59a4582111228b3b4542d871eb4f90155c5e6cb))
* clarify snippet entry and restore settings paste shortcuts ([0a308ff](https://github.com/dev-talix/flo/commit/0a308ff3c20d22fb8647f93d15134165fcbf43ba))
* clarify snippet entry and restore settings paste shortcuts ([0d9ef91](https://github.com/dev-talix/flo/commit/0d9ef91e5b5a775450640f9dbef3a5db2d2f6644))
* clean up terminal capture failures and monitor stream health ([4f428f6](https://github.com/dev-talix/flo/commit/4f428f6dd5e2e45ea0bfce8cbca9747948690d71))
* compact status and serialize model startup ([95814cd](https://github.com/dev-talix/flo/commit/95814cd912d8a5d3da910a28ea84ed5e3027488c))
* compact status and serialize model startup ([7838b5e](https://github.com/dev-talix/flo/commit/7838b5e78caf8846d6d18d818710ad52fd51d95f))
* compare release assets portably ([5e1d62f](https://github.com/dev-talix/flo/commit/5e1d62f516ac411880f4c1dda9519e0b67712e65))
* complete capture failure cleanup and monitor stream health ([4448cfc](https://github.com/dev-talix/flo/commit/4448cfce2ce22d0e809e1efc91066895ce026b03))
* decouple archive expiry and reconcile diagnostic imports ([862e42f](https://github.com/dev-talix/flo/commit/862e42f31505626c34f348a7b862ecaac7234ec9))
* decouple archive expiry and reconcile diagnostic imports ([aced1cb](https://github.com/dev-talix/flo/commit/aced1cb0b8f28faf1b4c8210790215258436b4f2))
* dispatch releases from default branch ([2c6c390](https://github.com/dev-talix/flo/commit/2c6c390d94656e8e6d777fa129df9b6e8a80ed7c))
* fail closed before publishing releases ([87ac6cc](https://github.com/dev-talix/flo/commit/87ac6cc2f80e60c7810006b7d358ae52e0304d7e))
* fail closed before publishing releases ([a9dc716](https://github.com/dev-talix/flo/commit/a9dc716f63544ccef5d29cbd44bd55a721d77e40))
* fall back to an installed cleanup model ([46ba035](https://github.com/dev-talix/flo/commit/46ba0353f15655673764800ae7e2d94e36da0a0c))
* finalize published release labels ([f89a3bb](https://github.com/dev-talix/flo/commit/f89a3bbdac3b116948c1af14014d0b8e2b62ced2))
* finalize published release labels ([0bdac60](https://github.com/dev-talix/flo/commit/0bdac60e10efa35b378c53c0ab364d73ce38298f))
* finish local text model integration ([c5a4acd](https://github.com/dev-talix/flo/commit/c5a4acdcc4b5b748764e9f80c24280685db65983))
* guard diagnostic import destinations and defer capacity errors ([bf536a1](https://github.com/dev-talix/flo/commit/bf536a177667e7f66f4e3eb85b124e298fe35733))
* identify installed apps by bundle and respect normal Quit ([27f9e7a](https://github.com/dev-talix/flo/commit/27f9e7a243fad91f299f3ff84534282374b85755))
* integrate local text model policy ([89fe898](https://github.com/dev-talix/flo/commit/89fe898aa3159b52dc3cbbb4ac4ba71c595aecdf))
* keep each Parakeet segment's start at or before its end ([e56e1d1](https://github.com/dev-talix/flo/commit/e56e1d1123a36f9ac9be5b67fbacccdd6efc6ea3))
* keep launch updater sessions from wedging ([4ecf7f5](https://github.com/dev-talix/flo/commit/4ecf7f5721980dddf6031bc3e27a8e91c245c5ec))
* keep liquid glass compatible with the CI SDK ([2fd63e1](https://github.com/dev-talix/flo/commit/2fd63e153370760811766a3426d6fd0fa4be810e))
* keep menu error summaries compact ([4417b35](https://github.com/dev-talix/flo/commit/4417b35081a8fdc6c0538e3923b574ce31e0b693))
* keep settings compatible with the CI SDK ([40325c5](https://github.com/dev-talix/flo/commit/40325c5f2c34142115341ea77e5b9cce5613c21a))
* keep the speech model loaded when Escape cancels a dictation ([bfad00d](https://github.com/dev-talix/flo/commit/bfad00df2c2d7a2337c8438234c8a8ce007b7071))
* key prewarm cooldowns by backend ([57c2fe5](https://github.com/dev-talix/flo/commit/57c2fe50bb910107d8f1d3dc29d3aae0d88bac91))
* let Escape cancel while Right Command is the held hotkey ([16d8cbf](https://github.com/dev-talix/flo/commit/16d8cbf31f781a9d1979b37a4dbf8f2f95bb0387))
* log a disabled Escape tap only while it should be on ([ce99886](https://github.com/dev-talix/flo/commit/ce998863b419a417c7dbc31cb8806b19b147e8b2))
* make release invocation non-replayable ([84fe882](https://github.com/dev-talix/flo/commit/84fe882e6df7f9abaecd7e00af19dbabad3b7023))
* make the non-ASCII lint work on BSD grep, and add release-please ([73ed875](https://github.com/dev-talix/flo/commit/73ed8759f9fee8b30f42d02a17f5acb9c630e682))
* match Liquid Glass icon to the listening waveform ([ab1848d](https://github.com/dev-talix/flo/commit/ab1848d15e1e99863ddb91521b19f7f52c00aa02))
* measure Parakeet pauses the way FluidAudio reports them ([1f71feb](https://github.com/dev-talix/flo/commit/1f71feb968f995519447778b19cc50dc9807e860))
* name the speech model, not Whisper, in errors and drop em dashes ([24ba624](https://github.com/dev-talix/flo/commit/24ba624b2689f4907609187b4d7b79145c12ea54))
* notify capture failure before hardware teardown ([888b8ee](https://github.com/dev-talix/flo/commit/888b8ee61e1c11337c1284cf7589824987c87914))
* pace clipboard delivery and validate command targets ([9183e4e](https://github.com/dev-talix/flo/commit/9183e4e4777d7d7a362f7533be91d8d0239d9bf9))
* pace queued delivery and pin command targets ([129bbf6](https://github.com/dev-talix/flo/commit/129bbf67a955528f08bbcd753e97c929afa767b7))
* preserve automatic lists around verbatim snippets ([97c962a](https://github.com/dev-talix/flo/commit/97c962a5bbbf1308f0cedd6cdb1195254c49776b))
* preserve Developer ID identity when updating theme icons ([84f6ce9](https://github.com/dev-talix/flo/commit/84f6ce94787859c87dc9e93159d2aca992abda3c))
* preserve displayed words across bounded previews ([d19a1ad](https://github.com/dev-talix/flo/commit/d19a1ad0db471806a3476c68f037b0b6035a4418))
* preserve injection stall deadline ([22ce84d](https://github.com/dev-talix/flo/commit/22ce84d3c6d76d5d353d23e8e52dfcee5464020b))
* preserve stalled dictation deadline ([d23afda](https://github.com/dev-talix/flo/commit/d23afda227002b919f66ae1e7fbbab4d89223489))
* preserve verbatim snippets and add literal formatting ([d5dd1f1](https://github.com/dev-talix/flo/commit/d5dd1f183f8a96406b9dbe12cc5574bb18a158e5))
* preserve verbatim snippets and offer literal formatting ([ae5382f](https://github.com/dev-talix/flo/commit/ae5382febea7673b487a3e4ecbe57a5700883a1b))
* preserve warm inference and atomic capture release ([4537179](https://github.com/dev-talix/flo/commit/4537179e618f4db52fa36c143c760913cf123268))
* recover inference abandoned by Escape ([95dc27f](https://github.com/dev-talix/flo/commit/95dc27f048a564842210d986bbbff7994d8e7cd7))
* recreate the Escape tap after macOS invalidates it ([eb5cf4d](https://github.com/dev-talix/flo/commit/eb5cf4d32f9bdd9b75b7e7a5fdb6e14557bfeac3))
* reduce repeated decoding of near-silent dictations ([5ddcfba](https://github.com/dev-talix/flo/commit/5ddcfba8922499201eb8fc8306ca0b9f338e5bee))
* reject focus changes during command target reads ([6ca3bab](https://github.com/dev-talix/flo/commit/6ca3bab456217a16a5bfebad665fbb14ae95643a))
* resolve dictation stalls and command, CLI, and history bugs ([396b8ff](https://github.com/dev-talix/flo/commit/396b8ff149a32d28de9e1a23e97e02c78af943d2))
* restore a pending clipboard at quit instead of refusing for up to 10 s ([b8ead55](https://github.com/dev-talix/flo/commit/b8ead5506c2a7bf7c19f04e94febf45d5de81ef8))
* restrict release please to main pushes ([3676efc](https://github.com/dev-talix/flo/commit/3676efc7042b50ddf9c5d11530327fd5ffdc8bf4))
* retain local diagnostics across app updates ([d08765d](https://github.com/dev-talix/flo/commit/d08765dd94b863c5b37b964f94eed1f9cd1c5bf3))
* run the app from a synchronous main entry ([d4eec7b](https://github.com/dev-talix/flo/commit/d4eec7b904a3d9cbffeacdd608c3382413003d4a))
* scale HUD loudness by log-ratio over the room floor ([8f69581](https://github.com/dev-talix/flo/commit/8f695817726143f11a26e1c82611fa1dedf80a92))
* share release gate logic across workflows ([518899b](https://github.com/dev-talix/flo/commit/518899b86f12a384b89375208f6b215c8ce1e99b))
* show Whisper previews before safe chunk completion ([82dbae7](https://github.com/dev-talix/flo/commit/82dbae7934c8e20fd44554795a8dcdf4a190b42d))
* show Whisper previews before safe chunk completion ([47f1bb9](https://github.com/dev-talix/flo/commit/47f1bb906e8f3b2291a617f13dd9bb0b11300e74))
* sign release disk images ([febfdbe](https://github.com/dev-talix/flo/commit/febfdbefcbf8ae69c8ce8e2dc2e9a909bea26bb2))
* sign release disk images ([0c68f85](https://github.com/dev-talix/flo/commit/0c68f854aac9a5efe6266f5ae5f41cdae61b9cde))
* skip the command-mode AX warmup while a paste awaits its read ([af978d0](https://github.com/dev-talix/flo/commit/af978d08d0be3c6e3038d023b14f0781d0029078))
* stop restoring the clipboard early at quit ([4b5e4cb](https://github.com/dev-talix/flo/commit/4b5e4cbc7121f2f3359ac7f19f8a9651e90f51c1))
* track command speech abandonment lifetime ([bc39465](https://github.com/dev-talix/flo/commit/bc39465f1db7a53d697f53bd9fb240c32ff82166))
* use bundle identity and normal Quit in installers ([3178520](https://github.com/dev-talix/flo/commit/3178520caba8ec9e1c2517ad6e8617eac62b7801))
* use compact native toolbar in settings ([601fee5](https://github.com/dev-talix/flo/commit/601fee53a3d9f5de87c7e7e2d74d300546ffd112))
* verify release source and destination ([b736066](https://github.com/dev-talix/flo/commit/b736066a976e79b8343a8ab51b1cfa996c9f3db7))


### Performance

* bound audio snapshots and retained WAV buffers ([60d59d0](https://github.com/dev-talix/flo/commit/60d59d0900de9503698ccaed9d5ceab85fcbc198))
* bound capture snapshots and retained audio buffers ([e5a8e06](https://github.com/dev-talix/flo/commit/e5a8e065ad28d371d3b3cf9428e10bd4cbc2d481))
* bound cleanup and expose Fast and Polished choices ([a7a5cc0](https://github.com/dev-talix/flo/commit/a7a5cc0078a3803ce8fe7719f3b5369e44ff1080))
* bound optional cleanup and preserve recognized text ([642b449](https://github.com/dev-talix/flo/commit/642b44990c154cc43a0f762f7613283e6402c9c0))
* budget preview inference and prioritize final work ([cd6c9bd](https://github.com/dev-talix/flo/commit/cd6c9bdea4c80dba82fef03477246eaca2e58d53))
* give previews a separate inference budget ([d51792b](https://github.com/dev-talix/flo/commit/d51792be239c0993c02685e9a30bf81a67580d0d))
* reduce diagnostic retention and idle audio work ([fd6cdea](https://github.com/dev-talix/flo/commit/fd6cdea339b28f9e5119173c55a0f4febd52fc9d))
* reduce diagnostic writes and idle audio analysis ([276f6c8](https://github.com/dev-talix/flo/commit/276f6c8fbb95cf0586af715cd192360fdf6599e2))
* reuse released audio preparation ([12c2c80](https://github.com/dev-talix/flo/commit/12c2c80e93e5cbd792647c0df4b2668b2c375a49))
* reuse released dictation audio preparation ([1ee33c1](https://github.com/dev-talix/flo/commit/1ee33c1b2524caa60768945fe96c8bf690998bd9))


### Chores

* release 1.10.0 ([36368ff](https://github.com/dev-talix/flo/commit/36368ffb4bffef5ee96c33668e93619ce81048ef))
* release 1.9.1 ([bcd05cf](https://github.com/dev-talix/flo/commit/bcd05cf5f0c2695d4608889890a3772ecf252751))

## [1.12.0](https://github.com/dev-talix/flo/compare/v1.11.1...v1.12.0) (2026-10-16)

### Features

* Choose Fast dictation to skip model cleanup, or Polished to clean up recognized prose. ([#48](https://github.com/dev-talix/flo/pull/48))
* Enable Literal formatting to keep spoken formatting commands and ordinal phrases as text. ([#54](https://github.com/dev-talix/flo/pull/54))

### Fixes

* Show live previews during continuous speech and preserve newer displayed words as chunks finish. ([#46](https://github.com/dev-talix/flo/pull/46), [#49](https://github.com/dev-talix/flo/pull/49))
* Preserve saved snippets exactly in Fast and Polished, including whitespace, line breaks, tabs, and literal backslashes. ([#54](https://github.com/dev-talix/flo/pull/54))
* Restore editing shortcuts in Settings and provide clearly labeled fields with a multiline snippet editor. ([#58](https://github.com/dev-talix/flo/pull/58))
* Recover from stalled or abandoned recognition after Escape and reject late results from cancelled sessions. ([#50](https://github.com/dev-talix/flo/pull/50))
* Detect microphone stream failures, discard failed captures, and prevent stale results from reaching delivery. ([#55](https://github.com/dev-talix/flo/pull/55))
* Pace queued pastes around clipboard reads and reject command replacements when the original target or selection changes. ([#53](https://github.com/dev-talix/flo/pull/53))
* Identify installed apps by bundle and request normal Quit during installation. ([#52](https://github.com/dev-talix/flo/pull/52))
* Keep retained-recording expiry working after recovery failures and refresh imported transcript stages while preserving review edits. ([#57](https://github.com/dev-talix/flo/pull/57))

### Performance

* Reuse prepared audio and bound preview inference, optional cleanup, capture snapshots, and retained audio buffers. ([#47](https://github.com/dev-talix/flo/pull/47), [#48](https://github.com/dev-talix/flo/pull/48), [#49](https://github.com/dev-talix/flo/pull/49), [#51](https://github.com/dev-talix/flo/pull/51))
* Skip idle audio analysis and unused spectrum work. ([#56](https://github.com/dev-talix/flo/pull/56))
* Reduce repeated archive scans and diagnostic encoding during recording. ([#56](https://github.com/dev-talix/flo/pull/56))

## [1.11.1](https://github.com/dev-talix/flo/compare/v1.10.0...v1.11.1) (2026-10-10)


### Features

* add monochrome light and dark Flo app icons ([#42](https://github.com/dev-talix/flo/issues/42)) ([99b75e0](https://github.com/dev-talix/flo/commit/99b75e0a2666bfab79b72c849ed2a70bc12d4631))


This release replaces the unpublished 1.11.0 release, which had the same changes.

## [1.11.0](https://github.com/dev-talix/flo/compare/v1.10.0...v1.11.0) (2026-10-10)


### Features

* add monochrome light and dark Flo app icons ([#42](https://github.com/dev-talix/flo/issues/42)) ([99b75e0](https://github.com/dev-talix/flo/commit/99b75e0a2666bfab79b72c849ed2a70bc12d4631))

## [1.10.0](https://github.com/NikAtNight/flo/compare/v1.9.0...v1.10.0) (2026-10-08)


### Features

* dot-wave app and menu bar icons for Flo ([645047e](https://github.com/NikAtNight/flo/commit/645047e8dec59920b1c9bdc50a1205156e6b9b79))
* rename Walkie to Flo ([ccc784c](https://github.com/NikAtNight/flo/commit/ccc784c7ee283adcf0ea5ddb41e8a4539d228c48))


This release also includes the Sparkle 2.10.0 update and the app icon work from the unpublished 1.9.0 release.

## [1.9.0](https://github.com/NikAtNight/walkie/compare/v1.8.0...v1.9.0) (2026-10-06)


### Features

* one app icon for every theme, with light and dark variants ([ffa14e1](https://github.com/NikAtNight/walkie/commit/ffa14e1b2203662ab15042ba85d4fc61ff2106b7))
* plain lit screen on the walkie-talkie app icon ([fe188d3](https://github.com/NikAtNight/walkie/commit/fe188d335ef4730d537306ac7fc5bfe898577800))
* walkie-talkie app icon in every listening theme ([2938147](https://github.com/NikAtNight/walkie/commit/29381475da4b629f6be3000890cd60ab2bc73335))

## [1.8.0](https://github.com/NikAtNight/walkie/compare/v1.7.0...v1.8.0) (2026-10-06)


### Features

* rename LocalFlow to Walkie ([ad726e1](https://github.com/NikAtNight/walkie/commit/ad726e1ab78e1fc591a6a357a246f0769c05af31))
* walkie-talkie menubar icon that animates while you talk ([56f5ac7](https://github.com/NikAtNight/walkie/commit/56f5ac731a26275c0f0eda5c05e9b6335df18e12))

## [1.7.0](https://github.com/NikAtNight/localflow/compare/v1.6.2...v1.7.0) (2026-10-02)


### Features

* add Parakeet TDT 0.6B v3 engine through FluidAudio ([86b65ac](https://github.com/NikAtNight/localflow/commit/86b65acd590fad17c1da775bbaa94d49aa187d3c))
* add Show live transcript in the HUD setting ([219efb5](https://github.com/NikAtNight/localflow/commit/219efb53ebe225c3eb2c74d971a11cdce5105b00))
* draw a live transcript strip under the HUD capsule ([d88b012](https://github.com/NikAtNight/localflow/commit/d88b012bd5cd90918e8b5a23978b7fede3b9acac))
* Escape cancels an in-progress dictation ([33c1c9c](https://github.com/NikAtNight/localflow/commit/33c1c9c57e9e2c78379cd3b8a6d689c5c54ff70d))
* offer Parakeet in the Model menu and Settings ([63a743a](https://github.com/NikAtNight/localflow/commit/63a743a94b161f12d9c78a357542485bd0c23118))
* pick the live-text chunk cadence from the speech engine ([48d5c81](https://github.com/NikAtNight/localflow/commit/48d5c8149546ccf973d1d6264cf5f815efc6ecd9))
* report raw partial transcripts from the dictation pipeline ([dcf12e2](https://github.com/NikAtNight/localflow/commit/dcf12e2cc03998c3d36e30d22783d3b7dcf78baf))
* restore clipboard after the paste is read, not on a fixed timer ([bb9ffae](https://github.com/NikAtNight/localflow/commit/bb9ffaeab7a4afd9ccbac77f083d12f76d0e5b55))
* show live transcript text in the HUD while dictating ([3bdb301](https://github.com/NikAtNight/localflow/commit/3bdb301f6db0a89d47ffe2cb701ae87e3cad8d6c))
* show Parakeet preview text in the HUD every second ([d104f5c](https://github.com/NikAtNight/localflow/commit/d104f5c7b77cfda55a57b5834494f7eba3db78f3))
* show the live transcript in a Handy-style panel above the HUD ([fd81fb6](https://github.com/NikAtNight/localflow/commit/fd81fb64ad7312a5d5b90180483301a230975d37))


### Fixes

* keep each Parakeet segment's start at or before its end ([e56e1d1](https://github.com/NikAtNight/localflow/commit/e56e1d1123a36f9ac9be5b67fbacccdd6efc6ea3))
* keep the speech model loaded when Escape cancels a dictation ([bfad00d](https://github.com/NikAtNight/localflow/commit/bfad00df2c2d7a2337c8438234c8a8ce007b7071))
* let Escape cancel while Right Command is the held hotkey ([16d8cbf](https://github.com/NikAtNight/localflow/commit/16d8cbf31f781a9d1979b37a4dbf8f2f95bb0387))
* log a disabled Escape tap only while it should be on ([ce99886](https://github.com/NikAtNight/localflow/commit/ce998863b419a417c7dbc31cb8806b19b147e8b2))
* measure Parakeet pauses the way FluidAudio reports them ([1f71feb](https://github.com/NikAtNight/localflow/commit/1f71feb968f995519447778b19cc50dc9807e860))
* name the speech model, not Whisper, in errors and drop em dashes ([24ba624](https://github.com/NikAtNight/localflow/commit/24ba624b2689f4907609187b4d7b79145c12ea54))
* recreate the Escape tap after macOS invalidates it ([eb5cf4d](https://github.com/NikAtNight/localflow/commit/eb5cf4d32f9bdd9b75b7e7a5fdb6e14557bfeac3))
* restore a pending clipboard at quit instead of refusing for up to 10 s ([b8ead55](https://github.com/NikAtNight/localflow/commit/b8ead5506c2a7bf7c19f04e94febf45d5de81ef8))
* skip the command-mode AX warmup while a paste awaits its read ([af978d0](https://github.com/NikAtNight/localflow/commit/af978d08d0be3c6e3038d023b14f0781d0029078))
* stop restoring the clipboard early at quit ([4b5e4cb](https://github.com/NikAtNight/localflow/commit/4b5e4cbc7121f2f3359ac7f19f8a9651e90f51c1))

## [1.6.2](https://github.com/NikAtNight/localflow/compare/v1.6.1...v1.6.2) (2026-10-01)


### Fixes

* resolve dictation stalls and command, CLI, and history bugs ([396b8ff](https://github.com/NikAtNight/localflow/commit/396b8ff149a32d28de9e1a23e97e02c78af943d2))

## [1.6.1](https://github.com/NikAtNight/localflow/compare/v1.6.0...v1.6.1) (2026-09-13)


### Fixes

* reduce repeated decoding of near-silent dictations ([5ddcfba](https://github.com/NikAtNight/localflow/commit/5ddcfba8922499201eb8fc8306ca0b9f338e5bee))

## [1.6.0](https://github.com/NikAtNight/localflow/compare/v1.5.0...v1.6.0) (2026-09-11)


### Features

* add production diagnostics with 30-day retention and export ([2201626](https://github.com/NikAtNight/localflow/commit/2201626466629327c0849554ee2dafaddd79d899))


### Fixes

* retain local diagnostics across app updates ([d08765d](https://github.com/NikAtNight/localflow/commit/d08765dd94b863c5b37b964f94eed1f9cd1c5bf3))

## [1.5.0](https://github.com/NikAtNight/localflow/compare/v1.4.1...v1.5.0) (2026-09-10)


### Features

* retain and review local personal voice recordings ([f635daf](https://github.com/NikAtNight/localflow/commit/f635daf109ef096cae3a55cd509a54e66fb2c81d))
* retain local audio and transcript stages for diagnostics ([7c12e64](https://github.com/NikAtNight/localflow/commit/7c12e64355a739cc3a16100c3a8c51e09a676f5f))


### Fixes

* preserve Developer ID identity when updating theme icons ([84f6ce9](https://github.com/NikAtNight/localflow/commit/84f6ce94787859c87dc9e93159d2aca992abda3c))

## [1.4.1](https://github.com/NikAtNight/localflow/compare/v1.4.0...v1.4.1) (2026-09-10)


### Fixes

* match Liquid Glass icon to the listening waveform ([ab1848d](https://github.com/NikAtNight/localflow/commit/ab1848d15e1e99863ddb91521b19f7f52c00aa02))
* use compact native toolbar in settings ([601fee5](https://github.com/NikAtNight/localflow/commit/601fee53a3d9f5de87c7e7e2d74d300546ffd112))

## [1.4.0](https://github.com/NikAtNight/localflow/compare/v1.3.0...v1.4.0) (2026-09-09)


### Features

* recover empty dictations and protect active recordings ([0d91b1b](https://github.com/NikAtNight/localflow/commit/0d91b1bd102ed5af42e53e0e70cef56215087429))

## [1.3.0](https://github.com/NikAtNight/localflow/compare/v1.2.0...v1.3.0) (2026-09-09)


### Features

* add native settings and local diagnostics ([3966f32](https://github.com/NikAtNight/localflow/commit/3966f321422b1ec92d36825ad4316daf4f2d26e7))

## [1.2.0](https://github.com/NikAtNight/localflow/compare/v1.1.4...v1.2.0) (2026-09-09)


### Features

* add local dictation and Whisper startup timing diagnostics ([4d3ca41](https://github.com/NikAtNight/localflow/commit/4d3ca410d949cfcba8d74f4dc8cfd4e68353f092))
* give Liquid Glass its own app icon ([cd22291](https://github.com/NikAtNight/localflow/commit/cd2229179e00c9fc6bdb184e2813c767d6200fe7))


### Fixes

* scale HUD loudness by log-ratio over the room floor ([8f69581](https://github.com/NikAtNight/localflow/commit/8f695817726143f11a26e1c82611fa1dedf80a92))

## [1.1.4](https://github.com/NikAtNight/localflow/compare/v1.1.3...v1.1.4) (2026-09-01)


### Fixes

* keep launch updater sessions from wedging ([4ecf7f5](https://github.com/NikAtNight/localflow/commit/4ecf7f5721980dddf6031bc3e27a8e91c245c5ec))
* run the app from a synchronous main entry ([d4eec7b](https://github.com/NikAtNight/localflow/commit/d4eec7b904a3d9cbffeacdd608c3382413003d4a))

## [1.1.3](https://github.com/NikAtNight/localflow/compare/v1.1.2...v1.1.3) (2026-09-01)


### Fixes

* fall back to an installed cleanup model ([46ba035](https://github.com/NikAtNight/localflow/commit/46ba0353f15655673764800ae7e2d94e36da0a0c))
* keep menu error summaries compact ([4417b35](https://github.com/NikAtNight/localflow/commit/4417b35081a8fdc6c0538e3923b574ce31e0b693))
* share release gate logic across workflows ([518899b](https://github.com/NikAtNight/localflow/commit/518899b86f12a384b89375208f6b215c8ce1e99b))

## [1.1.2](https://github.com/NikAtNight/localflow/compare/v1.1.1...v1.1.2) (2026-09-01)


### Fixes

* compact status and serialize model startup ([7838b5e](https://github.com/NikAtNight/localflow/commit/7838b5e78caf8846d6d18d818710ad52fd51d95f))

## [1.1.1](https://github.com/NikAtNight/localflow/compare/v1.1.0...v1.1.1) (2026-08-31)


### Fixes

* finalize published release labels ([f89a3bb](https://github.com/NikAtNight/localflow/commit/f89a3bbdac3b116948c1af14014d0b8e2b62ced2))
* finalize published release labels ([0bdac60](https://github.com/NikAtNight/localflow/commit/0bdac60e10efa35b378c53c0ab364d73ce38298f))
* sign release disk images ([febfdbe](https://github.com/NikAtNight/localflow/commit/febfdbefcbf8ae69c8ce8e2dc2e9a909bea26bb2))
* sign release disk images ([0c68f85](https://github.com/NikAtNight/localflow/commit/0c68f854aac9a5efe6266f5ae5f41cdae61b9cde))

## [1.1.0](https://github.com/NikAtNight/localflow/compare/v1.0.0...v1.1.0) (2026-08-31)


### Features

* speed up dictation and compact status feedback ([9c7be1d](https://github.com/NikAtNight/localflow/commit/9c7be1d8c5e2f5892a2741766da3e24c54fb2e32))
* speed up local dictation and compact feedback ([df8822f](https://github.com/NikAtNight/localflow/commit/df8822fc8aec45fefd17f44d1a535edbc78b34c4))


### Fixes

* apply correction replacements atomically ([161e6b5](https://github.com/NikAtNight/localflow/commit/161e6b5ba6cd73031eba44be93a7bfb88e83dba7))
* arm stalled dictation timeout ([1f50eda](https://github.com/NikAtNight/localflow/commit/1f50edab989eeeadbe9800968d1dbe5b1b9974e8))
* bind releases to trusted state ([f95603f](https://github.com/NikAtNight/localflow/commit/f95603f44d58d33f38d1b11b9893b7cff3389513))
* block stale release publication ([524b1d0](https://github.com/NikAtNight/localflow/commit/524b1d059dbe182e21b6bf5c808514aeaa365e9b))
* cancel stalled mixed-mode injections ([c59a458](https://github.com/NikAtNight/localflow/commit/c59a4582111228b3b4542d871eb4f90155c5e6cb))
* compare release assets portably ([5e1d62f](https://github.com/NikAtNight/localflow/commit/5e1d62f516ac411880f4c1dda9519e0b67712e65))
* dispatch releases from default branch ([2c6c390](https://github.com/NikAtNight/localflow/commit/2c6c390d94656e8e6d777fa129df9b6e8a80ed7c))
* fail closed before publishing releases ([87ac6cc](https://github.com/NikAtNight/localflow/commit/87ac6cc2f80e60c7810006b7d358ae52e0304d7e))
* fail closed before publishing releases ([a9dc716](https://github.com/NikAtNight/localflow/commit/a9dc716f63544ccef5d29cbd44bd55a721d77e40))
* finish local text model integration ([c5a4acd](https://github.com/NikAtNight/localflow/commit/c5a4acdcc4b5b748764e9f80c24280685db65983))
* integrate local text model policy ([89fe898](https://github.com/NikAtNight/localflow/commit/89fe898aa3159b52dc3cbbb4ac4ba71c595aecdf))
* keep liquid glass compatible with the CI SDK ([2fd63e1](https://github.com/NikAtNight/localflow/commit/2fd63e153370760811766a3426d6fd0fa4be810e))
* keep settings compatible with the CI SDK ([40325c5](https://github.com/NikAtNight/localflow/commit/40325c5f2c34142115341ea77e5b9cce5613c21a))
* key prewarm cooldowns by backend ([57c2fe5](https://github.com/NikAtNight/localflow/commit/57c2fe50bb910107d8f1d3dc29d3aae0d88bac91))
* make release invocation non-replayable ([84fe882](https://github.com/NikAtNight/localflow/commit/84fe882e6df7f9abaecd7e00af19dbabad3b7023))
* make the non-ASCII lint work on BSD grep, and add release-please ([73ed875](https://github.com/NikAtNight/localflow/commit/73ed8759f9fee8b30f42d02a17f5acb9c630e682))
* preserve injection stall deadline ([22ce84d](https://github.com/NikAtNight/localflow/commit/22ce84d3c6d76d5d353d23e8e52dfcee5464020b))
* preserve stalled dictation deadline ([d23afda](https://github.com/NikAtNight/localflow/commit/d23afda227002b919f66ae1e7fbbab4d89223489))
* restrict release please to main pushes ([3676efc](https://github.com/NikAtNight/localflow/commit/3676efc7042b50ddf9c5d11530327fd5ffdc8bf4))
* verify release source and destination ([b736066](https://github.com/NikAtNight/localflow/commit/b736066a976e79b8343a8ab51b1cfa996c9f3db7))
