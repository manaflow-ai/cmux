# iOS Action Button: call your Chief, save a voice note

Status: v1 landing on feat-cmux-next, 2026-10-19. Owner: a191 (Chief subagent).
Request (user, 2026-10-19): "hold [the Action Button] and it'll bring you into a call with your
chief ... save it as a voice note ... start recording you and then we can transcribe it."

## 1. What the user gets

| Entry point | How | Result |
| --- | --- | --- |
| iPhone Action Button (15 Pro and later) | Settings > Action Button > Shortcut > cmux > "Call Chief" | cmux opens straight into the Chief call screen and is already recording. |
| Siri / Spotlight / Shortcuts app | App Shortcuts "Call my Chief in cmux", "Record a voice note for Chief in cmux" | Same, or a voice note (same screen, titled "Voice Note"). |
| Control Center and Lock Screen | iOS 18 "Shortcuts" control > cmux > "Call Chief" (v1); our own control widget (v2, section 7) | Same. |
| Pressing the Action Button again during a call | The same intent arrives while recording | Ends the call (toggle), so one button starts and stops. |

The call screen (UIKit, full screen; HIG pages "Playing audio", "Buttons", "Modality"): Chief
name, a monogram, elapsed time, the state line ("Recording", "Transcribing",
"Sent to Chief", "Saved; sends when Chief is reachable"), and one red End button. VoiceOver
reads the state line on every change.

## 2. What "call" means in v1

There is no realtime voice backend for Chiefs yet: iOS Home talks to `HomeSource`, which is the
mock owner until the Home messaging backend lands (plans/cmux-next/ios-rewrite.md step 5). So v1
is a one-way call that always ends as a voice note:

1. The intent opens the app (`openAppWhenRun`); the app routes a `ChiefVoiceRequest` to the
   Chief call coordinator, queued until sign-in and Home are ready.
2. Mic permission (`AVAudioApplication.requestRecordPermission`). Denied: the screen says so and
   offers Settings; nothing records.
3. Recording starts at once (`AVAudioRecorder`, AAC in M4A, 22.05 kHz mono, `AVAudioSession`
   `.playAndRecord` / `.spokenAudio`, `UIBackgroundModes` gains `audio` so a locked phone keeps
   recording). The file goes straight into the voice-note outbox directory, so a crash still
   leaves the audio on disk.
4. End (button, second Action Button press, or an audio-session interruption such as a phone
   call or Siri): stop, save the note into the outbox, transcribe on device
   (`SFSpeechRecognizer` with `requiresOnDeviceRecognition`; a locale without an on-device
   model gets no transcript rather than Apple's server recognizer; no paid API), then send audio plus transcript to the Chief conversation through
   `HomeStore.send(conversation:text:attachments:)`. The transcript is the message text; the M4A
   is an `audio/mp4` attachment (already accepted by `HomeAttachmentPolicy`).
5. Chief unreachable (no Chief conversation, store stopped, upload or send fails): the note stays
   in the outbox, the screen says "Saved", and the outbox drains on the next launch / next call.
   A transcription failure still sends the audio, with no text.

v2 (not built): stream transcript segments on pauses into the Chief thread during the call and
speak the Chief's replies with `AVSpeechSynthesizer`, which turns this into a two-way call
without a new backend; v3: a realtime audio channel once the transport has one.

## 3. Modules (layers per CLAUDE.md "Refactor architecture")

```
ios/cmux (app target)          ChiefVoiceIntents.swift: 2 AppIntents + AppShortcutsProvider,
                               each perform() is one line into CmuxiOSApplication.handle(_:)
ios/CmuxiOS/CmuxiOSApp         composition root: builds the coordinator with the iOS adapters
                               and the HomeStore delivery adapter; RootViewController presents
                               the call screen
ios/CmuxiOS/CmuxiOSVoice (new) iOS services + UI: AVAudioRecorder recorder, SFSpeech
                               transcriber, mic permission, interruption stream, call screen
Packages/Shared/CmuxChiefVoiceCore (new, iOS 17 / macOS 14, no UIKit/AVFoundation)
                               ChiefVoiceRequest, ChiefCallCoordinator (@MainActor @Observable
                               state machine), protocol seams, VoiceNoteOutbox (actor
                               repository over an injected directory)
```

Protocol seams in the core: `VoiceRecording`, `VoiceTranscribing`, `MicrophoneAuthorizing`,
`ChiefVoiceDelivering`. All are constructor-injected; no singletons; tests pass fakes and a temp
directory, so the whole flow is testable with `swift test` on macOS (fleet light step).

App Intents in the app target: metadata extraction only reads the main bundle reliably for an
app whose code is otherwise in static SPM libraries, and the intents are entry points like the
`@main` delegate, so they stay one-line forwards.

## 4. State machine

```
idle -> requestingPermission -> recording(mode, startedAt) -> finishing -> transcribing
     -> sending -> sent(noteID)
                \-> savedForLater(noteID)      (delivery failed; note kept in outbox)
requestingPermission -> permissionDenied
recording -> (interruption began) -> finishing  (same path as End)
any -> failed(message)                          (recorder could not start)
```

A request while `recording` ends the call. A request while finishing/transcribing/sending is
ignored. `drainOutbox()` retries every saved note (oldest first), skipping on the first failure.

## 5. Tests (Swift Testing, `Packages/Shared/CmuxChiefVoiceCore/Tests`)

Failing-first commit, then the fix:

- call start with permission records into the outbox directory; denied never records;
- End transcribes, delivers audio plus transcript, empties the outbox, reaches `sent`;
- delivery failure keeps the note on disk (`savedForLater`) and `drainOutbox` sends it later;
- transcription failure still delivers the audio with no text;
- an interruption ends and saves like End;
- a second request while recording ends the call (Action Button toggle);
- the outbox survives a new instance over the same directory (relaunch).

Device-only behavior (real mic, on-device speech, the Action Button itself, lock-screen
recording) cannot run in CI; section 6 lists what was and was not checked.

## 6. Verification status

- Core tests: fleet light step (package-test-lane suite).
- iOS compile: fleet `cmux-ci build ios`.
- On device: not done in v1 (needs the user's iPhone and the personal auth profile through
  `ios/scripts/reload.sh`). Simulator has no Action Button and no on-device speech model by
  default; the call screen and recorder run there.

## 7. Left for later

- Own Control Center / Lock Screen control (`ControlWidgetButton` in a WidgetKit extension):
  needs a new extension target and bundle id (`<app>.ChiefControl`). Debug builds sign
  automatically, but the TestFlight/App Store lane (`ios/scripts/upload-testflight.sh`) re-signs
  only NotificationService.appex and needs an App Store profile for the new id. That is a
  provisioning step for the user. Until then the iOS 18 Shortcuts control covers both places.
- Live level meter on the call screen; `SpeechAnalyzer` (iOS 26) for long notes.
- Two-way call (section 2, v2), Live Activity with an End button on the Lock Screen, choosing
  which Chief when there are several (v1 takes the pinned Chief, else the first).
- Real Home backend: today delivery reaches the mock owner, like every other Home send on iOS.

## 8. cmux-next-ios (2026-10-20): the Action Button now targets Aziz's app

The user's cmux-next iPhone app is `cmux-next-ios/` (merged from `feat-cnx-ios`), not `ios/CmuxiOS`.
The flow is ported there and reuses `CmuxChiefVoiceCore` unchanged:

- `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileVoice`: the recorder, microphone permission and on-device
  transcriber (iOS adapters as above), `ChiefVoiceController` (presents the call, ends it on an
  audio interruption) and `ChiefCallScreen` (SwiftUI, full screen).
- Delivery: `ChiefVoiceTextDelivery` (core) sends to `ChiefSources.shared.primary` (the Cloud
  Chief when ready, else the Mac Chief) through `ChiefSession.send`, which queues in its own
  outbox while the Chief is not connected. That conversation carries text and images only, so
  the Chief gets the transcript (or "Voice note (N s), no transcript"); the audio is not sent.
- `cmux-next-ios/App/ChiefVoiceIntents.swift`: "Call Chief" and "Record Voice Note for Chief" intents and
  the App Shortcuts the Action Button setting lists. `project.yml` adds the speech usage string
  and the `audio` background mode.
- Ships through the cmux INTERNAL TestFlight lane (`rc/cnx-ios-internal-*`, bundle
  `dev.cmux.app.internal`).
