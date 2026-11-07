# Inline AI Command Autocomplete Design

## Product Decision

Build this as **Warp-style inline autocomplete for cmux, but BYOK**. The user sees gray ghost text directly after the cursor in the terminal grid, not a popup and not a shell-native suggestion line. Suggestions appear after a 300 ms debounce, stream as tokens arrive, dismiss on Esc or divergent typing, and accept with Right arrow or Tab. cmux never sends terminal history or command context through a cmux-hosted inference service: Anthropic and OpenAI require a user-owned API key in macOS Keychain, Ollama stays local, and `~/.config/cmux/ai.toml` stores only non-secret provider/model preferences.

## Chosen Architecture

Use **C. Hybrid**: a small shell integration reports the live line-editor state to cmux, and cmux owns the Warp-like ghost-text rendering, LLM orchestration, caching, provider configuration, and accept/dismiss state. The shell remains the authority for mutating the command line. This keeps the hard boundary clear: shells know the buffer and cursor; cmux knows the terminal grid, prompt marks, renderer, socket API, preferences, and Keychain-backed provider credentials.

This fits the cmux primitive-first direction better than a product-shaped shell plugin. The primitive is a versioned "line state plus suggestion state" channel that other shells or editors can emit later. cmux can render and broker suggestions without requiring a Fig-style spec database or a terminal-side reimplementation of zsh/bash/fish editing semantics.

Rejected: **A. Pure shell plugin** would ship fastest but would make the UI shell-specific, duplicate provider/config/key storage outside cmux, and miss the terminal-side primitive. **B. Terminal-side ghost layer** would look closest to Warp, but it would require cmux/libghostty to infer shell buffer state from raw keystrokes, prompt escape sequences, custom keybindings, IME commits, bracketed paste, and completion widgets. The codebase already treats `GhosttyNSView.keyDown`, `forceRefresh`, and `NSWindow.performKeyEquivalent` as typing-latency-sensitive paths; putting a line editor model there is the wrong first risk.

## Component Diagram

```text
User
  |
  v
Shell line editor: zsh ZLE, bash Readline, fish reader
  owns: editable buffer, cursor, accept/dismiss widgets, recent command records
  emits: cmux inline-ai OSC buffer.changed messages
  calls: cmux socket accept/dismiss commands
  |
  v
PTY running inside libghostty
  owns: shell process I/O stream
  emits: OSC 7 cwd, OSC 133 prompt/command marks, cmux inline-ai OSC
  |
  v
libghostty terminal parser/render core
  owns: grid, prompt semantic markers, actions for supported OSC
  already parses: OSC 7, OSC 9/777 notifications, OSC 133 semantic prompt
  needed: a narrow cmux-private OSC action if generic OSC passthrough is unavailable
  |
  v
cmux Swift/AppKit app
  owns: TerminalSurface/GhosttyNSView overlay, socket API, config loading,
        Keychain credentials, provider registry, cache, context builder
  |
  +--> InlineAIEngine actor
       owns: debounce, cancellation, request ids, cache lookup, provider calls
       |
       +--> HelpCaptureWorker
       |    owns: safe `<cmd> --help` capture with timeout and disk cache
       |
       +--> Provider adapters
            BYOK Anthropic, BYOK OpenAI, local Ollama; stream deltas back
```

The app already has the right anchor points: `TerminalController` exposes a Unix socket API with v1/v2 commands including `surface.send_text` and `surface.send_key`; `CmuxSocketEventMapper` redacts socket input events; `GhosttyApp.handleAction` consumes Ghostty actions such as desktop notifications from OSC 9/777; Ghostty's fork has `semantic_prompt.zig` for OSC 133 `A/B/C/D/P` prompt marks, and the zsh integration emits those marks plus OSC 7 cwd reports. I did not find a separate OSC 99 notification path in the inspected parser; the nearby supported path is OSC `9;9` for current-directory reporting.

## UX Decisions

The rendered behavior should match Warp's autocomplete feel: a single muted suffix appears inline at the cursor baseline, clipped to the current row for v1, with no explanatory text, popover, spinner, or command palette handoff. The overlay belongs to `GhosttySurfaceScrollView`/terminal portal territory, not the surrounding SwiftUI panel chrome, so it tracks the terminal cell grid during scrolling, resizing, font changes, and split movement.

Right arrow and Tab both accept by default when a suggestion is visible. To preserve shell completion, the shell widget only treats Tab as accept while the active `line_generation` has a visible suggestion; otherwise Tab falls through to the shell's normal completion. Esc always dismisses. Any typed byte that makes the line stop matching the suggestion request hides the overlay and cancels the provider request. cmux must not write completion bytes into the PTY; accept returns the suffix to the shell widget, and the shell mutates its own buffer.

## BYOK Configuration

`ai.inline.enabled` remains off by default. Enabling it without a configured provider opens Preferences to an Inline AI pane. The pane offers Anthropic, OpenAI-compatible, and Ollama providers. Anthropic and OpenAI-compatible providers require "bring your own key"; the key is saved only in Keychain under a cmux service name scoped by provider. Ollama stores no key and uses a user-configured local base URL.

`~/.config/cmux/ai.toml` is the portable, non-secret configuration surface:

```toml
[inline]
enabled = true
accept_keys = ["right", "tab"]
debounce_ms = 300

[provider]
name = "openai"
model = "fast-command-completion"
base_url = "https://api.openai.com/v1"
```

No API key, prompt, terminal history, or completion cache is written to this file. The Settings UI writes the same file for non-secret fields and writes/deletes Keychain items for secrets. There is no cmux cloud relay, hosted proxy, telemetry, or shared model account in v1.

## Wire Protocol

All new messages carry `version: 1`, `request_id`, `workspace_id`, and `surface_id` when known.

### Shell to cmux: `buffer.changed`

Transport: cmux-private OSC, preferred shape:

```text
ESC ] 9001;cmux-inline-ai;<base64url-json> BEL
```

Payload:

```json
{
  "version": 1,
  "type": "buffer.changed",
  "request_id": "uuid",
  "workspace_id": "uuid",
  "surface_id": "uuid",
  "shell": "zsh",
  "cwd": "/Users/me/project",
  "line": "claude --",
  "cursor_utf8": 9,
  "line_generation": 42,
  "head_command": "claude",
  "accept_keys": ["right", "tab"]
}
```

Response: none over the PTY. Invalid JSON, unknown version, stale surface, or oversized payload is ignored and recorded only in debug logs. Maximum payload is 16 KiB.

### cmux internal: `suggest.request`

Transport: Swift actor call to `InlineAIEngine`; provider adapters use HTTPS or local Ollama HTTP.

```json
{
  "version": 1,
  "type": "suggest.request",
  "request_id": "uuid",
  "line": "claude --",
  "cursor_utf8": 9,
  "cwd": "/Users/me/project",
  "history": [{"command": "claude --help", "output": "..."}],
  "help": {"command": "claude", "output": "..."},
  "provider": "configured-byok-provider",
  "model": "configured-fast-command-model",
  "deadline_ms": 600,
  "max_completion_tokens": 64
}
```

Responses:

```json
{"version":1,"type":"suggest.delta","request_id":"uuid","text":"dangerously"}
{"version":1,"type":"suggest.complete","request_id":"uuid","suffix":"dangerously-skip-permissions"}
{"version":1,"type":"suggest.error","request_id":"uuid","code":"rate_limited","retry_after_ms":30000}
```

Error codes: `timeout`, `offline`, `bad_key`, `rate_limited`, `provider_error`, `blocked_by_scrubber`, `unsupported_context`, `cancelled`, `invalid_response`.

### Shell to cmux socket: `inline_ai.accept`

The shell widget owns mutation. On Right or Tab, it asks cmux for the active suggestion:

```json
{
  "jsonrpc": "2.0",
  "id": "uuid",
  "method": "inline_ai.accept",
  "params": {
    "version": 1,
    "surface_id": "uuid",
    "line_generation": 42,
    "line": "claude --",
    "cursor_utf8": 9
  }
}
```

Success:

```json
{
  "ok": true,
  "result": {
    "version": 1,
    "accepted": true,
    "suffix": "dangerously-skip-permissions",
    "replacement_range_utf8": [9, 9]
  }
}
```

Errors: `no_suggestion`, `stale_generation`, `surface_not_found`, `feature_disabled`, `not_at_cursor`, `unauthorized_socket`. The plugin inserts `suffix` into ZLE/Readline/fish only after a successful response. cmux does not write completion bytes into the PTY on accept.

### Dismiss and Divergence

Esc or divergent edits emit `buffer.changed` with a new `line_generation`; cmux cancels the old request and hides the overlay. A shell widget may also call:

```json
{"jsonrpc":"2.0","id":"uuid","method":"inline_ai.dismiss","params":{"version":1,"surface_id":"uuid","reason":"escape"}}
```

Success is `{"ok":true,"result":{"version":1}}`; errors are non-fatal and the shell still proceeds normally.

### Help Capture

`HelpCaptureWorker` receives:

```json
{"version":1,"type":"help.request","command":"claude","cwd":"/Users/me/project","timeout_ms":800}
```

Response:

```json
{"version":1,"type":"help.response","ok":true,"resolved_path":"/opt/homebrew/bin/claude","stdout":"...","stderr":"","exit_code":0}
```

Errors: `not_found`, `timeout`, `non_executable`, `too_large`, `denied`, `exit_nonzero`. Captures are capped and never block typing.

## Prompt Template

System:

```text
You are cmux inline autocomplete. Complete the current terminal command line like Warp autocomplete. Return only the suffix that should be inserted at the cursor. Do not repeat the existing prefix. Do not include explanations, markdown, quotes, or trailing newline. Prefer exact flags/subcommands from provided help. If no useful completion is likely, return an empty string.
```

User:

```text
cwd: {cwd}
shell: {shell}
line_before_cursor: {line_before_cursor}
line_after_cursor: {line_after_cursor}
head_command: {head_command}

recent_terminal_history:
{history_blocks}

cached_help_for_head_command:
{help_output}

constraints:
- Single-line command suffix only.
- Must be safe to insert literally at the cursor.
- Do not invent secrets, paths, hostnames, or destructive flags.
- If the user is typing a flag prefix, complete the most likely flag.
```

For `claude --`, the help block should make `--dangerously-skip-permissions` available without a hand-written spec.

## Context Budget

Target 4k input tokens for the default fast model. Keep: current line and cursor always; cwd always; last 8 completed shell commands; last 80 lines or 24 KiB of associated output, whichever is smaller; current visible screen tail if OSC 133 command boundaries are incomplete; first 24 KiB of `<cmd> --help`; and 64 output tokens. The context builder prefers recent command/output pairs delimited by OSC 133 `C/D`; otherwise it falls back to visible scrollback with a lower confidence flag.

## Caching

Suggestion cache key:

```text
provider:model:shell:cwd:head-command:line-before-cursor:line-after-cursor:
recent-history-hash:help-output-hash:config-version
```

Use an in-memory LRU for suggestions: 512 entries, 10 minute TTL, invalidated on cwd change, line divergence, config change, or provider change. This is what delivers the under-50 ms warm path. Do not persist suggestion prompts or completions to disk by default.

Help cache is separate: disk-backed under Application Support, keyed by resolved executable path, `mtime`, size, cwd only when resolution depends on cwd, and command name. TTL is 7 days, max 256 commands, max 64 KiB per entry. Help text is less sensitive than terminal history, but the cache remains local and telemetry-free.

## Failure Modes

API timeout: hide overlay, keep a short cooldown per provider/model, no terminal input mutation. Rate limit: hide overlay and suppress calls until `retry_after_ms`. Offline: fail fast after network reachability says offline; keep zero typing lag. Missing or bad BYOK key: mark provider unavailable and surface a Preferences warning, not a terminal overlay. Ollama unavailable: same as offline for that provider. Provider returns a prefix, multiline text, or shell-unsafe content: normalize only if it is an exact suffix; otherwise reject.

Unsupported prompt sequences: if OSC 133 prompt/input boundaries are absent, cmux cannot reliably place terminal-rendered ghost text. In that state the engine may still compute suggestions, but the overlay stays hidden unless the shell plugin can provide a trusted cursor cell. Phase 1 should require Ghostty shell integration in zsh and fail closed when prompt marks are missing.

Feature disabled: no OSC handling, no key interception, no provider calls, and the shell plugin returns immediately from widgets. The resulting PTY bytes and key behavior should be byte-identical to vanilla cmux.

## Secret Scrubbing

Scrub before cache lookup and before provider calls. Do not collect full env. Allow only safe metadata such as `SHELL`, `TERM`, and sanitized `PATH` command resolution. Redact environment names matching `*_KEY`, `*_TOKEN`, `*_SECRET`, `*_PASSWORD`, `AWS_*`. Redact values matching common credentials: AWS access keys (`AKIA...`, `ASIA...`), OpenAI keys (`sk-...`, `sk-proj-...`), GitHub tokens (`ghp_...`, `github_pat_...`), Anthropic keys (`sk-ant-...`), private key blocks, bearer tokens, and URL userinfo tokens.

Examples:

```text
export AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE; aws s3 ls
=> export AWS_SECRET_ACCESS_KEY=<redacted:env-secret>; aws s3 ls

OPENAI_API_KEY=sk-proj-abc123 npm test
=> OPENAI_API_KEY=<redacted:openai-key> npm test

git clone https://ghp_abcd@github.com/org/repo
=> git clone https://<redacted:github-token>@github.com/org/repo
```

If the current editable line contains a suspected secret in or before the cursor, return `blocked_by_scrubber` and render no suggestion. This satisfies the acceptance case where a session exports `AWS_SECRET_ACCESS_KEY=AKIA...` before running `aws s3 ls`.

## Acceptance Targets

The production design should be validated against the exact v1 examples: `git`, `git c`, `git checkout -b feat`, `cd ~/`, `claude --`, and `kubectl get pods -n `. Cold latency is measured from the last accepted `buffer.changed` generation to first visible ghost text and must stay under 600 ms on broadband. Warm-cache latency is the in-memory suggestion path and must stay under 50 ms. Offline mode must prove zero measurable typing lag with `ai.inline.enabled = true`, and disabling the feature must produce byte-identical PTY behavior compared with vanilla cmux.

## Phase 1 Vertical Slice

Phase 1 should implement the narrowest zsh-only path: install a ZLE integration that emits `buffer.changed` after a 300 ms debounce, require OSC 133 prompt marks, support Anthropic BYOK as the first cloud adapter, use no disk suggestion cache, and render one gray inline suffix in the terminal overlay. Right arrow and Tab accept via `inline_ai.accept`, and the ZLE widget inserts the returned suffix into `BUFFER`. OpenAI-compatible BYOK and Ollama follow in Phase 2. The demo command is `claude --` producing `--dangerously-skip-permissions`, recorded as an asciinema cast under `docs/demo/`.

## Decisions for Phase 1

1. Use the hybrid architecture and terminal-rendered ghost text; do not ship a shell-native suggestion UI.
2. Add a narrow cmux-private OSC action in the Ghostty fork if generic OSC passthrough is unavailable.
3. Ship Anthropic BYOK first for the Phase 1 cloud path; no bundled cmux API key, no hosted inference proxy, no telemetry.
4. Store provider secrets in Keychain and keep `ai.toml` non-secret.
5. Enable Right arrow and Tab accept by default while a suggestion is visible; otherwise Tab falls through to shell completion.
6. Persist only help output, not prompts or suggestion completions.
7. Fail closed without OSC 133 placement in Phase 1; do not guess prompt geometry.
8. Treat the objective's OSC 99 reference as unresolved source evidence: the inspected Ghostty fork shows OSC 9 and OSC 777 notification handling plus OSC `9;9` cwd handling, so Phase 1 should verify whether any cmux-local OSC 99 convention exists before choosing the final private OSC number.
