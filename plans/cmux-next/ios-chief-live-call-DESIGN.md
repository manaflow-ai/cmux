# iOS: Call Chief, a live voice call

Status: v1 on feat-cmux-next, 2026-10-23. Supersedes the "v3: a realtime audio channel"
item of [ios-action-button-DESIGN.md](ios-action-button-DESIGN.md) for the Call Chief
entry; Record Voice Note for Chief keeps the v1 voice note.

## What the user gets

Call Chief starts a live, two-way voice call with Chief from the iPhone app.

| Entry point | Result |
| --- | --- |
| Chief info, Call quick action (the conversation header's avatar or name opens it) | Call. The header's trailing slot stays Invite to cmux. |
| Home, Chief row or tile, long-press menu | "Call Chief". |
| Action Button, Siri, Shortcuts ("Call Chief") | Call; pressed again with the call on screen, hangs up; a minimized call comes back. |
| No OpenAI API key for this account | Every entry opens Settings → Chief Calls instead. |

On the call:

- Chief's voice answers at once, and the user can talk over it (barge-in). Semantic VAD
  lets the user finish a thought. A tap on Chief's avatar also stops it.
- Live captions for both sides; what Chief did shows as green chips ("Sent to Chief: …",
  "Checked workspaces", "New message from Chief").
- Controls: Mute, Speaker (on by default, like a voice assistant; off is the earpiece),
  Keyboard (type a turn instead of speaking), End. The chevron minimizes the call to a green
  pill over the app; it keeps running, in the background and with the screen locked
  (`UIBackgroundModes: audio`).
- A phone call or Siri puts the call on hold (microphone off) until it gives the audio back.
- Failures say what happened and what to do: a refused key or a model the key can't use
  (Open Settings), no credit (Try Again after topping up), no network or a dropped call
  (Try Again), microphone off (Open Settings, the system app).

## How Chief works on a call

The voice model is Chief's voice and front desk; Chief's agent on the Mac (or in cmux
Cloud) still does the work. The model gets Chief's persona and a briefing (Chief's status,
the last 8 Chief chat messages, up to 15 workspaces, up to 10 items waiting on the user)
and five tools:

| Tool | What it does |
| --- | --- |
| `send_to_chief(message)` | Sends a message to the default Chief, exactly the composer's send (into the outbox when Chief is offline). |
| `read_chief_messages(count)` | The newest Chief chat messages. |
| `list_workspaces()` | Workspaces with Mac, folder, branch and each agent's state. |
| `list_needs_attention()` | Open questions and permission requests, recent finishes and failures. |
| `end_call()` | Hangs up after the goodbye plays. |

When Chief's agent replies in the chat during the call, the reply goes into the call as a
system message ("Chief replied: …") and the voice summarizes it as soon as the user isn't
talking and no response is running. The call can't approve permissions or answer agents'
questions: that stays a signed, on-screen action (trust policy, #13742).

## API, transport and model

- OpenAI Realtime API (GA), model `gpt-realtime-2.1` by default, `gpt-realtime-2.1-mini`
  selectable (Settings → Chief Calls → Model); voices Marin (default), Cedar and the other
  eight.
- Transport: WebRTC. The phone creates an offer (microphone track, `oai-events` data channel)
  and posts it with the session config to `POST /v1/realtime/calls` (multipart `sdp` +
  `session`), with the user's key; OpenAI's answer SDP completes the connection. Audio is
  Opus over SRTP with libwebrtc's voice processing (echo cancellation, so the speaker works);
  events are JSON on the data channel. libwebrtc is the stasel M154 build CmuxVNCWebRTC pins.
- Input transcription for the captions: `gpt-live-transcribe`; if a session refuses it, the
  call reconnects once with `gpt-4o-mini-transcribe`.
- `OpenAI-Safety-Identifier`: a SHA-256 of the cmux account id, never the id.
- Why not GPT-Live (`gpt-live-1`, Sep 2026): its sessions take no function tools directly
  (tools run in a delegated Responses backend or on the client after a bare
  `session.delegation.created`), there is no typed user turn, and Responses delegation had an
  open 403 bug report. Chief needs app-side tools and typed turns; Realtime has both. Revisit
  when GPT-Live gains direct function tools.

## Key handling

- The key is the user's own; calls bill their OpenAI account (the page says so).
- Keychain, generic password, service `dev.cmux.mobile.openai-api-key`, account = the cmux
  user id, `AfterFirstUnlockThisDeviceOnly` (no sync, no restore to another device). A second
  cmux account on the same phone never uses the first one's key.
- Adding a key checks it with `GET /v1/models/<model>` first; a refused (401) or malformed key
  is never stored. Offline, the key is stored unchecked and the call reports problems.
- The key leaves the phone only in the Authorization header of the two requests above. It is
  read from the Keychain per call and shown only masked (`sk-…1234`).

## Code

| Where | What |
| --- | --- |
| `CmuxMobileKit/Sources/CmuxMobileRealtime` (Foundation + Security, tested on macOS) | Realtime events, session config and instructions, tools, `VoiceCallSession` (the call's state machine), `RealtimeCallsAPI`, the Keychain key and `OpenAIKeyModel`, preferences. |
| `CmuxMobileVoice` | `WebRTCVoiceCallLink`, `ChiefCallToolbox` (Chief, workspaces, Feed), `ChiefLiveCall` (one call at a time, mic permission, Chief reply watch), `LiveCallScreen` and the pill, strings (21 languages). DEBUG: `ScriptedVoiceCallLink`. |
| `CmuxMobileChief` | `ChiefCallLauncher` (every entry point), Chief info's Call, Home's menu item. |
| `CmuxMobileSettings` | Settings → Chief Calls (`ChiefCallsPage`). |
| `CmuxMobileShell` | Hosts the call (cover, pill) and routes a missing key to Settings. |
| App | `CallChiefIntent` → the launcher. |

Tests: `CmuxMobileRealtimeTests` drive `VoiceCallSession` through a fake link with the API's
own event JSON (captions, barge-in, the tool loop, end_call after the goodbye, Chief replies
held while the user talks, mute and hold, a dropped call, the transcription fallback) and the
HTTP mapping. Live verification: `cmux-next-ios/verify/chief_call_live.py`.

## DEBUG hooks (not in Release, Production or TestFlight)

- `CMUX_MOBILE_CALL_DEMO=1|hold`: a scripted call through the real session, tools and screen
  (the Realtime API's event shapes), for simulator recordings without a key or microphone.
- `CMUX_MOBILE_CALL_SEED_KEY=<key>`: stores that key unchecked, for simulator runs of the real
  path.

## Not in v1

- CallKit (system call UI, lock-screen controls). Background audio keeps the call alive;
  CallKit would add the green status pill system-wide and Lock Screen controls.
- A call summary posted to the Chief chat at hang-up.
- Server-minted ephemeral keys (a cmux-paid voice backend instead of the user's key).
