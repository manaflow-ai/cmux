//! The worktree a sub-session can start in (`start_session` with
//! `worktree: true`, `hub/subsessions.rs`): a new git worktree of the
//! folder's repository, laid out as the app's `git.worktree.create` lays one
//! out (`cmux-tui-core` `git_ops/worktree.rs`), so its Apply and Remove work
//! on it. acpmux does not depend on that crate, and that one runs the user's
//! worktree hooks on purpose; this one runs git in the daemon, outside the
//! agent's sandbox, on a repository the agent can write, so it runs nothing
//! from that repository (no hooks, fsmonitor, submodule recursion, system
//! config) and refuses one whose own config names a checkout filter.

use std::path::{Path, PathBuf};
use std::process::Command;

/// A worktree [`make_worktree`] made.
pub struct Worktree {
    pub root: PathBuf,
    pub branch: String,
    pub base: String,
}

fn git_output(dir: &Path, args: &[&str]) -> Result<std::process::Output, String> {
    // The repository is the agent's to write: none of its hooks, fsmonitor,
    // submodule recursion or system config runs in this process, outside the
    // agent's sandbox. Its checkout filters are refused ([`refuse_own_filters`]).
    Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        .args(["-c", "submodule.recurse=false"])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .args(args)
        .output()
        .map_err(|e| format!("git did not run: {e}"))
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = git_output(dir, args)?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("git {} failed: {}", args.join(" "), err.trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// Refuses a repository whose own config (local, worktree or an include of
/// them) names a checkout filter: `git worktree add` would run it here, outside
/// the agent's sandbox. The user's global filters (Git LFS) stay allowed.
fn refuse_own_filters(folder: &Path) -> Result<(), String> {
    let args = ["config", "--show-scope", "--get-regexp", r"^filter\..*\.(smudge|process)$"];
    let out = git_output(folder, &args)?;
    match out.status.code() {
        Some(0) => {}
        // No filter configured anywhere.
        Some(1) => return Ok(()),
        _ => {
            let err = String::from_utf8_lossy(&out.stderr);
            return Err(format!("could not read the repository's git config: {}", err.trim()));
        }
    }
    let listed = String::from_utf8_lossy(&out.stdout);
    let own: Vec<&str> = listed
        .lines()
        .filter(|line| !line.starts_with("global\t") && !line.starts_with("system\t"))
        .collect();
    if own.is_empty() {
        return Ok(());
    }
    Err(format!(
        "this repository's own git config sets a checkout filter ({}), which a worktree checkout would run outside your sandbox: make the worktree yourself and pass it as cwd",
        own.join(", ")
    ))
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
    refuse_own_filters(folder)?;
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
    let base = git(folder, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .or_else(|_| git(folder, &["rev-parse", "HEAD"]))?;
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
        match git(folder, &["worktree", "add", "-b", &branch, &root.to_string_lossy(), &base]) {
            Ok(_) => {}
            Err(e) if e.contains("already exists") || e.contains("is already checked out") => {
                continue;
            }
            Err(e) => return Err(e),
        }
        git(folder, &["config", &format!("branch.{branch}.cmuxBase"), &base])?;
        return Ok(Worktree { root, branch, base });
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
