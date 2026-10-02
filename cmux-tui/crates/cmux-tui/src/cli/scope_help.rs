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
";
