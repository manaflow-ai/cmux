//! `cmux skill show`: the agent guide for this CLI, built by the CLI that
//! runs it, so it never names a command this build does not have.
//!
//! The recipes are data ([`RECIPES`]); the tests run each one through the
//! real parser. The scope table comes from the curated scope list and the
//! root help, and the usage blocks from each scope's own help text. Run in a
//! cmux terminal, the guide starts with the caller's live ids.

use std::fmt::Write as _;
use std::io::Write as _;

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

/// One task as a person asks for it, and the commands that do it.
pub(super) struct Recipe {
    /// The request in the person's words.
    pub ask: &'static str,
    /// Commands, in order. `<term>`, `<pane>`, `<tab>` and `<ws>` stand for
    /// ids an earlier command printed.
    pub commands: &'static [&'static str],
    /// What to read from the output, and what it means.
    pub read: &'static str,
}

pub(super) const RECIPES: &[Recipe] = &[
    Recipe {
        ask: "Where am I? / Which pane is yours?",
        commands: &["cmux --json identify"],
        read: "`caller.workspace`, `caller.screen`, `caller.pane`, `caller.tab`, \
               `caller.terminal_id` are your own ids; `session.name` is the session \
               (`--session` takes it); `caller.found: false` means this terminal is not \
               placed (yet).",
    },
    Recipe {
        ask: "Show me everything that is open / the layout.",
        commands: &["cmux --json session current snapshot"],
        read: "One JSON document: `workspaces`, `screens` (each with its `layout` tree), \
               `panes`, `tabs`, `terminals`, `agents`, `clients`, `notifications`.",
    },
    Recipe {
        ask: "Run the tests beside you and tell me if they pass.",
        commands: &[
            "cmux --json pane current split --right",
            "cmux --json terminal <term> send --text 'npm test' --wait prompt --timeout 10m",
        ],
        read: "split prints the new `value.pane_id` and `value.terminal_id` and keeps the \
               person's focus. send types the line, presses Enter, waits for the next \
               prompt and prints only the new `output`; `timed_out: true` (exit 124) means \
               it still runs. `exit_status` is the command's `$?` (OSC 133, which cmux \
               shells have); it is absent when the shell reports none, never guessed.",
    },
    Recipe {
        ask: "Run this in my shell and give me its exit code.",
        commands: &["cmux --json terminal <term> run --timeout 10m -- npm test"],
        read: "run types the command into the terminal's shell, waits for its next prompt, \
               prints the new `output` and `exit_status`, and exits with that status (124 \
               when the time passed, 125 when the shell reported no status). The words after \
               `--` reach the shell as the same words (`run -- sh -c 'exit 7'` exits 7); one \
               quoted word is a shell line (`run -- 'make && make test'`).",
    },
    Recipe {
        ask: "Run this command and give me its exit code.",
        commands: &[
            "cmux --json pane current run --on-exit keep -- sh -c 'npm test'",
            "cmux --json terminal <term> process wait --timeout-ms 600000",
            "cmux --json terminal <term> history read --limit 200",
        ],
        read: "run opens a new tab in your pane that runs the command as its own process \
               (`value.terminal_id`). process wait prints `outcome.code` (and \
               `outcome.kind`: exit or signal) once it ends. `--on-exit keep` keeps the \
               output readable after the exit.",
    },
    Recipe {
        ask: "Start the dev server and wait until it is ready.",
        commands: &[
            "cmux --json pane current split --down",
            "cmux --json terminal <term> send --text 'npm run dev' --pattern 'ready|listening' --timeout 60s",
        ],
        read: "send types the line and waits until output printed after it matches the \
               regex: `matched: true` (the typed line and older output never match); \
               `matched: false` (exit 1) when the command ended first, `timed_out: true` \
               (exit 124) when the time passed. For a command already running, `screen wait \
               --pattern RE --new` waits in the daemon for output printed after the wait \
               starts.",
    },
    Recipe {
        ask: "What does the pane on the right show?",
        commands: &[
            "cmux --json pane current neighbor right",
            "cmux --json tab list --pane <pane>",
            "cmux --json terminal <term> screen read",
        ],
        read: "neighbor prints `pane.id` (`pane: null` when there is none); each tab's \
               `content_id` is its terminal. screen read prints the visible `text`; \
               `--unwrap` joins the lines the pane wrapped and `--lines N` reads the last N \
               lines of scrollback and screen; `history read` has the rows that scrolled off, \
               `output read --after <offset>` the raw output since an offset.",
    },
    Recipe {
        ask: "Start Claude (or Codex) in a new pane and give it a task.",
        commands: &[
            "cmux --json agent start alpha --cmd 'sr2 claude' --no-focus",
            "cmux --json terminal alpha send --text 'Fix the failing test' --wait idle --timeout 15m",
        ],
        read: "agent start splits your pane (the new pane takes its width only from yours; \
               the agent panes of that row then share their space equally), runs \
               the launcher (--cmd; codex works too) in a tab named alpha and returns once the agent can take a message: `state` \
               `ready` (exit 0) with `terminal_id`, `tab_id`, `pane_id`, or `blocked` \
               (exit 4) with `dialog` (`folder_trust`, `login`, ...), `reason` and the \
               dialog's numbered `options` when a startup dialog waits on the person. Ask the \
               person; then answer with keys: for folder trust, with their consent, run \
               cmux terminal alpha keys plus the result's `accept_keys`, which pick \
               `accept_label` (tell the person when the reason warns that the option also \
               turns approvals off; Enter alone may pick \
               \"No, exit\" and end the agent). The name works \
               wherever a terminal, tab or pane selector goes. send pastes the task, presses \
               Enter, waits until the agent is idle and prints its new `output` and `reply` \
               (the agent's own last message, whole, when its hooks gave it); `state` is \
               `idle`, or `blocked` when it shows a dialog (send refuses to type \
               into a dialog unless --force). cmux adds its hooks to `claude` and `codex` \
               started in a cmux terminal; nothing is written to ~/.claude or ~/.codex.",
    },
    Recipe {
        ask: "Is agent alpha ready? What did it last say?",
        commands: &[
            "cmux --json terminal alpha wait --until ready --timeout 60s",
            "cmux --json terminal list --agents",
            "cmux terminal alpha screen read",
        ],
        read: "wait --until ready: `state` `ready`, or `blocked` with `dialog` and `reason` \
               (exit 4). terminal list --agents: one record per agent with `name`, `harness`, \
               `status` (blocked, working, done, idle, unknown; null when the session \
               ended; `state` is a deprecated alias), `tab_id`, `pane_id` and `last_reply` \
               (the agent's last answer, one line, at most 200 characters). screen read prints the screen as text \
               (--details or --json for the whole record).",
    },
    Recipe {
        ask: "Bring back an agent that exited (same conversation).",
        commands: &[
            "cmux --json agent resume alpha --no-focus",
            "cmux --json terminal <term> resume --split down --no-focus",
        ],
        read: "resume reruns the agent's launcher with its recorded harness session \
               (`claude --resume <id>`, `codex resume <id>`), in the old tab's pane unless \
               --pane or --split say otherwise, closes the exited tab and keeps its name; it \
               waits and answers like agent start, plus `resumed.agent_session_id`. \
               `agent.no_session` means the hooks never reported a session id.",
    },
    Recipe {
        ask: "Is an agent waiting for me? Which agents run here?",
        commands: &[
            "cmux --json terminal list --agents",
            "cmux --json agent list --needs-me",
            "cmux terminal <term> status",
        ],
        read: "terminal list --agents: one record per agent terminal of this session \
               (`name`, `harness`, `status`, `terminal`, `workspace`, `title`). agent list \
               --needs-me: the agents that wait on the person, with the same `name` and \
               `status` words (`state` is a deprecated alias of `status`). status: what the program reports \
               (for a dialog: kind permission, state blocked, msg).",
    },
    Recipe {
        ask: "Tell me when that agent is idle. / Wait until the workspace exists, then go on.",
        commands: &[
            "cmux --json agents events --until agent.state --match state=idle --match terminal_id=<term> --timeout 10m",
            "cmux --json agents events --until workspace.changed --match name=<name> --timeout 30s",
        ],
        read: "--until names the event (agents events: KIND.CHANGE such as agent.state, \
               dialog.opened; events: the app's name; a trailing * is a prefix) and \
               --match PATH=VALUE checks its fields. It prints only that event and exits 0, \
               or `timed_out: true` and exits 124. Start it before the action, or pass \
               --after so events already past count; always pass --timeout.",
    },
    Recipe {
        ask: "Stop it. / Press Ctrl-C. / Answer the dialog with Escape.",
        commands: &["cmux terminal <term> keys ctrl+c", "cmux terminal <term> keys escape"],
        read: "keys sends named keys (`enter`, `escape`, `tab`, `up`, `ctrl+c`, ...). To type \
               text without Enter: `cmux terminal <term> write --text '...'`.",
    },
    Recipe {
        ask: "Find the workspace called api. / Which workspaces are in ~/src/app?",
        commands: &[
            "cmux --json workspace list --name api",
            "cmux --json workspace list --cwd ~/src/app",
            "cmux --json terminal list --cwd ~/src/app",
        ],
        read: "--name keeps exact names (two workspaces may share one, which a `name:api` \
               selector refuses as ambiguous); --cwd keeps the workspaces with a terminal in \
               that folder or below it. No match is `[]`, exit 0. pane list takes both flags.",
    },
    Recipe {
        ask: "Zoom that pane. / Rename this workspace. / Open a new screen called api.",
        commands: &[
            "cmux pane <pane> zoom",
            "cmux pane <pane> zoom --enabled false",
            "cmux workspace current rename api-work",
            "cmux --json screen create --name api",
        ],
        read: "A screen is a tmux window: a full layout of panes in a workspace. A new \
               screen does not move the person's view.",
    },
    Recipe {
        ask: "Move that pane to its own screen. / Put it next to my editor pane.",
        commands: &[
            "cmux --json pane <pane> move --new-screen --name logs",
            "cmux --json pane <pane> move --to-pane <other-pane> --split right",
            "cmux --json pane <pane> move --to-workspace <ws>",
        ],
        read: "move takes every tab of the pane, in order, and the emptied pane closes: \
               `moved_tabs`, `destination.pane` (where they are now), `created` (the new \
               screen or pane, else null). --to-tab <tab> puts them after that tab. The \
               focus stays unless --focus.",
    },
    Recipe {
        ask: "Tell me when you need me.",
        commands: &[
            "cmux attention request --tab <tab> --reason 'Approve the migration'",
            "cmux notify --title 'Tests passed' --body '42 passed'",
            "cmux attention clear --tab <tab>",
        ],
        read: "attention marks the tab and its workspace in every cmux client without \
               moving focus; notify posts a notification for your terminal.",
    },
    Recipe {
        ask: "Make a worktree for feature-x with a workspace in it; remove both when done.",
        commands: &[
            "cmux --json workspace create --worktree feature-x --repo .",
            "cmux --json workspace <ws> close --remove-worktree",
        ],
        read: "create makes the branch cmux/feature-x in a new git worktree and a workspace \
               whose terminal starts there: `value.workspace_id`, `value.terminal_id` and \
               `worktree.root` (its folder). close removes that worktree and its branch, \
               then closes the workspace; it refuses (closing nothing) while the worktree has \
               uncommitted or unpushed work, unless `--discard`.",
    },
    Recipe {
        ask: "Clean up what you opened.",
        commands: &["cmux pane <pane> close", "cmux tab <tab> close"],
        read: "Close only the panes and tabs you made (their ids came from your split, run \
               or create). Never close your own pane, `cmux identify`'s `caller.pane`.",
    },
];

/// `Some(exit code)` for `skill [show]`; `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let (first, rest) = words.split_first()?;
    if first != "skill" {
        return None;
    }
    let messages = &crate::localization::catalog().pane_cli;
    let usage = |code| {
        let text = messages.skill_usage;
        if code == 0 {
            print!("{text}");
        } else {
            eprint!("{text}");
        }
        code
    };
    match rest.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        [] | ["show"] => Some(show(&global)),
        ["--help" | "-h"] | ["show", "--help" | "-h"] => Some(usage(0)),
        _ => Some(usage(2)),
    }
}

fn show(global: &GlobalArgs) -> i32 {
    let markdown = render(&location());
    match global.output {
        OutputMode::Human => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(markdown.as_bytes());
            let _ = stdout.flush();
            0
        }
        output => super::wire::print_local_success(
            &json!({"name": "cmux", "version": version(), "markdown": markdown}),
            output,
        ),
    }
}

/// This build, as `cmux --version` prints it (release, commit, Ghostty).
fn version() -> String {
    crate::version_string()
}

/// The caller's place, as `cmux identify` in a pane prints it.
#[cfg(unix)]
fn location() -> Option<Value> {
    let env = |key: &str| std::env::var(key).ok().filter(|value| !value.trim().is_empty());
    let terminal = env("CMUX_TUI_TERMINAL_ID").filter(|id| id.starts_with("term_"))?;
    let socket = env("CMUX_TUI_SOCKET").or_else(|| env("CMUX_MUX_SOCKET"))?;
    super::pane_identify::read_identity(std::path::Path::new(&socket), &terminal).ok()
}

#[cfg(not(unix))]
fn location() -> Option<Value> {
    None
}

/// The guide, for the caller at `location` (`None`: outside a cmux terminal),
/// with this process's `CMUX_TUI_CLI`.
pub(super) fn render(location: &Option<Value>) -> String {
    let cli = std::env::var("CMUX_TUI_CLI").ok();
    render_with(location, cli.as_deref())
}

/// [`render`] with `pane_cli`, the `CMUX_TUI_CLI` the pane sets.
pub(super) fn render_with(location: &Option<Value>, pane_cli: Option<&str>) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "# cmux: agent guide\n");
    let _ = writeln!(
        out,
        "Generated by `cmux skill show` from cmux {}. The installed `cmux` is the authority: \
         `cmux <scope> --help` prints every path and flag.\n",
        version()
    );
    write_location(&mut out, location, pane_cli);
    out.push_str(RULES);
    out.push_str("\n## Recipes\n\nIDs in angle brackets come from an earlier command's JSON.\n");
    for recipe in RECIPES {
        let _ = writeln!(out, "\n### \"{}\"\n\n```sh", recipe.ask);
        for command in recipe.commands {
            let _ = writeln!(out, "{command}");
        }
        let _ = writeln!(out, "```\n\n{}", recipe.read);
    }
    out.push_str(WAITS_AND_ERRORS);
    write_scopes(&mut out);
    for (title, help) in
        [("terminal", super::TERMINAL_HELP), ("pane", super::PANE_HELP), ("tab", super::TAB_HELP)]
    {
        let _ = writeln!(out, "\n### cmux {title}\n\n```text\n{}```", usage_block(help));
    }
    out
}

fn write_location(out: &mut String, location: &Option<Value>, pane_cli: Option<&str>) {
    out.push_str("## Where you are\n\n");
    let Some(identity) = location else {
        out.push_str(
            "This process does not run in a cmux terminal (`CMUX_TUI_TERMINAL_ID` is not \
             set). `cmux identify` reports what this CLI reaches; `cmux --session NAME ...` \
             names a session.\n\n",
        );
        return;
    };
    let text =
        |pointer: &str| identity.pointer(pointer).and_then(Value::as_str).unwrap_or("-").to_owned();
    // `"$CMUX_TUI_CLI"` only when the pane set it to an absolute path (a
    // pane of an older daemon has none): else it runs `""`.
    if pane_cli.is_some_and(|path| std::path::Path::new(path).is_absolute()) {
        let _ = writeln!(
            out,
            "You run in a cmux terminal. Run this session's own cmux as `\"$CMUX_TUI_CLI\"`: \
             the pane sets it to the absolute path of the session's build, and a `cmux` on PATH \
             can be another, older install. Every `cmux` in this guide means \
             `\"$CMUX_TUI_CLI\"` (for example `\"$CMUX_TUI_CLI\" --json identify`); it talks \
             to this session by default.\n"
        );
    } else {
        out.push_str(
            "You run in a cmux terminal. `cmux` here talks to this session by default.\n\n",
        );
    }
    let _ = writeln!(out, "| object | id |\n| --- | --- |");
    let _ =
        writeln!(out, "| session | `{}` (name `{}`) |", text("/session/id"), text("/session/name"));
    for (label, key) in [
        ("workspace", "workspace"),
        ("screen", "screen"),
        ("pane", "pane"),
        ("tab", "tab"),
        ("terminal", "terminal_id"),
    ] {
        let _ = writeln!(out, "| {label} | `{}` |", text(&format!("/caller/{key}")));
    }
    out.push_str(
        "\nThese ids were live when the guide was printed. Run `cmux --json identify` again \
         after a move.\n\n",
    );
}

const RULES: &str = "\
## Rules

- **Check first.** `cmux --json identify` prints where you run. In a cmux-tui pane it \
answers from the pane's session (`kind: \"cmux-tui\"`), even when that cmux-tui runs inside \
the cmux app; `cmux app identify` asks the app around it (`outer_app`).
- **Targets.** A selector is an id (`ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`), \
`current`, `caller`, or an exact name (`name:` forces a name). Inside a cmux terminal \
`current` and `caller` are your own workspace, screen, pane, tab and terminal, not the one the \
person looks at. For the person's focused pane, name the session: \
`cmux --session <session.name> pane current show` (an explicit route makes `current` the \
focused object).
- **Use ids from JSON.** Pass `--json` and read the ids each command prints. Do not \
guess them from names, order or examples.
- **Words.** The person's \"window\" (tmux window, a TUI tab) is a **screen**; a split is a \
**pane**; a pane holds **tabs**; a tab shows one **terminal** (`term_…`). A **workspace** is a \
sidebar row (a project); a **session** is one cmux-tui daemon with its workspaces.
- **Focus.** Never move the person's focus unless they ask: split, run, create and send keep \
it. Pass `--focus` (or run `cmux pane <pane> focus`) only when they ask to go there.
- **Your own pane.** Do not type into your own terminal and do not close your own pane.
- **Cleanup.** Close only what you created. Never stop the session (`cmux session current \
stop`, `cmux daemon stop`) or restart it unless the person asks: stop ends every terminal.
";

const WAITS_AND_ERRORS: &str = "
## Waits

| wait | returns when | timeout |
| --- | --- | --- |
| `terminal <term> send --text T --wait prompt` | the shell shows its next prompt | `--timeout 5m`, exit 124 |
| `terminal <term> send --text T --wait idle` | the agent or program is idle (screen still for `--settle`) | `--timeout`, exit 124 |
| `terminal <term> send --text T --wait none` | at once, after typing T and Enter | - |
| `terminal <term> run -- CMD` | the shell's next prompt; exits with CMD's `exit_status` | `--timeout 5m`, exit 124 (125: no status) |
| `terminal <term> send --text T --pattern RE` | output after T matches RE (or T ends: exit 1) | `--timeout`, exit 124 |
| `terminal <term> screen wait --pattern RE` | RE matches the screen | `--timeout-ms N`, exit 1 |
| `terminal <term> screen wait --pattern RE --new` | RE matches output printed after the wait starts | `--timeout-ms N`, exit 1 |
| `terminal <term> wait --until prompt\\|idle` | the terminal is at a prompt / idle | `--timeout 30s`, exit 124 |
| `terminal <term> process wait` | the terminal's process exits (`outcome.code`) | `--timeout-ms N` |

`--wait prompt` and `wait --until` need shell integration (OSC 133), which cmux shells have.
A timeout does not stop the command; read the screen before you send more.
A `--pattern` RE is matched line by line: `^` and `$` match at the start and end of each line \
(`--pattern '^BENCH_OK$'`), as in grep. Start it with `(?-m)` to match the whole text.

## Errors and exit codes

Errors are one JSON object on stderr with `--json`: `{\"code\", \"message\", \"details\", \
\"retryable\"}`. Exit codes: 0 done, 1 the operation failed (or `screen wait` found no \
match), 2 usage error (fix the command), 3 cannot reach the session, 124 a wait timed out.
A change that failed with `retryable: true` prints an idempotency key: run it again with \
`--idempotency-key <key>`, which never applies it twice. Before you retry a timed-out \
create, list first: it may have run.
";

/// The curated scopes with the root help's one-line description of each.
fn write_scopes(out: &mut String) {
    let help = crate::localization::catalog_for_locale("en_US.UTF-8").local_server.cmux_root_help;
    out.push_str("\n## Scopes\n\n| scope | what |\n| --- | --- |\n");
    for scope in super::surface::CMUX_SCOPES {
        let description = scope_description(help, scope).unwrap_or_default();
        let _ = writeln!(out, "| `{scope}` | {description} |");
    }
    out.push_str("\nThe app scopes (`app`, `window`, `chat`, `chief`, ...) need the cmux app.\n");
}

/// The description on `scope`'s line of the root help (`  scope   text`).
fn scope_description<'a>(help: &'a str, scope: &str) -> Option<&'a str> {
    help.lines().find_map(|line| {
        let rest = line.strip_prefix("  ")?.strip_prefix(scope)?;
        rest.starts_with("  ").then_some(rest.trim())
    })
}

/// The USAGE block of a scope help text (the lines up to the first blank line).
fn usage_block(help: &str) -> String {
    help.lines()
        .skip_while(|line| line.trim() != "USAGE")
        .skip(1)
        .take_while(|line| !line.trim().is_empty())
        .map(|line| format!("{line}\n"))
        .collect()
}

#[cfg(test)]
#[path = "skill_tests.rs"]
mod tests;
