//! `cmux workspace|pane|tab|terminal --help`, kept out of `cli.rs` for its
//! line budget.

pub(super) const WORKSPACE_HELP: &str = "\
USAGE
  cmux workspace list [--order session|personal]
  cmux workspace create [--name <value>] [--empty] [--ephemeral] [--focus] [--correlation-key <value>]
    [--expected-revision <revision>] [--cwd <path>] [--shell <script> | -- <argv...>]
  cmux workspace <selector> show|focus|close
  cmux workspace <selector> close [--report-closed-ids]
  cmux workspace <selector> close --others|--to-right|--to-left|--all [--end-terminals]
  cmux workspace <selector> rename <name>|--name <name>
  cmux workspace <selector> rename --release-to-auto
  cmux workspace <selector> move --index <n>
  cmux workspace <ws_id> pin|unpin
  cmux workspace <selector> update [--title <value>|--clear-title] [--color <value>|--clear-color]
    [--icon <value>|--clear-icon] [--description <text>|--clear-description]
    [--task-status todo|working|needs-attention|review|done|--clear-task-status]
  cmux workspace <selector> run [--on-exit <close|keep|shell>] [--correlation-key <value>] -- <argv...>
  cmux workspace <selector> run [--on-exit <close|keep|shell>] [--correlation-key <value>] shell <script>
  cmux workspace <selector> layout apply [OPTIONS]
  cmux workspace [<selector>] open-url --url <http(s) URL>
  cmux workspace <selector> screen ...
  cmux workspace [<selector>] status list
  cmux workspace status list --all
  cmux workspace [<selector>] status set <key> <text> [--icon <value>] [--color <value>]
  cmux workspace [<selector>] status clear [<key>]
  cmux workspace [<selector>] progress set <0..1>|--indeterminate [--label <value>]
  cmux workspace [<selector>] progress clear
  cmux workspace [<selector>] log append <text> [--level <level>] [--source <value>]
  cmux workspace [<selector>] log list [--limit <1..200>]
  cmux workspace [<selector>] log clear
  cmux workspace [<selector>] checklist list
  cmux workspace [<selector>] checklist add <text> [--state todo|in_progress|done] [--origin user|agent] [--index <n>]
  cmux workspace [<selector>] checklist update <item> [--text <text>] [--state todo|in_progress|done]
    [--index <n>] [--attachments-json <json-array>]
  cmux workspace [<selector>] checklist remove <item>
  cmux workspace placement list
  cmux workspace group list [--room <room>]
  cmux workspace group create --name <value> [--color <value>] [--room <room>] [--index <n>] [--collapse]
  cmux workspace group <group> update [--name <value>] [--color <value>|--clear-color]
    [--icon <icon>|--clear-icon] [--pinned true|false]
    [--room <room>] [--collapse|--expand] [--top-index <n>|--clear-top-index]
  cmux workspace group <group> delete
  cmux workspace group <group> move --index <n>
  cmux workspace group <group> add --workspace <selector> [--index <n>]
  cmux workspace group remove --workspace <selector>

close with --others, --to-right, --to-left or --all closes the selected
workspace's siblings (the session's workspaces, the home one never) as one
closed group: one `cmux closed reopen` restores them all. The same flags on
screen, pane and tab close work in the screen, pane or tab bar.
open-url opens an http(s) link on the workspace's right side (without a
selector, the home workspace): it navigates the browser tab shown there last,
else opens a browser tab, never in the agent chat dock, and keeps the focus.
Nested panes support split --right or --down. Without a selector, status,
progress and log target the caller's workspace inside a cmux terminal, else
the current one. Levels: info, progress, success, warning, error. Text that
starts with a dash goes after --. --ephemeral creates an incognito workspace
the session closes at its next start. Workspace groups and rooms are
personal: they live in this Mac's home session. A group or room is named by
its id or exact name. list --order session gives the session's workspace
order: creation order unless a workspace was moved. list --order personal
gives the cmux app's sidebar order: loose workspaces, and each group's
workspaces where the group shows. Without --order, list gives the sidebar
order to every caller when the session has the sidebar document; without
the document it gives the sidebar order in the app's context (an app
terminal or Chief addressing the app's own daemon), else the session
order. The app's
snapshot.get windows[].workspaces lists the order each window shows. --top-index
puts a group right before the workspace at that placement index;
--clear-top-index puts it after every loose workspace. --icon sets a group's
icon (one emoji, an SF Symbol name, or a stored image:sha256-<hex> or
svg:sha256-<hex> asset); --clear-icon removes it. --pinned true
saves a group so it stays when its workspaces close; false unpins it.
pin and unpin pin a workspace the way the sidebar does (the app's
Pin/Unpin Workspace action, `workspace pin-unpin --pinned true|false`); they
need the cmux app. Each list row's extra.pinned says whether the sidebar shows it
pinned.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), caller, current, or an
  exact name. Prefix name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session, where caller is refused).
";

pub(super) const PANE_HELP: &str = "\
USAGE
  cmux pane list [--workspace <selector>] [--screen <selector>]
  cmux pane create [--cwd <path>] [--correlation-key <value>]
    [--shell <script> | -- <argv...>]
  cmux pane <selector> show|focus|close
  cmux pane <selector> close --others|--all
  cmux pane <selector> rename <name>|--name <name>
  cmux pane <selector> split [--right|--down] [--ratio <value>]
    [--viewport-width <fraction>] [--focus] [--correlation-key <value>]
    [--shell <script> | -- <argv...>]
  cmux pane <selector> focus direction <left|right|up|down>
  cmux pane <selector> neighbor <left|right|up|down>
  cmux pane <selector> swap --other-workspace <selector>
    --other-screen <selector> --other-pane <selector>
  cmux pane <selector> zoom [--enabled <bool>]
  cmux pane <selector> split ratio set --split <id> --ratio <value>
  cmux pane <selector> viewport width set --columns <value>
  cmux pane <selector> run [--on-exit <close|keep|shell>] [--correlation-key <value>] -- <argv...>
  cmux pane <selector> tab ...

split keeps the focus where it is unless --focus is given. With --shell or
-- argv the new pane (of split or create) runs that command instead of a
shell. To add a terminal
to a pane that already exists, use `cmux tab create terminal --pane <selector>`
instead of splitting again.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), caller, current, or an
  exact name. Prefix name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session, where caller is refused).
";

pub(super) const TAB_HELP: &str = "\
USAGE
  cmux tab list [--workspace <selector>] [--screen <selector>] [--pane <selector>]
  cmux tab <selector> show|focus|close
  cmux tab <selector> close --others|--to-right|--to-left|--all [--include-pinned]
  cmux tab <selector> rename <name>|--name <name>
  cmux tab <selector> move --workspace <selector> --screen <selector>
    --pane <selector> --index <n>
  cmux tab <selector> pin|unpin
  cmux tab <tab_…> restart
  cmux tab <selector> zoom <0.25..5>|reset|in|out
  cmux tab <selector> update --zoom <0.25..5>|--clear-zoom
  cmux tab <selector> update [--icon <value>|--clear-icon] [--marked-unread <bool>]
  cmux tab create terminal [--cwd <path>] [--name <value>] [--cols <n> --rows <n>]
    [--workspace <selector>] [--screen <selector>] [--pane <selector>]
    [--correlation-key <value>] [--shell <script> | -- <argv...>]
  cmux tab create browser --url <value> [--name <value>] [--width-px <n> --height-px <n>]
    [--workspace <selector>] [--screen <selector>] [--pane <selector>]
    [--correlation-key <value>]
  cmux tab <selector> terminal|browser ...
  cmux tab group list [--pane <pane_…>]
  cmux tab group create --tabs <tab_…,...> [--name <value>] [--color <color>]
  cmux tab group <group> show|ungroup|close
  cmux tab group <group> update [--name <value>] [--color <color>]
    [--icon <icon>|--clear-icon] [--collapse|--expand]
  cmux tab group <group> add --tabs <tab_…,...> [--index <n>]
  cmux tab group remove --tabs <tab_…,...>
  cmux tab group <group> move [--pane <pane_…>] [--index <n>]
  cmux tab group <group> save [--room <room>]
  cmux tab group <group> split --pane <id> --edge <left|right|top|bottom> [--ratio <r>]
  cmux tab group <group> column [--pane <id>|--screen <id>] [--after-column <id>] [--width <w>]
  cmux tab group <group> new-workspace [--workspace-group <id>] [--index <n>]
  cmux tab group <group> unsave
  cmux tab group saved list [--room <room>]
  cmux tab group saved <saved> reopen [--pane <pane_…>]
  cmux tab group saved <saved> delete

Zoom is a browser page zoom or a terminal font scale. Pinned tabs sort first
and leave their group. A group or saved group is named by its id or exact
name. Group colors: grey, blue, red, yellow, green, pink, purple, cyan, orange,
or a custom #RRGGBB. A group icon is one emoji, an SF Symbol name, or a stored
image:sha256-<hex> or svg:sha256-<hex> asset; --clear-icon removes it.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), caller, current, or an
  exact name. Prefix name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session, where caller is refused).
";

pub(super) const TERMINAL_HELP: &str = "\
USAGE
  cmux terminal list [--workspace <selector>] [--screen <selector>] [--pane <selector>]
    [--tab <selector>]
  cmux terminal list --agents
  cmux terminal <selector> show
  cmux terminal <selector> status
  cmux terminal <selector> write [--text <value>|--bytes-base64 <base64>]
  cmux terminal <selector> keys <key...>
  cmux terminal <selector> mouse <kind> [OPTIONS]
  cmux terminal <selector> focus <in|out>
  cmux terminal <selector> screen read
  cmux terminal <selector> screen wait --pattern <regex> [--timeout-ms <n>]
  cmux terminal <selector> state read
  cmux terminal <selector> history read|clear
  cmux terminal <selector> output read [--after <offset>] [--max-bytes <n>]
  cmux terminal <selector> copy|process show [OPTIONS]
  cmux terminal <selector> process wait [--timeout-ms <n>]
  cmux terminal <selector> wait --until idle|prompt [--timeout <500ms|30s|5m>]
  cmux terminal <selector> send --text <message|-> [--wait idle|prompt|none]
    [--timeout <5m>] [--settle <3s>] [--force]
  cmux terminal <selector> viewport scroll --delta-rows <n>
  cmux terminal <selector> move|project --workspace <selector> --screen <selector>
    --pane <selector> --index <n>
  cmux terminal <selector> attach|close [OPTIONS]
  cmux terminal <term_id> keep on|off

screen wait prints its result either way and exits 1 when the timeout
passes without a match. keep on stops the owner from ending the terminal
when it has no tab; keep off lets it end after the reap grace period.
status prints the program status records (OSC 7501) the terminal's
programs reported: state, progress, kind, app, title and msg per record id.
wait --until prompt returns when the shell shows its prompt; --until idle
when no command runs and no program reports work. Both need OSC 133 shell
integration to see commands, and print the terminal record; a passed
--timeout exits 124.
list --agents lists the terminals that run a coding agent (Claude Code,
Codex, or a program reporting OSC 7501 status): harness, state (busy, idle,
waiting-for-input, ended), age, workspace and title.
send types the message as one bracketed paste, presses Enter, waits until
the agent is idle (no fresh working report, screen still for --settle) or
the shell shows its prompt, and prints only what the terminal printed after
the message. A passed --timeout exits 124 with the output so far. An agent
that waits on a dialog is refused unless --force.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), caller, current, or an
  exact name. Prefix name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session, where caller is refused).
";

/// `cmux <scope> rename --help` for the scopes whose resources have names.
pub(super) fn rename_help(topic: &str) -> String {
    let scope = topic.split(' ').next().unwrap_or(topic);
    let release = if scope == "workspace" {
        "\n  cmux workspace [<selector>] rename --release-to-auto\n\n\
         Keeps the current name and lets cmux name the workspace automatically\n\
         again. A rename pins the name until it is released.\n"
    } else {
        ""
    };
    format!(
        "USAGE\n  cmux {scope} [<selector>] rename <name>\n  cmux {scope} [<selector>] rename --name <name>\n\n\
         Renames the {scope}. Without a selector, renames the current one. Put a\n\
         name that starts with a dash after --name.\n{release}{SELECTORS}"
    )
}

const SELECTORS: &str = "
SELECTORS
  <selector> is an id (ws_…, screen_…, pane_…, tab_…), caller, current, or
  an exact name. Prefix name: to a name that looks like an id or a command
  word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session, where caller is refused).
";
