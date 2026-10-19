//! The worktree a sub-session can start in (`start_session` with
//! `worktree: true`, `hub/subsessions.rs`): a new git worktree of the
//! folder's repository, laid out as the app's `git.worktree.create` lays one
//! out (`cmux-tui-core` `git_ops/worktree.rs`), so its Apply and Remove work
//! on it. acpmux does not depend on that crate, and that one runs the user's
//! worktree hooks on purpose; this one runs git in the daemon, outside the
//! agent's sandbox, on a repository the agent can write, so it runs nothing
//! that repository names.
//!
//! The worktree is added without a checkout, and its files are written by a
//! throwaway git directory that borrows the repository's objects but none of
//! its config, nor the user's: no filter, hook, fsmonitor, transport,
//! credential helper or lazy fetch can come from what the agent wrote, and
//! a change the agent makes to that config meanwhile changes nothing. The
//! files are as committed (a Git LFS file stays its pointer); the child's own
//! git, in its sandbox, uses the repository's config from then on.

use std::path::{Path, PathBuf};
use std::process::Command;

/// A worktree [`make_worktree`] made.
pub struct Worktree {
    pub root: PathBuf,
    pub branch: String,
    pub base: String,
    /// The folder the child starts in: the started-from folder's place in the worktree.
    pub cwd: PathBuf,
}

/// Git that runs nothing from the repository at `dir`: no hooks, fsmonitor,
/// submodule recursion, credential helper, system config, network transport
/// or lazy fetch of a partial clone.
fn hardened(dir: &Path) -> Command {
    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(dir)
        .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        .args(["-c", "submodule.recurse=false", "-c", "credential.helper="])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .env("GIT_ALLOW_PROTOCOL", "none")
        .env("GIT_SSH_COMMAND", "false")
        .env("GIT_LFS_SKIP_SMUDGE", "1")
        .env("LC_ALL", "C");
    cmd
}

fn run(mut cmd: Command, args: &[&str]) -> Result<String, String> {
    let out = cmd.args(args).output().map_err(|e| format!("git did not run: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("git {} failed: {}", args.join(" "), err.trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    run(hardened(dir), args)
}

/// Writes `commit`'s files into `root` with a throwaway git directory next
/// to nothing of the repository's but its objects (`objects`): no config of
/// the repository's, the user's or the system's is read.
fn check_out_without_config(
    objects: &Path,
    format: &str,
    root: &Path,
    commit: &str,
) -> Result<(), String> {
    let scratch = std::env::temp_dir().join(format!("acpmux-wt-{}", uuid::Uuid::now_v7()));
    let result: Result<(), String> = (|| {
        let info = scratch.join("objects/info");
        std::fs::create_dir_all(&info).map_err(|e| format!("{}: {e}", info.display()))?;
        std::fs::create_dir_all(scratch.join("refs")).map_err(|e| e.to_string())?;
        std::fs::write(scratch.join("HEAD"), format!("{commit}\n")).map_err(|e| e.to_string())?;
        // Only what reading its objects needs: the format version and hash.
        let config = if format == "sha1" {
            "[core]\n\trepositoryformatversion = 0\n".to_owned()
        } else {
            format!(
                "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tobjectFormat = {format}\n"
            )
        };
        std::fs::write(scratch.join("config"), config).map_err(|e| e.to_string())?;
        std::fs::write(info.join("alternates"), format!("{}\n", objects.display()))
            .map_err(|e| e.to_string())?;
        let isolated = || {
            let mut cmd = hardened(root);
            cmd.env("GIT_DIR", &scratch)
                .env("GIT_WORK_TREE", root)
                .env("GIT_INDEX_FILE", scratch.join("index"))
                .env("GIT_CONFIG_GLOBAL", "/dev/null");
            cmd
        };
        run(isolated(), &["read-tree", commit])?;
        run(isolated(), &["checkout-index", "--all", "--force"])?;
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(&scratch);
    result
}

/// Removes a worktree [`make_worktree`] made, and its branch.
pub fn remove_worktree(folder: &Path, worktree: &Worktree) {
    let root = worktree.root.to_string_lossy();
    let _ = git(folder, &["worktree", "remove", "--force", &root]);
    let _ = git(folder, &["branch", "-D", &worktree.branch]);
    let _ = git(folder, &["config", "--unset", &format!("branch.{}.cmuxBase", worktree.branch)]);
}

/// Lowercase ASCII letters and digits, every other run one `-`, at most 48
/// characters: `git_ops/worktree.rs`'s names.
pub fn slug(text: &str) -> String {
    let mut slug = String::new();
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c.to_ascii_lowercase());
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
        if slug.len() >= 48 {
            break;
        }
    }
    slug.trim_end_matches('-').to_owned()
}

/// A new worktree of `folder`'s repository at `~/.cmux/worktrees/<project>/<name>`
/// on a new branch `cmux/<name>` from the current branch (else HEAD), its
/// base recorded as `branch.<branch>.cmuxBase`, as `git.worktree.create`
/// makes one. A taken name gets the next free suffix.
pub fn make_worktree(folder: &Path, title: &str) -> Result<Worktree, String> {
    let home = std::env::var_os("HOME").map(PathBuf::from).ok_or("no home folder for worktrees")?;
    make_worktree_under(folder, title, &home)
}

/// [`make_worktree`] with `home` as the home folder.
fn make_worktree_under(folder: &Path, title: &str, home: &Path) -> Result<Worktree, String> {
    let common =
        PathBuf::from(git(folder, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?);
    let objects = PathBuf::from(git(
        folder,
        &["rev-parse", "--path-format=absolute", "--git-path", "objects"],
    )?);
    let prefix = git(folder, &["rev-parse", "--show-prefix"])?;
    let format = git(folder, &["rev-parse", "--show-object-format"])?;
    let main = if common.file_name().is_some_and(|n| n == ".git") {
        common.parent().map(Path::to_path_buf)
    } else {
        None
    };
    let project = main
        .as_deref()
        .unwrap_or(&common)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let project = Some(slug(project.strip_suffix(".git").unwrap_or(&project)))
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "repository".into());
    let parent = home.join(".cmux").join("worktrees").join(project);
    // The commit is resolved once; a branch name that reads as an option
    // (`-x`) is recorded as that commit instead.
    let commit = git(folder, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])?;
    let base = git(folder, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .ok()
        .filter(|b| !b.is_empty() && !b.starts_with('-'))
        .unwrap_or_else(|| commit.clone());
    let name = Some(slug(title)).filter(|n| !n.is_empty()).unwrap_or_else(|| "task".into());
    let free = |candidate: &str| {
        !parent.join(candidate).exists()
            && git(
                folder,
                &["rev-parse", "--verify", "--quiet", &format!("refs/heads/cmux/{candidate}")],
            )
            .is_err()
    };
    std::fs::create_dir_all(&parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    // Another start may take a free name before this one adds it: git then
    // says it already exists, and the next name is tried.
    for chosen in std::iter::once(name.clone()).chain((2..=99).map(|n| format!("{name}-{n}"))) {
        if !free(&chosen) {
            continue;
        }
        let root = parent.join(&chosen);
        let branch = format!("cmux/{chosen}");
        let add =
            ["worktree", "add", "--no-checkout", "-b", &branch, &root.to_string_lossy(), &commit];
        match git(folder, &add) {
            Ok(_) => {}
            Err(e) if e.contains("already exists") || e.contains("is already checked out") => {
                continue;
            }
            Err(e) => return Err(e),
        }
        let cwd = Some(root.join(&prefix)).filter(|p| p.is_dir()).unwrap_or_else(|| root.clone());
        let made = Worktree { root: root.clone(), branch: branch.clone(), base: base.clone(), cwd };
        // Its files without the repository's config; then its index, which
        // `read-tree` (no `-u`) writes from the objects alone.
        let filled = check_out_without_config(&objects, &format, &root, &commit)
            .and_then(|()| git(&root, &["read-tree", &commit]).map(drop))
            .and_then(|()| {
                git(folder, &["config", &format!("branch.{branch}.cmuxBase"), &base]).map(drop)
            });
        if let Err(e) = filled {
            remove_worktree(folder, &made);
            return Err(e);
        }
        return Ok(made);
    }
    Err(format!("every worktree name from {name} to {name}-99 is taken"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_matches_the_worktree_names() {
        assert_eq!(slug("Fix the flaky upload test!"), "fix-the-flaky-upload-test");
        assert_eq!(slug("  --  "), "");
        assert_eq!(slug(&"a".repeat(80)).len(), 48);
    }
}
