# Unified Agent Needs-Input Notifications

Issue: <https://github.com/manaflow-ai/cmux/issues/4395>

## Current Codepath

Claude is the clearest root-cause example. `CLI/cmux.swift` receives `claude-hook pre-tool-use`, detects `AskUserQuestion`, extracts the prompt text, and stores it as `lastBody`. Before this change, it did not publish a notification or status there; it waited for a later generic `Notification` hook and hoped that hook arrived and was not suppressed. Generic agents use `runGenericAgentHook` for session/status notifications and `runFeedHook` for blocking permission/question feed items. Raw terminal desktop notifications still enter through `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` in `Sources/GhosttyTerminalView.swift` and then `TerminalNotificationStore`.

That split means the same user-facing fact, "the agent is blocked on the user", can be owned by at least four places:

- Claude-specific hook state (`ClaudeHookSessionStore`)
- Generic agent hook status/notification handlers
- Feed blocking events
- Raw PTY/OSC desktop notification bridging

## Root Cause

Symptom: AskUserQuestion-style agent prompts can fail to blink, badge, or notify consistently, or can duplicate when a later generic attention notification also arrives.

Root cause: cmux does not have one needs-input event boundary. Each adapter decides independently whether a hook, transcript line, OSC sequence, title change, or process state means user input is required.

Class of bugs: dropped AskUserQuestion notifications, generic "needs attention" duplicates, idle prompts treated as blocking prompts, raw OSC suppression swallowing non-Claude CLIs, and stale status updates racing with prompt-submit/stop.

## Architecture

Use `AgentNeedsInputEvent` as the adapter output and `AgentNeedsInputPublisher` as the single publisher.

Adapters normalize source-specific signals:

- Claude `PreToolUse` with `tool_name == AskUserQuestion`
- Claude `Notification` generic attention fallback
- Codex OSC 9 / OSC 777 and hook `PermissionRequest`
- Grok `Notification` / `PreToolUse` feed hooks
- OpenCode plugin `question.asked`, `permission.asked`, and `plan_exit`
- Cursor hook/feed events once trust and runtime payload shape are stable
- Gemini/Qwen hook events after valid event names and auth are confirmed

The publisher owns:

- target validation
- notification payload shaping
- status update
- redaction
- dedup by `(agentKind, sessionId, normalized body)`
- cooldown window
- handoff into app-side notification policy via `notify_target_async`

This keeps `TerminalNotificationStore` as the app-side policy/side-effect owner while giving every CLI adapter one CLI-side needs-input publication path.

## Signal Map

Runtime probes were launched in unfocused cmux workspaces on May 19, 2026. Raw logs are under `/tmp/cmux-issue4395-investigation/*-fg`. The first pass exposed a probe job-control issue; the foreground pass below is the usable evidence. Cloud Mac was not used because this pass was about hook/PTY/process signals, not visual badge verification.

| CLI | Located version | cmux probe | Needs-input signal observed | Hook payload observed | PTY / title / process notes | Adapter decision |
| --- | --- | --- | --- | --- | --- | --- |
| Claude Code | `/Applications/cmux.app/Contents/Resources/bin/claude`, 2.1.145 | `workspace:212`, `surface:410` | Prompt produced plain assistant question, not the `AskUserQuestion` tool in this run. Existing issue/PR evidence identifies `PreToolUse` + `tool_name=AskUserQuestion` as the reliable structured signal. | Debug log showed `SessionStart`, `UserPromptSubmit`, `Stop`; wrapper used cmux directly so shim did not capture stdin JSON. | Raw PTY had BEL=3, OSC9=3, title OSC=0. | First adapter landed here: publish immediately from `AskUserQuestion`; dedupe later generic `Notification`. |
| Codex | `~/.nvm/versions/node/v22.17.1/bin/codex`, 0.131.0 | `workspace:213`, `surface:411` | Prompt produced a visible question: "Should I apply this to every future task?" | No shim-captured hook stdin in the 60s window. Installed hooks include `PermissionRequest` and `PreToolUse` feed; `PreToolUse` is currently non-actionable for Codex in `classifyFeedEvent`. | Raw PTY had BEL=3, OSC9=0, OSC777=0, title OSC=3. cmux status tags appeared as Idle. | Next adapter should combine OSC 9/777 detection from PR #3266 with actionable `PermissionRequest` feed events. |
| Grok | `~/.local/bin/grok`, 0.1.212 | `workspace:214`, `surface:412` | Probe command used TUI positional syntax incorrectly and exited with "unrecognized subcommand"; no ask state observed. | Installed hook file has `Notification`, `PreToolUse`, `Stop`, `SessionStart`, `SessionEnd`, and uses absolute cmux path. | Raw PTY had BEL=0, OSC9=0, OSC777=0, title OSC=0 for the failed launch. | Adapter should build on PR #4227 hooks; rerun with `grok -p` or `grok agent` before enabling question notifications. |
| OpenCode | `~/.nvm/versions/node/v22.17.1/bin/opencode`, 1.15.5 | `workspace:215`, `surface:413` | Prompt produced a visible question about using AGENTS.md build setup. | Shim captured `session.created`, repeated `session.updated`, `session.status`, `session.idle`. No `question.asked` for this plain-text model question. | Raw PTY had BEL=2, OSC9=0, OSC777=0, title OSC=2. | Use `cmux-feed.js` `question.asked` and `permission.asked` paths as authoritative; do not infer every plain assistant question from stdout. |
| Cursor Agent | `~/.local/bin/cursor-agent`, 2026.05.09-0afadcc | `workspace:216`, `surface:414` | Blocked on Workspace Trust before agent prompt. | No cmux hook payload captured. Installed hooks cover `beforeSubmitPrompt`, `beforeShellExecution`, `stop`, `afterAgentResponse`. | Raw PTY had BEL=0, OSC/title=0; process exited by timeout. | Needs a trusted-workspace repro before adding an adapter. Current reliable signal is shell/agent lifecycle, not user-question state. |
| Aider | not found | not launched | Not available on this machine. | none | none | No adapter until CLI is available. |
| Gemini CLI | `~/.nvm/versions/node/v22.17.1/bin/gemini`, 0.41.2 | `workspace:217`, `surface:415` | Prompt produced visible question: "Would you like me to start by exploring the codebase..." | No shim-captured hook stdin. Startup warned `Invalid hook event name: "PreToolUse" from project config. Skipping.` | Raw PTY had BEL=5, OSC9=0, OSC777=0, title OSC=1. cmux status tag appeared Idle. | Fix installed hook event names first; likely use `BeforeTool`/`Notification` rather than `PreToolUse`. |
| Qwen Code | `~/.nvm/versions/node/v22.17.1/bin/qwen`, 0.11.1 | `workspace:218`, `surface:416` | Blocked on auth method; OAuth credentials expired. | No cmux hooks installed in `~/.qwen/settings.json`. | Raw PTY had BEL=1, OSC9=0, OSC777=0, title OSC=1. | No adapter until auth and hook support are installed. |
| qwen-code | not found | not launched | Not available on this machine. | none | none | Prefer `qwen` adapter once auth/hook support are confirmed. |

## Initial Rollout

This PR lands the shared publisher scaffold and the first Claude adapter slice. It deliberately does not infer plain assistant questions from terminal text because that would create spurious notifications. The safe first invariant is:

> A structured `AskUserQuestion` event publishes exactly one needs-input notification immediately, and the later generic attention notification for the same question is suppressed.

The regression harness exercises that invariant with one initial question plus 100 additional unique questions.

## Follow-Up Adapter Work

1. Codex: route OSC 9/777 and hook `PermissionRequest` through `AgentNeedsInputEvent`; keep Claude raw notification suppression exact.
2. Grok: rerun the probe with the correct headless command and map PR #4227 Notification payloads into needs-input only when status is blocking.
3. OpenCode: bridge `question.asked` and `permission.asked` from `cmux-feed.js` into the publisher; keep lifecycle `session.idle` as completion, not needs-input.
4. Cursor: repeat after trusting the workspace and capturing hook stdin for a blocking permission/question.
5. Gemini: update hook event names before relying on feed hooks.
6. Qwen/aider: install/authenticate before designing adapters.
