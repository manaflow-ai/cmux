//! `upload --socket PATH --remote-root DIR FILE...`: the files and folders
//! the person dropped, pasted or picked into a Cloud chat (the app runs it
//! on that gesture), each copied once to `DIR/local/uploads/<random
//! id>/<name>` on the machine, which the app then names in the chat.
//!
//! A folder may go when a folder grant could share it ([`grants::shareable`])
//! or it is in one of the places a dropped file may come from
//! ([`dropped_place`]), and its name is not a dot or credential folder's. Its
//! files go as a shared folder's do ([`super::shared_file`]: never a secret
//! file at any depth, nothing of a repository, in git only what git does
//! not ignore), and none on a path with a dot, credential or `Keychains`
//! name ([`folder_file`]); never a symlink, and no sync record is left with
//! the copy.
//!
//! What may go: a regular file (canonical, so a symlink is judged by where
//! it leads), whose name is not a secret file's or a dot
//! file's, and that is either one a file request could share (in the home
//! folder, outside `~/Library`, dot folders and credential folders:
//! [`grants::shareable_item`]), one in a place the person keeps files
//! outside those rules ([`dropped_place`]: iCloud Drive, a cloud-storage
//! folder, another volume, `/Users/Shared`), or in `cmux-pastes` of this
//! Mac's temporary folder, where the app writes what the person pasted
//! (never when the temporary folder and the home folder are inside one
//! another). Its name
//! must be one the machine can hold (no control character, at most 255
//! bytes). Every file of a call is checked before any goes: one refused
//! file (`upload_refused`) sends nothing. A link failure part way names the
//! files that already went.
//!
//! Known limit: a file is checked, then read again to be sent; a process of
//! this Mac's user that swaps a folder above it in between can make another
//! file of the same name go.

use std::path::{Path, PathBuf};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{Failure, grants, is_secret};
use crate::link::sync_cli;

/// Files one call takes.
const MAX_FILES: usize = 64;
/// The folder of the temporary folder the app writes pastes to.
const PASTES: &str = "cmux-pastes";
/// The longest file name the machine holds.
const MAX_NAME_BYTES: usize = 255;

#[cfg(test)]
pub(super) fn upload(socket: &Path, root: &str, files: &[String]) -> Result<Value, Failure> {
    upload_with_id(socket, root, files, None)
}

/// An app-owned id lets the app clean the exact transfer's directory after a killed CLI exits.
pub(super) fn upload_with_id(
    socket: &Path,
    root: &str,
    files: &[String],
    id: Option<&str>,
) -> Result<Value, Failure> {
    use std::io::Write as _;

    if id.is_some_and(|id| !valid_id(id) || files.len() != 1) {
        return Err(Failure::new("upload_refused", "an upload id names exactly one file"));
    }
    if files.is_empty() || files.len() > MAX_FILES {
        return Err(Failure::new("upload_refused", "upload 1 to 64 files at a time"));
    }
    let checked =
        files.iter().map(|file| uploadable(Path::new(file))).collect::<Result<Vec<_>, _>>()?;
    let mut uploads = Vec::new();
    let mut sent: Vec<String> = Vec::new();
    for (file, name, folder) in &checked {
        let at = format!(
            "{root}/local/uploads/{}/{name}",
            id.map(str::to_string).map(Ok).unwrap_or_else(random_id)?
        );
        let mut heartbeat = || {
            println!(r#"{{"progress":"upload"}}"#);
            let _ = std::io::stdout().flush();
        };
        let copied = if let Some(identity) = *folder {
            let keep = |relative: &str, git: bool| folder_file(file, relative, git);
            let enter = |relative: &str| relative.split('/').all(goes_by_name);
            sync_cli::copy_folder_with_progress(
                socket,
                file,
                identity,
                &at,
                &enter,
                &keep,
                &mut heartbeat,
            )
            .map(|(files, skipped)| json!({"folder": true, "files": files, "skipped": skipped}))
        } else {
            sync_cli::copy_file_with_progress(socket, file, &at, &mut heartbeat).map(|()| json!({}))
        };
        let mut entry = copied.map_err(|error| {
            let went = if sent.is_empty() {
                String::new()
            } else {
                format!("; already sent: {}", sent.join(", "))
            };
            Failure::new(&sync_cli::push_failure_code(&error), format!("{error:#}{went}"))
        })?;
        sent.push(at.clone());
        entry.set("file", json!(file));
        entry.set("path", json!(at));
        uploads.push(entry);
    }
    Ok(json!({"uploads": uploads}))
}

/// Whether the file at `relative` of an uploaded `folder` goes: as a shared
/// folder's would ([`super::shared_file`]), and with no dot file or folder,
/// credential folder or `Keychains` folder anywhere on its path, so a folder
/// that holds a home's worth of files (a backup's `Library/Keychains`,
/// `.config`) sends none of those. Such a folder is not even listed, so one
/// this Mac's user cannot read is skipped, not a failed upload.
fn folder_file(folder: &Path, relative: &str, git: bool) -> bool {
    relative.split('/').all(goes_by_name) && super::shared_file(folder, relative, git)
}

/// Whether a file or folder of this name inside an uploaded folder may go:
/// not a dot, credential or `Keychains` name.
fn goes_by_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    !name.starts_with('.')
        && !super::SECRET_FOLDERS.contains(&lower.as_str())
        && lower != "keychains"
}

/// Only the random transfer directory can be removed, never an arbitrary relative path.
fn valid_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub(super) fn cancel(socket: &Path, root: &str, id: &str) -> Result<Value, Failure> {
    if !valid_id(id) {
        return Err(Failure::new("upload_refused", "invalid upload id"));
    }
    sync_cli::delete_remote(socket, &format!("{root}/local/uploads/{id}")).map_err(|error| {
        Failure::new(&sync_cli::push_failure_code(&error), format!("{error:#}"))
    })?;
    Ok(json!({}))
}

/// A checked upload: the canonical path, its name, and for a folder the
/// device and inode it had when checked, so a folder swapped in later is
/// refused.
type Checked = (PathBuf, String, Option<(u64, u64)>);

/// The canonical file or folder at `path`, when it may be uploaded.
fn uploadable(path: &Path) -> Result<Checked, Failure> {
    let refused = |why: &str| {
        Failure::new("upload_refused", format!("{} cannot be uploaded: {why}", path.display()))
    };
    let canonical = std::fs::canonicalize(path).map_err(|_| refused("it does not exist"))?;
    let meta = std::fs::metadata(&canonical).map_err(|_| refused("it does not exist"))?;
    if !meta.is_file() && !meta.is_dir() {
        return Err(refused("only files and folders can be uploaded"));
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
    // A keychain folder anywhere on the way, the upload's own folder included.
    if canonical.iter().any(|part| part.eq_ignore_ascii_case("keychains")) {
        return Err(refused("keychains are never uploaded"));
    }
    if meta.is_dir() {
        let identity = {
            use std::os::unix::fs::MetadataExt as _;
            Some((meta.dev(), meta.ino()))
        };
        if super::SECRET_FOLDERS.contains(&name.to_ascii_lowercase().as_str()) {
            return Err(refused("credential folders are never uploaded"));
        }
        return match grants::shareable(&canonical) {
            Ok(_) => Ok((canonical, name, identity)),
            Err(_) if dropped_place(&canonical, &grants::homes()) => {
                Ok((canonical, name, identity))
            }
            Err(why) => Err(refused(&why.to_string())),
        };
    }
    if pasted(&canonical) {
        return Ok((canonical, name, None));
    }
    match grants::shareable_item(&canonical) {
        Ok(_) => Ok((canonical, name, None)),
        Err(_) if dropped_place(&canonical, &grants::homes()) => Ok((canonical, name, None)),
        Err(why) => Err(refused(&why.to_string())),
    }
}

/// Places under `~/Library` where the person keeps their own files, and how
/// many names below one a file must be: iCloud Drive itself, and a
/// cloud-storage provider's own folder (`CloudStorage/<provider>/...`).
/// Apps' own iCloud containers stay refused with the rest of `~/Library`.
const HOME_PLACES: &[(&str, usize)] =
    &[("Library/Mobile Documents/com~apple~CloudDocs", 1), ("Library/CloudStorage", 2)];
/// Places outside the home folder where the person keeps their own files:
/// another or external volume (in its own folder, never `/Volumes` itself)
/// and the Mac's shared folder.
const OTHER_PLACES: &[(&str, usize)] = &[("/Volumes", 2), ("/Users/Shared", 1)];

/// Whether the canonical file `canonical`, which the home folder's share
/// rules refuse, is in a place the person keeps their own files
/// ([`HOME_PLACES`] of a home in `homes`, or [`OTHER_PLACES`]), with no dot
/// folder or credential folder anywhere on its path from the disk root
/// (`/Volumes/disk/gcloud/...` stays refused). The file's own name is
/// checked by the caller. The rest of `~/Library`, system folders, the
/// temporary folders and other people's home folders stay refused.
fn dropped_place(canonical: &Path, homes: &[PathBuf]) -> bool {
    let places = homes
        .iter()
        .flat_map(|home| HOME_PLACES.iter().map(move |(place, depth)| (home.join(place), *depth)))
        .chain(OTHER_PLACES.iter().map(|(place, depth)| (PathBuf::from(place), *depth)));
    let placed = places.into_iter().any(|(place, depth)| {
        canonical.strip_prefix(&place).is_ok_and(|rest| rest.components().count() >= depth)
    });
    let Some(parent) = canonical.parent().filter(|_| placed) else { return false };
    parent.components().all(|part| match part {
        std::path::Component::RootDir => true,
        std::path::Component::Normal(name) => {
            let name = name.to_string_lossy();
            !name.starts_with('.')
                && !super::SECRET_FOLDERS.contains(&name.to_ascii_lowercase().as_str())
        }
        _ => false,
    })
}

/// Whether `canonical` is in the app's paste folder of this Mac's
/// temporary folder (not in a dot or credential folder there).
fn pasted(canonical: &Path) -> bool {
    let Ok(tmp) = std::fs::canonicalize(std::env::temp_dir()) else { return false };
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

#[cfg(test)]
#[path = "uploads_tests.rs"]
mod tests;
