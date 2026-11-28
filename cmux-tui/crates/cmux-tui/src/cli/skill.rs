//! `cmux skill show`: the agent guide for this CLI, built by the CLI that
//! runs it, so it never names a command this build does not have.
//!
//! The recipes are data ([`RECIPES`]); the tests run each one through the
//! real parser. The scope table comes from the public scope list and the
//! root help, and the usage blocks from each scope's own help text. Run in a
//! cmux-tui terminal, the guide starts with the caller's live ids.

use std::fmt::Write as _;
use std::io::Write as _;
use std::path::Path;

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

/// One task as a person asks for it, and the commands that do it.
pub(super) struct Recipe {
    /// The request in the person's words.
    pub ask: &'static str,
    /// Commands, in order. `<ws>`, `<pane>`, `<new-pane>`, `<tab>` and
    /// `<term>` stand for ids `cmux --json identify` or an earlier command
    /// printed.
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
               (`--session` takes it); `caller.found: false` means this process does not \
               run in a placed cmux-tui terminal.",
    },
    Recipe {
        ask: "Show me everything that is open / the layout.",
        commands: &["cmux --json session current snapshot"],
        read: "One JSON document: `workspaces`, `screens` (each with its `layout` tree), \
               `panes`, `tabs`, `terminals`, `agents`, `notifications`.",
    },
    Recipe {
        ask: "Run this command and give me its exit code.",
        commands: &[
            "cmux --json pane <pane> split --right",
            "cmux --json pane <new-pane> run --on-exit keep -- sh -c 'npm test'",
            "cmux --json terminal <term> process wait --timeout-ms 600000",
            "cmux --json terminal <term> history read --limit 200",
        ],
        read: "Split beside you first (`value.pane_id`): run opens a new tab in the pane it \
               names and shows that tab there, so never run in your own pane. The tab runs \
               the command as its own process (`value.terminal_id`). process wait prints \
               `state: exited` and \
               `outcome.code` (`outcome.kind`: exit or signal) once it ends, or \
               `state: pending` when the time passed. `--on-exit keep` keeps the output \
               readable after the exit.",
    },
    Recipe {
        ask: "Start the dev server beside you and wait until it is ready.",
        commands: &[
            "cmux --json pane <pane> split --right",
            "cmux terminal <term> write --text 'npm run dev'",
            "cmux terminal <term> keys enter",
            "cmux --json terminal <term> screen wait --pattern 'ready|listening' --timeout-ms 60000",
        ],
        read: "split prints the new `value.pane_id` and `value.terminal_id` and keeps the \
               person's focus. write types text without Enter; `keys enter` presses it. \
               screen wait waits in the daemon (no polling) until the regex matches the \
               screen: `matched: true` and the screen `text`; exit 1 when the time passes \
               without a match.",
    },
    Recipe {
        ask: "What does the pane on the right show?",
        commands: &[
            "cmux --json pane <pane> neighbor right",
            "cmux --json pane <pane> tab list",
            "cmux --json terminal <term> screen read",
        ],
        read: "neighbor prints `pane.id` (`pane: null` when there is none); each tab's \
               `content_id` is its terminal. screen read prints the visible `text`; \
               `history read` has the rows that scrolled off, `output read --after <offset>` \
               the raw output since an offset.",
    },
    Recipe {
        ask: "Start Claude (or Codex) in a new pane and give it a task.",
        commands: &[
            "cmux --json agent start alpha --no-focus",
            "cmux terminal alpha write --text 'Fix the failing test'",
            "cmux terminal alpha keys enter",
            "cmux --json agent list",
        ],
        read: "agent start splits your pane, runs claude (or the launcher --cmd names, such \
               as codex) in a \
               tab named alpha and returns once the agent can take a message: `state` \
               `ready` (exit 0) with `terminal_id`, `tab_id`, `pane_id`, or `blocked` \
               (exit 4) with `dialog` (`folder_trust`, `login`, ...) and `reason` when a \
               startup dialog waits on the person; never answer it yourself. The name works \
               wherever a terminal, tab or pane selector goes. cmux adds its hooks to \
               `claude` and `codex` started in a cmux-tui terminal, so `agent list` shows \
               their `status` (working, blocked, done, idle); nothing is written to ~/.claude \
               or ~/.codex. Read the screen before you type into an agent that is \
               `blocked`: typed text answers its dialog.",
    },
    Recipe {
        ask: "Is agent alpha ready? What does it show?",
        commands: &[
            "cmux --json terminal alpha wait --until ready --timeout 60s",
            "cmux terminal alpha screen read",
        ],
        read: "wait --until ready: `state` `ready` (exit 0), or `blocked` with `dialog` and \
               `reason` (exit 4). screen read prints the screen as text (--details or --json \
               for the whole record).",
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
        commands: &["cmux --json agent list", "cmux --json agent list --state blocked"],
        read: "One record per agent terminal of this session (`terminal_id`, `name`, \
               `tab_id`, `pane_id`, `status`, `state`, `source`). `status` is the word the TUI shows: `done` is a finished \
               turn nobody has viewed, `null` a session that ended. `--state blocked` lists \
               the agents that wait on the person; `--state ended` the ended sessions.",
    },
    Recipe {
        ask: "Stop it. / Press Ctrl-C. / Answer the dialog with Escape.",
        commands: &["cmux terminal <term> keys ctrl+c", "cmux terminal <term> keys escape"],
        read: "keys sends named keys (`enter`, `escape`, `tab`, `up`, `ctrl+c`, ...). To type \
               text without Enter: `cmux terminal <term> write --text '...'`.",
    },
    Recipe {
        ask: "Zoom that pane. / Rename this workspace. / Open a new screen called api.",
        commands: &[
            "cmux pane <pane> zoom",
            "cmux pane <pane> zoom --enabled false",
            "cmux workspace <ws> rename --name api-work",
            "cmux --json workspace <ws> screen create --name api",
        ],
        read: "A screen is a tmux window: a full layout of panes in a workspace. A new \
               screen does not move the person's view unless --focus.",
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
        commands: &["cmux notify --title 'Tests passed' --body '42 passed'"],
        read: "notify posts a notification for your terminal: an unread mark on its tab and \
               workspace in every cmux client, without moving focus.",
    },
    Recipe {
        ask: "Clean up what you opened.",
        commands: &["cmux pane <pane> close", "cmux tab <tab> close"],
        read: "Close only the panes and tabs you made (their ids came from your split, run \
               or create). Never close your own pane, `cmux identify`'s `caller.pane`.",
    },
];

/// `skill show` without its help (`cli.rs` routes `--help` to the help
/// topic).
pub(super) fn run(global: &GlobalArgs) -> i32 {
    let cli = std::env::current_exe().ok().map(|path| path.canonicalize().unwrap_or(path));
    let markdown = render(&location(global), cli.as_deref());
    match global.output {
        OutputMode::Human => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(markdown.as_bytes());
            let _ = stdout.flush();
            0
        }
        output => super::wire::print_local_success(
            &json!({"name": "cmux", "version": crate::version_string(), "markdown": markdown}),
            output,
        ),
    }
}

/// The caller's place, as `cmux identify` prints it, when this process runs
/// in a placed cmux-tui terminal.
fn location(global: &GlobalArgs) -> Option<Value> {
    let terminal = super::pane_identify::caller_terminal(|key| std::env::var(key).ok())?;
    super::pane_identify::read_identity(global, Some(&terminal))
        .ok()
        .filter(|identity| identity.pointer("/caller/found") == Some(&Value::Bool(true)))
}

/// The guide, for the caller at `location` (`None`: outside a cmux-tui
/// terminal, or one the session does not place). `cli` is the executable
/// that prints it, which every `cmux` in the guide means.
pub(super) fn render(location: &Option<Value>, cli: Option<&Path>) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "# cmux: agent guide\n");
    let _ = writeln!(
        out,
        "Generated by `cmux skill show` from cmux {}. This CLI is the authority: \
         `cmux <scope> --help` prints every path, and `--help` after an action its flags.\n",
        crate::version_string()
    );
    if let Some(cli) = cli {
        let _ = writeln!(
            out,
            "`cmux` in this guide means this build's CLI, `{}`. A `cmux` elsewhere on PATH \
             (such as the cmux app's) can be another program: run this path when \
             `cmux --json identify` does not answer with `kind: \"cmux-tui\"`.\n",
            cli.display()
        );
    }
    write_location(&mut out, location);
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

fn write_location(out: &mut String, location: &Option<Value>) {
    out.push_str("## Where you are\n\n");
    let Some(identity) = location else {
        out.push_str(
            "This process does not run in a cmux-tui terminal (`CMUX_TUI_TERMINAL_ID` is not \
             set, or the session does not place it). `cmux identify` reports what this CLI \
             reaches; `cmux --session NAME ...` names a session.\n\n",
        );
        return;
    };
    let text =
        |pointer: &str| identity.pointer(pointer).and_then(Value::as_str).unwrap_or("-").to_owned();
    let _ = writeln!(
        out,
        "You run in a cmux-tui terminal. This CLI talks to this session by default \
         (`CMUX_TUI_SOCKET`).\n"
    );
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

- **Check first.** `cmux --json identify` prints where you run (`kind: \"cmux-tui\"`): \
your session and your own workspace, screen, pane, tab and terminal (`caller`).
- **Targets.** A selector is an id (`ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`), \
`current`, or an exact name (`name:` forces a name); an agent name (`cmux agent start \
NAME`) or a unique tab name also selects that tab's terminal, tab or pane. `current` is the session's focused \
object, the one the person looks at, not your own pane: pass your own ids from \
`cmux --json identify` to act beside yourself.
- **Use ids from JSON.** Pass `--json` and read the ids each command prints. Do not \
guess them from names, order or examples.
- **Words.** The person's \"window\" (tmux window, a TUI tab) is a **screen**; a split is a \
**pane**; a pane holds **tabs**; a tab shows one **terminal** (`term_…`). A **workspace** is a \
sidebar row (a project); a **session** is one cmux-tui daemon with its workspaces.
- **Focus.** Never move the person's focus unless they ask: split, run, create and write keep \
it. `run` shows its new tab in the pane it names, so run in a pane you split, never in your \
own. Run `cmux pane <pane> focus` only when they ask to go there.
- **Your own pane.** Do not type into your own terminal and do not close your own pane.
- **Cleanup.** Close only what you created. Never stop the session (`cmux server stop`, \
`cmux session current shutdown`) unless the person asks: stop ends every terminal.
";

const WAITS_AND_ERRORS: &str = "
## Waits

| wait | returns when | timeout |
| --- | --- | --- |
| `terminal <term> screen wait --pattern RE` | RE matches the screen | `--timeout-ms N`, exit 1 |
| `terminal <term> process wait` | the terminal's process exits (`outcome.code`) | `--timeout-ms N`, `state: pending` |
| `terminal <term> wait --until ready` | its agent can take a message (`blocked`: a startup dialog, exit 4) | `--timeout D`, exit 124 |

A timeout does not stop the command; read the screen before you send more.
A `--pattern` RE is matched line by line: `^` and `$` match at the start and end of each line \
(`--pattern '^BENCH_OK$'`), as in grep. Start it with `(?-m)` to match the whole text.

## Errors and exit codes

Errors are one JSON object on stderr with `--json`: `{\"code\", \"message\", \"details\", \
\"retryable\"}`. Exit codes: 0 done, 1 the operation failed (or `screen wait` found no \
match), 2 usage error (fix the command), 3 cannot reach the session, 4 an agent waits on \
a startup dialog (`agent start`, `wait --until ready`), 124 a wait's `--timeout` passed.
A change that failed with `retryable: true` can run again with the same \
`--idempotency-key <key>`, which never applies it twice. Before you retry a timed-out \
create, list first: it may have run.
";

/// The public scopes with the English root help's one-line description of
/// each (the scope list after its `RESOURCE SCOPES` heading).
fn write_scopes(out: &mut String) {
    out.push_str("\n## Scopes\n\n| scope | what |\n| --- | --- |\n");
    let help = super::root_help(crate::localization::catalog_for_locale("en_US.UTF-8"));
    let scopes = help.split_once("RESOURCE SCOPES\n").map_or(help.as_str(), |(_, scopes)| scopes);
    for scope in super::PUBLIC_SCOPES {
        let description = scope_description(scopes, scope).unwrap_or_default();
        let _ = writeln!(out, "| `{scope}` | {description} |");
    }
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
