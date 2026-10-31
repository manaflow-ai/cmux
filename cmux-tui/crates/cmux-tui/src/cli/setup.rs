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
use cmux_json::JsonSet as _;

mod browser_import;
mod cloud_machine;
mod computer_use;
mod harness;
mod machine;
mod mcp;
mod notifications;
mod tailnet;
mod trust;

const HELP: &str = "Usage: cmux setup <list|status|local|trust|machine|harness|mcp|computer-use|cloud-machine|notifications|browser-import|tailnet>\n\nSet up cmux for the person, from an agent. Every command prints one JSON object (but `list --prompts-md`, which prints Markdown).\n\n  cmux setup list [--prompts-md]  Every setup task, the commands that check and do it, and the prompt a person pastes into Chief to have it done (--prompts-md: the prompts as Markdown, docs/chief-setup-prompts.md)\n  cmux setup status               Read-only checks of the tasks setup runs\n  cmux setup local [--dry-run]    One safe local pass: trust this folder, inspect harnesses, and wire the cmux MCP server\n  cmux setup trust [FOLDER] [--level trusted|untrusted|unknown] [--dry-run]\n                                  Record the person's trust for a folder (default: this folder, trusted)\n  cmux setup machine SSH_TARGET [--name NAME] [--dry-run]\n                                  Add an ssh machine as an agent peer, or update or repair it (key-only ssh)\n  cmux setup harness [ID ...] [--dry-run]\n                                  Check that each harness is installed, signed in and current (default: every configured or found one)\n  cmux setup mcp [claude|codex ...] [--dry-run]\n                                  Give Claude Code and Codex outside cmux the cmux MCP server (default: each installed one)\n  cmux setup computer-use [--dry-run]\n                                  Turn on cmux Computer Use (the person allows it in cmux) and name the macOS grants it still needs\n  cmux setup cloud-machine [--dry-run] [--forget]\n                                  Have a cmux Cloud machine; create one if there is none (the person allows it in cmux; it costs money while it runs). --forget drops setup's record of the machine it asked for\n  cmux setup notifications [--dry-run]\n                                  Let cmux show macOS notifications (the person allows them on the macOS prompt)\n  cmux setup browser-import [--browser BROWSER[:PROFILE]] [--cookies [--domain D] [--reason TEXT]] [--dry-run]\n                                  Import another browser's bookmarks, or with --cookies its sign-ins (the person allows it in cmux)\n  cmux setup tailnet [--owner LOGIN] [--dry-run]\n                                  Serve this machine to the person's other machines over Tailscale (cmux host enable); names the Tailscale step the person still needs\n\nA task result is {schema_version, task, state, dry_run, ..., undo, user_action}. state is ok (nothing to do), changed, planned (--dry-run), needs_user (user_action says what the person must do), failed, or not_applicable (nothing to set up on this machine). undo is the command that puts the old state back, or null. Exits 0 unless the task failed (1) or the arguments are wrong (2).\n";

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
    let after_verb = args.get(1..).unwrap_or_default();
    let result = match args.first().map(String::as_str) {
        Some("list") if after_verb == ["--prompts-md"] => {
            print!("{}", prompts_markdown());
            return 0;
        }
        None | Some("list") => {
            no_arguments(after_verb).map(|()| Outcome { report: list(), failed: false })
        }
        Some("status") => no_arguments(after_verb).and_then(|()| status(global)),
        Some("local") => local(after_verb),
        Some("trust") => trust::run(after_verb),
        Some("machine") => machine::run(after_verb),
        Some("harness") => harness::run(after_verb),
        Some("mcp") => mcp::run(after_verb),
        Some("computer-use" | "computer_use") => computer_use::run(global, after_verb),
        Some("cloud-machine" | "cloud_machine") => cloud_machine::run(global, after_verb),
        Some("notifications") => notifications::run(global, after_verb),
        Some("browser-import" | "browser_import") => browser_import::run(global, after_verb),
        Some("tailnet") => tailnet::run(after_verb),
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

/// Runs the local first-chat prerequisites as one explicit, idempotent pass.
///
/// This deliberately stops at the local folder, harness health, and optional
/// MCP wiring. Cloud machines, tailnet peers, and other external resources
/// remain separate setup tasks because they need a person's approval or can
/// incur cost. Each child task keeps its own report and undo command so Chief
/// can explain exactly what changed and recover it without a second status
/// round trip.
fn local(args: &[String]) -> Result<Outcome, Refusal> {
    if let Some(arg) = args.iter().find(|arg| arg.as_str() != "--dry-run") {
        return Err(Refusal::Usage(format!("cmux: setup local: unknown option {arg:?}")));
    }

    // Every child runs and reports, even when an earlier one is refused, so a
    // trust change already made still comes back with its undo.
    let children =
        [("trust", trust::run(args)), ("harness", harness::run(args)), ("mcp", mcp::run(args))];
    let mut failed = false;
    let mut reports = Vec::with_capacity(children.len());
    for (task, result) in children {
        match result {
            Ok(outcome) => {
                failed |= outcome.failed;
                reports.push(outcome.report);
            }
            Err(Refusal::Usage(error) | Refusal::Failed(error)) => {
                failed = true;
                reports.push(json!({"task": task, "state": "failed", "error": error}));
            }
        }
    }

    let state = if failed {
        "failed"
    } else if reports.iter().any(|report| report["state"] == "needs_user") {
        "needs_user"
    } else if reports.iter().any(|report| report["state"] == "planned") {
        "planned"
    } else if reports.iter().any(|report| report["state"] == "changed") {
        "changed"
    } else {
        "ok"
    };
    let user_action = reports
        .iter()
        .find_map(|report| {
            (!report["user_action"].is_null()).then(|| report["user_action"].clone())
        })
        .unwrap_or(Value::Null);
    let undo = reports
        .iter()
        .filter_map(|report| report["undo"].as_str())
        .filter(|command| !command.is_empty())
        .map(str::to_owned)
        .collect::<Vec<_>>();

    Ok(Outcome {
        report: json!({
            "schema_version": 1,
            "task": "local",
            "state": state,
            "dry_run": args.iter().any(|arg| arg == "--dry-run"),
            "tasks": reports,
            "undo": (!undo.is_empty()).then(|| undo.join(" && ")),
            "user_action": user_action,
        }),
        failed,
    })
}

fn no_arguments(args: &[String]) -> Result<(), Refusal> {
    match args.first() {
        None => Ok(()),
        Some(arg) => Err(Refusal::Usage(format!("cmux: setup: unexpected argument {arg:?}"))),
    }
}

/// Concise human instructions in the same manifest agents read.
#[derive(serde::Serialize)]
struct HumanGuide {
    title: &'static str,
    steps: &'static [&'static str],
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
    /// Human instructions, also bundled into Help > Setup Guide and its documentation.
    guide: Option<HumanGuide>,
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
        guide: None,
    },
    Task {
        id: "harness",
        summary: "Install and sign in an agent harness (Claude Code, Codex, OpenCode, Gemini, ...)",
        setup: Some("cmux setup harness [ID ...] [--dry-run]"),
        check: &["cmux setup harness [ID ...]", "cmux harness doctor ID --json"],
        apply: &["cmux harness add ...", "cmux harness login ID"],
        person: Some("the harness's own sign-in (OAuth in a browser) and installing its CLI"),
        prompt: "Check that my agent harnesses (Claude Code, Codex, ...) are installed, signed in and current here: run `cmux setup harness`, start any sign-in it names in a terminal beside this chat, and tell me what to click.",
        guide: Some(HumanGuide {
            title: "Start an agent on this Mac",
            steps: &[
                "Open the model picker and choose + to see Harnesses. Install a provider, then use Sign In and finish its browser or terminal instructions.",
                "Run cmux setup harness to check the result. Follow the recovery it reports for that profile; unknown sign-in evidence does not confirm a working account.",
            ],
        }),
    },
    Task {
        id: "machine",
        summary: "Add an ssh machine as an agent peer, or update or repair one",
        setup: Some("cmux setup machine SSH_TARGET [--name NAME] [--dry-run]"),
        check: &["cmux setup machine SSH_TARGET --dry-run", "cmux setup status"],
        apply: &["cmux setup machine SSH_TARGET [--name NAME]"],
        person: Some("key-only ssh to the machine: adding a key there or fixing ssh config"),
        prompt: "Add my machine HOST as an agent machine (a Mac on my tailnet such as `studio`, or an ssh host such as `ubuntu@build-1`): run `cmux setup machine HOST`, then run `cmux acp host doctor <name> --json`, where <name> is the `name` that result reports. If ssh refuses, give me the command to try; never ask for my password. Tell me the undo.",
        guide: None,
    },
    Task {
        id: "host_update",
        summary: "Update acpmux on peer machines that run an older build",
        setup: None,
        check: &["cmux setup status", "cmux acp host ls --json"],
        apply: &["cmux setup machine SSH_TARGET --name NAME", "cmux acp host update --all --json"],
        person: None,
        prompt: "Something is wrong with my agent machine NAME: run `cmux setup status`, and if it lists NAME as outdated or not connected, run the `fix` it names for NAME only. If NAME still fails, run `cmux acp host doctor NAME --fix --json` and tell me what is left.",
        guide: None,
    },
    Task {
        id: "accounts",
        summary: "Check and recover cmux and agent-provider sign-ins",
        setup: None,
        check: &["cmux accounts list --json"],
        apply: &["cmux cloud sign-in"],
        person: Some("the cmux sign-in in the browser"),
        prompt: "Check and recover my sign-ins: run `cmux accounts list --json`. If cmux is signed out, run `cmux cloud sign-in` and tell me to finish it in the browser; if the command or browser reports offline or Cloud unavailable, stop and tell me to reconnect before retrying. If a provider is missing or expired, open Settings > Accounts and use Sign In or Re-authenticate (or run `cmux accounts reauth --provider PROVIDER`), then run the list again. If I picked the wrong cmux account, use Switch Account in Settings > Accounts and verify the masked account; if a saved key is missing or unreadable, use Add Key there and save or send it without printing the secret. Tell me which providers remain unavailable and never claim an unknown or Keychain-backed sign-in is valid.",
        guide: Some(HumanGuide {
            title: "Recover a sign-in",
            steps: &[
                "Open Settings > Accounts. Use Sign In for a missing provider or Re-authenticate for an expired one, then check again.",
                "For the wrong cmux account, use Switch Account and check the masked address. For a missing or unreadable saved key, use Add Key; never paste the secret into a chat.",
                "If the command or browser reports offline, reconnect before retrying. If Cloud is unavailable, retry when the service returns; local work can continue.",
            ],
        }),
    },
    Task {
        id: "cloud_machine",
        summary: "Create a cmux Cloud machine",
        setup: Some("cmux setup cloud-machine [--dry-run] [--forget]"),
        check: &["cmux setup cloud-machine --dry-run", "cmux cloud diagnostics"],
        apply: &["cmux setup cloud-machine"],
        person: Some("signing in to cmux, and allowing the new machine on the card cmux shows"),
        prompt: "Make me a cmux Cloud machine. I know it costs money every hour it runs. Run `cmux setup cloud-machine`, tell me which card to click, and tell me the undo.",
        guide: Some(HumanGuide {
            title: "Use another machine",
            steps: &[
                "For a Cloud machine, sign in to cmux, then preview with cmux setup cloud-machine --dry-run. To proceed, run cmux setup cloud-machine without --dry-run. Creating a machine costs money; confirm the request only when you want it.",
                "For an existing SSH machine, run cmux setup machine HOST. If the connection fails, use the SSH command it reports. Do not enter a password into an agent chat.",
                "Run cmux setup status for the current checks and recovery steps. A detected credential is not proof that it is valid or belongs to the intended account.",
            ],
        }),
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
        guide: None,
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
        guide: None,
    },
    Task {
        id: "pairing_ticket",
        summary: "Add another machine with one pasted line (a single-use pairing ticket)",
        setup: None,
        check: &["cmux host ticket ls --json"],
        apply: &["cmux host ticket new --json", "cmux host ticket revoke ID --json"],
        person: Some("pasting the line on the other machine"),
        prompt: "Give me one line to paste on my other machine MACHINE so it can use this one: run `cmux host ticket new --label MACHINE --json` and give me its `install_command` (or its `join_command` when cmux is already installed there). If its `url` starts with ws://, tell me what to forward first. It works once, within 15 minutes; tell me how to revoke it.",
        guide: None,
    },
    Task {
        id: "mcp",
        summary: "Give Claude Code and Codex the cmux MCP server outside cmux (chats cmux starts have it)",
        setup: Some("cmux setup mcp [claude|codex ...] [--dry-run]"),
        check: &["cmux setup mcp --dry-run", "cmux agents doctor --json", "cmux mcp tools --json"],
        apply: &["cmux setup mcp"],
        person: Some("turning on \"mcp\": {\"enabled\": true} in the cmux settings file"),
        prompt: "Give Claude Code and Codex outside cmux the cmux MCP server: run `cmux setup mcp`. If it names a setting, give me that one line to turn on; do not edit the file. Tell me the undo.",
        guide: None,
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
        guide: None,
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
        guide: None,
    },
    Task {
        id: "keyboard_shortcuts",
        summary: "Read and change key bindings",
        setup: None,
        check: &["cmux keybinding list --json", "cmux keybinding resolve KEYS --json"],
        apply: &["cmux settings keyboard-shortcuts"],
        person: None,
        prompt: "Show me my cmux key bindings: run `cmux keybinding list --json` and list them; to see what one chord does, run `cmux keybinding resolve KEYS --json`.",
        guide: None,
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
        guide: None,
    },
    Task {
        id: "team_invites",
        summary: "Invite people to a cmux team, or to a Home conversation",
        setup: None,
        check: &[],
        apply: &["cmux home invite --email EMAIL"],
        person: Some("team invites from the web dashboard (Teams > Members)"),
        prompt: "Invite EMAIL to this Home conversation: once I confirm the address, run `cmux home invite --email EMAIL`. Team invites I send myself from the web dashboard (Teams > Members).",
        guide: None,
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
                "guide": task.guide,
            })
        })
        .collect::<Vec<_>>();
    json!({"schema_version": 1, "status_prompt": STATUS_PROMPT, "tasks": tasks})
}

/// The prompt that sets up this Mac with one safe local pass.
const STATUS_PROMPT: &str = "Set up this Mac for agents: run `cmux setup local`, which trusts this folder, checks the harnesses, and wires the cmux MCP server when its setting is already enabled. For the Cloud machine, Tailscale and other machines, list what you find and ask me before you change anything. Keep each undo, and tell me only what I must do myself.";

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
    ]
    .into_iter()
    .map(enrich_status)
    .collect::<Vec<_>>();
    Ok(Outcome { report: json!({"schema_version": 1, "checks": checks}), failed: false })
}

/// Give every setup check the same agent-facing status and recovery shape while
/// retaining each task's existing fields. Nested peer/client fixes are folded
/// into `recovery`, so a failing matrix cell always has an exact command.
fn enrich_status(mut check: Value) -> Value {
    let values = recoveries(&check);
    let status = if has_failure(&check) {
        "failed"
    } else {
        match check["state"].as_str() {
            Some("ok" | "not_applicable") => "ok",
            Some("needs_user" | "needs_setup") => "needs_action",
            _ if !values.is_empty() => "needs_action",
            _ => "ok",
        }
    };
    let recovery = match values.as_slice() {
        [] => Value::Null,
        [one] => one.clone(),
        many => Value::Array(many.to_vec()),
    };
    check.set("check_status", json!(status));
    check.set("recovery", recovery);
    check
}

fn has_failure(value: &Value) -> bool {
    match value {
        Value::Object(map) => {
            map.get("state").and_then(Value::as_str) == Some("failed")
                || map.get("error").is_some_and(|error| {
                    !error.is_null() && error.as_str().is_some_and(|text| !text.is_empty())
                })
                || map.values().any(has_failure)
        }
        Value::Array(values) => values.iter().any(has_failure),
        _ => false,
    }
}

fn recoveries(value: &Value) -> Vec<Value> {
    fn visit(value: &Value, found: &mut Vec<Value>) {
        match value {
            Value::Object(map) => {
                if let Some(action) = map.get("user_action").filter(|value| !value.is_null()) {
                    push_unique(found, action.clone());
                } else if let Some(fix) = map.get("fix").and_then(Value::as_str) {
                    push_unique(found, json!({"command": fix}));
                }
                for (key, child) in map {
                    if key != "user_action" && key != "fix" {
                        visit(child, found);
                    }
                }
            }
            Value::Array(values) => values.iter().for_each(|value| visit(value, found)),
            _ => {}
        }
    }
    fn push_unique(found: &mut Vec<Value>, value: Value) {
        if !found.iter().any(|existing| existing == &value) {
            found.push(value);
        }
    }
    let mut found = Vec::new();
    visit(value, &mut found);
    found
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
    fn status_checks_have_typed_recovery_without_losing_task_fields() {
        let matrix = [
            ("trust", "needs_setup", "needs_action"),
            ("machine", "needs_user", "needs_action"),
            ("harness", "needs_user", "needs_action"),
            ("mcp", "failed", "failed"),
            ("computer_use", "not_applicable", "ok"),
            ("cloud_machine", "ok", "ok"),
            ("notifications", "needs_user", "needs_action"),
            ("browser_import", "ok", "ok"),
            ("tailnet", "unknown", "needs_action"),
        ];
        for (task, state, expected) in matrix {
            let mut check = json!({"task": task, "state": state});
            if task == "tailnet" {
                check["fix"] = json!("cmux setup tailnet");
            }
            let check = enrich_status(check);
            assert_eq!(check["check_status"], expected, "{task}: {check}");
            assert!(check["task"].is_string(), "{task}: task identity was lost");
        }

        let check = enrich_status(json!({
            "task": "machine",
            "state": "needs_setup",
            "peers": [{"name": "build", "fix": "cmux setup machine build --name build"}],
        }));
        assert_eq!(check["recovery"]["command"], "cmux setup machine build --name build");
        assert_eq!(check["peers"][0]["name"], "build");

        let failed =
            enrich_status(json!({"task": "harness", "state": "failed", "error": "timeout"}));
        assert_eq!(failed["check_status"], "failed");
        assert_eq!(failed["recovery"], Value::Null);

        let multiple = enrich_status(json!({
            "task": "mcp",
            "state": "needs_setup",
            "clients": [{"fix": "cmux setup mcp claude"}, {"fix": "cmux setup mcp codex"}],
        }));
        assert_eq!(multiple["check_status"], "needs_action");
        assert_eq!(multiple["recovery"].as_array().unwrap().len(), 2);

        let nested_failure = enrich_status(json!({
            "task": "mcp",
            "state": "needs_setup",
            "clients": [{"state": "failed", "error": "client timed out"}],
        }));
        assert_eq!(nested_failure["check_status"], "failed");
        assert_eq!(nested_failure["status"], Value::Null);

        let existing = enrich_status(json!({
            "task": "computer_use",
            "state": "needs_user",
            "status": {"phase": "off", "accessibility": false},
        }));
        assert_eq!(existing["check_status"], "needs_action");
        assert_eq!(existing["status"]["phase"], "off");
    }

    #[test]
    fn chief_prompt_on_every_task_names_its_command() {
        assert!(STATUS_PROMPT.contains("`cmux setup local`"), "{STATUS_PROMPT:?}");
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

    /// The offline app guide is a generated projection of the same tasks agents read.
    #[test]
    fn human_guide_matches_the_native_bundle() {
        let bundled: Value = serde_json::from_str(include_str!(
            "../../../../../Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/setup-guide.json"
        ))
        .unwrap();
        let manifest = list();
        let expected = manifest["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|task| {
                let guide = task["guide"].as_object()?;
                Some(json!({"id": task["id"], "title": guide["title"], "steps": guide["steps"]}))
            })
            .collect::<Vec<_>>();
        assert_eq!(bundled, json!(expected));
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

    /// The accounts prompt is the single human recovery path. Keep the
    /// generated prompt useful for the states the Accounts screen exposes,
    /// without teaching agents to claim that an unknown Keychain sign-in is
    /// healthy.
    #[test]
    fn accounts_prompt_names_each_recovery_state() {
        let prompt = TASKS.iter().find(|task| task.id == "accounts").unwrap().prompt;
        for phrase in [
            "cmux accounts list --json",
            "cmux cloud sign-in",
            "command or browser reports offline or Cloud unavailable",
            "missing or expired",
            "cmux accounts reauth --provider PROVIDER",
            "Switch Account",
            "saved key is missing or unreadable",
            "never claim an unknown or Keychain-backed sign-in is valid",
        ] {
            assert!(prompt.contains(phrase), "accounts prompt missing {phrase:?}: {prompt}");
        }
    }
}
