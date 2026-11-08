# Composer dictation: cmux's own, or the app you already use

The composer's mic (`webviews/src/agent-session/acpmux/DictationButton.tsx`, `DictationMic.tsx`,
`dictation.ts`) runs cmux's own dictation today: Swift owns the microphone and the speech engine
(`CmuxNextAgentPane/AgentPaneDictation.swift`) and the page splices its words at the cursor. This
page covers the other case: the person already dictates with another app and pastes or types the
result into the composer.

## The ask (Leo 2026-11-07)

> "could you do a thing where it's like, you know, you can optionally have it be like, oh, you use
> Claude's thing, or ChatGPT's thing, or like it detects Claude's thing or ChatGPT's thing if you
> have that app open. ... if you want to use Whisper Flow here, you know, you can, and it'll just
> display that, and it'll be able to listen to that ... Maybe it just, there's, like, some sort of
> indicator that it's like, oh yeah, hey, we recognize that you're using your microphone right now,
> or something. Or, like, maybe you can map the button to that thing, perhaps? ... at the very
> least, like you see the in macOS, you have the orange indicator and the top right ... maybe we
> can have that, the sort of waveform thing. But of course it's like, okay, the benefit of having
> nothing there is just that, okay, you can still use the composer normally while you are
> dictating your other thing. ... I guess it depends on if your dictating thing, like, goes in real
> time and just has that transcription as you go, or if it just does it all in one burst."

Earlier the same day he said he uses the ChatGPT app for speech-to-text and pastes into the
composer (`cmux-design-references` `cmux/live/composer-dictated-paste-chip`).

## The apps

Researched 2026-11-07 from each vendor's help pages and app catalogs. "Unverified" means no
first-party source said so; check on a Mac before relying on it
(`mdls -name kMDItemCFBundleIdentifier /Applications/X.app` for a bundle id).

| Source | Bundle id | How dictation starts | Where the words go | How they arrive |
|---|---|---|---|---|
| macOS Dictation | none (system service) | Fn/Globe twice, or Control twice without a Globe key; configurable in System Settings > Keyboard > Dictation. In cmux, Edit > Start Dictation reaches it (`CmuxApplication+Dictation.swift`) | The focused text field, any app | Live, through the text input system, with interim text |
| Wispr Flow | `com.electron.wispr-flow` (older `com.wispr.flowapp`) | Hold Fn (push to talk); Fn+Space hands-free, pressed again to stop. Without Fn: Ctrl+Opt, Ctrl+Opt+Space. All rebindable; a custom one needs a modifier ([docs](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)) | The frontmost text field, any app (needs Accessibility and Input Monitoring) | One burst at the end: clipboard plus paste, then the clipboard is restored |
| Superwhisper | `com.superduper.superwhisper` (Setapp: `-setapp`) | A global hotkey, default unverified | The frontmost text field | One burst (unverified) |
| ChatGPT | `com.openai.codex` (the current ChatGPT.app); `com.openai.chat` (ChatGPT Classic) | Option+Space opens the companion window (rebindable). No system-wide dictation hotkey is documented; a dictation shortcut inside the app is disputed (unverified) | ChatGPT's own composer only | The person copies the text and pastes it: one burst |
| Claude | `com.anthropic.claudefordesktop` | Quick entry: double Option or Option+Space by default; its voice shortcut (Caps Lock, opt-in) dictates into quick entry ([help](https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac)) | Claude's own quick entry only | Live inside Claude; one burst when pasted here |
| Gemini | `com.google.GeminiMacOS` | Option+Space opens the mini chat, Option+Shift+Space the full one; both rebindable ([Google](https://blog.google/innovation-and-ai/products/gemini-app/gemini-app-now-on-mac-os/)) | Gemini's own window only | One burst when pasted here |

What follows from the table:

- **Only macOS Dictation, Wispr Flow and Superwhisper type into cmux by themselves.** ChatGPT,
  Claude and Gemini dictate into their own window. Mapping the mic to them opens that window
  (their shortcut); the words still come back as a paste, which is what Leo does today.
- **Two shapes of arrival.** Live (macOS Dictation) writes into the composer word by word, like
  cmux's own. Burst (everything else) lands once, as a paste. The composer treats a burst as a
  paste: the paste chip still applies past `PASTE_CHIP_WORDS` (750 words, `pastedText.ts`), so a
  normal dictation lands as text.
- **Synthesizing the shortcut.** A modifier+key chord (Option+Space, Ctrl+Opt+Space, a custom
  chord) posted with `CGEvent` at the HID tap reaches the app's global hotkey. Fn alone, Fn twice,
  Caps Lock and modifier-only holds are not reliable to synthesize: Wispr Flow's Fn default needs
  the person to bind a chord in Flow, and the source's shortcut in cmux must match it. Posting
  events needs the Accessibility (post event) grant: `CGPreflightPostEventAccess()`, and
  `CGRequestPostEventAccess()` the first time.

## Detecting the app and the microphone

Detecting never opens the microphone; cmux never captures audio to learn whether, or which, app
dictates. Only the level meter below opens it, and only while that is already known.

- **Installed and running:** `NSWorkspace.urlForApplication(withBundleIdentifier:)` for each
  known bundle id above, and `NSWorkspace.runningApplications`. The list is fixed in the host, so
  the page cannot ask whether an arbitrary app is installed (the same rule as
  `AttachmentSourceIcons`).
- **Microphone in use somewhere:** `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default
  input device, with `AudioObjectAddPropertyListenerBlock`; also listen to
  `kAudioHardwarePropertyDefaultInputDevice` on the system object to follow a device change. A
  read of a property, no TCC prompt.
- **Which app holds it (macOS 14.2+):** `kAudioHardwarePropertyProcessObjectList`, then per process
  `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyBundleID` and
  `kAudioProcessPropertyPID`. Caveats: the list's listener can fire before IO starts (re-read once
  shortly after); helpers hold the mic under their own ids (match by prefix, or map the pid with
  `NSRunningApplication`); cmux's own process shows up and is filtered out. Before 14.2 the
  indicator says only that the mic is in use.
- **No level without capture.** CoreAudio says whether input runs, not how loud it is. A level
  needs an input tap of cmux's own (below); without one the indicator's motion is drawn, not
  measured, and must never claim to show the person's voice.

### The level meter

Leo, 2026-11-08, on the drawn pulse: "It's not accurate ... Could you do it? But you'd have to,
like, also detect the mic more completely, right? Like from the system level." So while the
indicator shows, cmux measures the level itself:

- **When.** Another app's input runs, a composer has the keyboard in a focused window, macOS is
  14.2 or later, cmux already has microphone permission
  (`AVCaptureDevice.authorizationStatus(for: .audio) == .authorized`), and cmux's own dictation
  does not hold the microphone. Then the host opens a meter-only `AVAudioEngine` input tap on the
  default input.
- **Levels only.** The tap folds each buffer into one RMS level (`DictationAudioLevelMeter`, no
  recording) and sends the page that number (`micLevel {level}`, about 12 a second); no sample is
  kept, written or sent. `micActivity` says `metered: true` while it runs.
- **Stops at once** when the other app's input stops (its process's
  `kAudioProcessPropertyIsRunningInput`: the device's `IsRunningSomewhere` stays true while cmux's
  own tap runs, so it cannot tell), when the last composer loses the keyboard or the window its
  focus, and when cmux's own dictation claims the microphone.
- **Never prompts.** With no permission yet, or denied, or before macOS 14.2 (where a running
  device names no process, so cmux could not see the other app let go while its own tap runs),
  the indicator keeps the drawn pulse. cmux never asks for the microphone to draw this.
- **Cost.** While it runs, macOS lists cmux among the apps using the microphone (the menu bar's
  privacy indicator), which is true: cmux reads the level.

## What cmux builds

### 1. Dictation source (`agentPane.dictationSource`)

A choice setting, default `cmux` (today's behavior; the default never changes):

- `cmux`: cmux's own dictation, as today.
- `macos`: the mic starts macOS Dictation in the composer (the path `agent.systemDictation`
  already takes, `AgentPaneView+DictationKey.swift`).
- `chatgpt`, `claude`, `gemini`, `wisprFlow`, `superwhisper`: the mic posts that app's shortcut
  (the table's default, or `agentPane.dictationShortcut` when the person set one to match the
  app), and wears the app's icon. A source whose app is not installed on this Mac falls back to
  cmux's own and says so in the mic's tooltip.

The picker lives where the mic's other controls are: the mic's right-click lists cmux and each
installed source as checked items above Hide Dictation Button (as the usage ring's right-click
picks Context or Plan Usage), and Settings > Agent Chat has the same choice. The mic's tooltip
names the source ("Dictate with ChatGPT").

### 2. Outside dictation indicator

While another app holds the microphone and a composer has focus, the composer shows a small live
mark. Rules:

- It never takes focus, never blocks typing, never moves or resizes the composer: it sits in the
  slot the dictation strip uses beside the mic, absolutely placed, `pointer-events: none`.
- It names the app when the host knows it (its icon, "ChatGPT is using the microphone"). While
  the level meter runs, its bars follow the measured level as cmux's own dictation wave does;
  otherwise its motion is a slow drawn pulse, never presented as a level.
- It goes away when the microphone is released. When the composer loses focus the host drops its
  listener: no observer runs while no composer is focused, and none runs while the source is
  `cmux` and the indicator is off.
- cmux's own dictation keeps its own waveform; the indicator never shows for cmux's own session.

Variants live in `webviews/src/agent-session/acpmux/OutsideDictation.gallery.tsx`.

### 3. Burst arrival

A burst paste that lands while (or shortly after) an outside app held the microphone is a normal
paste. The composer's growth to fit it is the composer's own growth (chat-rendering owns it); this
work reuses it and adds no animation of its own.

## Out of scope

- Reading another app's transcript (Accessibility scraping, the clipboard while it is not
  pasted). The words come to cmux only as the person's paste or the app's own typing.
- Capturing audio for an outside session beyond the level meter above: no samples kept or sent,
  no meter without permission already granted, no permission prompt for it.
- Bundling or launching any third-party app.
