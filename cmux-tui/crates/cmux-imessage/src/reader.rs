use std::path::{Path, PathBuf};

use crate::error::MirrorError;
use crate::model::{Message, Thread};

/// The most rows one call returns, whatever the caller asks for.
pub const MAX_LIMIT: usize = 500;

/// `~/Library/Messages/chat.db` for the current user, when `HOME` is set.
pub fn default_database_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(Path::new(&home).join("Library/Messages/chat.db"))
}

/// A read-only connection to a Messages database (not implemented yet).
pub struct Reader;

impl Reader {
    pub fn open(path: &Path) -> Result<Self, MirrorError> {
        Err(MirrorError::Schema(format!("not implemented: {}", path.display())))
    }
    pub fn threads(&self, _limit: usize) -> Result<Vec<Thread>, MirrorError> {
        Ok(Vec::new())
    }
    pub fn messages(&self, _chat_id: i64, _before_rowid: Option<i64>, _limit: usize) -> Result<Vec<Message>, MirrorError> {
        Ok(Vec::new())
    }
    pub fn since(&self, _after_rowid: i64, _limit: usize) -> Result<Vec<Message>, MirrorError> {
        Ok(Vec::new())
    }
    pub fn latest_rowid(&self) -> Result<i64, MirrorError> {
        Ok(0)
    }
}
