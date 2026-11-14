//! The capabilities a session daemon advertised, remembered per daemon
//! process so a command from an agent's terminal does not send one more
//! `identify` before every request (that round trip doubled each call on a
//! busy session).
//!
//! An entry is keyed by the socket path and the daemon's process key
//! (`token:<pid>.<pid version>`, from the connection itself): a restarted or
//! re-exec'd daemon has another key, so its entry is never reused. Only
//! capabilities a daemon process keeps for its whole life may be checked
//! through the cache (launch credentials, notification fields).
//!
//! The files live in `$TMPDIR/cmux-cli-capabilities-<uid>/`, a directory
//! this user alone may write; an entry in a directory that fails that check
//! is ignored, and a failure to save only costs the next call an `identify`.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// Where remembered capabilities are kept; `None` keeps nothing.
pub(super) struct CapabilityCache {
    directory: Option<PathBuf>,
}

impl CapabilityCache {
    /// This user's cache under the temporary directory.
    pub(super) fn for_user() -> Self {
        #[cfg(unix)]
        {
            let uid = cmux_tui_core::platform::effective_uid();
            let directory = std::env::temp_dir().join(format!("cmux-cli-capabilities-{uid}"));
            Self { directory: Some(directory) }
        }
        #[cfg(not(unix))]
        {
            Self { directory: None }
        }
    }

    #[cfg(test)]
    pub(super) fn at(directory: PathBuf) -> Self {
        Self { directory: Some(directory) }
    }

    /// The capabilities the daemon `peer` on `socket` advertised, if known.
    pub(super) fn load(&self, socket: &Path, peer: &str) -> Option<Vec<String>> {
        let directory = self.trusted_directory()?;
        let bytes = std::fs::read(directory.join(entry_name(socket))).ok()?;
        let entry: Value = serde_json::from_slice(&bytes).ok()?;
        if entry["socket"].as_str() != socket.to_str() || entry["peer"].as_str() != Some(peer) {
            return None;
        }
        entry["capabilities"]
            .as_array()?
            .iter()
            .map(|capability| capability.as_str().map(str::to_owned))
            .collect()
    }

    /// Remember `capabilities` for the daemon `peer` on `socket`; best effort.
    pub(super) fn store(&self, socket: &Path, peer: &str, capabilities: &[String]) {
        let Some(directory) = self.directory.as_deref() else { return };
        let Some(socket_text) = socket.to_str() else { return };
        if create_private_directory(directory).is_err() || self.trusted_directory().is_none() {
            return;
        }
        let entry = json!({"socket": socket_text, "peer": peer, "capabilities": capabilities});
        let name = entry_name(socket);
        let temporary = directory.join(format!(".{name}.{}", std::process::id()));
        if write_private(&temporary, entry.to_string().as_bytes()).is_ok()
            && std::fs::rename(&temporary, directory.join(&name)).is_err()
        {
            let _ = std::fs::remove_file(&temporary);
        }
    }

    /// The directory, when it exists and only this user may write it.
    fn trusted_directory(&self) -> Option<&Path> {
        let directory = self.directory.as_deref()?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let metadata = std::fs::symlink_metadata(directory).ok()?;
            let ours =
                metadata.is_dir() && metadata.uid() == cmux_tui_core::platform::effective_uid();
            (ours && metadata.mode() & 0o077 == 0).then_some(directory)
        }
        #[cfg(not(unix))]
        {
            Some(directory)
        }
    }
}

/// One file per socket path: its hash, so any path makes a plain file name.
fn entry_name(socket: &Path) -> String {
    let digest = Sha256::digest(socket.as_os_str().as_encoded_bytes());
    let hex: String = digest.iter().take(16).map(|byte| format!("{byte:02x}")).collect();
    format!("{hex}.json")
}

fn create_private_directory(directory: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        match std::fs::DirBuilder::new().mode(0o700).create(directory) {
            Err(error) if error.kind() != std::io::ErrorKind::AlreadyExists => Err(error),
            _ => Ok(()),
        }
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(directory)
    }
}

fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)?.write_all(bytes)
}

#[cfg(test)]
mod tests;
