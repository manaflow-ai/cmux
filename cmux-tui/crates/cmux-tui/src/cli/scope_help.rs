//! Help for the session-state scopes `closed` and `git`, kept out of
//! `cli.rs` for its line budget.

pub(super) const CLOSED_HELP: &str = "\
USAGE
  cmux closed list
  cmux closed <closed> reopen

The session keeps recently closed tabs, screens and workspaces. A tab reopens
in its pane, a screen in its workspace, a workspace as a new workspace.
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
