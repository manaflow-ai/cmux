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
    /// The pump's mark sent with the begin (`agent-transfer-begin-token-v1`), saved before it
    /// is sent. A record with no `transfer_id` is a begin whose answer was lost: the source's
    /// `transfer.moving` refusal hands this token back for the move that begin made.
    #[serde(default)]
    pub begin_token: Option<String>,
    /// The source tab's public id (its `agent-transfer-source` or begin answer): a restart of
    /// the source daemon restores the tab in a new surface slot, so a give back, commit or
    /// check after one names the tab by this. None from a source too old to answer it.
    #[serde(default)]
    pub source_tab: Option<String>,
}

/// Where the record of one chat's move is kept, locked for this run.
pub(super) struct Records {
    path: PathBuf,
    _lock: std::fs::File,
    /// The surface slot's lock, also held when the record is filed by the tab: a pump of the
    /// same chat by its slot alone (an older cmux-tui) never runs beside this one.
    _slot_lock: Option<std::fs::File>,
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
    /// The record place for the chat in `surface` of the daemon at `from` under `dir` (default
    /// `<daemon state dir>/agent-moves`, mode 0700), filed by `tab` (the tab's public id) when
    /// the source answered one, else by the surface slot.
    ///
    /// By the tab because a restart of the source daemon restores every tab in a new surface
    /// slot: a rerun by that slot found no record under the old one, began a second move of a
    /// chat that had landed on the target, and the chat stayed open in two places with its
    /// queued prompt run on both (kill-mid-move drill off-src, run 45907132927). A record a
    /// slot-filed run left for this slot is taken over.
    pub(super) fn open(
        dir: Option<PathBuf>,
        from: &Path,
        surface: u64,
        tab: Option<&str>,
    ) -> anyhow::Result<Self> {
        let dir = match dir {
            Some(dir) => dir,
            None => cmux_tui_core::platform::workspace_state_dir()
                .context("no state directory")?
                .join("agent-moves"),
        };
        create_private_dir(&dir)
            .with_context(|| format!("cannot make the state folder {}", dir.display()))?;
        let from = std::fs::canonicalize(from).unwrap_or_else(|_| from.to_path_buf());
        let digest = Sha256::digest(from.as_os_str().as_encoded_bytes());
        let key: String = digest.iter().take(8).map(|byte| format!("{byte:02x}")).collect();
        let slot_path = dir.join(format!("{surface}-{key}.json"));
        let Some(tab) = tab.filter(|tab| is_file_word(tab)) else {
            // No tab answered (a source restarted since, so the slot is stale, or one too old):
            // the slot's name may be an alias of the tab-filed record a run by the tab left.
            let slot_lock = take_lock(&slot_path)?;
            if let Ok(target) = std::fs::read_link(&slot_path)
                && let Some(name) = target.file_name().filter(|name| {
                    name.to_str().and_then(|name| name.strip_suffix(".json")).is_some_and(|stem| {
                        stem.strip_suffix(&format!("-{key}")).is_some_and(is_file_word)
                    })
                })
            {
                let path = dir.join(name);
                let lock = take_lock(&path)?;
                return Ok(Self { path, _lock: lock, _slot_lock: Some(slot_lock) });
            }
            return Ok(Self { path: slot_path, _lock: slot_lock, _slot_lock: None });
        };
        let path = dir.join(format!("{tab}-{key}.json"));
        let lock = take_lock(&path)?;
        let slot_lock = take_lock(&slot_path)?;
        let records = Self { path, _lock: lock, _slot_lock: Some(slot_lock) };
        let slot_kind = std::fs::symlink_metadata(&slot_path).map(|meta| meta.file_type());
        if records.load()?.is_none()
            && slot_kind.as_ref().is_ok_and(std::fs::FileType::is_file)
            && let Ok(bytes) = std::fs::read(&slot_path)
            && serde_json::from_slice::<Record>(&bytes)
                .is_ok_and(|kept| kept.source_tab.as_deref().is_none_or(|kept| kept == tab))
        {
            std::fs::rename(&slot_path, &records.path)
                .context("cannot take over the move record")?;
        }
        // The slot's name becomes an alias of this record, so a rerun by this slot that no
        // longer names the tab (its source restarted since) still finds the move. A slot file
        // of another tab's unended move (an older pump's) is left alone.
        let slot_free = match std::fs::symlink_metadata(&slot_path) {
            Ok(meta) => meta.file_type().is_symlink(),
            Err(error) => error.kind() == std::io::ErrorKind::NotFound,
        };
        if slot_free && let Some(name) = records.path.file_name() {
            let alias = slot_path.with_extension("json.alias");
            let _ = std::fs::remove_file(&alias);
            std::os::unix::fs::symlink(name, &alias).context("cannot name the move record")?;
            std::fs::rename(&alias, &slot_path).context("cannot name the move record")?;
        }
        Ok(records)
    }

    pub(super) fn load(&self) -> anyhow::Result<Option<Record>> {
        match std::fs::read(&self.path) {
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
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .context("cannot write the move record")?;
        file.write_all(&serde_json::to_vec(record)?)?;
        file.sync_all()?;
        std::fs::rename(&temporary, &self.path).context("cannot save the move record")?;
        // The rename itself survives a crash once its folder is synced.
        if let Some(dir) = self.path.parent() {
            std::fs::File::open(dir)?.sync_all()?;
        }
        Ok(())
    }

    pub(super) fn clear(&self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Locks `record`'s lock file for this run.
fn take_lock(record: &Path) -> anyhow::Result<std::fs::File> {
    let lock = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(record.with_extension("lock"))
        .context("cannot open the move lock")?;
    match lock.try_lock() {
        Ok(()) => Ok(lock),
        Err(std::fs::TryLockError::WouldBlock) => Err(Busy.into()),
        Err(std::fs::TryLockError::Error(error)) => Err(error).context("cannot take the move lock"),
    }
}

/// A tab id that is safe as part of a file name (`tab_` and hex in practice).
fn is_file_word(word: &str) -> bool {
    !word.is_empty()
        && word.len() <= 64
        && word.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

fn create_private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}
