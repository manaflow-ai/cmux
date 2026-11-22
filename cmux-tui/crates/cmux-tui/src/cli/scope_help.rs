//! Help for the scopes `browser`, `notification`, `room`, `closed`, `git` and
//! `conversation`,
//! kept out of `cli.rs` for its line budget.

pub(super) const BROWSER_HELP: &str = "\
USAGE
  cmux browser open <url> [--workspace <selector>] [--screen <selector>]
    [--pane <selector>] [--name <value>] [--width-px <n> --height-px <n>]
  cmux browser list
  cmux browser <selector> show|navigate|back|forward|reload|activate
  cmux browser <selector> key|text [OPTIONS]
  cmux browser <selector> mouse|wheel --pointer-frame-seq <decimal> [OPTIONS]
  cmux browser <selector> attach|close [OPTIONS]
  cmux browser page|<tab_…> <verb> [ARGS]   Drive a page the cmux app hosts
    (`cmux browser page --help`)

browser open adds a browser tab, like
`cmux tab create browser --url <url> [--workspace <selector>]`: in the named
workspace, screen or pane, else the current one. --url <url> is the same as
the positional URL.
";

pub(super) const NOTIFICATION_HELP: &str = "\
USAGE
  cmux notification list [--limit <1..256>]
  cmux notification create --title <value> --body <value> [--subtitle <value>]
    [--level info|success|warning|error] [--terminal <term_id>]
  cmux notification clear [--terminal <term_id>]
  cmux notification ack --client <id> <notification_id>...

clear without --terminal clears every notification of the session. `cmux
notify` takes the flags of the macOS `cmux notify` (`cmux notify --help`).
";

pub(super) const NOTIFY_HELP: &str = "\
USAGE
  cmux notify [--title <text>] [--subtitle <text>] [--body <text>]
    [--surface <term_id>|current] [--workspace <ws_id>|current]
  cmux notify --clear [--surface <term_id>|current] [--workspace current]

The flags of the macOS `cmux notify`. The notification belongs to the caller's
terminal unless --surface names another terminal or --workspace asks for a
session-level row. --title defaults to \"Notification\". --reply is refused:
a reply would type into a terminal. --window and --id-format are accepted and
ignored.
";

pub(super) const ROOM_HELP: &str = "\
USAGE
  cmux room list
  cmux room create --name <value> [--color <value>] [--icon <value>] [--theme <value>] [--index <n>]
  cmux room <room> update [--name <value>] [--color <value>|--clear-color]
    [--icon <value>|--clear-icon] [--theme <value>|--clear-theme]
    [--browser-profile <id>|--clear-browser-profile]
    [--default-session <id>|--clear-default-session]
  cmux room <room> delete [--move-to <room>]
  cmux room <room> move --index <n>
  cmux room <room> follow --sessions <session,...>
  cmux room <room> pin --workspace <selector>
  cmux room unpin --workspace <selector>

Rooms are personal views of this Mac's home session. A room shows the
workspaces pinned to it and the unpinned workspaces of the sessions it
follows; --sessions is the complete follow set (\"\" follows none). A
workspace is pinned to at most one room. A room is named by its id or exact
name.
";

pub(super) const CLOSED_HELP: &str = "\
USAGE
  cmux closed list [--window <install/window>] [--limit <n>]
  cmux closed reopen [--window <install/window>]
  cmux closed <closed> reopen [--window <install/window>] [--members <i,j,...>]

The session keeps every close as one group: a bulk close (a tab group, the
tabs to the right) is one group. Reopen restores the whole group, each tab in
its pane at its old index, each screen in its workspace, each workspace as a
new workspace. Without an id, reopen takes the newest group of the window, else
the newest group of a closed window, never a group of another open window.
--members reopens only those members; the rest stay in the group.
";

pub(super) const GIT_HELP: &str = "\
USAGE
  cmux git status [TARGET]
  cmux git diff [TARGET] [--scope <scope>] [--patch] [--max-patch-bytes <n>]
    [--max-files <n>] [<path>...]
  cmux git files [TARGET] [--limit <n>] <query>...
  cmux git checkpoint create [TARGET] [--untracked eligible | <untracked-path>...]
    [--exclude <path,...>] [--reason manual|handoff|turn] [--max-bytes <n>]
    [--max-files <n>] [--expected-repository <id>] [--expected-worktree <id>]
  cmux git checkpoint get [TARGET] <checkpoint> | --key <idempotency-key>
  cmux git checkpoint list [TARGET] [--cursor <cursor>] [--limit <n>] [--candidates]
  cmux git checkpoint pin [TARGET] <checkpoint> --pin <pin-id> --reason <text>
  cmux git checkpoint unpin [TARGET] <checkpoint> --pin <pin-id>
  cmux git checkpoint diff [TARGET] <from> [<to>] [--only <path,...>] [--patch]
    [--max-patch-bytes <n>] [--max-files <n>]

TARGET
  --path <path>          A file or folder in the repository
  --workspace <selector> The working directory of the workspace's current terminal
  --screen <selector>    ... of the screen's current terminal
  --pane <selector>      ... of the pane's current terminal
  --tab <selector>       ... of the tab's terminal
  --terminal <selector>  ... of the terminal
  Without one, the current directory.

SCOPES
  uncommitted  The working tree against HEAD, with untracked files (default)
  unstaged     The working tree against the index, with untracked files
  staged       The index against HEAD
  committed    HEAD against its first parent
  branch       The working tree against the merge base with origin's default
               branch (else main or master), with untracked files

status prints the branch, upstream, how far it is ahead and behind, and the
base branch. diff prints each changed file's status and line counts; --patch
adds each file's patch from its first @@ line, cut at --max-patch-bytes
(262144 by default). At most --max-files files (500) are listed; the rest are
counted. Paths are relative to the repository root and taken literally.

files lists the files under the target folder whose path contains the query's
characters in order (case-insensitive, spaces ignored), best first: tracked
files and untracked files that are not ignored. At most --limit (50, up to
200) are printed, relative to the folder searched.

checkpoint create stores the index, the tracked worktree files and the named
untracked files (or every eligible one) under refs/cmux/checkpoints/ without
changing HEAD, the index or the worktree. Ignored, credential-like and
oversized files are skipped and reported. A reused --idempotency-key replays
the first result; get --key recovers it. Checkpoints expire after 7 days unless
pinned; pins beginning handoff: or restore: belong to cmux. checkpoint diff
lists what changed from one checkpoint to a later one, or to the working tree
now when <to> is left out, in the shape of diff.
";

/// Levenshtein distance, for "did you mean" scope suggestions.
pub(super) fn edit_distance(left: &str, right: &str) -> usize {
    let right = right.chars().collect::<Vec<_>>();
    let mut previous = (0..=right.len()).collect::<Vec<_>>();
    for (row, left) in left.chars().enumerate() {
        let mut current = vec![row + 1];
        for (column, right) in right.iter().enumerate() {
            current.push(
                (current[column] + 1)
                    .min(previous[column + 1] + 1)
                    .min(previous[column] + usize::from(left != *right)),
            );
        }
        previous = current;
    }
    previous[right.len()]
}

pub(super) const CONVERSATION_HELP: &str = "\
USAGE
  cmux conversation list
  cmux conversation <conv_id> get [--tail <0..500>]
  cmux conversation <conv_id> history --before-seq <n> --limit <1..500>
  cmux conversation search <words>... [--limit <1..100>]
  cmux conversation <conv_id> send --text <text> | --parts-json <json>
    [--reply-to <msg_id> [--reply-part <n>]]
  cmux conversation <conv_id> events [--tail <0..500>] [--cursor-rev <rev>]

The conversations of this session that you take part in (Home and the Chief).
send writes as you; Home shows it at once. events streams the conversation:
a snapshot, then each commit, typing and the Chief's live reply drafts, one
JSON line each with --jsonl. `cmux chief` is the chat on top of these.
";
