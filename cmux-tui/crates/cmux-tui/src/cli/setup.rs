//! `cmux setup`: the one entry point an agent (the Chief or any chat) uses to
//! set up cmux NEXT for the person (plans/cmux-next/setup-DESIGN.md).
//!
//! `list` names every setup task and the command that checks and does it,
//! whether `setup` itself runs it yet or an older command does. A task that
//! `setup` runs (`trust`, `machine`, `harness`, `mcp` and `computer-use` today) checks before it
//! changes anything, changes nothing when the state is already right, prints
//! what it would do with `--dry-run`, and names the command that undoes it.
//! Only what a person must do themselves (an OAuth sign-in, a secret,
//! installing a CLI, a macOS grant, a key on an ssh machine) comes back as
//! `user_action`. Output is always JSON: these commands are for agents.

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, parse_globals, wire};

mod computer_use;
mod harness;
mod machine;
mod mcp;
mod trust;

const HELP: &str = "Usage: cmux setup <list|status|trust|machine|harness|mcp|computer-use>\n\nSet up cmux for the person, from an agent. Every command prints one JSON object.\n\n  cmux setup list                 Every setup task and the commands that check and do it\n  cmux setup status               Read-only checks of the tasks setup runs\n  cmux setup trust [FOLDER] [--level trusted|untrusted|unknown] [--dry-run]\n                                  Record the person's trust for a folder (default: this folder, trusted)\n  cmux setup machine SSH_TARGET [--name NAME] [--dry-run]\n                                  Add an ssh machine as an agent peer, or update or repair it (key-only ssh)\n  cmux setup harness [ID ...] [--dry-run]\n                                  Check that each harness is installed, signed in and current (default: every configured or found one)\n  cmux setup mcp [claude|codex ...] [--dry-run]\n                                  Give Claude Code and Codex outside cmux the cmux MCP server (default: each installed one)\n  cmux setup computer-use [--dry-run]\n                                  Turn on cmux Computer Use (the person allows it in cmux) and name the macOS grants it still needs\n\nA task result is {schema_version, task, state, dry_run, ..., undo, user_action}. state is ok (nothing to do), changed, planned (--dry-run), needs_user (user_action says what the person must do) or failed. undo is the command that puts the old state back, or null. Exits 0 unless the task failed (1) or the arguments are wrong (2).\n";

/// The result of a setup task: the JSON the agent reads, and whether it failed.
pub(super) struct Outcome {
    report: Value,
    failed: bool,
}

/// Why a task did not run: wrong arguments (exit 2) or a failure (exit 1).
pub(super) enum Refusal {
    Usage(String),
    Failed(String),
}

/// Handles `cmux setup` before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command_args) = parse_globals(args).ok()?;
    if command_args.first().map(String::as_str) != Some("setup") {
        return None;
    }
    if global.output == OutputMode::Human {
        global.output = OutputMode::Json;
    }
    Some(run(&global, &command_args[1..]))
}

fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    if args.first().is_some_and(|arg| arg == "help")
        || args.iter().any(|arg| matches!(arg.as_str(), "--help" | "-h"))
    {
        print!("{HELP}");
        return 0;
    }
    let result = match args.first().map(String::as_str) {
        None | Some("list") => no_arguments(&args[args.len().min(1)..])
            .map(|()| Outcome { report: list(), failed: false }),
        Some("status") => no_arguments(&args[1..]).and_then(|()| status(global)),
        Some("trust") => trust::run(&args[1..]),
        Some("machine") => machine::run(&args[1..]),
        Some("harness") => harness::run(&args[1..]),
        Some("mcp") => mcp::run(&args[1..]),
        Some("computer-use" | "computer_use") => computer_use::run(global, &args[1..]),
        Some(other) => Err(Refusal::Usage(format!(
            "cmux: setup: unknown task {other:?}; `cmux setup list` names every task"
        ))),
    };
    match result {
        Ok(outcome) => {
            let code = wire::print_local_success(&outcome.report, global.output);
            if code == 0 && outcome.failed { 1 } else { code }
        }
        Err(Refusal::Usage(message)) => wire::print_local_error(
            &json!({"code": "usage.invalid", "message": message, "details": {}, "retryable": false}),
            global.output,
            2,
        ),
        Err(Refusal::Failed(message)) => wire::print_local_error(
            &json!({"code": "setup.failed", "message": message, "details": {}, "retryable": true}),
            global.output,
            1,
        ),
    }
}

fn no_arguments(args: &[String]) -> Result<(), Refusal> {
    match args.first() {
        None => Ok(()),
        Some(arg) => Err(Refusal::Usage(format!("cmux: setup: unexpected argument {arg:?}"))),
    }
}

/// One setup task as `list` names it.
struct Task {
    id: &'static str,
    summary: &'static str,
    /// The `cmux setup` command that runs it, when `setup` runs it.
    setup: Option<&'static str>,
    /// Read-only commands that report the current state.
    check: &'static [&'static str],
    /// Commands that change it, as they run today.
    apply: &'static [&'static str],
    /// What only the person can do, or None when an agent can do all of it.
    person: Option<&'static str>,
}

/// Every setup task a person meets in cmux NEXT, with the command that does
/// it today (the inventory in plans/cmux-next/setup-DESIGN.md).
const TASKS: &[Task] = &[
    Task {
        id: "trust",
        summary: "Trust a folder so agents start in it without asking",
        setup: Some("cmux setup trust FOLDER [--level trusted|untrusted|unknown] [--dry-run]"),
        check: &["cmux setup trust FOLDER --dry-run"],
        apply: &["cmux setup trust FOLDER"],
        person: None,
    },
    Task {
        id: "harness",
        summary: "Install and sign in an agent harness (Claude Code, Codex, OpenCode, Gemini, ...)",
        setup: Some("cmux setup harness [ID ...] [--dry-run]"),
        check: &["cmux setup harness [ID ...]", "cmux harness doctor ID --json"],
        apply: &["cmux harness add ...", "cmux harness login ID"],
        person: Some("the harness's own sign-in (OAuth in a browser) and installing its CLI"),
    },
    Task {
        id: "machine",
        summary: "Add an ssh machine as an agent peer, or update or repair one",
        setup: Some("cmux setup machine SSH_TARGET [--name NAME] [--dry-run]"),
        check: &["cmux setup machine SSH_TARGET --dry-run", "cmux setup status"],
        apply: &["cmux setup machine SSH_TARGET [--name NAME]"],
        person: Some("key-only ssh to the machine: adding a key there or fixing ssh config"),
    },
    Task {
        id: "host_update",
        summary: "Update acpmux on peer machines that run an older build",
        setup: None,
        check: &["cmux setup status", "cmux acp host ls --json"],
        apply: &["cmux setup machine SSH_TARGET --name NAME", "cmux acp host update --all --json"],
        person: None,
    },
    Task {
        id: "accounts",
        summary: "Sign in to cmux and see each agent provider's sign-in",
        setup: None,
        check: &["cmux accounts list --json"],
        apply: &["cmux cloud sign-in"],
        person: Some("the cmux sign-in in the browser"),
    },
    Task {
        id: "cloud_machine",
        summary: "Create a cmux Cloud machine",
        setup: None,
        check: &["cmux cloud machine-status", "cmux cloud diagnostics"],
        apply: &["cmux cloud new-machine"],
        person: Some("confirming the New Cloud Machine sheet"),
    },
    Task {
        id: "tailnet",
        summary: "Serve this machine to the person's other machines over Tailscale",
        setup: None,
        check: &["cmux host status --json"],
        apply: &["cmux host enable --json"],
        person: Some("signing in to Tailscale (`tailscale up`) when it is not signed in"),
    },
    Task {
        id: "mcp",
        summary: "Give Claude Code and Codex the cmux MCP server outside cmux (chats cmux starts have it)",
        setup: Some("cmux setup mcp [claude|codex ...] [--dry-run]"),
        check: &["cmux setup mcp --dry-run", "cmux agents doctor --json", "cmux mcp tools --json"],
        apply: &["cmux setup mcp"],
        person: Some("turning on \"mcp\": {\"enabled\": true} in the cmux settings file"),
    },
    Task {
        id: "computer_use",
        summary: "Let agents use the Mac (cmux Computer Use)",
        setup: Some("cmux setup computer-use [--dry-run]"),
        check: &["cmux setup computer-use --dry-run", "cmux agents doctor --json"],
        apply: &["cmux setup computer-use"],
        person: Some(
            "allowing Computer Use on the sheet cmux shows, and the Accessibility and Screen Recording switches in System Settings",
        ),
    },
    Task {
        id: "browser_import",
        summary: "Bring bookmarks, cookies, history and passwords from another browser",
        setup: None,
        check: &["cmux bookmark list"],
        apply: &[
            "cmux bookmark import-from-browser --browser BROWSER",
            "cmux browser import-cookies --from BROWSER:PROFILE --domain DOMAIN --reason REASON",
        ],
        person: Some(
            "history and password import (Import from Browser...) and the Keychain prompt",
        ),
    },
    Task {
        id: "keyboard_shortcuts",
        summary: "Read and change key bindings",
        setup: None,
        check: &["cmux keybinding list --json", "cmux keybinding resolve KEYS --json"],
        apply: &["cmux settings keyboard-shortcuts"],
        person: None,
    },
    Task {
        id: "notifications",
        summary: "Choose which notifications show, and mute a workspace",
        setup: None,
        check: &["cmux settings get notifications"],
        apply: &["cmux settings set notifications.KEY VALUE"],
        person: Some("allowing macOS notifications, asked the first time one shows"),
    },
    Task {
        id: "team_invites",
        summary: "Invite people to a cmux team, or to a Home conversation",
        setup: None,
        check: &[],
        apply: &["cmux home invite --email EMAIL"],
        person: Some("team invites from the web dashboard (Teams > Members)"),
    },
];

fn list() -> Value {
    let tasks = TASKS
        .iter()
        .map(|task| {
            json!({
                "id": task.id,
                "summary": task.summary,
                "setup": task.setup,
                "check": task.check,
                "apply": task.apply,
                "person": task.person,
            })
        })
        .collect::<Vec<_>>();
    json!({"schema_version": 1, "tasks": tasks})
}

/// The read-only check of every task `setup` runs: this folder's trust,
/// every acpmux peer with whether it is connected and on this build, every
/// harness with whether it is installed, signed in and current, whether
/// Claude Code and Codex outside cmux have the cmux MCP server, and whether
/// agents can use the Mac (Computer Use and its macOS grants).
fn status(global: &GlobalArgs) -> Result<Outcome, Refusal> {
    let checks = [
        trust::status()?,
        machine::status()?,
        harness::status(),
        mcp::status(),
        computer_use::status(global),
    ];
    Ok(Outcome { report: json!({"schema_version": 1, "checks": checks}), failed: false })
}
