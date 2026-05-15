# Voice Input Design

**Date:** 2026-05-15  
**Status:** Approved  
**Scope:** Native macOS voice control for cmux — tab switching, text dictation, command execution

---

## Overview

Voice is an additional input modality for cmux, equivalent to the keyboard. The user speaks; the app responds. No dedicated voice UI panel — just a toolbar status glyph and a toggle shortcut.

The implementation follows the architecture of `realtime-voice-component` (OpenAI Realtime API + tool-calling pattern) translated from React/WebRTC to Swift/WebSocket.

---

## Architecture

All new files live under `Sources/App/Voice/`.

### Components

**`VoiceInputController`**  
The central coordinator. Owns the session lifecycle: connect, disconnect, reconnect on transient errors. Subscribes to audio from `AVAudioEngine`, streams PCM frames to `VoiceRealtimeTransport`, receives tool call events, and dispatches them to `VoiceToolExecutor`. Exposes `VoiceInputState` for UI binding.

**`VoiceRealtimeTransport`**  
WebSocket client targeting `wss://api.openai.com/v1/realtime`. Handles the Realtime protocol: session config messages, audio delta streaming, tool call response parsing. Uses `URLSessionWebSocketTask`. This is the Swift equivalent of `webRtcRealtimeTransport.ts` — native macOS apps use WebSocket, not WebRTC.

**`VoiceToolExecutor`**  
Receives structured tool call events (name + arguments JSON) and routes them to existing app infrastructure. Each tool is a small pure function: validate args → call app API → return result. All execution happens on the main actor.

**`VoiceInputState`**  
`@Observable` class. Properties: `isActive: Bool`, `activity: VoiceActivity`, `transcript: String`. `VoiceActivity` is an enum: `.idle`, `.connecting`, `.listening`, `.processing`, `.executing`. Bound to the toolbar indicator.

**`VoiceToolDefinitions`**  
Defines the tool schemas (JSON Schema format matching Realtime API spec) and wires each name to its `VoiceToolExecutor` handler.

### Data Flow

```
User speaks
    ↓
AVAudioEngine — PCM audio frames
    ↓
VoiceRealtimeTransport — WebSocket → OpenAI Realtime API
    ↓
Server VAD detects turn end → AI interprets → tool call response
    ↓
VoiceInputController receives tool call event
    ↓
VoiceToolExecutor dispatches:
    switch_workspace  → look up Workspace by id → TabManager.selectWorkspace(_:)
    switch_tab        → look up Workspace by id → TabManager.selectTab(_:)
    type_text         → active TerminalPanel.sendText(_:)
    execute_command   → active TerminalPanel.sendInput(_:) (sends text + newline)
    get_app_state     → snapshot of TabManager state → JSON string
    ↓
Tool result returned to API via WebSocket
    ↓
Session continues
```

---

## Tool Set (MVP)

All tools operate on the currently active workspace/surface unless a target is specified.

### `get_app_state`
Returns a JSON snapshot of current app state. The AI calls this automatically to stay grounded before taking navigation actions.

**Parameters:** none  
**Returns:** `{ workspaces: [{ id, name, tabs: [{ id, name, isActive }] }], activeWorkspaceId, activeTabId }`

### `switch_workspace`
Switches the active workspace.

**Parameters:** `{ id: string }` — workspace ID from `get_app_state`  
**Returns:** `{ ok: true }` or `{ ok: false, error: string }`

### `switch_tab`
Switches the active tab within the current workspace.

**Parameters:** `{ id: string }` — tab ID from `get_app_state`  
**Returns:** `{ ok: true }` or `{ ok: false, error: string }`

### `type_text`
Injects text into the active terminal surface without pressing Enter.

**Parameters:** `{ text: string }`  
**Returns:** `{ ok: true }`

### `execute_command`
Injects text into the active terminal surface and presses Enter.

**Parameters:** `{ command: string }`  
**Returns:** `{ ok: true }`

---

## Session Configuration

**Model:** `gpt-4o-realtime-preview` (current Realtime API model)  
**Output mode:** `tool-only` — AI calls tools silently, no audio playback  
**Turn detection:** Server VAD with `interrupt_response: false`

```json
{
  "type": "server_vad",
  "threshold": 0.5,
  "prefix_padding_ms": 300,
  "silence_duration_ms": 200,
  "create_response": true,
  "interrupt_response": false
}
```

**System instructions:**
> "You are a voice controller for cmux, a macOS terminal app. Use only the registered tools to act on the app. Call `get_app_state` first when you need to know what workspaces or tabs are open. When the user says 'type X', use `type_text`. When they say 'run X' or 'execute X', use `execute_command`. Keep any spoken reply to one short sentence. Do not invent capabilities."

---

## Settings & Activation

### Keyboard Shortcut
A new `voice.toggle` entry in `KeyboardShortcutSettings`. Default binding: unbound (user assigns). Configurable via Settings UI and `~/.config/cmux/cmux.json`.

### Settings Panel
New "Voice" section in the existing Settings window (`SettingsNavigation`):
- **API Key** — masked text field, stored in macOS Keychain via `SecItem` APIs. Never `UserDefaults`.
- **Activation mode** — VAD (always-on while session is active) or push-to-talk (hold shortcut to capture)
- **Model** — dropdown, defaults to `gpt-4o-realtime-preview`

### Toolbar Indicator
A small mic glyph added to the window toolbar. States:
- Idle (mic off) — default, no session
- Connecting — animated spinner
- Listening — filled mic, green tint
- Processing — pulsing
- Error — red tint

Uses SF Symbols: `mic`, `mic.fill`, `mic.slash`.

---

## Entitlements

| Entitlement | Status |
|---|---|
| `com.apple.security.device.audio-input` | Already present |
| Outbound network (WebSocket) | Covered by existing network entitlements |

---

## Files Changed

### New
```
Sources/App/Voice/VoiceInputController.swift
Sources/App/Voice/VoiceRealtimeTransport.swift
Sources/App/Voice/VoiceToolExecutor.swift
Sources/App/Voice/VoiceInputState.swift
Sources/App/Voice/VoiceToolDefinitions.swift
Sources/App/Voice/VoiceSettingsView.swift
```

### Modified
```
Sources/App/cmuxApp.swift              — instantiate VoiceInputController, add toolbar button
Sources/App/KeyboardShortcutSettings.swift  — add voice.toggle shortcut
Sources/App/SettingsNavigation.swift   — add Voice settings tab
Resources/Localizable.xcstrings        — new UI strings
```

---

## Out of Scope (v1)

- Audio playback / spoken AI responses
- Push-to-talk mode (VAD only for v1)
- `open_new_tab`, `close_tab`, `split_pane` tools
- Wake-word activation
- On-device transcription fallback (no internet)
