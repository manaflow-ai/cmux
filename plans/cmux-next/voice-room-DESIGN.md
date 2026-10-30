# Voice Room: an always-on room where people and Chief talk

Status: MVP. The room server and page (experiments/voice-room) are landed; the cmux Labs part
(`labs.voiceRoom`, CmuxNextDictation/VoiceRoom, the two actions) is part 2. Owner: the Voice Room agent (a764),
2026-10-27. Ask (Lawrence, 14549): record the screen all the time and just talk, like Wispr Flow, but
shaped like FaceTime/Zoom: an input method into a multiplayer interface to AI; a website first, or
pulled into cmux as a non-official feature enabled only in Settings; several people in one room
over Tailscale, also several in the same physical room; a cheap model analyzes everything said and
does the OptChat/unii thing, and starts tasks.

## 1. Shape

```
 cmux app (each person, Labs on)                 room server (one Mac, Bun, loopback)
 ┌──────────────────────────────┐   text only   ┌───────────────────────────────────────┐
 │ VoiceRoomSession             │ ───────────▶ │ /api/transcript   speaker = Tailscale id │
 │  mic → DictationSession      │   POST lines  │ CrossMicDedupe (same physical room)      │
 │        (on device)           │               │ RoomMemory: OptChat log + binary fold    │
 │  screen → SCK still → Vision │ ◀─────────── │ cheap model: fold summaries, task digest  │
 │        (on device, on change)│  ws observer  │ TaskBoard → `cmux chief -p` (Chief task)  │
 └──────────────────────────────┘   (pause)     │ /ws: roster + WebRTC signaling + events  │
 room page in a cmux browser tab  ◀──────────── │ page: tiles, transcript, tasks, memory   │
 and in any guest's browser           WebRTC    └───────────────────────────────────────┘
       ▲───────── media P2P over the tailnet (100.x host candidates) ─────────▲
```

- **The room is a web page and a small server** (`experiments/voice-room`), so it stands alone as a
  website: a guest needs only a browser on the tailnet. cmux adds what a page cannot do well:
  always-on on-device transcription and screen reading, outside any tab.
- **cmux part is unofficial Labs**: `labs.voiceRoom` (Settings > Advanced > Labs) is off by default;
  while off, `voiceRoom.open` / `voiceRoom.stop` are unavailable on every surface (palette, CLI
  `cmux action voice-room-open`, MCP). Only the person turns it on: the key is not in the
  agent-writable settings list. Turning it off while a room is open stops capture at once
  (Observation on the settings snapshot, no polling).
- **Room address**: `labs.voiceRoomURL`; empty is the local server `http://127.0.0.1:4788/`.

## 2. Capture (CmuxNextVoiceRoom, macOS)

| Part | How | Cost |
| --- | --- | --- |
| Mic | `DictationSession` (SpeechAnalyzer on 26+, SFSpeechRecognizer before; on device), restarted when it ends by itself; gives up after 3 empty ends or a denial | on-device ANE; no upload |
| Lines | `VoiceRoomLineSplitter`: a sentence is sent once the next one starts; long unpunctuated runs cut at a word; the rest at session end; each line carries its peak mic level | O(text) |
| Screen | every 5 s (injected clock, cancelled with the session) a ScreenCaptureKit still of the main display at 1440 px, cmux's own windows excluded (the room page never reads itself); a 32×20 grey signature decides "changed" (> 2 % mean difference) | one still per 5 s; OCR only on change |
| Screen text | Vision `.fast` text recognition, top to bottom, ≤ 800 characters, sent as a `screen` line | ~30–60 ms off main per change |
| Keyframes | JPEG (q 0.6) per change in `~/Library/Application Support/cmux/voice-room/frames`, newest 2,000 kept | local only, never sent |
| Pause | the room's pause (any participant, button or Ctrl-Option-P in the page) reaches the app over the observer socket; capture stops until resume; a line the paused room refused also pauses | — |

The mic is shared through `DictationMicrophoneClaims`: a composer's dictation takes it and the
room stops (state `micTaken`) rather than fighting for the audio engine.

## 3. Transport: Tailscale

There is no Tailscale video product to build on. Tailscale itself has no WebRTC; adding a WebRTC
path for its JS/wasm client is an open proposal ([tailscale#21027](https://github.com/tailscale/tailscale/issues/21027),
[tailcat#4](https://github.com/tailscale/tailcat/issues/4)). So:

- **Media**: a WebRTC mesh, one `RTCPeerConnection` per pair, perfect negotiation, **no ICE servers**:
  every peer's tailnet address is a reachable host candidate, so no STUN/TURN and no media on the
  server. A mesh is right up to ~6 people (each uploads n−1 streams at 640×400/15 fps); past that,
  an SFU (LiveKit or mediasoup on the room Mac) is the next step.
- **Secure context**: browsers give mic and camera only on https or localhost. `--share` runs
  `tailscale serve --bg --https=4789 http://127.0.0.1:4788`: the room gets this Mac's tailnet HTTPS
  name with a real certificate, tailnet only, and every request carries the visitor's
  `Tailscale-User-Login`/`-Name`, which the server uses as the speaker. The server itself binds
  loopback only.
- Known WebRTC-over-Tailscale stall (Electron clients hiding private interfaces) does not apply to a
  page granted mic access: Chrome then exposes real host addresses instead of mDNS names.

## 4. Same physical room

Two people side by side: each mic hears both. Browser echo cancellation removes the call's own
playback, not a voice in the room. The server's `CrossMicDedupe` drops a line from another speaker
within 4 s whose word set overlaps ≥ 60 % (Jaccard), unless it is louder: then the louder mic is the
real speaker and the entry is credited to them (`reattribute`). Diarization is thus by device, which
is exact for remote people and right by loudness for co-located ones. Two people sharing one Mac's
mic remain one speaker (a later step: on-device speaker embeddings).

## 5. Memory: OptChat for a room

`RoomMemory` follows plans/cmux-next/optchat.md: every entry (speech, screen, join) is appended
verbatim to `log.jsonl`; level 0 is one entry; the newest 12 stay raw; older nodes merge with their
equal-level neighbour, oldest pair first, never split; a pair whose text fits 512 B merges free, a
larger one is summarized by the cheap model (≤ 400 B). The view is the covering node list rendered as
`id+n|text` lines (newlines as spaces), the same shape Chief reads. Retention: 24 h by default
(`VOICE_ROOM_RETENTION_HOURS`), pruned at start and hourly.

## 6. The cheap model and tasks

- Model: Claude Haiku 4.5 ($1 / $5 per M tokens) through any Anthropic Messages endpoint
  (`VOICE_ROOM_MODEL_URL`, default the session's `ANTHROPIC_BASE_URL`, i.e. the team gateway; the cmux
  `/v1/inference` route works the same once the room runs under a cmux account). Picked over
  DeepSeek/Qwen flash for JSON reliability at this size; swapping is one env var.
- Digest: 5 s after the last line (at most every 30 s while people talk), the settled view plus only
  the new lines go to one call that returns `{"tasks":[...]}`.
- **What starts work**: a task goes to Chief by itself only if the model marked it addressed **and** its
  verbatim quote names the AI (`Chief`, `cmux`, `hey AI/Claude/computer`). Everything else is a
  proposal with Send / Dismiss in the page. Repeats (≥ 60 % word overlap) are not added twice.
- Chief: `cmux chief --no-wait-agents -p "<2-5 word title>\n…ask…\nTheir words: …\nRoom: …"`, the same
  path as the person typing to Chief.
- **Measured** (fixtures/standup.txt, 4 speakers, 472 words ≈ 3.1 min of talk, digest every ~75 words,
  real Haiku via the team gateway, 2026-10-27): 10 calls, 4,335 input + 1,316 output tokens,
  **$0.0109 → ≈ $0.21 per hour of nonstop talk**; screen lines add roughly the same per hour of
  constantly changing screens, so plan on **$0.20–0.45 per active hour**, ~$0 when silent. All 3 asks
  spoken to Chief were sent; 6 other asks became proposals; no false auto-send.

## 7. Privacy and safety

- Everything is opt-in: the Labs switch, then Open Voice Room per session; the room page always shows
  a red Recording dot (grey when paused); macOS shows its own mic and screen-recording indicators.
- On device: speech recognition, screen OCR, keyframes. Only text leaves the Mac, only to the room
  server you named, and from there only to the cheap model you configured.
- Pause is for everyone, from any participant, and the server refuses lines while paused.
- The server answers loopback only; every request must have the server's own Host (DNS rebinding) and,
  when a browser sends one, its own Origin; POSTs must be `application/json` (forces a CORS preflight).
  Without this any web page the person had open could POST "Chief, …" lines into the room.
- Guests come only through `tailscale serve` (tailnet ACLs apply), never the open internet.

## 8. Not in the MVP (next)

1. A native recording indicator and a default pause shortcut in cmux (today: system indicators + the
   page; the actions are bindable in Settings > Keyboard).
2. The app starting the room server itself (today: `bun experiments/voice-room/src/server.ts`).
3. Room as a cmux Cloud service (a Durable Object room, multiple rooms, invites outside the tailnet).
4. SFU past ~6 people; on-device speaker separation for a shared mic.
5. Vision model on keyframes for screens with little text (cost ≈ 10× text).
6. Feeding the room's memory view into Chief's own OptChat memory instead of one message per task.
