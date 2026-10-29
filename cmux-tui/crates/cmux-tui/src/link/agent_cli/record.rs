//! The record of a move this Mac began and has not ended, one file per chat
//! (source socket and surface), so a rerun can resolve a move a lost answer
//! left frozen. A Mac source names no target acpmux could ask itself, so
//! without this record nothing would end such a move. A run holds the
//! record's lock throughout, so two pumps never move one chat at once.

use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

/// One unended move.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub(super) struct Record {
    pub transfer_id: String,
    /// The chat the move took (begin's manifest): nothing is ended for a tab
    /// that now shows another.
    #[serde(default)]
    pub source_session_id: Option<String>,
    /// The target daemon's socket, as this Mac reaches it.
    pub to_socket: PathBuf,
    pub cwd: String,
    #[serde(default)]
    pub receive_id: Option<String>,
    #[serde(default)]
    pub session_id: Option<String>,
    /// Set before the finish is sent: from then on only the target can say
    /// whether the chat is there.
    #[serde(default)]
    pub finish_sent: bool,
    /// What the target answered (it forgot the move, so a "no" holds).
    #[serde(default)]
    pub landed: Option<bool>,
}

/// Where the record of one chat's move is kept, locked for this run.
pub(super) struct Records {
    path: PathBuf,
    _lock: std::fs::File,
}

/// Another run holds the record's lock.
#[derive(Debug)]
pub(super) struct Busy;

impl std::fmt::Display for Busy {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("another move of this chat is running")
    }
}

impl std::error::Error for Busy {}

impl Records {
    /// The record place for `surface` of the daemon at `from` under `dir`
    /// (default `<daemon state dir>/agent-moves`, mode 0700).
    pub(super) fn open(dir: Option<PathBuf>, from: &Path, surface: u64) -> anyhow::Result<Self> {
        let dir = match dir {
            Some(dir) => dir,
            None => cmux_tui_core::platform::workspace_state_dir()
                .context("no state directory")?
                .join("agent-moves"),
        };
        create_private_dir(&dir)
            .with_context(|| format!("cannot make the state folder {}", dir.display()))?;
        let from = cmux_blocking::fs::canonicalize(from).unwrap_or_else(|_| from.to_path_buf());
        let digest = Sha256::digest(from.as_os_str().as_encoded_bytes());
        let key: String = digest.iter().take(8).map(|byte| format!("{byte:02x}")).collect();
        let path = dir.join(format!("{surface}-{key}.json"));
        let lock = crate::blocking::fs::open_with(
            std::fs::OpenOptions::new().write(true).create(true).truncate(false).mode(0o600),
            path.with_extension("lock"),
        )
        .context("cannot open the move lock")?;
        match lock.try_lock() {
            Ok(()) => {}
            Err(std::fs::TryLockError::WouldBlock) => return Err(Busy.into()),
            Err(std::fs::TryLockError::Error(error)) => {
                return Err(error).context("cannot take the move lock");
            }
        }
        Ok(Self { path, _lock: lock })
    }

    pub(super) fn load(&self) -> anyhow::Result<Option<Record>> {
        match cmux_blocking::fs::read(&self.path) {
            Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes).with_context(|| {
                format!("the move record {} is unreadable", self.path.display())
            })?)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error).context("cannot read the move record"),
        }
    }

    /// Replaces the record (written whole, then renamed into place).
    pub(super) fn save(&self, record: &Record) -> anyhow::Result<()> {
        let temporary = self.path.with_extension("json.tmp");
        let mut file = crate::blocking::fs::open_with(
            std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600),
            &temporary,
        )
        .context("cannot write the move record")?;
        file.write_all(&serde_json::to_vec(record)?)?;
        crate::blocking::fs::sync_all(&file)?;
        cmux_blocking::fs::rename(&temporary, &self.path).context("cannot save the move record")?;
        // The rename itself survives a crash once its folder is synced.
        if let Some(dir) = self.path.parent() {
            crate::blocking::fs::sync_all(&cmux_blocking::fs::open(dir)?)?;
        }
        Ok(())
    }

    pub(super) fn clear(&self) {
        let _ = cmux_blocking::fs::remove_file(&self.path);
    }
}

fn create_private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
    crate::blocking::fs::create_dir_with(
        std::fs::DirBuilder::new().recursive(true).mode(0o700),
        dir,
    )?;
    crate::blocking::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}
