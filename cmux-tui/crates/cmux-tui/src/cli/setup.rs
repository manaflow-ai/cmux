//! `cmux setup`: the one entry point an agent (the Chief or any chat) uses to
//! set up cmux NEXT for the person (plans/cmux-next/setup-DESIGN.md).
//!
//! `list` names every setup task and the command that checks and does it,
//! whether `setup` itself runs it yet or an older command does. A task that
//! `setup` runs (`trust`, `machine`, `harness`, `mcp`, `computer-use`,
//! `cloud-machine`, `notifications`, `browser-import` and `tailnet` today) checks
//! before it changes anything, changes nothing when the state is already
//! right, prints what it would do with `--dry-run`, and names the command
//! that undoes it. Each task also carries the `prompt` a person pastes into
//! Chief to have it done; docs/chief-setup-prompts.md is made from them.
//! Only what a person must do themselves (an OAuth sign-in, a secret,
//! installing a CLI, a macOS grant, a key on an ssh machine, allowing a
//! paid Cloud machine) comes back as
//! `user_action`. Output is JSON (but `list --prompts-md`): these commands
//! are for agents.

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, parse_globals, wire};

mod browser_import;
mod cloud_machine;
mod computer_use;
mod harness;
mod machine;
mod mcp;
mod notifications;
mod tailnet;
mod trust;

const HELP: &str = "Usage: cmux setup <list|status|trust|machine|harness|mcp|computer-use|cloud-machine|notifications|browser-import|tailnet>\n\nSet up cmux for the person, from an agent. Every command prints one JSON object (but `list --prompts-md`, which prints Markdown).\n\n  cmux setup list [--prompts-md]  Every setup task, the commands that check and do it, and the prompt a person pastes into Chief to have it done (--prompts-md: the prompts as Markdown, docs/chief-setup-prompts.md)\n  cmux setup status               Read-only checks of the tasks setup runs\n  cmux setup trust [FOLDER] [--level trusted|untrusted|unknown] [--dry-run]\n                                  Record the person's trust for a folder (default: this folder, trusted)\n  cmux setup machine SSH_TARGET [--name NAME] [--dry-run]\n                                  Add an ssh machine as an agent peer, or update or repair it (key-only ssh)\n  cmux setup harness [ID ...] [--dry-run]\n                                  Check that each harness is installed, signed in and current (default: every configured or found one)\n  cmux setup mcp [claude|codex ...] [--dry-run]\n                                  Give Claude Code and Codex outside cmux the cmux MCP server (default: each installed one)\n  cmux setup computer-use [--dry-run]\n                                  Turn on cmux Computer Use (the person allows it in cmux) and name the macOS grants it still needs\n  cmux setup cloud-machine [--dry-run] [--forget]\n                                  Have a cmux Cloud machine; create one if there is none (the person allows it in cmux; it costs money while it runs). --forget drops setup's record of the machine it asked for\n  cmux setup notifications [--dry-run]\n                                  Let cmux show macOS notifications (the person allows them on the macOS prompt)\n  cmux setup browser-import [--browser BROWSER[:PROFILE]] [--cookies [--domain D] [--reason TEXT]] [--dry-run]\n                                  Import another browser's bookmarks, or with --cookies its sign-ins (the person allows it in cmux)\n  cmux setup tailnet [--owner LOGIN] [--dry-run]\n                                  Serve this machine to the person's other machines over Tailscale (cmux host enable); names the Tailscale step the person still needs\n\nA task result is {schema_version, task, state, dry_run, ..., undo, user_action}. state is ok (nothing to do), changed, planned (--dry-run), needs_user (user_action says what the person must do), failed, or not_applicable (nothing to set up on this machine). undo is the command that puts the old state back, or null. Exits 0 unless the task failed (1) or the arguments are wrong (2).\n";

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
        Some("list") if args[1..] == ["--prompts-md"] => {
            print!("{}", prompts_markdown());
            return 0;
        }
        None | Some("list") => no_arguments(&args[args.len().min(1)..])
            .map(|()| Outcome { report: list(), failed: false }),
        Some("status") => no_arguments(&args[1..]).and_then(|()| status(global)),
        Some("trust") => trust::run(&args[1..]),
        Some("machine") => machine::run(&args[1..]),
        Some("harness") => harness::run(&args[1..]),
        Some("mcp") => mcp::run(&args[1..]),
        Some("computer-use" | "computer_use") => computer_use::run(global, &args[1..]),
        Some("cloud-machine" | "cloud_machine") => cloud_machine::run(global, &args[1..]),
        Some("notifications") => notifications::run(global, &args[1..]),
        Some("browser-import" | "browser_import") => browser_import::run(global, &args[1..]),
        Some("tailnet") => tailnet::run(&args[1..]),
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
    /// What the person pastes into Chief (or any agent chat in cmux) to have
    /// the task done: the exact command to run, what to hand the person and
    /// what to reply. Capitals (HOST, FOLDER) are the person's to fill in.
    prompt: &'static str,
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
        prompt: "Trust FOLDER so agents start there without asking: run `cmux setup trust FOLDER` and tell me the undo.",
    },
    Task {
        id: "harness",
        summary: "Install and sign in an agent harness (Claude Code, Codex, OpenCode, Gemini, ...)",
        setup: Some("cmux setup harness [ID ...] [--dry-run]"),
        check: &["cmux setup harness [ID ...]", "cmux harness doctor ID --json"],
        apply: &["cmux harness add ...", "cmux harness login ID"],
        person: Some("the harness's own sign-in (OAuth in a browser) and installing its CLI"),
        prompt: "Check that my agent harnesses (Claude Code, Codex, ...) are installed, signed in and current here: run `cmux setup harness`, start any sign-in it names in a terminal beside this chat, and tell me what to click.",
    },
    Task {
        id: "machine",
        summary: "Add an ssh machine as an agent peer, or update or repair one",
        setup: Some("cmux setup machine SSH_TARGET [--name NAME] [--dry-run]"),
        check: &["cmux setup machine SSH_TARGET --dry-run", "cmux setup status"],
        apply: &["cmux setup machine SSH_TARGET [--name NAME]"],
        person: Some("key-only ssh to the machine: adding a key there or fixing ssh config"),
        prompt: "Add my machine HOST as an agent machine (a Mac on my tailnet such as `studio`, or an ssh host such as `ubuntu@build-1`): run `cmux setup machine HOST`, then run `cmux acp host doctor <name> --json`, where <name> is the `name` that result reports. If ssh refuses, give me the command to try; never ask for my password. Tell me the undo.",
    },
    Task {
        id: "host_update",
        summary: "Update acpmux on peer machines that run an older build",
        setup: None,
        check: &["cmux setup status", "cmux acp host ls --json"],
        apply: &["cmux setup machine SSH_TARGET --name NAME", "cmux acp host update --all --json"],
        person: None,
        prompt: "Something is wrong with my agent machine NAME: run `cmux setup status`, and if it lists NAME as outdated or not connected, run the `fix` it names for NAME only. If NAME still fails, run `cmux acp host doctor NAME --fix --json` and tell me what is left.",
    },
    Task {
        id: "accounts",
        summary: "Sign in to cmux and see each agent provider's sign-in",
        setup: None,
        check: &["cmux accounts list --json"],
        apply: &["cmux cloud sign-in"],
        person: Some("the cmux sign-in in the browser"),
        prompt: "Check my sign-ins: run `cmux accounts list --json`. If I am signed out of cmux, run `cmux cloud sign-in` and tell me to finish it in the browser. Then tell me which agent providers are signed in.",
    },
    Task {
        id: "cloud_machine",
        summary: "Create a cmux Cloud machine",
        setup: Some("cmux setup cloud-machine [--dry-run] [--forget]"),
        check: &["cmux setup cloud-machine --dry-run", "cmux cloud diagnostics"],
        apply: &["cmux setup cloud-machine"],
        person: Some("signing in to cmux, and allowing the new machine on the card cmux shows"),
        prompt: "Make me a cmux Cloud machine. I know it costs money every hour it runs. Run `cmux setup cloud-machine`, tell me which card to click, and tell me the undo.",
    },
    Task {
        id: "tailnet",
        summary: "Serve this machine to the person's other machines over Tailscale",
        setup: Some("cmux setup tailnet [--owner LOGIN] [--dry-run]"),
        check: &[
            "cmux setup tailnet --dry-run",
            "cmux host status --json",
            "cmux host list --json",
        ],
        apply: &["cmux setup tailnet", "cmux host enable --json"],
        person: Some(
            "installing Tailscale, signing in to it (`tailscale up`, a browser sign-in), and an admin approving the device when the tailnet requires it",
        ),
        prompt: "Let my other machines reach this one over Tailscale, for my own Tailscale login only: run `cmux setup tailnet`, tell me the one Tailscale step it names for me (install, start, sign in or approve), and run it again once I have done it. If it asks for my tailnet login, ask me. Tell me the undo.",
    },
    Task {
        id: "phone",
        summary: "Use cmux from an iPhone: pair the cmux iOS app with this Mac",
        setup: None,
        check: &["cmux settings get mobile.allowIPhoneConnections", "cmux accounts list --json"],
        apply: &["cmux cloud open-mobile-pairing"],
        person: Some(
            "turning on iPhone connections on the Mobile Pairing page, installing the cmux iPhone app (TestFlight invite while it is in beta), signing in there with the same cmux account, and allowing the phone on this Mac when it asks",
        ),
        prompt: "Set up the cmux iPhone app with this Mac: run `cmux settings get mobile.allowIPhoneConnections` and `cmux cloud open-mobile-pairing`. If iPhone connections are off, tell me to turn them on there (only I can). Then tell me to install cmux on my iPhone, sign in there with the same cmux account, and allow the phone on this Mac when it asks.",
    },
    Task {
        id: "pairing_ticket",
        summary: "Add another machine with one pasted line (a single-use pairing ticket)",
        setup: None,
        check: &["cmux host ticket ls --json"],
        apply: &["cmux host ticket new --json", "cmux host ticket revoke ID --json"],
        person: Some("pasting the line on the other machine"),
        prompt: "Give me one line to paste on my other machine MACHINE so it can use this one: run `cmux host ticket new --label MACHINE --json` and give me its `install_command` (or its `join_command` when cmux is already installed there). If its `url` starts with ws://, tell me what to forward first. It works once, within 15 minutes; tell me how to revoke it.",
    },
    Task {
        id: "mcp",
        summary: "Give Claude Code and Codex the cmux MCP server outside cmux (chats cmux starts have it)",
        setup: Some("cmux setup mcp [claude|codex ...] [--dry-run]"),
        check: &["cmux setup mcp --dry-run", "cmux agents doctor --json", "cmux mcp tools --json"],
        apply: &["cmux setup mcp"],
        person: Some("turning on \"mcp\": {\"enabled\": true} in the cmux settings file"),
        prompt: "Give Claude Code and Codex outside cmux the cmux MCP server: run `cmux setup mcp`. If it names a setting, give me that one line to turn on; do not edit the file. Tell me the undo.",
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
        prompt: "Let agents use this Mac: run `cmux setup computer-use`, tell me to click Allow on the sheet cmux shows, then open each System Settings pane it names and tell me which switch to turn on.",
    },
    Task {
        id: "browser_import",
        summary: "Bring bookmarks, cookies, history and passwords from another browser",
        setup: Some(
            "cmux setup browser-import --browser BROWSER[:PROFILE] [--cookies [--domain D] [--reason TEXT]] [--dry-run]",
        ),
        check: &["cmux setup browser-import --browser BROWSER --dry-run", "cmux bookmark list"],
        apply: &[
            "cmux setup browser-import --browser BROWSER",
            "cmux setup browser-import --browser BROWSER --cookies --domain DOMAIN --reason REASON",
        ],
        person: Some(
            "allowing the cookie import on the panel cmux shows and the Keychain prompt; history and password import (Import from Browser...)",
        ),
        prompt: "Bring my bookmarks over from BROWSER: run `cmux setup browser-import --browser BROWSER` and tell me the undo. Leave my cookies alone unless I ask.",
    },
    Task {
        id: "keyboard_shortcuts",
        summary: "Read and change key bindings",
        setup: None,
        check: &["cmux keybinding list --json", "cmux keybinding resolve KEYS --json"],
        apply: &["cmux settings keyboard-shortcuts"],
        person: None,
        prompt: "Show me my cmux key bindings: run `cmux keybinding list --json` and list them; to see what one chord does, run `cmux keybinding resolve KEYS --json`.",
    },
    Task {
        id: "notifications",
        summary: "Let cmux show macOS notifications; choose which show, and mute a workspace",
        setup: Some("cmux setup notifications [--dry-run]"),
        check: &["cmux setup notifications --dry-run", "cmux settings get notifications"],
        apply: &["cmux setup notifications", "cmux settings set notifications.KEY VALUE"],
        person: Some(
            "allowing notifications on the macOS prompt, or turning them on in System Settings > Notifications once denied",
        ),
        prompt: "Let cmux show me notifications: run `cmux setup notifications`, then tell me to click Allow on the macOS prompt, or open the System Settings page it names and tell me what to turn on.",
    },
    Task {
        id: "team_invites",
        summary: "Invite people to a cmux team, or to a Home conversation",
        setup: None,
        check: &[],
        apply: &["cmux home invite --email EMAIL"],
        person: Some("team invites from the web dashboard (Teams > Members)"),
        prompt: "Invite EMAIL to this Home conversation: once I confirm the address, run `cmux home invite --email EMAIL`. Team invites I send myself from the web dashboard (Teams > Members).",
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
                "prompt": task.prompt,
            })
        })
        .collect::<Vec<_>>();
    json!({"schema_version": 1, "status_prompt": STATUS_PROMPT, "tasks": tasks})
}

/// The prompt that sets up this Mac: `cmux setup status` and the fix of
/// each check it names.
const STATUS_PROMPT: &str = "Set up this Mac for agents: run `cmux setup status`, then run the `fix` it names for the harness, MCP and folder trust checks only. For the Cloud machine, Tailscale and other machines, list what it found and ask me before you change anything. Keep each undo, and tell me only what I must do myself.";

/// docs/chief-setup-prompts.md: every prompt as a copyable block, made from
/// [`TASKS`] (`cmux setup list --prompts-md`).
fn prompts_markdown() -> String {
    let mut page = String::from(
        "# Set up cmux with Chief\n\n\
         <!-- Generated by `cmux setup list --prompts-md` from `TASKS` in \
         cmux-tui/crates/cmux-tui/src/cli/setup.rs; a test fails when they differ. -->\n\n\
         Paste one of these into Chief, or any agent chat in cmux. Each one runs a \
         `cmux setup` task: the agent does every step it can and tells you only what you \
         must do yourself. Replace the words in capitals (HOST, FOLDER, ...) first.\n",
    );
    let block = |page: &mut String, title: &str, prompt: &str| {
        page.push_str(&format!("\n## {title}\n\n```text\n{prompt}\n```\n"));
    };
    block(&mut page, "Set up this Mac", STATUS_PROMPT);
    for task in TASKS {
        block(&mut page, task.summary, task.prompt);
        if let Some(person) = task.person {
            page.push_str(&format!("\nWhat only you can do: {person}.\n"));
        }
    }
    page
}

/// The read-only check of every task `setup` runs: this folder's trust,
/// every acpmux peer with whether it is connected and on this build, every
/// harness with whether it is installed, signed in and current, whether
/// Claude Code and Codex outside cmux have the cmux MCP server, whether
/// agents can use the Mac (Computer Use and its macOS grants), the Cloud
/// machine setup created, whether macOS lets cmux show notifications, and
/// which browsers' bookmarks are imported.
fn status(global: &GlobalArgs) -> Result<Outcome, Refusal> {
    let checks = [
        trust::status()?,
        machine::status()?,
        harness::status(),
        mcp::status(),
        computer_use::status(global),
        cloud_machine::status(global),
        notifications::status(global),
        browser_import::status(global),
        tailnet::status(),
    ];
    Ok(Outcome { report: json!({"schema_version": 1, "checks": checks}), failed: false })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The words of a command before its first argument: `cmux setup
    /// machine` of `cmux setup machine SSH_TARGET [--name NAME]`.
    fn command_words(command: &str) -> String {
        command
            .split_whitespace()
            .take_while(|word| word.chars().all(|c| c.is_ascii_lowercase() || c == '-'))
            .take_while(|word| !word.starts_with('-'))
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Every task has a Chief prompt, and the prompt names, in backticks,
    /// the command that does the task: its `cmux setup` command when setup
    /// runs it, else one of its check or apply commands.
    #[test]
    fn chief_prompt_on_every_task_names_its_command() {
        assert!(STATUS_PROMPT.contains("`cmux setup status`"), "{STATUS_PROMPT:?}");
        for task in TASKS {
            assert!(!task.prompt.trim().is_empty(), "{} has no prompt", task.id);
            assert!(!task.prompt.contains('\n'), "{}: one paragraph", task.id);
            let commands = match task.setup {
                Some(setup) => vec![setup],
                None => task.check.iter().chain(task.apply).copied().collect(),
            };
            assert!(
                commands.iter().any(|command| {
                    let words = command_words(command);
                    words.split(' ').count() >= 3 && task.prompt.contains(&format!("`{words}"))
                }),
                "{}: prompt {:?} names none of {commands:?}",
                task.id,
                task.prompt
            );
        }
    }

    /// The generated page has one block per task, each with its prompt.
    #[test]
    fn chief_prompt_markdown_has_a_block_per_task() {
        let page = prompts_markdown();
        assert!(page.starts_with("# "), "{page}");
        assert!(page.contains(STATUS_PROMPT));
        for task in TASKS {
            assert!(page.contains(&format!("```text\n{}\n```", task.prompt)), "{}", task.id);
        }
    }
}
