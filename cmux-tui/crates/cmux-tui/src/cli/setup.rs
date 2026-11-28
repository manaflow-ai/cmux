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
mod cmux_serve;
mod computer_use;
mod harness;
mod machine;
mod mcp;
mod notifications;
mod repo;
mod tailnet;
mod trust;

const HELP: &str = "Usage: cmux setup <list|status|local|trust|machine|harness|mcp|computer-use|cloud-machine|notifications|browser-import|tailnet>\n\nSet up cmux for the person, from an agent. Every command prints one JSON object (but `list --prompts-md`, which prints Markdown).\n\n  cmux setup list [--prompts-md]  Every setup task, the commands that check and do it, and the prompt a person pastes into Chief to have it done (--prompts-md: the prompts as Markdown, docs/chief-setup-prompts.md)\n  cmux setup status               Read-only checks of the tasks setup runs\n  cmux setup local [--dry-run]    One safe local pass: trust this folder, inspect harnesses, and report the cmux MCP server\n  cmux setup trust [FOLDER] [--level trusted|untrusted|unknown] [--dry-run]\n                                  Record the person's trust for a folder (default: this folder, trusted)\n  cmux setup machine SSH_TARGET [--name NAME] [--dry-run]\n                                  Add an ssh machine as an agent peer, or update or repair it (key-only ssh)\n  cmux setup harness [ID ...] [--dry-run]\n                                  Check that each harness is installed, signed in and current (default: every configured or found one)\n  cmux setup mcp [claude|codex ...]\n                                  Which coding agents cmux gives its MCP server when it starts them (agents.cmuxMcp), and the lines a person runs to use it elsewhere; writes nothing\n  cmux setup computer-use [--dry-run]\n                                  Turn on cmux Computer Use (the person allows it in cmux) and name the macOS grants it still needs\n  cmux setup cloud-machine [--dry-run] [--forget]\n                                  Have a cmux Cloud machine; create one if there is none (the person allows it in cmux; it costs money while it runs). --forget drops setup's record of the machine it asked for\n  cmux setup notifications [--dry-run]\n                                  Let cmux show macOS notifications (the person allows them on the macOS prompt)\n  cmux setup browser-import [--browser BROWSER[:PROFILE]] [--cookies [--domain D] [--reason TEXT]] [--dry-run]\n                                  Import another browser's bookmarks, or with --cookies its sign-ins (the person allows it in cmux)\n  cmux setup tailnet [--owner LOGIN] [--dry-run]\n                                  Serve this machine to the person's other machines over Tailscale (cmux host enable); names the Tailscale step the person still needs\n\nA task result is {schema_version, task, state, dry_run, ..., undo, user_action}. state is ok (nothing to do), changed, planned (--dry-run), needs_user (user_action says what the person must do), failed, or not_applicable (nothing to set up on this machine). undo is the command that puts the old state back, or null. Exits 0 unless the task failed (1) or the arguments are wrong (2).\n\nA whole customization from a git repo (a setup repo, cmux-setup.json at its root):\n  cmux setup install HOST/OWNER/REPO[@REF] [--yes] | update [REPO] | remove [REPO] | installed | gallery | preview ID [--scheme light|dark] | export DIR --id OWNER/NAME | check DIR [--strict]\n                                  `cmux setup install --help` says more\n";

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
    // A setup repo's verbs speak to the person too (a consent card), so
    // they keep the output the caller asked for.
    if command_args.get(1).is_some_and(|verb| repo::VERBS.contains(&verb.as_str())) {
        return Some(repo::run(&global, command_args.get(1..).unwrap_or_default()));
    }
    if global.output == OutputMode::Human {
        global.output = OutputMode::Json;
    }
    Some(run(&global, command_args.get(1..).unwrap_or_default()))
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
/// This deliberately stops at the local folder, harness health, and the cmux
/// MCP report (it writes no agent config). Cloud machines, tailnet peers, and other external resources
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
        summary: "Check and recover cmux and agent-provider sign-ins",
        setup: None,
        check: &["cmux accounts list --json"],
        apply: &["cmux login"],
        person: Some("the cmux sign-in in the browser"),
        prompt: "Check and recover my sign-ins: run `cmux accounts list --json`. If cmux is signed out, run `cmux login` and tell me to finish it in the browser; if the command or browser reports offline or Cloud unavailable, stop and tell me to get back online. If a provider is missing or expired, open Settings > Accounts and use Sign In or Re-authenticate (or run `cmux accounts reauth --provider PROVIDER`), then run the list again. If I picked the wrong cmux account, use Switch Account in Settings > Accounts and verify the masked account; if a saved key is missing or unreadable, use Add Key there and save or send it without printing the secret. Tell me which providers remain unavailable and never claim an unknown or Keychain-backed sign-in is valid. These are cmux and CodeRouter sign-ins: a model for Cloud chats is connected in Settings > Cloud (`cmux://settings/cloud`), not here.",
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
    // Leo, 2026-11-20: "you say there's a copy pastable command that you can just get to your
    // agents? Like, people love that shit." The first Cloud chat and its follow-up, with the
    // CLI the composer's Cloud start shares (chat_start.rs, chat_send.rs).
    Task {
        id: "cloud_chat",
        summary: "Start a chat on cmux Cloud and send it a follow-up",
        setup: None,
        check: &[
            "cmux whoami",
            "cmux cloud diagnostics",
            "cmux vm ls",
            "cmux cloud connections --json",
        ],
        apply: &[
            "cmux login",
            "cmux cloud connect claude",
            "cmux cloud connect chatgpt",
            "cmux cloud connect api-key --provider anthropic|openai",
            "cmux chat --on vm --prompt TEXT --wait --json",
            "cmux chat send SESSION_ID TEXT --wait",
            "open cmux://settings/cloud/claude",
        ],
        person: Some(
            "signing in to cmux in the browser, picking a Cloud plan, and connecting a model in Settings > Cloud (Claude setup token, ChatGPT or an API key; `cmux://settings/cloud/claude`) when the team shares none",
        ),
        prompt: "Start me a chat on cmux Cloud and show me it works: run `cmux whoami`; if I am signed out, run `cmux login` and wait while I finish it in the browser. Then run `cmux chat --on vm --harness HARNESS --prompt 'Say hello in one sentence.' --wait --json` (HARNESS is claude or codex) and show me its reply, then `cmux chat send SESSION_ID 'Say it once more, shorter.' --wait` with the answer's session_id. If a start is refused for a model connection, run `cmux cloud connections`: when none of them serves Cloud, open `cmux://settings/cloud/claude` (Settings > Cloud; `/cloud/chatgpt` or `/cloud/api-key` for those), or connect from here with `cmux cloud connect claude` (I open its link and paste the code back) or `cmux cloud connect chatgpt` (I open its link in a browser on this Mac); not `cmux accounts`, which is CodeRouter. Then start again. If it is refused for a Cloud plan or GitHub, tell me the one card or Settings page that fixes it and run it again once I have. Tell me how long each step took, and that `cmux vm pause NAME` or `cmux vm rm NAME --yes` stops the machine.",
    },
    Task {
        id: "cloud_session",
        summary: "Work in cmux Cloud: start an agent there, move a chat over and bring it back",
        setup: None,
        check: &["cmux cloud diagnostics", "cmux cloud list-machines"],
        apply: &[
            "cmux cloud start-session --target machine:ID --agent AGENT --from-folder FOLDER",
            "cmux cloud move",
            "cmux cloud bring-back",
        ],
        person: Some(
            "signing in to cmux in the browser, and saying yes to a machine that costs money",
        ),
        prompt: "Get me working in cmux Cloud from this folder: run `cmux cloud diagnostics`; if it says I am signed out, run `cmux login` and tell me to finish it in the browser. Run `cmux cloud list-machines`; if I have none, run `cmux setup cloud-machine` and tell me which card to click (it costs money every hour it runs). Then run `cmux cloud start-session --target machine:<id> --agent AGENT --from-folder .` with that machine's id from the list (or the one you just made), and give me the chat it opens. To move a chat I already have, run `cmux cloud move` in it; to bring it back to this Mac, `cmux cloud bring-back`. If a step fails, show me its error and what it needs from me; never guess.",
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
            "installing the cmux iPhone app, signing in there with the same cmux account, and allowing the phone on this Mac when it asks (or turning on Approve Phone Requests Automatically in Settings > Accounts > iPhone)",
        ),
        prompt: "Set up the cmux iPhone app with this Mac and get me to a working agent on it: run `cmux settings get mobile.allowIPhoneConnections` and `cmux cloud open-mobile-pairing` (it opens Settings > Accounts > iPhone). iPhone connections are on by default; if they are off, tell me to turn them on there (only I can). Then tell me to install cmux on my iPhone and sign in there with the same cmux account: this Mac shows up on the phone by itself, and I allow the phone on this Mac when it asks. When I say the phone is paired, run `cmux chat --on vm --harness claude --prompt 'Say hello in one sentence.' --wait --json`, show me its reply, and tell me to open that chat on the phone and send it one message. Then read the chat and show me the agent's answer to what I sent.",
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
        summary: "Give agents you start in cmux the cmux MCP server (its terminals, agent chats and the Chief)",
        setup: Some("cmux setup mcp [claude|codex ...]"),
        check: &["cmux setup mcp", "cmux agents doctor --json", "cmux mcp tools --json"],
        apply: &["cmux settings set agents.cmuxMcp on --confirm"],
        person: Some(
            "turning cmux Tools for agents on or off in Settings > Agents (agents.cmuxMcp, on by default), and running the report's manual lines yourself to use cmux's tools in agents started elsewhere",
        ),
        prompt: "Tell me whether agents I start in cmux get cmux's MCP tools: run `cmux setup mcp`. If it names a setting, give me that one line to turn on; do not edit the file. If I want cmux's tools in agents started outside cmux, show me its manual lines to run myself; do not run them.",
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
/// agents cmux starts get the cmux MCP server, whether
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
#[path = "setup_tests.rs"]
mod tests;
