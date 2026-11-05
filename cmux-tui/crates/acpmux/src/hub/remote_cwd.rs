//! The folder a remote-origin Claude Code session may be created in.
//!
//! A remote chain's Claude Code runs with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`
//! (`remote_sandbox.rs`), and in that mode Claude creates empty placeholder
//! files in its working folder at every start: `package.json`, the npm, yarn
//! and pnpm lockfiles, `bunfig.toml`, `.npmrc`, `.yarnrc*`, `.gitmodules`,
//! the `.env*` files and `node_modules/.bin`. In a folder that holds
//! checkouts (a projects folder, a home), the empty `package.json` becomes
//! the parent workspace of every checkout below it, and workspace-aware
//! tools there (formatters, package managers) fail to parse it.
//!
//! So a new remote-origin Claude session runs in a git work tree (the stubs
//! land beside the repository's own files, where git shows them), or in a
//! scratch folder: a folder under `~/.cache/` or the system temporary
//! folder, never those roots themselves. Anything else is refused with the
//! cause and both ways out.
//!
//! Checked when the session is created, on the machine it runs on (the only
//! one that can read the folder). A session that already exists is never
//! re-checked: its respawn, resume and transfer keep working as before.

use std::path::{Path, PathBuf};

use serde_json::json;

use crate::rpc::RpcError;

/// What decides whether a new session's folder is checked.
#[derive(Clone, Copy)]
pub(super) struct NewSession {
    /// Started over a remote connection (`remote_origin`): the remote chain.
    pub remote: bool,
    /// The trigger bridge's fixed-id chat (`server/trigger_chat.rs`), which keeps its own folder rule.
    pub trigger: bool,
    pub kind: crate::config::HarnessKind,
}

/// The check for a new session: only a remote chain's Claude Code (the one
/// `remote_sandbox.rs` runs in scrub mode) has its folder checked; a local
/// session, another harness and a trigger chat are unchanged.
pub(super) fn admit_new(
    new: NewSession,
    cwd: &Path,
    home: Option<&Path>,
    tmp: &Path,
) -> Result<(), RpcError> {
    let _ = (new, cwd, home, tmp, check);
    Ok(())
}

/// Ok when `cwd` is inside a git work tree or a scratch folder (module
/// docs); else the refusal. `home` is the user's home folder and `tmp` the
/// system temporary folder.
pub(super) fn check(cwd: &Path, home: Option<&Path>, tmp: &Path) -> Result<(), RpcError> {
    let real = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    if in_work_tree(&real) || scratch(&real, home, tmp) {
        return Ok(());
    }
    let suggestion = match home {
        Some(home) => format!(
            "a checkout, or a scratch folder named after the lane such as {}",
            home.join(".cache/<lane>-tmp").display()
        ),
        None => "a checkout, or a scratch folder under ~/.cache/".to_owned(),
    };
    Err(RpcError::invalid_params(format!(
        "a remote Claude session needs a git checkout or a scratch folder as its working folder: \
         Claude creates empty placeholder files (package.json, lockfiles, .env*) in its working \
         folder, and {} isn't a checkout. Start it in {suggestion}.",
        cwd.display()
    ))
    .with_data(json!({"reason": "remote.cwd_not_checkout", "cwd": cwd}))
}

/// Whether `dir` or a folder above it holds `.git` (a folder, or the file a
/// linked worktree or submodule has).
fn in_work_tree(dir: &Path) -> bool {
    dir.ancestors().any(|d| d.join(".git").symlink_metadata().is_ok())
}

/// Whether `dir` sits strictly below `~/.cache` or the temporary folder.
fn scratch(dir: &Path, home: Option<&Path>, tmp: &Path) -> bool {
    let roots: Vec<PathBuf> = home
        .map(|h| h.join(".cache"))
        .into_iter()
        .chain(std::iter::once(tmp.to_path_buf()))
        .map(|r| std::fs::canonicalize(&r).unwrap_or(r))
        .collect();
    roots.iter().any(|root| dir != root && dir.starts_with(root))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        _dir: tempfile::TempDir,
        home: PathBuf,
        tmp: PathBuf,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let home = root.join("home/agent");
        let tmp = root.join("tmp");
        std::fs::create_dir_all(home.join("Projects/checkouts/app/src")).unwrap();
        std::fs::create_dir_all(home.join("Projects/checkouts/app/.git")).unwrap();
        std::fs::create_dir_all(home.join("Projects/linked")).unwrap();
        std::fs::write(home.join("Projects/linked/.git"), "gitdir: /x/.git/worktrees/linked\n").unwrap();
        std::fs::create_dir_all(home.join(".cache/lane-tmp")).unwrap();
        std::fs::create_dir_all(tmp.join("job")).unwrap();
        Fixture { _dir: dir, home, tmp }
    }

    #[test]
    fn a_folder_above_the_checkouts_is_refused_with_the_cause() {
        let f = fixture();
        let projects = f.home.join("Projects");
        let err = check(&projects, Some(&f.home), &f.tmp).unwrap_err();
        assert_eq!(err.code, -32602);
        assert!(err.message.contains(
            "Claude creates empty placeholder files (package.json, lockfiles, .env*) in its working folder"
        ));
        assert!(err.message.contains(&format!("{} isn't a checkout", projects.display())));
        assert!(err.message.contains(&f.home.join(".cache/<lane>-tmp").display().to_string()));
        assert_eq!(err.data.unwrap()["reason"], "remote.cwd_not_checkout");
        assert!(check(&f.home, Some(&f.home), &f.tmp).is_err());
    }

    #[test]
    fn a_checkout_and_a_folder_inside_one_are_fine() {
        let f = fixture();
        let app = f.home.join("Projects/checkouts/app");
        assert!(check(&app, Some(&f.home), &f.tmp).is_ok());
        assert!(check(&app.join("src"), Some(&f.home), &f.tmp).is_ok());
        assert!(check(&f.home.join("Projects/linked"), Some(&f.home), &f.tmp).is_ok());
    }

    #[test]
    fn a_scratch_folder_is_fine_but_not_the_scratch_roots() {
        let f = fixture();
        assert!(check(&f.home.join(".cache/lane-tmp"), Some(&f.home), &f.tmp).is_ok());
        assert!(check(&f.tmp.join("job"), Some(&f.home), &f.tmp).is_ok());
        assert!(check(&f.home.join(".cache"), Some(&f.home), &f.tmp).is_err());
        assert!(check(&f.tmp, Some(&f.home), &f.tmp).is_err());
    }

    #[test]
    fn only_a_new_remote_claude_session_is_checked() {
        use crate::config::HarnessKind;
        let f = fixture();
        let projects = f.home.join("Projects");
        let gate = |remote, trigger, kind| {
            admit_new(NewSession { remote, trigger, kind }, &projects, Some(&f.home), &f.tmp)
        };
        let err = gate(true, false, HarnessKind::ClaudeStdio).unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "remote.cwd_not_checkout");
        assert!(gate(false, false, HarnessKind::ClaudeStdio).is_ok(), "a local session is unchanged");
        assert!(gate(true, true, HarnessKind::ClaudeStdio).is_ok(), "a trigger chat is unchanged");
        for kind in [HarnessKind::Acp, HarnessKind::Terminal] {
            assert!(gate(true, false, kind).is_ok(), "another harness is unchanged");
        }
        let app = f.home.join("Projects/checkouts/app");
        assert!(
            admit_new(
                NewSession { remote: true, trigger: false, kind: HarnessKind::ClaudeStdio },
                &app,
                Some(&f.home),
                &f.tmp
            )
            .is_ok()
        );
    }

    #[test]
    fn a_symlink_into_a_checkout_is_judged_by_where_it_leads() {
        let f = fixture();
        let link = f.home.join("app-link");
        std::os::unix::fs::symlink(f.home.join("Projects/checkouts/app"), &link).unwrap();
        assert!(check(&link, Some(&f.home), &f.tmp).is_ok());
        let up = f.home.join(".cache/projects-link");
        std::os::unix::fs::symlink(f.home.join("Projects"), &up).unwrap();
        assert!(check(&up, Some(&f.home), &f.tmp).is_err(), "a link in ~/.cache to a non-checkout is not scratch");
    }
}
