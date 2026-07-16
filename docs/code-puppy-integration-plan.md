# Code Puppy Agent Integration Plan

Status: PROPOSED (repo-verified). Author: Betty White (code-puppy-2c1583). Last
updated: 2026-07-16. Scope: integrate the **Code Puppy** coding agent into cmux
so it is detected, launchable, session-tracked, restorable, and
notification-aware — with parity to Claude Code / Codex where practical.

> **Verified against the Code Puppy source** at
> `~/dev/Projects/Community/code_puppy` (v0.0.643). The findings below
> collapse the original design: Code Puppy already ships a native,
> Claude-Code-compatible hook engine and native session resume, so the
> integration is **Codex-parity minus the PATH-shim wrapper, plus free
> resume** — and needs no custom cmux-authored plugin.

This plan follows the pattern established by `codex-agent-detection-plan.md` and
`agent-session-tracking-spec.md`. It leans on Code Puppy's own architecture (see
the `code-puppy-agent` skill): Code Puppy is **plugin-first**, which lets us do
the cleanest possible cooperative integration instead of the file-injection
hacks other agents require.

---

## 1. What "Code Puppy" is (and why it's the easiest integration yet)

Code Puppy is a Python TUI/CLI coding agent. Entry points (from
`pyproject.toml`): console scripts `code-puppy` and `pup`, plus
`python -m code_puppy`. Three verified facts make this integration trivial:

1. **It ships a native, Claude-Code-compatible hook engine.**
   `code_puppy/hook_engine/` supports the events cmux needs — `SessionStart`,
   `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
   `Notification`, `Stop`, `SubagentStop`, `PreCompact` — with matcher
   patterns, per-hook `timeout` (milliseconds), exit-code blocking (0 allow /
   1 block / 2 error), and **Claude-Code stdin JSON** (`session_id`,
   `hook_event_name`, `tool_name`, `tool_input`, `cwd`, `permission_mode`).
   The built-in `plugins/claude_code_hooks/` plugin already binds these events
   to Code Puppy's run lifecycle. We author **no plugin**.

2. **It reads its hook config from a plain JSON file.**
   `plugins/claude_code_hooks/config.py` loads and merges:
   - `~/.code_puppy/hooks.json` (global) — accepts both bare `{Event: [...]}`
     and wrapped `{"hooks": {Event: [...]}}`.
   - `.claude/settings.json` (project) — reads its `hooks` section.
   This is the **same JSON shape cmux's existing `.nested` format writer
   already emits** for Codex (`~/.codex/hooks.json`), Gemini, and Copilot.

3. **It has native session resume.** `cli_runner.py` exposes
   `--resume/-r <path|name>` (a `.pkl` session or a session *name*, lazily
   created via `resolve_or_create_resume_target`) and `--quick-resume/-qr
   [PATH]` (most recent session for a dir, git-root+branch scoped). Sessions
   persist under `~/.code_puppy/` (unified `autosaves/`; legacy `contexts/`)
   as `<name>.pkl` + `<name>_meta.json` (`session_storage.py`).

Because Code Puppy fires its own `SessionStart` hook (like Claude Code), cmux
does **not** need the PATH-shim wrapper Codex required: the hook itself is the
reliable, per-launch session-start signal. And because resume is native and
cmux can *mint the session name at launch*, restore is essentially free.

---

## 1b. Net effect on the design

- **Drop** the bespoke `.codePuppyPlugin` install format and the
  cmux-authored `register_callbacks.py` — unnecessary. Reuse the existing
  `.nested(timeoutMs:)` writer pointed at `~/.code_puppy/hooks.json`.
- **Drop** the PATH-shim wrapper — Code Puppy's `SessionStart` hook is the
  signal.
- The hook config is global (affects Code Puppy outside cmux too), exactly
  like the existing Gemini/Copilot/Factory integrations. The `cmux hooks`
  command no-ops without `CMUX_SURFACE_ID`, and a `CMUX_CODE_PUPPY_HOOKS_DISABLED`
  env var gives a per-process kill switch — same pattern as every other agent.
- Session id for resume comes from **argv** (cmux mints `--resume <name>`),
  not the hook stdin (whose `SessionStart` `session_id` is the placeholder
  `"codepuppy-session"` and thus unreliable for resume).

## 2. Integration surfaces in cmux (the checklist)

Adding an agent touches a well-defined set of files. Each layer is independent,
so we can ship incrementally. Discovered surfaces:

| # | Surface | File | Purpose |
|---|---------|------|---------|
| A | Process detection | `Sources/CmuxTaskManagerCodingAgentDefinition+BuiltIns.swift` | Recognize a running `code-puppy` process (task manager, pixel pets, status). |
| B | Detection struct/tests | `Sources/TaskManagerTypes.swift`, `cmuxTests/TaskManagerResourcesTests.swift` | Matching rules + regression coverage. |
| C | Launch config kind | `Sources/CmuxConfig.swift` (`CmuxConfigAgentKind`) | `agent` action buttons / plus-menu / command palette. |
| D | Session presentation | `Sources/SessionAgentPresentation.swift`, `Sources/SessionIndexModels.swift` (`SessionAgent`) | Display name + brand icon in the session index / iOS registry. |
| E | Brand icon asset | `Assets.xcassets/AgentIcons/CodePuppy.imageset/` | The visual mark. |
| F | Hook catalog | `CLI/CMUXCLI+AgentHookCatalog.swift` (`agentDefs`) | `cmux hooks setup code-puppy`: write `~/.code_puppy/hooks.json` via the existing `.nested` writer, map lifecycle → cmux subcommands, session store, resume. |
| G | Notification gating | `Sources/AgentNotificationGate.swift` | turn-complete / needs-permission / idle categories. |
| H | Docs | `docs/agent-hooks.md`, `docs/configuration.md` | User-facing tables + supported-agent lists. |

No new install format and no Code-Puppy-side plugin are required (see §1b).

---

## 3. Design principles

- **Reuse, don't invent.** Code Puppy's native hook engine speaks Claude Code
  JSON; cmux's `.nested` writer already emits it. One catalog row wires them
  together — no new format, no wrapper, no plugin.
- **Cooperative, not coercive.** Rely on Code Puppy's own `SessionStart` hook
  as the reliable per-launch signal. The `cmux hooks` command no-ops without
  `CMUX_SURFACE_ID`, so Code Puppy behaves identically outside cmux.
- **cmux owns the session id.** Launch with `code-puppy --resume <cmux-name>`
  (lazily created) so cmux always knows the id — resume is deterministic.
- **Ship in tiers.** Each tier is independently valuable and mergeable.
- **No unreliable fallback.** An agent launched outside a cmux terminal simply
  isn't tracked. Correct, not a bug (same stance as the codex plan).

---

## 4. Tiered rollout

### Tier 0 — Detection (smallest, highest value)

Make a running `code-puppy` visible to the task manager, pixel pets, and status
UI. **cmux-only, no Code Puppy changes.**

1. Add a `CmuxTaskManagerCodingAgentDefinition` builtin:

   ```swift
   .init(id: "code-puppy", displayName: "Code Puppy", assetName: "AgentIcons/CodePuppy",
         launchKinds: ["code-puppy"],
         directBasenames: ["code-puppy", "code_puppy"],
         argumentNeedles: ["code-puppy", "code_puppy"]),
   ```

   Note: Code Puppy is a Python entry point. It runs as `code-puppy` or
   `code_puppy` (console scripts), `python -m code_puppy`, or a wrapper such as
   `uvx code-puppy`. The `code_puppy` needle covers `python -m code_puppy`, and
   the `code-puppy` needle covers `uvx`/`pipx` wrappers. The `pup` console
   script is intentionally NOT a bare-process matcher: `ericchiang/pup` (a
   popular HTML CLI) shares that name, so `pup` is only recognized as an
   explicit config/hook alias or when cmux stamps `CMUX_AGENT_LAUNCH_KIND`.

2. Add the brand icon asset (surface E) — `AgentIcons/CodePuppy.imageset` with
   `@1x/@2x/@3x` PNGs and an optional dark variant, mirroring `Codex.imageset`.
   Until real art exists, `assetName: nil` falls back to an SF Symbol, so this
   asset is not a blocker.

3. Regression test in `TaskManagerResourcesTests.swift`: assert a synthetic
   `code-puppy` process maps to the new definition and asset name.

**Acceptance:** launch `code-puppy` in a cmux terminal → it appears in the task
manager with the right name/icon.

### Tier 1 — Launch config

Let users add a Code Puppy launch button / palette entry.

1. Add `.codePuppy` to `CmuxConfigAgentKind` in `CmuxConfig.swift`:
   - `commandName` → `"code-puppy"`
   - `defaultIcon` → `.symbol("pawprint")` (or the brand asset once it exists)
   - decode aliases: `"code-puppy"`, `"codePuppy"`, `"code_puppy"`, `"codepuppy"`
   - `defaultTitle` → localized `"Code Puppy"` (add
     `command.cmuxConfig.defaultCodePuppyTitle`)
2. Add the keyword to the agent-chat command-palette keyword lists
   (`ContentView+AgentChatCommandPalette.swift`, `CmuxConfig.swift` line ~1376).
3. Doc the config example in `docs/configuration.md`.

**Acceptance:** a `cmux.json` `agent` action with `"agent": "code-puppy"` shows a
titled, iconed button that launches Code Puppy.

### Tier 2 — Session tracking, restore & Feed (now just one catalog row)

Because Code Puppy natively reads `~/.code_puppy/hooks.json` in the exact shape
cmux's `.nested` writer produces, this collapses to a single `AgentHookDef`.

**Catalog row (surface F).** Add to `agentDefs`, cloning the Codex row but
pointing at Code Puppy's global hooks file and dropping the wrapper/config-toml
post-install:

```swift
AgentHookDef(
    name: "code-puppy", displayName: "Code Puppy", statusKey: "code-puppy",
    configDir: ".code_puppy", configFile: "hooks.json",
    createConfigDirIfMissing: true,
    binaryName: "code-puppy",
    sessionStoreSuffix: "code-puppy",
    disableEnvVar: "CMUX_CODE_PUPPY_HOOKS_DISABLED",
    hookMarker: "cmux hooks code-puppy",
    format: .nested(timeoutMs: 5000), // Code Puppy hook_engine timeout is ms
    events: [
        .init(agentEvent: "SessionStart",     cmuxSubcommand: "session-start"),
        .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit"),
        .init(agentEvent: "Stop",             cmuxSubcommand: "stop"),
        .init(agentEvent: "Notification",     cmuxSubcommand: "notification"),
        .init(agentEvent: "SessionEnd",       cmuxSubcommand: "session-end"),
    ],
    feedHookEvents: ["PreToolUse", "PostToolUse"]
),
```

The `.nested` writer emits exactly what Code Puppy's registry expects:
`{ "SessionStart": [ { "hooks": [ {"type":"command","command":"cmux hooks
code-puppy session-start","timeout":5000} ] } ], ... }`. Code Puppy's registry
defaults an absent `matcher` to `"*"`, so PreToolUse/PostToolUse Feed bridges
work without a matcher. Wire the name into `cmux hooks setup` and the
supported-agents help text (`CLI/cmux.swift` ~line 15289).

**Resume (native, no changes to Code Puppy).** Register a Vault agent
(`CmuxVaultAgentRegistration`) so cmux mints and reads the session id from argv:

```swift
static var builtInCodePuppy: CmuxVaultAgentRegistration {
    CmuxVaultAgentRegistration(
        id: "code-puppy", name: "Code Puppy", iconAssetName: "AgentIcons/CodePuppy",
        detect: CmuxVaultAgentDetectRule(
            processNames: ["code-puppy", "code_puppy"],
            alternateArgvContains: ["code_puppy"]),
        sessionIdSource: .argvOption("--resume"),
        resumeCommand: "{{executable}} --resume {{sessionId}}",
        cwd: .preserve,
        sessionDirectory: "~/.code_puppy/autosaves")
}
```

With this, cmux launches `code-puppy --resume <name>` (lazily created by
`resolve_or_create_resume_target`), reads the name straight off argv, and
replays the same command on restore. `sessionStoreSuffix` also gives us
`~/.cmuxterm/code-puppy-hook-sessions.json` for free, so restore, agent
hibernation, and resume-command sanitization all apply with no extra work.

**Acceptance:** `cmux hooks setup code-puppy`, then launch Code Puppy in a cmux
terminal via a `--resume <name>` action → one session appears, state flips
working ↔ idle, mutating tools raise Feed cards, and app relaunch resumes the
same session.

### Tier 3 — Notifications & auto-naming

1. **Notification categories (surface G).** Code Puppy's hook stdin carries the
   event type, but the turn/permission gating happens on cmux's side: the
   `Stop` → `stop` subcommand is the turn-complete signal, and a blocking
   `PreToolUse`/`Notification` is the needs-permission signal. Tag the emitted
   notify payloads with the `c=<category>;p=<0|1>` meta the gate already parses
   so Code Puppy gets the same turn/permission/idle gating as Claude with zero
   new gate code. This is driven by the `cmux hooks code-puppy stop` /
   `notification` handlers, not by editing the gate.
2. **Feed classification.** Confirm `FeedEventClassifier` renders Code Puppy's
   `PreToolUse`/`PostToolUse` stdin payloads (`tool_name`, `tool_input`,
   `tool_result`) sensibly; add a mapping if needed. Code Puppy's tool names
   are its internal names (`create_file`, `agent_run_shell_command`, ...) — the
   engine also accepts Claude aliases, but the payload reports the internal one.
3. **Workspace auto-naming (optional, later).** Code Puppy can summarize via its
   own CLI (`code-puppy -p <prompt>` non-interactive), so it *could* join the
   auto-naming adapters (`CMUXCLI+AutoNaming*`). Defer until the hook path is
   dogfooded; list Code Puppy as "skipped until verified" in
   `docs/agent-hooks.md` first, exactly as the doc does for other new agents.

---

## 5. File-by-file change list (implementation order)

1. `Assets.xcassets/AgentIcons/CodePuppy.imageset/` — brand icon (or defer;
   `assetName: nil` falls back to an SF Symbol).
2. `Sources/CmuxTaskManagerCodingAgentDefinition+BuiltIns.swift` — Tier 0 def
   (basenames `code-puppy`/`code_puppy`, needles `code-puppy`/`code_puppy`).
3. `cmuxTests/TaskManagerResourcesTests.swift` — detection regression test
   (two-commit: failing test, then the def — per repo test-commit policy).
4. `Sources/CmuxConfig.swift` — `.codePuppy` kind, title, palette keywords.
5. `Sources/SessionIndexModels.swift` + `Sources/SessionAgentPresentation.swift`
   — `SessionAgent.codePuppy` (or rely on `.registered`) + display/asset.
6. `CLI/CMUXCLI+AgentHookCatalog.swift` — the `AgentHookDef` row (reuses the
   existing `.nested(timeoutMs:)` format — **no new format file needed**).
7. `CLI/cmux.swift` — supported-agent help text + any `def.name` special-cases.
8. `Sources/VaultAgentRegistry.swift` — `builtInCodePuppy` + include in `load()`
   (declarative argv-sourced resume; also a zero-cmux-code path via `cmux.json`).
9. `docs/agent-hooks.md`, `docs/configuration.md` — user docs.

**No Code Puppy repo changes required.** Its native hook engine + `--resume`
cover everything. (Optional future nicety: a Code Puppy PR that ships a
`cmux`-aware default so `cmux hooks setup` isn't even needed — not required.)

---

## 6. Answered questions (verified in the Code Puppy source)

1. **Console-script name & module path.** `pyproject.toml` → `code-puppy` and
   `pup` console scripts; `code_puppy/__main__.py` → `python -m code_puppy`
   works. Detection covers `code-puppy`, `code_puppy`, the `code-puppy` and
   `code_puppy` argv needles (wrappers and `python -m`), and the `code-puppy`
   launch kind. `pup` is an explicit alias only, not a bare-process matcher.
2. **Session resume by id.** Native. `cli_runner.py` → `--resume/-r <path|name>`
   (lazily created via `resolve_or_create_resume_target`) and
   `--quick-resume/-qr [PATH]`. No Code Puppy change needed.
3. **Session id source.** cmux mints it at launch (`--resume <name>`) and reads
   it from argv via the Vault `sessionIdSource: .argvOption("--resume")`. The
   hook stdin `session_id` is unreliable at `SessionStart` (defaults to the
   `"codepuppy-session"` placeholder in `hook_engine/executor.py`), so we do
   **not** depend on it for resume.
4. **Config file & dir.** Hooks: `~/.code_puppy/hooks.json` (global, bare or
   `{"hooks":{}}`) + `.claude/settings.json` (project), per
   `plugins/claude_code_hooks/config.py`. Sessions: `~/.code_puppy/` unified
   `autosaves/` (`config.py` `DATA_DIR`; legacy `contexts/`). No dedicated
   `CODE_PUPPY_HOME` for hooks — the file lives under `~/.code_puppy`.
5. **Hook stdin/timeout contract.** `hook_engine/executor.py`: Claude-Code JSON
   on stdin (`session_id`, `hook_event_name`, `tool_name`, `tool_input`, `cwd`),
   per-hook `timeout` in **milliseconds**, exit 0/1/2 semantics, and JSON
   control payloads (`{"decision":"block"}` etc.). Matches what `cmux hooks`
   handlers already parse (surface via `CMUXCLI+AgentHookPayload.swift`).
6. **Kill switch / no-op.** `CMUX_CODE_PUPPY_HOOKS_DISABLED` (new `disableEnvVar`)
   plus the existing `cmux hooks` no-op-without-`CMUX_SURFACE_ID` behavior make
   the global hooks file safe outside cmux — same pattern as Gemini/Copilot.

Remaining verification (build-time, not blockers): confirm the `.nested` writer
round-trips cleanly when `~/.code_puppy/hooks.json` already exists with unrelated
hooks (idempotent marker merge), and that `FeedEventClassifier` renders Code
Puppy tool payloads.

---

## 7. Testing & dogfood

- **Unit:** detection mapping (Tier 0), config decode of `.codePuppy` aliases
  (Tier 1), Vault registration decode/resume-command round-trip (Tier 2),
  notify-gate decision table (add a Code Puppy category case).
- **Hook-file test:** assert `cmux hooks setup code-puppy` writes a
  `~/.code_puppy/hooks.json` whose JSON parses under Code Puppy's
  `build_registry_from_config` shape (Event → [{hooks:[{type,command,timeout}]}]).
- **E2E dogfood (per repo policy):** build a tagged Debug app
  (`./scripts/reload.sh --tag code-puppy`), run `cmux hooks setup code-puppy`,
  launch Code Puppy via a `--resume <name>` action in a cmux terminal, and
  verify: appears in GUI → state tracks working/idle → mutating tool raises a
  Feed card → turn-complete notify respects the gate → quit and relaunch
  resumes the same session. Prove the no-`CMUX_SURFACE_ID` no-op by running
  `code-puppy` in a plain Terminal (hooks fire but do nothing).

---

## 8. Why this is the right shape

Code Puppy already speaks cmux's language: its native hook engine emits
Claude-Code JSON, and cmux's `.nested` writer already produces it. So the whole
session-tracking integration is **one catalog row + one Vault registration** —
no PATH shim, no wrapper, no cmux-authored plugin, no edits to Code Puppy, and
no new install format. Everything downstream (session store, restore,
hibernation, resume sanitization, notify gating, Feed) reuses cmux machinery
that already exists, and resume is native. That's DRY on the cmux side and
zero-touch on the Code Puppy side — the best of both kennels.

