//! Keep a PR-archived checkout intact. Git moves its directory and updates its
//! registration. A failed move (including across devices) leaves its files alone.
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use cmux_git::write_run::{Bound, WriteGit};

use crate::archive::empty_hooks;
use crate::git;
use crate::inventory::now_ms;
use crate::restore::Restored;
use crate::store::{Manifest, Store};

const LOCK: &str = "cmux PR archive";

pub(super) fn destination(store: &Store, id: &str) -> PathBuf {
    store.dir.join("parked").join(id).join("checkout")
}

fn move_tree(git: &WriteGit<'_>, from: &Path, to: &Path) -> Result<(), String> {
    match to.symlink_metadata() {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        _ => return Err(format!("cannot move over {}", to.display())),
    }
    git::write(
        git,
        None,
        &[
            OsStr::new("worktree"),
            OsStr::new("move"),
            OsStr::new("--"),
            from.as_os_str(),
            to.as_os_str(),
        ],
        Bound::Unbounded,
    )?;
    Ok(())
}

pub(super) fn park(
    git: &WriteGit<'_>,
    store: &Store,
    manifest: &Manifest,
    to: &Path,
) -> Result<(), String> {
    std::fs::create_dir_all(store.dir.join("parked")).map_err(|e| e.to_string())?;
    std::fs::create_dir(to.parent().ok_or("missing archive directory")?)
        .map_err(|e| e.to_string())?;
    // Run Git outside the directory about to move.
    let anchor =
        WriteGit { root: &manifest.common_dir, overrides: git.overrides, hooks: git.hooks };
    move_tree(&anchor, &manifest.path, to)?;
    git::write(
        &anchor,
        None,
        &[
            "worktree".as_ref(),
            "lock".as_ref(),
            "--reason".as_ref(),
            LOCK.as_ref(),
            "--".as_ref(),
            to.as_os_str(),
        ],
        Bound::Unbounded,
    )?;
    Ok(())
}

pub(super) fn restore(store: &Store, manifest: &Manifest, to: &Path) -> Result<Restored, String> {
    if Path::new(&manifest.id).file_name() != Some(OsStr::new(&manifest.id)) {
        return Err("invalid archive id".into());
    }
    if to.symlink_metadata().is_ok() {
        return Err(format!("cannot move over {}", to.display()));
    }
    let from = destination(store, &manifest.id);
    let hooks = empty_hooks(store)?;
    let git = WriteGit { root: &manifest.common_dir, overrides: &[], hooks: &hooks };
    let dir = git::line(&from, &[], &["rev-parse", "--absolute-git-dir"])?;
    let admin = Path::new(&dir);
    if admin.parent() != Some(manifest.common_dir.join("worktrees").as_path()) {
        return Err("the parked checkout belongs to a different repository".into());
    }
    let lock = admin.join("locked");
    match std::fs::read_to_string(lock) {
        Ok(reason) if reason.trim_end() == LOCK => {
            git::write(
                &git,
                None,
                &["worktree".as_ref(), "unlock".as_ref(), "--".as_ref(), from.as_os_str()],
                Bound::Unbounded,
            )?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        _ => return Err("the parked checkout has another lock".into()),
    }
    move_tree(&git, &from, to)?;
    store.save(&Manifest { restored_ms: Some(now_ms()), ..manifest.clone() })?;
    Ok(Restored {
        path: to.to_owned(),
        branch: git::try_line(to, &[], &["symbolic-ref", "--quiet", "--short", "HEAD"]),
        head: git::try_line(to, &[], &["rev-parse", "--verify", "HEAD"]),
        archive: true,
        notes: vec![],
    })
}
