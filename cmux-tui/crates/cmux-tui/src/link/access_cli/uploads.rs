//! `upload --socket PATH --remote-root DIR FILE...`: the files the person
//! dropped or pasted into a Cloud chat (the app runs it on that gesture),
//! each copied once to `DIR/local/uploads/<random id>/<name>` on the
//! machine, which the app then names in the chat.
//!
//! What may go: a regular file (canonical, so a symlink is judged by where
//! it leads) of at most 1 GiB, whose name is not a secret file's or a dot
//! file's, and that is either one a file request could share (in the home
//! folder, outside `~/Library`, dot folders and credential folders:
//! [`grants::shareable_item`]) or in `cmux-pastes` of this Mac's temporary
//! folder, where the app writes what the person pasted (never when the
//! temporary folder and the home folder are inside one another). Its name
//! must be one the machine can hold (no control character, at most 255
//! bytes). Every file of a call is checked before any goes: one refused
//! file (`upload_refused`) sends nothing. A link failure part way names the
//! files that already went.
//!
//! Known limit: a file is checked, then read again to be sent; a process of
//! this Mac's user that swaps a folder above it in between can make another
//! file of the same name go.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::{Failure, grants, is_secret};
use crate::link::sync_cli;

/// Files one call takes.
const MAX_FILES: usize = 64;
/// The largest file uploaded.
const MAX_FILE_BYTES: u64 = 1 << 30;
/// The folder of the temporary folder the app writes pastes to.
const PASTES: &str = "cmux-pastes";
/// The longest file name the machine holds.
const MAX_NAME_BYTES: usize = 255;

pub(super) fn upload(socket: &Path, root: &str, files: &[String]) -> Result<Value, Failure> {
    if files.is_empty() || files.len() > MAX_FILES {
        return Err(Failure::new("upload_refused", "upload 1 to 64 files at a time"));
    }
    let checked =
        files.iter().map(|file| uploadable(Path::new(file))).collect::<Result<Vec<_>, _>>()?;
    let mut uploads = Vec::new();
    let mut sent: Vec<String> = Vec::new();
    for (file, name) in &checked {
        let at = format!("{root}/local/uploads/{}/{name}", random_id()?);
        sync_cli::copy_file(socket, file, &at).map_err(|error| {
            let went = if sent.is_empty() {
                String::new()
            } else {
                format!("; already sent: {}", sent.join(", "))
            };
            Failure::new(&sync_cli::push_failure_code(&error), format!("{error:#}{went}"))
        })?;
        sent.push(at.clone());
        uploads.push(json!({"file": file, "path": at}));
    }
    Ok(json!({"uploads": uploads}))
}

/// The canonical file at `path` and its name, when it may be uploaded.
fn uploadable(path: &Path) -> Result<(PathBuf, String), Failure> {
    let refused = |why: &str| {
        Failure::new("upload_refused", format!("{} cannot be uploaded: {why}", path.display()))
    };
    let canonical =
        cmux_blocking::fs::canonicalize(path).map_err(|_| refused("it does not exist"))?;
    let meta = cmux_blocking::fs::metadata(&canonical).map_err(|_| refused("it does not exist"))?;
    if !meta.is_file() {
        return Err(refused("only files can be uploaded"));
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err(refused("it is larger than 1 GiB"));
    }
    let name = canonical
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| refused("its name is not UTF-8"))?
        .to_string();
    if name.len() > MAX_NAME_BYTES || name.chars().any(char::is_control) {
        return Err(refused("the machine cannot hold its name"));
    }
    if name.starts_with('.') || is_secret(&name) {
        return Err(refused("secret files are never uploaded"));
    }
    if pasted(&canonical) {
        return Ok((canonical, name));
    }
    grants::shareable_item(&canonical).map_err(|why| refused(&why.to_string()))?;
    Ok((canonical, name))
}

/// Whether `canonical` is in the app's paste folder of this Mac's
/// temporary folder (not in a dot or credential folder there).
fn pasted(canonical: &Path) -> bool {
    let Ok(tmp) = cmux_blocking::fs::canonicalize(std::env::temp_dir()) else { return false };
    // A temporary folder that holds the home folder, or is in it, would
    // open what the home folder's rules keep.
    let homes = grants::homes();
    if tmp.components().count() < 2
        || homes.is_empty()
        || homes.iter().any(|home| home.starts_with(&tmp) || tmp.starts_with(home))
    {
        return false;
    }
    let Ok(inside) = canonical.strip_prefix(tmp.join(PASTES)) else { return false };
    let inside = inside.to_string_lossy();
    !inside.split('/').any(|name| name.starts_with('.')) && !is_secret(&inside)
}

/// A new upload folder's name: 16 random bytes in hex.
fn random_id() -> Result<String, Failure> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|error| Failure::new("upload_failed", format!("no random id: {error}")))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}
