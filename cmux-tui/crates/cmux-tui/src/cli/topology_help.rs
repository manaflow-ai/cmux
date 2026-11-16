//! `cmux workspace|pane|tab|terminal --help`, kept out of `cli.rs` for its
//! line budget.

pub(super) const WORKSPACE_HELP: &str = "\
USAGE
  cmux workspace list [--order session|personal] [--name <name>] [--cwd <path>]
  cmux --machine <cloud machine> workspace list
  cmux workspace create [--name <value>] [--empty] [--ephemeral] [--focus] [--top] [--correlation-key <value>]
    [--expected-revision <revision>] [--cwd <path>] [--shell <script> | -- <argv...>]
  cmux workspace create --worktree <name> [--repo <path>] [--base <revision>] [--name <value>] [--focus]
    [--shell <script> | -- <argv...>]
  cmux workspace <selector> show|focus|close
  cmux workspace <selector> close [--report-closed-ids]
  cmux workspace <selector> close --remove-worktree [--discard]
  cmux workspace <selector> close --others|--to-right|--to-left|--all [--end-terminals]
  cmux workspace <selector> rename <name>|--name <name>
  cmux workspace <selector> rename --release-to-auto
  cmux workspace <selector> move --index <n>
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
  cmux workspace group create --name <value> [--color <value>] [--room <room>] [--index <n>] [--collapse] [--reuse]
  cmux workspace group create --remote <host> [--name <value>]
  cmux workspace group create --parent <group> --name <value>
  cmux workspace group <group> update [--name <value>] [--color <value>|--clear-color]
    [--icon <icon>|--clear-icon] [--pinned true|false]
    [--room <room>] [--collapse|--expand] [--top-index <n>|--clear-top-index]
  cmux workspace group <group> delete
  cmux workspace group <group> move --index <n>
  cmux workspace group <group> add --workspace <selector> [--index <n>]
  cmux workspace group remove --workspace <selector>

create --worktree <name> makes a git worktree of the repository --repo is in
(default: the current folder) on a new branch cmux/<name>, in
~/.cmux/worktrees/<project>/<name>, and a workspace named <name> whose
terminal starts there; --json has the workspace ids and the worktree as
worktree (root is its folder). close --remove-worktree removes that worktree
and its branch (refused with uncommitted or unpushed work unless --discard),
then closes the workspace.
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
the session closes at its next start. --top puts the new workspace first in
the sidebar (below Home), whatever workspaces.newPlacement says. move
--index <n> moves a workspace to place n of list (the sidebar order) and
in the session order; it stays in its section and group. Workspace groups and rooms are
personal: they live in this Mac's home session. --remote makes a remote
group: it connects <host> (an ~/.ssh/config alias, a Tailscale name or
user@host) and its new workspaces run there. --parent makes a group inside
<group>. A group or room is named by
its id or exact name. list --name <name> keeps the workspaces named exactly
<name>; list --cwd <path> keeps those with a terminal in <path> or a folder
inside it (relative to the current folder; links resolved too). Both together
keep rows that match both; no match is an empty list and exit 0, so
`list --name api --json` finds every workspace a `name:api` selector calls
ambiguous. list --order session gives the session's workspace
order: creation order unless a workspace was moved. list --order personal
gives the cmux app's sidebar order: loose workspaces, and each group's
workspaces where the group shows. Without --order, list gives the sidebar
order to every caller when the session has the sidebar document; without
the document it gives the sidebar order in the app's context (an app
terminal or Chief addressing the app's own daemon), else the session
order. The app's
snapshot.get windows[].workspaces lists the order each window shows. In the
cmux app's session, list also gives each connected Cloud machine's
workspaces after this Mac's, marked origin cloud with machine_id (the vm-…
id cloud new-workspace answers), machine_name and target vm:<id>;
--machine <vm-…|vm:vm-…|name> lists one Cloud machine's. --top-index
puts a group right before the workspace at that placement index;
--clear-top-index puts it after every loose workspace. --icon sets a group's
icon (one emoji, an SF Symbol name, or a stored image:sha256-<hex> or
svg:sha256-<hex> asset); --clear-icon removes it. --pinned true
saves a group so it stays when its workspaces close; false unpins it.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), a unique id prefix
  (pane_3f0a, 4 hex digits or more), the bare 32 hex digits (for a terminal also the host
  terminal_id that run prints, or a tab or pane id), caller, current, focused
  (the object the person looks at), or an exact name. Prefix name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session naming another session, where caller is
  refused; --session naming the caller's own session keeps it).
";

pub(super) const PANE_HELP: &str = "\
USAGE
  cmux pane list [--workspace <selector>] [--screen <selector>] [--name <name>] [--cwd <path>]
  cmux pane create [--cwd <path>] [--correlation-key <value>]
    [--shell <script> | -- <argv...>]
  cmux pane <selector> show|focus|close
  cmux pane <selector> close --others|--all
  cmux pane <selector> rename <name>|--name <name>
  cmux pane <selector> split [--right|--down] [--ratio <value>]
    [--fit | --viewport-width <fraction>] [--focus] [--correlation-key <value>]
    [--shell <script> | -- <argv...>]
  cmux pane <selector> focus direction <left|right|up|down>
  cmux pane <selector> neighbor <left|right|up|down>
  cmux pane <selector> swap --other-workspace <selector>
    --other-screen <selector> --other-pane <selector>
  cmux pane <selector> zoom [--enabled <bool>]
  cmux pane <selector> split ratio set --split <id> --ratio <value>
  cmux pane <selector> viewport width set --columns <value>
  cmux pane <selector> run [--on-exit <close|keep|shell>] [--correlation-key <value>] -- <argv...>
  cmux pane <selector> move --to-pane <selector> [--split right|down|left|up] [--index <n>] [--focus]
  cmux pane <selector> move --to-tab <selector> [--index <n>] [--focus]
    (with --to-pane or --to-tab: [--to-workspace <selector>] [--to-screen <selector>])
  cmux pane <selector> move --to-workspace <selector> [--name <value>] [--focus]
  cmux pane <selector> move --new-screen|--new-tab [--name <value>] [--focus]
  cmux pane <selector> tab ...

list --name <name> keeps the panes named exactly <name>; list --cwd <path>
keeps those with a terminal in <path> or a folder inside it.

split --right --fit makes a new column that shares the window: when the
screen's columns fit it, the new one takes an equal share and the others are
scaled to fill the rest, so nothing scrolls sideways. Use it to open a pane
beside a chat. --viewport-width <fraction> makes a column of exactly that
share of the window, and the row scrolls sideways when the columns are wider
than the window.

split keeps the focus where it is unless --focus is given. With --shell or
-- argv the new pane (of split or create) runs that command instead of a
shell. To add a terminal
to a pane that already exists, use `cmux tab create terminal --pane <selector>`
instead of splitting again.

move moves the whole pane, all its tabs in order (tmux join-pane and
break-pane), in one change: a retry with the same --idempotency-key does not
move it twice. With --to-pane and --split it goes beside that pane, with
--to-workspace into a new screen in that workspace, with --new-screen
(--new-tab is the same) into a new screen in its own workspace: the pane keeps
its id. --to-pane without --split puts the tabs at the end of that pane (or at
--index), --to-tab after that tab: the tabs keep their ids and the moved pane
closes. With --to-pane or --to-tab, --to-workspace and --to-screen name that
pane's or tab's workspace and screen (for a name in another one). The focus
stays where it is unless --focus is given (when the moved
pane had the focus, the focus goes with it). --json prints pane_id (where the
tabs are now), moved_pane_id, pane_kept, workspace_id, screen_id, tab_ids,
index, and created_screen_id, closed_screen_id and focused_pane_id.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), a unique id prefix
  (pane_3f0a, 4 hex digits or more), the bare 32 hex digits (for a terminal also the host
  terminal_id that run prints, or a tab or pane id), caller, current, focused
  (the object the person looks at), or an exact name. An agent name (cmux agent start NAME) or a tab name that is
  unique in the session selects that tab's terminal, tab or pane. Prefix
  name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session naming another session, where caller is
  refused; --session naming the caller's own session keeps it).
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
name. A group has no color until one is given: grey, blue, red, yellow, green,
pink, purple, cyan, orange, a custom #RRGGBB, or none. A group icon is one emoji, an SF Symbol name, or a stored
image:sha256-<hex> or svg:sha256-<hex> asset; --clear-icon removes it.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), a unique id prefix
  (pane_3f0a, 4 hex digits or more), the bare 32 hex digits (for a terminal also the host
  terminal_id that run prints, or a tab or pane id), caller, current, focused
  (the object the person looks at), or an exact name. An agent name (cmux agent start NAME) or a tab name that is
  unique in the session selects that tab's terminal, tab or pane. Prefix
  name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session naming another session, where caller is
  refused; --session naming the caller's own session keeps it).
";

pub(super) const TERMINAL_HELP: &str = "\
USAGE
  cmux terminal list [--workspace <selector>] [--screen <selector>] [--pane <selector>]
    [--tab <selector>] [--cwd <path>]
  cmux terminal list --agents
  cmux terminal <selector> show
  cmux terminal <selector> status
  cmux terminal <selector> write [--text <value>|--bytes-base64 <base64>]
  cmux terminal <selector> keys <key...>
  cmux terminal <selector> mouse <kind> [OPTIONS]
  cmux terminal <selector> focus <in|out>
  cmux terminal <selector> screen read [--unwrap] [--lines <n>] [--details]
  cmux terminal <selector> screen wait --pattern <regex> [--new] [--timeout-ms <n>]
  cmux terminal <selector> state read
  cmux terminal <selector> history read|clear
  cmux terminal <selector> output read [--after <offset>] [--max-bytes <n>]
  cmux terminal <selector> copy [--mode screen|selection|scrollback] [--unwrap] [--details]
  cmux terminal <selector> process show
  cmux terminal <selector> process wait [--timeout-ms <n>]
  cmux terminal <selector> wait --until idle|prompt|ready
    [--timeout <500ms|30s|5m>]
  cmux terminal <selector> send --text <message|-> [--wait idle|prompt|none]
    [--pattern <regex>] [--timeout <5m>] [--settle <3s>] [--force] [--exit-with-status]
  cmux terminal <selector> run [--pattern <regex>] [--timeout <5m>] [--force] -- <command...>
  cmux terminal <selector> viewport scroll --delta-rows <n>
  cmux terminal <selector> move|project --workspace <selector> --screen <selector>
    --pane <selector> --index <n>
  cmux terminal <selector> attach|close [OPTIONS]
  cmux terminal <selector> close --if-unplaced
  cmux terminal <selector> resume [--cmd <launcher>] [--pane <selector>]
    [--split right|down|left|up] [--cwd <dir>] [--no-focus] [--no-wait]
  cmux terminal <term_id> keep on|off
  cmux terminal <term_id>|current pin-tail on|off

list --cwd <path> keeps the terminals in <path> or a folder inside it.
screen read and copy print the text; --details (or --json) gives the whole
record. screen read --unwrap joins rows the terminal soft-wrapped into the
lines the program printed; --lines <n> reads the last n lines of scrollback and
screen (logical lines with --unwrap). copy --unwrap does the same for screen and
scrollback. screen wait prints its result either way; when the timeout passes
without a match it says timed_out: true and exits 124. --new matches only output printed below the
cursor's line after the call, never a typed command's echo or older output. keep on stops the owner from ending the terminal
when it has no tab; keep off lets it end after the reap grace period.
close --if-unplaced ends the terminal only when it has no tab, no keep mark
and no attach stream; otherwise it fails and changes nothing.
status prints the program status records (OSC 7501) the terminal's
programs reported: state, progress, kind, app, title and msg per record id.
STATE is the word list --agents shows (a finished turn somebody viewed is
idle, one nobody viewed done); --json keeps the program's own word as state
and adds that word as status.
wait --until prompt returns when the shell shows its prompt; --until idle
when no command runs and no program reports work. Both need OSC 133 shell
integration to see commands, and print the terminal record; a passed
--timeout exits 124. --until ready waits until the terminal's agent can take
a message, as cmux agent start does: a startup dialog (Claude's folder-trust
question, a login) ends it as blocked with the dialog and a reason (exit 4).
process wait prints outcome once the process ends; when the timeout passes
first it prints state pending, timed_out: true and exits 124.
list --agents lists the terminals that run a coding agent (Claude Code,
Codex, or a program reporting OSC 7501 status): name, harness, state
(blocked, done, working, idle, unknown, ended), age, workspace and title.
done is a finished turn nobody has viewed yet; viewing the tab makes it idle.
The JSON rows carry that word as status (state is a deprecated alias with
the same word), and add the agent's name, the tab, the pane and the
agent's last reply.
resume starts an agent that exited again with its recorded harness session
(claude --resume <id>, codex resume <id>), in the same pane by default, and
gives it the old tab's name.
send types the message as one bracketed paste, presses Enter, waits until
the agent is idle (no fresh working report, screen still for --settle) or
the shell shows its prompt, and prints only what the terminal printed after
the message (soft wraps joined). With --wait prompt and OSC 133 shell
integration it returns as soon as the command finishes, and --json has the
command's exit_status (absent when the shell reports none, never guessed).
--pattern also ends the wait when output after the message's echo matches
(the echo never does) and when the command finishes without a match (exit 1).
--exit-with-status exits with the command's status (125: unknown). A passed
--timeout exits 124 with the output so far. An agent that waits on a dialog
is refused unless --force. A send to an idle agent whose hooks report each
prompt it takes fails with send.not_submitted (exit 1) when the agent starts
no turn within 10 s of Enter, or the message is still in its input box; read
the screen before you send again. A send to a working agent, /, ! and #
input, --pattern and --wait none are not checked. --wait none returns once
the message is typed and Enter is pressed.
run types a command into the terminal's shell, waits for it to finish and
exits with its status: send --wait prompt --exit-with-status. status also
names the last command's exit status (terminal show --json:
extra.last_command). The words after -- reach the shell as the same words:
run -- sh -c 'exit 7' exits 7 (POSIX quoting, for sh, bash and zsh; for
cmd.exe or PowerShell pass the line as one word). One word is a shell line
as it is: run -- 'make && make test'.
A --pattern (screen wait, send, run) is a regular expression matched line by
line: ^ and $ match at the start and end of each line, as in grep, so
--pattern '^BENCH_OK$' matches a line that is only BENCH_OK. Start the
pattern with (?-m) to match the whole text instead.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), a unique id prefix
  (pane_3f0a, 4 hex digits or more), the bare 32 hex digits (for a terminal also the host
  terminal_id that run prints, or a tab or pane id), caller, current, focused
  (the object the person looks at), or an exact name. An agent name (cmux agent start NAME) or a tab name that is
  unique in the session selects that tab's terminal, tab or pane. Prefix
  name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session naming another session, where caller is
  refused; --session naming the caller's own session keeps it).
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
