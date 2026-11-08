//! `--from-folder DIR`: a folder on this Mac the chat starts in a copy of. The app copies it the way the
//! agent pane composer's Cloud start copies one, and a retry on the same machine reuses the finished copy.
//! This checks it before any step runs, so a refused folder never gets a machine made for it
//! (`--environment` makes one before `cloud start-session` reads the folder).

use std::path::Path;

use super::UsageError;
use crate::link::sync_cli::skips::{home_credential_folder, within};

/// `--from-folder DIR`, checked: never with `--cwd`, an absolute folder that exists on this Mac, never
/// this Mac's home, a folder above it (the disk's root too) or one that is in or holds a credential
/// folder of home's, as the app refuses one. Answered canonical.
pub(super) fn local_folder(dir: &str, with_cwd: bool) -> Result<String, UsageError> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    local_folder_in(dir, with_cwd, home.as_deref())
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
    if !Path::new(dir).is_absolute() {
        return Err(UsageError::new(format!(
            "--from-folder {dir}: an absolute folder on this Mac"
        )));
    }
    let folder = match std::fs::canonicalize(dir) {
        Ok(path) if path.is_dir() => path.to_string_lossy().into_owned(),
        Ok(_) => return Err(UsageError::new(format!("--from-folder {dir}: not a folder"))),
        Err(error) => return Err(UsageError::new(format!("--from-folder {dir}: {error}"))),
    };
    let home = home.map(|home| {
        std::fs::canonicalize(home)
            .unwrap_or_else(|_| home.to_owned())
            .to_string_lossy()
            .into_owned()
    });
    if folder == "/" || home.as_deref().is_some_and(|home| within(home, &folder)) {
        return Err(UsageError::new(format!(
            "--from-folder {dir}: your home folder or a folder above it; pick a project folder"
        )));
    }
    if let Some(secret) =
        home.as_deref().and_then(|home| home_credential_folder(&folder, home))
    {
        return Err(UsageError::new(format!(
            "--from-folder {dir}: is or holds ~/{secret}, a folder of keys or logins, which never goes to a machine"
        )));
    }
    Ok(folder)
}
