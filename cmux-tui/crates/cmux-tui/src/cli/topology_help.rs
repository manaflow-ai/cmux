//! `cmux workspace|pane|tab|terminal --help`, kept out of `cli.rs` for its
//! line budget.

pub(super) const WORKSPACE_HELP: &str = "\
USAGE
  cmux workspace list [--order session|personal]
  cmux workspace create [--name <value>] [--empty] [--ephemeral] [--correlation-key <value>]
    [--expected-revision <revision>]
  cmux workspace <selector> show|focus|close
  cmux workspace <selector> rename --name <value>
  cmux workspace <selector> move --index <n>
  cmux workspace <selector> update [--title <value>|--clear-title] [--color <value>|--clear-color]
    [--icon <value>|--clear-icon]
  cmux workspace <selector> run [--on-exit <close|keep>] [--correlation-key <value>] -- <argv...>
  cmux workspace <selector> run [--on-exit <close|keep>] [--correlation-key <value>] shell <script>
  cmux workspace <selector> layout apply [OPTIONS]
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
  cmux workspace placement list
  cmux workspace group list [--room <room>]
  cmux workspace group create --name <value> [--color <value>] [--room <room>] [--index <n>] [--collapse]
  cmux workspace group <group> update [--name <value>] [--color <value>|--clear-color]
    [--room <room>] [--collapse|--expand] [--top-index <n>|--clear-top-index]
  cmux workspace group <group> delete
  cmux workspace group <group> move --index <n>
  cmux workspace group <group> add --workspace <selector> [--index <n>]
  cmux workspace group remove --workspace <selector>

Nested panes support split --right or --down. Without a selector, status,
progress and log target the caller's workspace inside a cmux terminal, else
the current one. Levels: info, progress, success, warning, error. Text that
starts with a dash goes after --. --ephemeral creates an incognito workspace
the session closes at its next start. Workspace groups and rooms are
personal: they live in this Mac's home session. A group or room is named by
its id or exact name. list --order personal gives the sidebar order: loose
workspaces, and each group's workspaces where the group shows. --top-index
puts a group right before the workspace at that placement index;
--clear-top-index puts it after every loose workspace.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), current, or an exact
  name. Prefix name: to a name that looks like an id or a command word.
";

pub(super) const PANE_HELP: &str = "\
USAGE
  cmux pane list
  cmux pane create [--correlation-key <value>]
  cmux pane <selector> show|focus|close
  cmux pane <selector> rename --name <value>
  cmux pane <selector> split [--right|--down] [--ratio <value>]
    [--viewport-width <fraction>] [--correlation-key <value>]
  cmux pane <selector> focus direction <left|right|up|down>
  cmux pane <selector> neighbor <left|right|up|down>
  cmux pane <selector> swap --other-workspace <selector>
    --other-screen <selector> --other-pane <selector>
  cmux pane <selector> zoom [--enabled <bool>]
  cmux pane <selector> split ratio set --split <id> --ratio <value>
  cmux pane <selector> viewport width set --columns <value>
  cmux pane <selector> run [--on-exit <close|keep>] [--correlation-key <value>] -- <argv...>
  cmux pane <selector> tab ...

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), current, or an exact
  name. Prefix name: to a name that looks like an id or a command word.
";

pub(super) const TAB_HELP: &str = "\
USAGE
  cmux tab list
  cmux tab <selector> show|focus|close
  cmux tab <selector> rename --name <value>
  cmux tab <selector> move --workspace <selector> --screen <selector>
    --pane <selector> --index <n>
  cmux tab <selector> pin|unpin
  cmux tab <selector> zoom <0.25..5>|reset|in|out
  cmux tab <selector> update --zoom <0.25..5>|--clear-zoom
  cmux tab create terminal [--correlation-key <value>] [OPTIONS]
  cmux tab create browser --url <value> [--correlation-key <value>] [OPTIONS]
  cmux tab <selector> terminal|browser ...
  cmux tab group list [--pane <pane_…>]
  cmux tab group create --tabs <tab_…,...> [--name <value>] [--color <color>]
  cmux tab group <group> show|ungroup|close
  cmux tab group <group> update [--name <value>] [--color <color>] [--collapse|--expand]
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
name. Group colors: grey, blue, red, yellow, green, pink, purple, cyan, orange.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), current, or an exact
  name. Prefix name: to a name that looks like an id or a command word.
";

pub(super) const TERMINAL_HELP: &str = "\
USAGE
  cmux terminal list
  cmux terminal <selector> show
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
  cmux terminal <selector> viewport scroll --delta-rows <n>
  cmux terminal <selector> move|project --workspace <selector> --screen <selector>
    --pane <selector> --index <n>
  cmux terminal <selector> attach|close [OPTIONS]
  cmux terminal <term_id> keep on|off

screen wait prints its result either way and exits 1 when the timeout
passes without a match. keep on stops the owner from ending the terminal
when it has no tab; keep off lets it end after the reap grace period.

SELECTORS
  <selector> is an id (ws_…, pane_…, tab_…, term_…), current, or an exact
  name. Prefix name: to a name that looks like an id or a command word.
";
