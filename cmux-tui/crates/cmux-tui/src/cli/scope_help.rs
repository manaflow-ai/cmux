//! Help for the scopes `browser`, `notification`, `room`, `closed`, `git`,
//! `status` and `conversation`,
//! kept out of `cli.rs` for its line budget.

pub(super) const BROWSER_HELP: &str = "\
USAGE
  cmux browser open <url> [--workspace <selector>] [--screen <selector>]
    [--pane <selector>] [--name <value>] [--width-px <n> --height-px <n>]
  cmux browser list
  cmux browser profile list
  cmux browser profile create --name <name> [--color <value>] [--icon <value>]
    [--index <n>]
  cmux browser profile move --profile <id-or-name> --index <n>
  cmux browser profile proxy set --profile <id-or-name>
    --url http|https|socks5://host:port [--bypass <host,...>]
  cmux browser profile proxy clear --profile <id-or-name>
  cmux browser profile open <url> --profile <id-or-name> [--engine webkit|cef]
    [--pane <selector>] [--title <value>] [--background true|false]
  cmux browser <selector> show|navigate|back|forward|reload|activate
  cmux browser <selector> key|text [OPTIONS]
  cmux browser <selector> mouse|wheel --pointer-frame-seq <decimal> [OPTIONS]
  cmux browser <selector> attach|close [OPTIONS]
  cmux browser page|<tab_…> <verb> [ARGS]   Drive a page the cmux app hosts
    (`cmux browser page --help`)
  cmux browser right <verb> [ARGS] [--agent NAME]   The same verbs on the
    browser right of the Home chat (an agent's own tab there, opened when
    needed; `cmux browser right release` gives it back)

browser open adds a browser tab, like
`cmux tab create browser --url <url> [--workspace <selector>]`: in the named
workspace, screen or pane, else the current one. --url <url> is the same as
the positional URL.

browser profile list shows each profile's id, name, color, icon and index,
never its cookies, history or site data. browser profile open opens a tab in
the profile, in the named pane, else the focused one; the URL must be http or
https. Without --engine the tab uses the browser.defaultEngine setting.
";

pub(super) const NOTIFICATION_HELP: &str = "\
USAGE
  cmux notification list [--limit <1..256>]
  cmux notification create --title <value> --body <value> [--subtitle <value>]
    [--level info|warning|error] [--terminal <term_id> | --workspace <ws_id>]
  cmux notification clear [--terminal <term_id> | --workspace <ws_id>]
  cmux notification ack --client <id> <notification_id>...

clear without --terminal or --workspace clears every notification of the
session; --workspace clears that workspace's rows and those of its terminals. `cmux
notify` takes the flags of the macOS `cmux notify` (`cmux notify --help`).
";

pub(super) const ATTENTION_HELP: &str = "\
USAGE
  cmux attention request --tab <tab_…> --reason <text>
  cmux attention clear --tab <tab_…>

request marks the tab where the person must act (confirm, log in, approve,
pick): the tab and its workspace show as needing them in every cmux client.
The reason is one line they read (at most 200 bytes). It never moves focus;
to take the person there when they ask, run `cmux tab <tab_…> focus`. The mark stays while they look at the tab and clears
when you clear it, when a browser tab goes to another page, or when the tab
closes. Name the workspace and tab by their titles when you talk to the person,
never by a ws_ or tab_ id.
";

pub(super) const NOTIFY_HELP: &str = "\
USAGE
  cmux notify [--title <text>] [--subtitle <text>] [--body <text>]
    [--surface <term_id>|current] [--workspace <ws_id>|current]
    [--reply] [--desktop true|false]
  cmux notify --clear [--surface <term_id>|current] [--workspace <ws_id>|current]

The flags of the macOS `cmux notify`. The notification belongs to the caller's
terminal unless --surface names another terminal or --workspace names a
workspace (--workspace current asks for a session-level row). --clear
--workspace <ws_id> clears that workspace's notifications and those of its
terminals; --workspace current clears the whole session. --title defaults to \"Notification\". --reply asks for a
banner with a Reply field when the notification belongs to a terminal: its
text is typed into that terminal, then Return. --desktop false posts no
banner. --window and --id-format are accepted and ignored.
";

pub(super) const STATUS_HELP: &str = "\
USAGE
  cmux status set [KEY] (TEXT | --label <text>) [--target <ws_…>|current]
    [--state busy|waiting|success|error|info] [--progress 0.4|40%]
    [--style arc|native|dot|none] [--ttl 30s] [--pid <n>] [--keep | --owner none]
  cmux status clear [KEY] [--target <ws_…>|current] [--all]
  cmux status list [--target <ws_…>|current | --all]
  cmux status run [--label <text>] [--target <ws_…>|current] [--badge-ttl 8s] -- CMD …
  cmux status wait KEY [--target <ws_…>|current] [--until settled|cleared|state=<s>]
    [--timeout <500ms|30s|5m>]

Loading indicators for scripts and agents, shown on the workspace's sidebar
row. A shorthand for `cmux workspace [<ws>] status …`: the target is the
caller's terminal (its workspace), else the current workspace.

KEY defaults to cli:<terminal>, so repeated sets from one terminal replace each
other. An entry set from a terminal belongs to that terminal and goes when it
closes; --pid ties it to a process instead, --ttl ends it after that long, and
--keep (or --owner none) keeps it until cleared. clear without KEY clears the
default key; --all clears every entry of the workspace. list --all lists the
entries of every workspace.

run marks the entry busy and owned by this process (a killed CLI leaves no
spinner), runs CMD with the terminal's input and output, then shows success or
error with the exit code and duration for --badge-ttl, and exits with CMD's
status (128 + signal when a signal ended it).

wait blocks until the entry KEY holds --until, following the session's events
(no polling), and prints it. settled, the default, returns when the entry is
gone (cleared, its owner ended or its TTL passed) or shows success (exit 0),
or shows error (exit 1); cleared waits for the entry to go; state=<s> for that
state. A passed --timeout exits 124.
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
  cmux closed reopen --tab <tab> [--fallback-pane <pane>]
  cmux closed <closed> reopen [--window <install/window>] [--members <i,j,...>] [--fallback-pane <pane>]
  cmux closed <closed> delete [--members <i,j,...>]
  cmux closed clear [--since-ms <unix-ms>] [--before-ms <unix-ms>] [--keep-newest <n>]

The session keeps every close as one group: a bulk close (a tab group, the
tabs to the right) is one group. Reopen restores the whole group, each tab in
its pane at its old index, each screen in its workspace, each workspace as a
new workspace. Without an id, reopen takes the newest group of the window, else
the newest group of a closed window, never a group of another open window.
--members reopens only those members; the rest stay in the group.
--tab reopens the closed tab under its own id (a cmux://tab/ link to it keeps
working), from the newest group that holds it. A tab whose pane and workspace
are gone opens in --fallback-pane, else in the session's focused pane.
delete and clear remove groups permanently (and their terminal archives; the
journals keep what they recorded); clear --since-ms removes only the groups
closed at or after that time, --before-ms only those closed before it, and
--keep-newest every group but the newest n (retention by age and by count).
";

pub(super) const GIT_HELP: &str = "\
USAGE
  cmux git status [TARGET]
  cmux git diff [TARGET] [--scope <scope>] [--patch] [--max-patch-bytes <n>]
    [--max-files <n>] [--context-lines <n>] [<path>...]
  cmux git branches [TARGET] [--limit <n>]
  cmux git files [TARGET] [--limit <n>] <query>...
  cmux git list [TARGET] [--limit <n>]
  cmux git checkpoint create [TARGET] [--untracked eligible | <untracked-path>...]
    [--exclude <path,...>] [--reason manual|handoff|turn] [--max-bytes <n>]
    [--max-files <n>] [--expected-repository <id>] [--expected-worktree <id>]
  cmux git checkpoint get [TARGET] <checkpoint> | --key <idempotency-key>
  cmux git checkpoint list [TARGET] [--cursor <cursor>] [--limit <n>] [--candidates]
  cmux git checkpoint pin [TARGET] <checkpoint> --pin <pin-id> --reason <text>
  cmux git checkpoint unpin [TARGET] <checkpoint> --pin <pin-id>
  cmux git checkpoint diff [TARGET] <from> [<to>] [--only <path,...>] [--patch]
    [--max-patch-bytes <n>] [--max-files <n>] [--context-lines <n>]
  cmux git commit [TARGET] --message <text> [--all [--include-untracked]] [--amend]
    [--no-verify] [--expected-head <commit>] [<path>...]
  cmux git push [TARGET] [--remote <name>] [--branch <name>]
    [--set-upstream | --no-set-upstream] [--expected-head <commit>]
  cmux git worktree create [TARGET] [--name <name>] [--base <revision>]
  cmux git worktree apply [TARGET]
  cmux git worktree remove [TARGET] [--discard]

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
  branch       The working tree against the merge base with the base branch,
               with untracked files

status prints the branch, upstream, how far it is ahead and behind, the base
branch (the one a worktree create recorded for the branch, else origin's
default branch, else main or master), and in a linked worktree its main
checkout. diff prints each changed file's status and line counts; --patch
adds each file's patch from its first @@ line, cut at --max-patch-bytes
(262144 by default). At most --max-files files (500) are listed; the rest are
counted. Paths are relative to the repository root and taken literally.

branches lists local branches, then remote-tracking ones, newest commit first:
each one's ref and commit, and for a local branch its upstream and how far it
is ahead and behind. At most --limit (200, up to 1000) are printed. It also
suggests the bases a branch diff may compare with: the base a worktree create
recorded for the branch, origin's default branch (else main or master), then
the upstream of HEAD's branch.

files lists the files under the target folder whose path contains the query's
characters in order (case-insensitive, spaces ignored), best first: tracked
files and untracked files that are not ignored. At most --limit (50, up to
200) are printed, relative to the folder searched.

list (or ls) lists the immediate children of the target folder, as a file explorer
shows them: folders first, then files, by name. A child is listed when git
knows a file at or under it (tracked, or untracked and not ignored); a
submodule is a folder. At most --limit (2000, up to 5000) are printed.

checkpoint create stores the index, the tracked worktree files and the named
untracked files (or every eligible one) under refs/cmux/checkpoints/ without
changing HEAD, the index or the worktree. Ignored, credential-like and
oversized files are skipped and reported. A reused --idempotency-key replays
the first result; get --key recovers it. Checkpoints expire after 7 days unless
pinned; pins beginning handoff: or restore: belong to cmux. checkpoint diff
lists what changed from one checkpoint to a later one, or to the working tree
now when <to> is left out, in the shape of diff.

commit and push run git as in your terminal, with your hooks, identity and
credentials, but never prompt and stop after 120 s. commit commits the named
paths, every tracked change with --all (and untracked files with
--include-untracked), or else the index as it is. push pushes the branch's
commit to the branch of the same name, never forced, and sets its upstream
when it has none. --expected-head refuses when HEAD moved since you read it.

worktree create makes a worktree for a chat at ~/.cmux/worktrees/<project>/<name>
on a new branch cmux/<name> from --base (the current branch by default), and
records the base as branch.cmux/<name>.cmuxBase. A taken name gets the next free
suffix (-2, -3, ...); without --name it is chat-<random>. Your checkout is left
as it is.

worktree apply, run in such a worktree, brings everything it changed since its
recorded base (commits, edits and new files; not submodules) to the main checkout
as uncommitted changes. HEAD and the index stay; it is refused when the main
checkout has changes of its own (or untracked files) at those paths, or when the
work does not apply cleanly there.

worktree remove, run in such a worktree, removes it (with its ignored files) and
the cmux/<name> branch worktree create made. It is refused while the worktree has
uncommitted changes or commits on no other branch or remote, unless --discard.
The main checkout is never removed.
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
