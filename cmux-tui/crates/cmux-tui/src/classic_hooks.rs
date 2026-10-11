//! Agent hooks classic cmux wrote into an agent's own config (`cmux hooks
//! setup`) run `cmux hooks [enqueue] <agent> <subcommand>`, and older ones
//! `cmux codex-hook <subcommand>`. After the update to cmux-next that `cmux`
//! is this binary: each such hook goes through the agent hook helper as the
//! agent's native event, exactly as a hook `agent hook install` wrote would.
//!
//! Only agents whose classic hook gets the agent's own payload on stdin are
//! forwarded. Plugin and wrapper agents (OpenCode, Pi, OMP, Campfire, Amp,
//! Hermes, Rovo Dev) sent a payload classic shaped, so their hooks, and any
//! subcommand next has no event for, exit quietly as they did outside cmux;
//! `cmux agent hook install <agent>` replaces them.

use std::io::Read;

/// The native event classic's `<subcommand>` hook was wired to for `agent`
/// (classic `CLI/CMUXCLI+AgentHookCatalog.swift`). Where classic sent two
/// events to one subcommand (Copilot's Stop and Notification are both `stop`),
/// the turn's end is the one kept.
fn native_event(agent: &str, subcommand: &str) -> Option<&'static str> {
    let event = match (agent, subcommand) {
        ("codex" | "grok" | "kimi", "prompt-submit") => "UserPromptSubmit",
        ("gemini", "prompt-submit") => "BeforeAgent",
        ("antigravity", "prompt-submit") => "PreInvocation",
        ("kiro", "prompt-submit") => "userPromptSubmit",
        ("cursor", "prompt-submit") => "beforeSubmitPrompt",
        ("kiro", "session-start") => "agentSpawn",
        (
            "codex" | "grok" | "gemini" | "antigravity" | "copilot" | "codebuddy" | "factory"
            | "qoder" | "kimi",
            "session-start",
        ) => "SessionStart",
        ("gemini", "stop") => "AfterAgent",
        ("kiro" | "cursor", "stop") => "stop",
        (
            "codex" | "grok" | "antigravity" | "copilot" | "codebuddy" | "factory" | "qoder"
            | "kimi",
            "stop",
        ) => "Stop",
        ("grok" | "antigravity" | "kimi", "notification") => "Notification",
        (
            "grok" | "gemini" | "antigravity" | "copilot" | "codebuddy" | "factory" | "qoder"
            | "kimi",
            "session-end",
        ) => "SessionEnd",
        ("cursor", "agent-response") => "afterAgentResponse",
        ("cursor", "shell-exec") => "beforeShellExecution",
        ("cursor", "shell-done") => "afterShellExecution",
        ("cursor", "shell-failed") => "postToolUseFailure",
        _ => return None,
    };
    // Only an event this build wires for the agent; another would be refused.
    cmux_tui_hooks::provider_events(agent)?.contains(&event).then_some(event)
}

/// What a classic hook command asks for.
enum ClassicHook {
    /// Forward as `(agent, native event)`.
    Forward(String, &'static str),
    /// A classic hook this build does not read: exit quietly.
    Ignore,
}

/// `arguments` (after the program name) as a classic hook, or `None` when
/// they are not one.
fn parse(arguments: &[String]) -> Option<ClassicHook> {
    let words: Vec<&str> = arguments.iter().map(String::as_str).collect();
    let (agent, subcommand) = match words.as_slice() {
        ["hooks", "enqueue", agent, subcommand, ..] => (*agent, *subcommand),
        // `hooks setup|uninstall|...` and `hooks <agent> install` are not hooks.
        ["hooks", agent, subcommand, ..]
            if !matches!(*agent, "setup" | "uninstall" | "feed")
                && !matches!(*subcommand, "install" | "uninstall") =>
        {
            (*agent, *subcommand)
        }
        ["codex-hook", subcommand, ..] => ("codex", *subcommand),
        ["hooks", "feed", ..] | ["feed-hook", ..] | ["claude-hook", ..] => {
            return Some(ClassicHook::Ignore);
        }
        _ => return None,
    };
    Some(match native_event(agent, subcommand) {
        Some(event) => ClassicHook::Forward(agent.to_string(), event),
        None => ClassicHook::Ignore,
    })
}

/// Runs this process's arguments as a hook, or `None` when they are not one:
/// hook helper mode for hosts that received only this binary
/// (`cmux_tui_hooks::HOOK_MODE_ARG`), or a classic hook command. Either runs
/// inside a provider's hook, so it touches no daemon, log, or config state.
pub(crate) fn run() -> Option<std::process::ExitCode> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.first().map(String::as_str) == Some(cmux_tui_hooks::HOOK_MODE_ARG) {
        return Some(crate::hook_helper::run_cli(
            arguments[1..].to_vec(),
            &[cmux_tui_hooks::HOOK_MODE_ARG],
        ));
    }
    Some(match parse(&arguments)? {
        ClassicHook::Forward(agent, event) => crate::hook_helper::run_cli(
            vec![agent, event.to_string()],
            &[cmux_tui_hooks::HOOK_MODE_ARG],
        ),
        ClassicHook::Ignore => {
            drain_stdin();
            std::process::ExitCode::SUCCESS
        }
    })
}

/// Reads and drops the agent's payload so it never blocks writing it.
fn drain_stdin() {
    let _ = std::io::stdin().lock().take(4 << 20).read_to_end(&mut Vec::new());
}
