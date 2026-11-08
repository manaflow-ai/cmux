//! The journal's storage behind the lost-home fence (`config::refuse_lost_home`).

use super::*;

/// The journal's storage, refusing every write under a lost home: `fence` (in the daemon,
/// `config::refuse_lost_home`) is asked before each operation that makes, writes, renames or
/// removes a file or folder. Reads, syncs and the lock are not writes.
pub(crate) struct FencedStorage {
    inner: Arc<dyn cmux_journal::Storage>,
    fence: Box<dyn Fn(&Path) -> Result<()> + Send + Sync>,
}

impl FencedStorage {
    pub(crate) fn new(
        inner: Arc<dyn cmux_journal::Storage>,
        fence: Box<dyn Fn(&Path) -> Result<()> + Send + Sync>,
    ) -> Self {
        Self { inner, fence }
    }

    /// The daemon's: the real file system behind `config::refuse_lost_home`.
    pub(crate) fn daemon() -> Self {
        Self::new(Arc::new(cmux_journal::FsStorage), Box::new(crate::config::refuse_lost_home))
    }

    fn check(&self, path: &Path) -> std::io::Result<()> {
        (self.fence)(path).map_err(|error| std::io::Error::other(format!("{error:#}")))
    }
}

impl cmux_journal::Storage for FencedStorage {
    fn create_dir_all(&self, dir: &Path) -> std::io::Result<()> {
        self.check(dir)?;
        self.inner.create_dir_all(dir)
    }
    fn list(&self, dir: &Path) -> std::io::Result<Vec<String>> {
        self.inner.list(dir)
    }
    fn open(
        &self,
        path: &Path,
        mode: cmux_journal::OpenMode,
    ) -> std::io::Result<Box<dyn cmux_journal::StorageFile>> {
        if mode != cmux_journal::OpenMode::Read {
            self.check(path)?;
        }
        self.inner.open(path, mode)
    }
    fn rename(&self, from: &Path, to: &Path) -> std::io::Result<()> {
        self.check(from)?;
        self.check(to)?;
        self.inner.rename(from, to)
    }
    fn remove_file(&self, path: &Path) -> std::io::Result<()> {
        self.check(path)?;
        self.inner.remove_file(path)
    }
    fn sync_dir(&self, dir: &Path) -> std::io::Result<()> {
        self.inner.sync_dir(dir)
    }
    fn try_lock(&self, path: &Path) -> std::io::Result<Option<Box<dyn cmux_journal::StorageLock>>> {
        self.inner.try_lock(path)
    }
}
