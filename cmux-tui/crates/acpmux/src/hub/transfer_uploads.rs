//! A moved chat takes its uploads along: the files the person dropped or pasted into it
//! (`file_uploads.rs`, `<ACPMUX_HOME>/uploads/<session id>/<upload id>/<name>`).
//!
//! Before this, a chat moved to a Cloud machine (or back) left its uploads on the machine they
//! were sent to. A prompt still queued with a reference to one (`prompt_uploads.rs`) was refused
//! at its turn on the target, and a later turn that opened an attached file found nothing. A
//! hybrid start with `--attach` (`chat_start/hybrid_start.rs`, #64309) runs its first turn here
//! for that reason. Leo, 2026-11-22: "moving sessions back and forth, the histories the pausing
//! the images".
//!
//! The source copies each finished upload into the bundle's `uploads/<upload id>/<name>`. A
//! folder's own files (`.part`, `.meta`, `.owner`, `.used`, the store's record) stay behind, and
//! so does any file [`file_uploads::open_finished`] would refuse: a symlink, a file that is not the
//! person's own, or a file with another name. The target keeps each file under the same upload id
//! in its own uploads folder for the chat, owner-only, so a reference resolves there as it did
//! here.
//!
//! The source bundles uploads only when [`enabled`] (`ACPMUX_MOVE_UPLOADS=1`). A move's size is
//! then its uploads' size too, so the default stays as it was until it is measured. The target
//! always takes them when it lists [`crate::capabilities::TRANSFER_UPLOADS`]. A target older than
//! that gets the chat without them: the move's client leaves them out
//! (`capabilities::leave_out_untaken`).

use super::file_uploads;
use std::path::Path;

/// The bundle folder a moved chat's uploads go in.
pub(crate) const BUNDLE_DIR: &str = "uploads";

/// The env flag that has a move's source bundle the chat's uploads.
pub(crate) const FLAG: &str = "ACPMUX_MOVE_UPLOADS";

/// Whether this daemon bundles a moved chat's uploads ([`FLAG`] is `1`).
pub(crate) fn enabled() -> bool {
    flag_on(std::env::var(FLAG).ok().as_deref())
}

fn flag_on(value: Option<&str>) -> bool {
    value.is_some_and(|v| v.trim() == "1")
}

/// Whether `upload` and `name` are a bundled upload's path parts: a UUIDv7 folder and a plain
/// file name that is not one of the folder's own dotfiles. Nothing else is read or written.
pub(crate) fn valid_parts(upload: &str, name: &str) -> bool {
    uuid::Uuid::try_parse(upload).is_ok_and(|id| id.get_version_num() == 7)
        && file_uploads::is_file_name(name)
        && !name.starts_with('.')
}

/// Copies chat `session`'s finished uploads into `bundle/uploads/`. Answers how many went.
/// Blocking.
pub(super) fn bundle_uploads(session: &str, bundle: &Path) -> std::io::Result<usize> {
    let Some(dir) = file_uploads::session_dir(session) else { return Ok(0) };
    let Ok(folders) = std::fs::read_dir(&dir) else { return Ok(0) };
    let mut copied = 0;
    for folder in folders.flatten() {
        if !folder.file_type().is_ok_and(|k| k.is_dir() && !k.is_symlink()) {
            continue;
        }
        let Some(upload) = folder.file_name().to_str().map(str::to_owned) else { continue };
        let Ok(files) = std::fs::read_dir(folder.path()) else { continue };
        for file in files.flatten() {
            let Some(name) = file.file_name().to_str().map(str::to_owned) else { continue };
            if !valid_parts(&upload, &name) || !file.file_type().is_ok_and(|k| k.is_file()) {
                continue;
            }
            // The same checks a prompt's reference passes before it is read.
            if file_uploads::open_finished(&file.path()).is_err() {
                continue;
            }
            let to = bundle.join(BUNDLE_DIR).join(&upload);
            crate::home_fs::create_dirs(&to)?;
            crate::home_fs::copy(file.path(), to.join(&name))?;
            copied += 1;
        }
    }
    Ok(copied)
}

/// Each bundled upload: its upload id, its name, its path in the bundle.
fn bundled(bundle: &Path) -> Vec<(String, String, std::path::PathBuf)> {
    let mut out = Vec::new();
    let Ok(folders) = std::fs::read_dir(bundle.join(BUNDLE_DIR)) else { return out };
    for folder in folders.flatten() {
        let Some(upload) = folder.file_name().to_str().map(str::to_owned) else { continue };
        let Ok(files) = std::fs::read_dir(folder.path()) else { continue };
        for file in files.flatten() {
            let Some(name) = file.file_name().to_str().map(str::to_owned) else { continue };
            if valid_parts(&upload, &name) && file.file_type().is_ok_and(|k| k.is_file()) {
                out.push((upload.clone(), name, file.path()));
            }
        }
    }
    out.sort();
    out
}

/// Keeps a moved chat's uploads here, under the same upload ids, in chat `session`'s uploads
/// folder. A file already there with the same size is kept as it is: a chat moved back finds its
/// own uploads. Answers how many are here now. Blocking.
pub(super) fn restore_uploads(bundle: &Path, session: &str) -> std::io::Result<usize> {
    let mut kept = 0;
    for (upload, name, from) in bundled(bundle) {
        let Some(dest) = file_uploads::finished_path(session, &upload, &name) else { continue };
        let size = std::fs::metadata(&from)?.len();
        if std::fs::symlink_metadata(&dest).is_ok_and(|m| m.is_file() && m.len() == size) {
            kept += 1;
            continue;
        }
        if let Some(parent) = dest.parent() {
            crate::home_fs::create_dirs(parent)?;
        }
        crate::home_fs::copy(&from, &dest)?;
        kept += 1;
    }
    Ok(kept)
}

/// The bundled uploads [`restore_uploads`] did not keep here, as bundle paths.
pub(super) fn unacked_uploads(bundle: &Path, session: &str) -> Vec<String> {
    bundled(bundle)
        .into_iter()
        .filter(|(upload, name, from)| {
            let size = std::fs::metadata(from).map(|m| m.len()).ok();
            let here = file_uploads::finished_path(session, upload, name)
                .and_then(|dest| std::fs::symlink_metadata(dest).ok())
                .filter(|m| m.is_file())
                .map(|m| m.len());
            here.is_none() || here != size
        })
        .map(|(upload, name, _)| format!("{BUNDLE_DIR}/{upload}/{name}"))
        .collect()
}

#[cfg(test)]
#[path = "transfer_uploads_tests.rs"]
mod tests;
