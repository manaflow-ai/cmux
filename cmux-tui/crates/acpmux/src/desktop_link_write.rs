//! Part of `desktop_link.rs`: how an app's config file is edited while the app (or a person)
//! may write it too.
//!
//! The guarantee: another writer's text is never lost, and this edit is either in the file, built
//! on the text that is there, or reported as an error.
//!
//! - A writer that takes the shared lock (`cmux_tui_platform::codex_config_lock`: the hook
//!   installer, the Cloud devbox provider merge) waits for it: `lock` is held from the first read
//!   to the last check.
//! - A writer outside it (Codex or Claude desktop itself, an editor) is caught by what the swap
//!   took the place of. The new text goes in with an atomic exchange of names (`RENAME_EXCHANGE`
//!   on Linux, `RENAME_SWAP` on macOS, `write_journal/nofollow.rs`), so the file that comes out is
//!   exactly the one it replaced: a write into it in place, or a file renamed over it, both show
//!   there. Different from the text the edit was built on, the edit is done again on that text and
//!   put in again. Where no exchange is offered (another system, a folder that is a link), a plain
//!   rename runs and the file it replaced is read through the handle opened before it, which
//!   catches a write in place; a rename over it in that moment is the one case it cannot see.
//! - After the swap the path is read again: a file renamed in after ours is another writer's,
//!   and the edit is done again on it.
//! - After [`EDIT_TRIES`] rounds that each met another writer, the last other text is put back
//!   (when ours is the one in place) and the edit is refused: theirs wins, ours is reported.
//!
//! A write made through a handle to a file after the swap took it out of place (the one moment
//! no check can follow) lands in a file no longer at the path, as it would against any writer.

use std::io::{Read as _, Seek as _};
use std::path::Path;

use anyhow::{Context, Result, anyhow, bail};

/// How many rounds an edit runs against other writers before it is refused.
pub(super) const EDIT_TRIES: usize = 3;

/// Read `path` (none: empty), `render` its new text, and put that in whole (module docs), so
/// the app never reads half a file and no other writer's text is lost.
pub(super) fn edit_file(
    path: &Path,
    lock: Option<&Path>,
    render: impl Fn(&str) -> Result<String>,
) -> Result<()> {
    edit_file_raced(path, lock, render, &mut || {})
}

/// [`edit_file`], running `before_swap` after the last compare and before the new text goes in:
/// the tests' other writer.
pub(super) fn edit_file_raced(
    path: &Path,
    lock: Option<&Path>,
    render: impl Fn(&str) -> Result<String>,
    before_swap: &mut dyn FnMut(),
) -> Result<()> {
    let dir = path.parent().ok_or_else(|| anyhow!("{} has no folder", path.display()))?;
    std::fs::create_dir_all(dir).with_context(|| format!("making {}", dir.display()))?;
    let _lock = lock.and_then(cmux_tui_platform::codex_config_lock::lock);
    // The text the edit is built on, and the text this edit expects at the path (ours, once a
    // round put it in over another writer's).
    let mut base = read(path)?;
    let mut at_path = base.clone();
    // Ours, in place over another writer's text `base`.
    let mut stale: Option<String> = None;
    for _ in 0..EDIT_TRIES {
        let ours = render(base.as_deref().unwrap_or_default())?;
        let tmp = temp_beside(path, &ours)?;
        let mut kept = std::fs::File::open(path).ok();
        let now = match &mut kept {
            Some(file) => Some(read_handle(file, path)?),
            None => read(path)?,
        };
        if now != at_path {
            (base, at_path) = (now.clone(), now);
            continue;
        }
        before_swap();
        let displaced = match put(tmp, path, at_path.is_some(), kept)? {
            Put::Swapped(displaced) => displaced,
            Put::Taken => {
                let now = read(path)?;
                (base, at_path) = (now.clone(), now);
                continue;
            }
        };
        if displaced != at_path {
            // Another writer's text came out: the edit is done again on it.
            (base, at_path, stale) = (displaced, Some(ours.clone()), Some(ours));
            continue;
        }
        let after = read(path)?;
        if after.as_deref() != Some(ours.as_str()) {
            // A file renamed in after ours: theirs stays, and the edit is done again on it.
            (base, at_path, stale) = (after.clone(), after, None);
            continue;
        }
        return Ok(());
    }
    if let (Some(ours), Some(theirs)) = (&stale, &base)
        && read(path)?.as_deref() == Some(ours.as_str())
    {
        let tmp = temp_beside(path, theirs)?;
        tmp.persist(path).map_err(|e| anyhow!("restoring {}: {}", path.display(), e.error))?;
    }
    bail!(
        "{} kept changing while it was edited; its other writer's text is kept; run it again",
        path.display()
    )
}

/// What putting the new text in did.
enum Put {
    /// It is in; the text of the file it took the place of (`None`: there was none).
    Swapped(Option<String>),
    /// A file appeared where there was none: nothing was put in.
    Taken,
}

/// Put `tmp` in at `path`: an exchange of names where the system offers it, else a rename, with
/// the file it replaced read back (module docs). `exists`: the path had a file when compared.
fn put(
    tmp: tempfile::NamedTempFile,
    path: &Path,
    exists: bool,
    kept: Option<std::fs::File>,
) -> Result<Put> {
    if !exists {
        return match tmp.persist_noclobber(path) {
            Ok(_) => Ok(Put::Swapped(None)),
            Err(e) if e.error.kind() == std::io::ErrorKind::AlreadyExists => Ok(Put::Taken),
            Err(e) => Err(anyhow!("writing {}: {}", path.display(), e.error)),
        };
    }
    if exchange(tmp.path(), path) {
        // The temp name now holds the file that was at the path; it is removed when `tmp` drops.
        return Ok(Put::Swapped(read(tmp.path())?));
    }
    tmp.persist(path).map_err(|e| anyhow!("replacing {}: {}", path.display(), e.error))?;
    match kept {
        Some(mut file) => Ok(Put::Swapped(Some(read_handle(&mut file, path)?))),
        None => Ok(Put::Swapped(None)),
    }
}

/// Swap the names `a` and `b` (in the same folder) atomically; false when it cannot (nothing
/// changed then).
#[cfg(unix)]
fn exchange(a: &Path, b: &Path) -> bool {
    let (Some(dir), Some(a), Some(b)) = (
        b.parent(),
        a.file_name().and_then(|n| n.to_str()),
        b.file_name().and_then(|n| n.to_str()),
    ) else {
        return false;
    };
    crate::write_journal::nofollow::exchange_in(dir, a, b).is_ok()
}

#[cfg(not(unix))]
fn exchange(_: &Path, _: &Path) -> bool {
    false
}

fn read(path: &Path) -> Result<Option<String>> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
    }
}

/// The whole text of an open file, from its start.
fn read_handle(file: &mut std::fs::File, path: &Path) -> Result<String> {
    let mut text = String::new();
    file.rewind()
        .and_then(|()| file.read_to_string(&mut text))
        .with_context(|| format!("reading {}", path.display()))?;
    Ok(text)
}

/// `text` in a temp file beside `path`, with its mode (a person may have made it 0600).
fn temp_beside(path: &Path, text: &str) -> Result<tempfile::NamedTempFile> {
    let dir = path.parent().ok_or_else(|| anyhow!("{} has no folder", path.display()))?;
    let mut tmp = tempfile::NamedTempFile::new_in(dir)
        .with_context(|| format!("writing beside {}", path.display()))?;
    std::io::Write::write_all(&mut tmp, text.as_bytes())?;
    #[cfg(unix)]
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(tmp.path(), meta.permissions());
    }
    Ok(tmp)
}
