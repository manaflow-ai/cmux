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

use std::io::{IsTerminal, Read};

/// The native events classic's `<subcommand>` hook was wired to for
/// `agent` (classic `CLI/CMUXCLI+AgentHookCatalog.swift`), the usual one
/// first. Where classic folded two events onto one subcommand (Copilot's
/// Stop and Notification are both `stop`), the payload's own event name
/// picks between them (`resolve`).
fn native_events(agent: &str, subcommand: &str) -> &'static [&'static str] {
    match (agent, subcommand) {
        ("codex" | "grok" | "kimi" | "muse", "prompt-submit") => &["UserPromptSubmit"],
        ("gemini", "prompt-submit") => &["BeforeAgent"],
        ("antigravity", "prompt-submit") => &["PreInvocation"],
        ("kiro", "prompt-submit") => &["userPromptSubmit"],
        ("cursor", "prompt-submit") => &["beforeSubmitPrompt"],
        ("kiro", "session-start") => &["agentSpawn"],
        (
            "codex" | "grok" | "gemini" | "antigravity" | "copilot" | "codebuddy" | "factory"
            | "qoder" | "kimi" | "muse",
            "session-start",
        ) => &["SessionStart"],
        ("gemini", "stop") => &["AfterAgent"],
        ("kiro" | "cursor", "stop") => &["stop"],
        ("copilot" | "codebuddy" | "factory", "stop") => &["Stop", "Notification"],
        ("codex" | "grok" | "antigravity" | "qoder" | "kimi" | "muse", "stop") => &["Stop"],
        ("kimi" | "muse", "notification") => &["Notification", "StopFailure"],
        ("grok" | "antigravity", "notification") => &["Notification"],
        (
            "grok" | "gemini" | "antigravity" | "copilot" | "codebuddy" | "factory" | "qoder"
            | "kimi" | "muse",
            "session-end",
        ) => &["SessionEnd"],
        ("cursor", "agent-response") => &["afterAgentResponse"],
        ("cursor", "shell-exec") => &["beforeShellExecution"],
        ("cursor", "shell-done") => &["afterShellExecution"],
        ("cursor", "shell-failed") => &["postToolUseFailure"],
        _ => &[],
    }
}

/// The event to journal: the payload's own event name when it is one of
/// `candidates`, else the first, and only one this build wires for the agent
/// (another would be refused).
fn resolve(agent: &str, candidates: &[&'static str], payload: &[u8]) -> Option<&'static str> {
    let named = serde_json::from_slice::<serde_json::Value>(payload).ok().and_then(|value| {
        let name = value.get("hook_event_name").or_else(|| value.get("hookEventName"))?;
        let name = name.as_str()?;
        candidates.iter().copied().find(|candidate| *candidate == name)
    });
    let event = named.or_else(|| candidates.first().copied())?;
    cmux_tui_hooks::provider_events(agent)?.contains(&event).then_some(event)
}

/// What a classic hook command asks for.
#[derive(Debug, PartialEq)]
enum ClassicHook {
    /// Classic's subcommand for an agent, resolved against the payload.
    Subcommand(String, &'static [&'static str]),
    /// `hooks feed --source <agent> --event <native event>`, which names it.
    Named(String, String),
    /// A classic hook this build does not read: exit quietly.
    Ignore,
}

/// `arguments` (after the program name) as a classic hook, or `None` when
/// they are not one. Classic's hook lines pass `--socket <path>` first
/// inside a cmux terminal.
fn parse(arguments: &[&str]) -> Option<ClassicHook> {
    let mut words = arguments;
    loop {
        match words {
            ["--socket", _, rest @ ..] => words = rest,
            [flag, rest @ ..] if flag.starts_with("--socket=") || *flag == "--json" => words = rest,
            _ => break,
        }
    }
    let (agent, subcommand) = match words {
        ["hooks", "feed", rest @ ..] => {
            let value = |name: &str| {
                let prefix = format!("{name}=");
                rest.iter().enumerate().find_map(|(index, word)| {
                    if *word == name {
                        rest.get(index + 1).map(|value| value.to_string())
                    } else {
                        word.strip_prefix(&prefix).map(str::to_string)
                    }
                })
            };
            return Some(match (value("--source"), value("--event")) {
                (Some(agent), Some(event)) => ClassicHook::Named(agent, event),
                _ => ClassicHook::Ignore,
            });
        }
        ["hooks", "enqueue", agent, subcommand, ..] => (*agent, *subcommand),
        // `hooks setup|uninstall` and `hooks <agent> install` are not hooks.
        ["hooks", agent, subcommand, ..]
            if !matches!(*agent, "setup" | "uninstall")
                && !matches!(*subcommand, "install" | "uninstall") =>
        {
            (*agent, *subcommand)
        }
        ["codex-hook", subcommand, ..] => ("codex", *subcommand),
        ["feed-hook", ..] | ["claude-hook", ..] => return Some(ClassicHook::Ignore),
        _ => return None,
    };
    Some(match native_events(agent, subcommand) {
        [] => ClassicHook::Ignore,
        events => ClassicHook::Subcommand(agent.to_string(), events),
    })
}

/// The most of an agent's payload read; the helper refuses more than 1 MiB.
const MAX_PAYLOAD_BYTES: u64 = (1 << 20) + 1;

/// Runs this process's arguments as a hook, or `None` when they are not one:
/// hook helper mode for hosts that received only this binary
/// (`cmux_tui_hooks::HOOK_MODE_ARG`), or a classic hook command. Either runs
/// inside a provider's hook, so it touches no daemon, log, or config state.
/// A classic hook typed at a terminal is not one (the agent pipes its payload).
pub(crate) fn run() -> Option<std::process::ExitCode> {
    let arguments: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    let prefix = &[cmux_tui_hooks::HOOK_MODE_ARG];
    if arguments.first().and_then(|argument| argument.to_str())
        == Some(cmux_tui_hooks::HOOK_MODE_ARG)
    {
        // Hook helper arguments are agent and event names, never anything else.
        let rest = arguments.iter().skip(1).map(|argument| argument.to_string_lossy().into_owned());
        return Some(crate::hook_helper::run_cli(rest.collect(), prefix));
    }
    // Classic hook lines are ASCII; any other argv is not one.
    let words: Vec<&str> =
        arguments.iter().map(|argument| argument.to_str()).collect::<Option<_>>()?;
    let hook = parse(&words)?;
    if std::io::stdin().is_terminal() {
        return None;
    }
    let mut payload = Vec::new();
    let _ = std::io::stdin().lock().take(MAX_PAYLOAD_BYTES).read_to_end(&mut payload);
    let forward = match hook {
        ClassicHook::Subcommand(agent, events) => {
            resolve(&agent, events, &payload).map(|event| (agent, event.to_string()))
        }
        ClassicHook::Named(agent, event) => cmux_tui_hooks::provider_events(&agent)
            .is_some_and(|events| events.contains(&event.as_str()))
            .then_some((agent, event)),
        ClassicHook::Ignore => None,
    };
    Some(match forward {
        Some((agent, event)) => {
            crate::hook_helper::run_with_payload(agent, event, &payload, prefix)
        }
        None => std::process::ExitCode::SUCCESS,
    })
}
