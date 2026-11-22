//! Working-tree steps git has no one command for: the Mac's sparse patterns
//! (non-cone), the untracked files of WORK outside them (git leaves those
//! out of the working tree, but on the Mac they are there).

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Component, Path};

use super::git::{Credential, Failure, Git};

/// Writes `patterns` as the checkout's sparse patterns (non-cone), or turns
/// sparse checkout off when there are none.
pub fn configure(
    git: &Git,
    credential: &Credential,
    folder: &Path,
    patterns: Option<&str>,
) -> Result<(), Failure> {
    let Some(patterns) = patterns else {
        // A clone seeded before with patterns: unset, so HEAD checks out whole.
        let _ = git.quiet(Some(folder), credential, &["config", "--unset", "core.sparseCheckout"]);
        return Ok(());
    };
    let git_dir = String::from_utf8_lossy(&git.quiet(
        Some(folder),
        credential,
        &["rev-parse", "--absolute-git-dir"],
    )?)
    .trim()
    .to_owned();
    let info = Path::new(&git_dir).join("info");
    std::fs::create_dir_all(&info).map_err(io_failure)?;
    let mut text = patterns.to_owned();
    if !text.ends_with('\n') {
        text.push('\n');
    }
    std::fs::write(info.join("sparse-checkout"), text).map_err(io_failure)?;
    git.quiet(Some(folder), credential, &["config", "core.sparseCheckout", "true"])?;
    git.quiet(Some(folder), credential, &["config", "core.sparseCheckoutCone", "false"])?;
    Ok(())
}

/// Writes the files WORK has and INDEX lacks (the Mac's untracked files)
/// that the sparse patterns left out of the working tree. Their blobs came
/// in the bundle, so this needs no network.
pub fn restore_untracked(
    git: &Git,
    credential: &Credential,
    folder: &Path,
    index: &str,
    work: &str,
) -> Result<(), Failure> {
    let listing = git.quiet(
        Some(folder),
        credential,
        &["diff-tree", "-r", "-z", "--no-renames", "--diff-filter=A", index, work],
    )?;
    let mut fields = listing.split(|byte| *byte == 0).filter(|field| !field.is_empty());
    while let (Some(meta), Some(path)) = (fields.next(), fields.next()) {
        // `:000000 100644 <old> <new> A`
        let meta = String::from_utf8_lossy(meta);
        let parts: Vec<&str> = meta.trim_start_matches(':').split(' ').collect();
        let (Some(mode), Some(blob)) = (parts.get(1), parts.get(3)) else { continue };
        let Ok(path) = std::str::from_utf8(path) else { continue };
        let relative = Path::new(path);
        if !safe(folder, relative) {
            continue;
        }
        let target = folder.join(relative);
        if std::fs::symlink_metadata(&target).is_ok() {
            continue;
        }
        let bytes = git.quiet(Some(folder), credential, &["cat-file", "blob", blob])?;
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(io_failure)?;
        }
        match *mode {
            "120000" => {
                let link = String::from_utf8_lossy(&bytes).into_owned();
                std::os::unix::fs::symlink(link, &target).map_err(io_failure)?;
            }
            "100755" | "100644" => {
                std::fs::write(&target, &bytes).map_err(io_failure)?;
                let bits = if *mode == "100755" { 0o755 } else { 0o644 };
                std::fs::set_permissions(&target, std::fs::Permissions::from_mode(bits))
                    .map_err(io_failure)?;
            }
            // A gitlink (a submodule) has no blob to write.
            _ => {}
        }
    }
    Ok(())
}

/// A tree path that stays in `folder`: plain components, none named
/// `.git`, and no existing parent that is a symlink.
fn safe(folder: &Path, relative: &Path) -> bool {
    let mut at = folder.to_path_buf();
    let components: Vec<Component<'_>> = relative.components().collect();
    let Some((_, parents)) = components.split_last() else { return false };
    for component in &components {
        match component {
            Component::Normal(name) if !name.eq_ignore_ascii_case(".git") => {}
            _ => return false,
        }
    }
    for component in parents {
        at.push(component);
        if std::fs::symlink_metadata(&at).is_ok_and(|meta| !meta.is_dir()) {
            return false;
        }
    }
    true
}

fn io_failure(error: std::io::Error) -> Failure {
    Failure::of(format!("fatal: {error}"))
}
