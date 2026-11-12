# First-class harnesses in cmux

Status: proposal

## Problem

Many coding tools already have a useful runtime boundary: a project session,
workspace, server, or multiplexer that can keep a process alive and provide a
real attach operation. Today cmux can start a terminal with a command, but the
user has to know which harness to use, remember its attach command, and decide
whether a second invocation would create a duplicate session.

The product should make the useful path discoverable without making cmux the
owner of every tool's process model. When cmux recognizes a harness in the
current project, the user should see a clear recommendation:

> **cmux found your harness. Use it because it keeps this project session alive
> when the terminal surface is closed or cmux restarts.**

The explanation must name the evidence and the consequence. For example:

> **Use local tmux for this project** — found a tmux session named `work` in
> `~/src/project`; attaching preserves its shell, agent, and scrollback.

## User flow

1. The user focuses a terminal surface or workspace and opens the command
   palette (`⌘⇧P`).
2. cmux performs a bounded, read-only discovery pass for the focused working
   directory. Discovery may inspect project files and ask an installed harness
   for a list of sessions, but it must not start a process or mutate project
   state.
3. If a harness is found, the palette shows **Use `<harness>` for this
   project**. Its subtitle states the evidence (`found ...`) and the benefit
   (`attaches ...`, `keeps ...`, or `reconnects ...`). The command is disabled
   while discovery is pending and absent when the harness is not installed or
   the evidence is stale.
4. Activating the command opens or reuses a terminal surface in the current
   pane. If a matching live session exists, cmux attaches to it. Otherwise it
   launches the harness owner with the requested working directory and then
   attaches the surface to the resulting session.
5. cmux reports the result in the terminal title/sidebar and command-palette
   status: **Attached to `<harness>`**, **Started `<harness>`**, or a concise
   failure with the next action. A failed attach must never silently create a
   second owner.
6. Closing the cmux surface detaches the client. It does not stop the harness
   owner unless the user explicitly chooses **Stop harness session**. On
   restore, cmux tries the same stable harness/session identity and explains
   when the owner no longer exists.

The first slice should ship one harness end to end, preferably local tmux,
because its ownership and attach semantics are already documented in
[`docs/local-tmux.md`](../local-tmux.md). The discovery and palette contract
must remain generic so later harnesses do not add provider-specific UI.

## What cmux owns

cmux owns the user-facing integration and the client surface:

- Detecting a candidate in the focused project, with a short timeout and
  explicit evidence.
- Presenting one command-palette contribution with context and enablement
  gates. The existing `CommandPaletteCommandContribution` already separates
  this declaration from behavior; the app registers the handler through
  `CommandPaletteHandlerRegistry`.
- Choosing the target workspace, pane, and terminal surface, including the
  existing local/remote/cloud routing rules.
- Passing a structured launch/attach request, the working directory, and
  cmux-owned identity markers to the terminal runtime.
- Tracking whether the surface is attached, detached, reconnecting, or failed;
  exposing that state in the sidebar, title, and diagnostics.
- Persisting the client attachment and attempting restore with a stable
  harness/session identifier. Restore must fail closed when the identity is
  stale rather than attaching to a lookalike session by title or cwd.
- Safe cancellation, timeout, error copy, and explicit stop behavior.

cmux is a client and coordinator. It does not become the process supervisor,
the source of harness scrollback, or the authority for tool-specific session
state.

## What the harness owns

The harness remains authoritative for its runtime:

- The owner process, child process tree, PTY/session state, and scrollback.
- Session identity and the attach/detach protocol.
- Project-specific configuration, authentication, model selection, and
  restart/resume semantics.
- Whether an existing session is attachable, busy, stopped, or incompatible.
- Cleanup of sessions that the user explicitly stops.

cmux must not infer these facts from a tab title, process name, or a mutable
working directory. A harness adapter may expose those as display hints, but
the attach response is the authority.

## Smallest integration

The minimum contract is a detector plus a launch/attach descriptor. It can be
implemented behind one app-owned registry without changing the terminal
renderer:

```text
HarnessDescriptor {
  id:             stable adapter id, e.g. "local-tmux"
  displayName:    "local tmux"
  evidence:       short human-readable discovery reason
  cwd:            project directory used for discovery
  executable:     resolved binary path or null when attaching remotely
  version:        optional display/version string
  sessionId:      stable harness session id, if one was found
  state:          attachable | running | stopped | unavailable
  benefit:        one sentence shown in the palette
}

HarnessLaunch {
  descriptor:     HarnessDescriptor
  mode:           attach | start-and-attach
  arguments:      structured argument array; no shell interpolation
  command:        adapter-generated shell-quoted bridge for the first slice
  environment:    cmux-owned markers plus harness-required values
}
```

The detector should be pure from cmux's perspective: return no candidate,
one candidate, or several candidates with an explicit priority. It should be
bounded (target 250 ms for local checks), cache positive results briefly, and
surface a retryable **Discovery unavailable** result instead of blocking the
palette indefinitely.

The first launch path can use the existing terminal entry point:

```swift
workspace.newTerminalSurfaceOutcome(
    inPane: pane,
    workingDirectory: launch.descriptor.cwd,
    initialCommand: launch.command,
    startupEnvironment: launch.environment
)
```

`Workspace.newTerminalSurfaceOutcome` already distinguishes a locally created
surface from a request routed to a remote tmux mirror or cloud terminal. The
harness integration must branch on the result: attach using the returned local
surface identity only for `.created(panel)`, and obtain a remote surface receipt
or let the route owner perform attachment for `.routedToRemote`. A remote
outcome does not contain a local panel identity, so cmux must never invent one
or create a local fallback.

For the first implementation, `initialCommand` may be a harness-provided
attach command generated from the structured arguments. The adapter must apply
the existing shell-quoting rules; later work should promote the arguments to a
native spawn request so cmux never has to concatenate a shell command.

The environment markers are deliberately generic and namespaced:

```text
CMUX_HARNESS_ID
CMUX_HARNESS_SESSION_ID
CMUX_HARNESS_MODE=owner|client
```

They identify the cmux attachment to hooks and diagnostics. They do not grant
the harness authority over cmux, and the harness must not treat a missing
marker as permission to guess a surface.

For the local-tmux adapter, `attach` maps to the existing
`cmux local-tmux attach <name>` path and `start-and-attach` maps to
`cmux local-tmux start <name> --cwd <cwd>` followed by attach. The adapter
should prefer the local-tmux registry and server-incarnation marker over a
bare `tmux has-session` check, so a recycled session number cannot be mistaken
for the user's session.

## Command-palette contract

Each adapter contributes one command per discovered candidate:

```text
commandId:  palette.harness.attach.<adapter-id>
title:      Use <display name> for this project
subtitle:   <evidence>; <benefit>
keywords:   harness, attach, resume, <adapter aliases>
when:       a focused project and a valid descriptor exist
enablement: discovery settled and launch/attach target is available
```

The handler resolves the current context again before acting. A stale palette
row must not attach to the directory or session that happened to be focused
when the palette opened. The handler then calls one shared attach operation;
future CLI, sidebar, and restore entry points should call the same operation
rather than reimplementing harness rules.

The palette should show **Use** rather than **Start** when a session is already
available. If no session is available, the same row may say **Start with** and
its subtitle must say what will be created. Do not silently replace a user's
ordinary shell or silently terminate an existing owner.

## Failure and visibility rules

- Missing executable: **`<harness>` is not installed** with its install/help
  action, if known.
- No matching session: offer **Start with `<harness>`**, with the exact cwd.
- Attach race: re-list once; attach the winner or report that another client
  owns the session. Never launch a second owner automatically.
- Owner exited: mark the attachment ended and offer **Start again**.
- Remote/cloud route unavailable: preserve the normal routed failure and show
  where the request was sent. Do not create a local orphan surface.
- Timeout or malformed response: show **Harness status unavailable** with a
  retry action and a diagnostic request id.

The status needs to be visible without opening a log. A surface row should be
able to answer: which harness, which session, attached where, last state
change, and what cmux will do on restore. Detailed protocol output belongs in
the terminal or diagnostics view.

## Non-goals for the first slice

- A universal harness protocol or automatic support for every installed CLI.
- Moving an existing harness owner between machines.
- Replacing ordinary cmux terminals or changing the default shell launch.
- Inferring sessions from titles, cwd equality, or process-name heuristics.
- Automatic model/provider failover; that belongs to the harness or its router.
- A new Swift terminal renderer. The existing surface creation and command
  palette seams are sufficient for the first attach path.

## Acceptance criteria

The first harness is complete when a user can:

1. Focus a project terminal and find a contextual **Use `<harness>`** command.
2. See why cmux chose it and what continuity it provides.
3. Attach to an existing session or start exactly one owner in the current
   pane.
4. Close/reopen cmux and reconnect to the same session when the owner remains.
5. See a bounded, actionable failure when the owner is gone or unreachable.
6. Use the ordinary **New Terminal** path unchanged when no harness is found.
