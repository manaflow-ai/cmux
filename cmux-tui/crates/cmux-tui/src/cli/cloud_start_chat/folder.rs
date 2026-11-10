//! `--from-folder DIR`: a folder on this Mac the chat starts in a copy of. The app copies it the way the
//! agent pane composer's Cloud start copies one, and a retry on the same machine reuses the finished copy.
//! This checks it before any step runs, so a refused folder never gets a machine made for it
//! (`--environment` makes one before `cloud start-session` reads the folder).

use std::path::Path;

use super::UsageError;
use crate::link::sync_cli::skips::{credential_folder_of, home_credential_folder, within};

/// The code of a `--from-folder` this Mac refuses for what the folder is (home, a key folder,
/// gone): printed as its reason and what to do, never with the whole help, exit 2 kept.
pub(super) const REFUSED_CODE: &str = "cloud_start_chat.folder_refused";

/// What starts the message of a folder refusal in a [`UsageError`] (never shown).
const REFUSED: &str = "\u{1}folder:";

/// A [`UsageError`] that is a folder refusal ([`REFUSED_CODE`]).
fn refused(message: String) -> UsageError {
    UsageError::new(format!("{REFUSED}{message}"))
}

/// The reason of a folder refusal ([`refused`]); none for any other usage error.
pub(super) fn refusal(error: &UsageError) -> Option<&str> {
    error.0.strip_prefix(REFUSED)
}

/// `--from-folder DIR`, checked as the app checks it: never with `--cwd`, at most 4096 bytes with no
/// control character, a folder that exists on this Mac, never
/// this Mac's home, a folder above it (the disk's root too) or one that is in or holds a credential
/// folder of home's, as the app refuses one. A relative `DIR` is a folder of the caller's working
/// directory, made absolute as `cloud start-session --from-folder` makes it
/// (`app::caller_absolute`). Answered canonical.
pub(super) fn local_folder(dir: &str, with_cwd: bool) -> Result<String, UsageError> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    let absolute = crate::cli::app::caller_absolute(dir);
    local_folder_in(absolute.as_deref().unwrap_or(dir), with_cwd, home.as_deref())
}

/// [`local_folder`] with `home` given (none: no home check, as with no `HOME`).
pub(super) fn local_folder_in(
    dir: &str,
    with_cwd: bool,
    home: Option<&Path>,
) -> Result<String, UsageError> {
    if with_cwd {
        return Err(UsageError::new("give --from-folder or --cwd, not both"));
    }
    if dir.len() > 4096 || dir.chars().any(char::is_control) {
        return Err(refused("--from-folder: a path with no control characters".to_owned()));
    }
    if !Path::new(dir).is_absolute() {
        return Err(refused(format!("--from-folder {dir}: an absolute folder on this Mac")));
    }
    let folder = match std::fs::canonicalize(dir) {
        Ok(path) if path.is_dir() => path.to_string_lossy().into_owned(),
        Ok(_) => return Err(refused(format!("--from-folder {dir}: not a folder"))),
        Err(error) => return Err(refused(format!("--from-folder {dir}: {error}"))),
    };
    let home = home.map(|home| {
        std::fs::canonicalize(home)
            .unwrap_or_else(|_| home.to_owned())
            .to_string_lossy()
            .into_owned()
    });
    if folder == "/" || home.as_deref().is_some_and(|home| within(home, &folder)) {
        return Err(refused(format!(
            "--from-folder {dir}: your home folder or a folder above it, too broad to copy. \
             Pick the project folder inside it"
        )));
    }
    if let Some(secret) = home.as_deref().and_then(|home| home_credential_folder(&folder, home)) {
        return Err(refused(format!(
            "--from-folder {dir}: is or holds ~/{secret}, a folder of keys or logins, which never goes to a machine"
        )));
    }
    if let Some(secret) = credential_folder_of(&folder) {
        return Err(refused(format!(
            "--from-folder {dir}: is in a {secret} folder, a folder of keys or logins, which never goes to a machine"
        )));
    }
    Ok(folder)
}
