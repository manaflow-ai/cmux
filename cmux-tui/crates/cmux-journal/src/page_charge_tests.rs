//! What the journal's writes cost a kernel that charges a process by the pages it dirties
//! (cmuxterm-hq#11322). macOS filed a "disk writes" report against the daemon (2 GB of
//! file-backed memory dirtied in 11,502 s, under `FsFile::append`): it charges a 16 KiB page each
//! time a clean page becomes dirty, and a sync cleans every page it wrote, so the next append
//! into the same page is charged in full again. Linux charges the same way, per 4 KiB page
//! (`write_bytes` in /proc/<pid>/io). So a journal pays at least one page per sync that follows
//! a write, however few bytes the write added.
//!
//! [`Charged`] wraps a storage and counts those charges at [`MACOS_PAGE`]: per file, the pages
//! written since the file's last sync.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use crate::{
    Class, Config, Journal, Lsn, OpenMode, SimStorage, Storage, StorageFile, StorageLock, SyncLevel,
};

/// The macOS page size on arm64: what one dirtied page costs there.
const MACOS_PAGE: u64 = 16 * 1024;
const WAIT: Duration = Duration::from_secs(10);

#[derive(Default)]
struct Counts {
    /// Per file, the pages written since its last sync.
    dirty: BTreeMap<PathBuf, BTreeSet<u64>>,
    /// Clean pages a write made dirty: what the kernel charges.
    charged_pages: u64,
    syncs: u64,
    appends: u64,
}

#[derive(Clone, Default)]
struct Meter(Arc<Mutex<Counts>>);

impl Meter {
    fn with<T>(&self, f: impl FnOnce(&mut Counts) -> T) -> T {
        f(&mut self.0.lock().unwrap_or_else(PoisonError::into_inner))
    }

    fn charged_bytes(&self) -> u64 {
        self.with(|c| c.charged_pages * MACOS_PAGE)
    }
}

struct Charged {
    inner: Arc<dyn Storage>,
    meter: Meter,
}

impl Storage for Charged {
    fn create_dir_all(&self, dir: &Path) -> io::Result<()> {
        self.inner.create_dir_all(dir)
    }
    fn list(&self, dir: &Path) -> io::Result<Vec<String>> {
        self.inner.list(dir)
    }
    fn open(&self, path: &Path, mode: OpenMode) -> io::Result<Box<dyn StorageFile>> {
        let file = self.inner.open(path, mode)?;
        Ok(Box::new(ChargedFile { file, path: path.to_path_buf(), meter: self.meter.clone() }))
    }
    fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
        self.inner.rename(from, to)
    }
    fn remove_file(&self, path: &Path) -> io::Result<()> {
        self.inner.remove_file(path)
    }
    fn sync_dir(&self, dir: &Path) -> io::Result<()> {
        self.inner.sync_dir(dir)
    }
    fn try_lock(&self, path: &Path) -> io::Result<Option<Box<dyn StorageLock>>> {
        self.inner.try_lock(path)
    }
}

struct ChargedFile {
    file: Box<dyn StorageFile>,
    path: PathBuf,
    meter: Meter,
}

impl StorageFile for ChargedFile {
    fn size(&self) -> io::Result<u64> {
        self.file.size()
    }
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        self.file.read_at(offset, buf)
    }
    fn append(&mut self, bytes: &[u8]) -> io::Result<()> {
        let start = self.file.size()?;
        self.file.append(bytes)?;
        let len = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        if len == 0 {
            return Ok(());
        }
        let (first, last) = (start / MACOS_PAGE, (start + len - 1) / MACOS_PAGE);
        self.meter.with(|c| {
            c.appends += 1;
            let dirty = c.dirty.entry(self.path.clone()).or_default();
            for page in first..=last {
                if dirty.insert(page) {
                    c.charged_pages += 1;
                }
            }
        });
        Ok(())
    }
    fn truncate(&mut self, size: u64) -> io::Result<()> {
        self.file.truncate(size)
    }
    fn sync(&mut self, level: SyncLevel) -> io::Result<()> {
        self.file.sync(level)?;
        self.meter.with(|c| {
            c.syncs += 1;
            c.dirty.remove(&self.path);
        });
        Ok(())
    }
}

fn charged_journal(config: Config) -> (Journal, Meter) {
    let meter = Meter::default();
    let storage: Arc<dyn Storage> =
        Arc::new(Charged { inner: Arc::new(SimStorage::new(11322)), meter: meter.clone() });
    let (journal, _) =
        Journal::open(storage, Path::new("/sim/journal"), config, 0, &mut |_| Ok(()))
            .unwrap_or_else(|e| panic!("open: {e}"));
    (journal, meter)
}

fn settle(journal: &Journal, lsn: Lsn) {
    journal.wait_durable(lsn, WAIT).unwrap_or_else(|e| panic!("{e}"));
}

/// A lone acked change (a prompt, a meta save) after a quiet time: one sync makes it durable,
/// and the full sync the power-loss window owes follows. The change dirties one page; that is
/// the least a sync after a write can cost. Nothing else may dirty a page again before the next
/// change: each page charged more is 16 KiB the change did not need.
#[test]
fn a_lone_acked_change_is_charged_one_page() {
    let config = Config { full_sync_interval: Duration::from_millis(20), ..Config::default() };
    let (journal, meter) = charged_journal(config);
    let before = meter.charged_bytes();
    let changes = 20u64;
    let mut payload_bytes = 0u64;
    for index in 0..changes {
        let payload = format!("{{\"seenSeq\":{index}}}");
        payload_bytes += u64::try_from(payload.len()).unwrap_or(0);
        let lsn =
            journal.append(7, Class::Ack, payload.as_bytes()).unwrap_or_else(|e| panic!("{e}"));
        settle(&journal, lsn);
        // The full sync of the power-loss window ran alone before the next change comes.
        let deadline = std::time::Instant::now() + WAIT;
        while journal.full_durable_lsn() < lsn {
            assert!(std::time::Instant::now() < deadline, "no full sync: {:?}", journal.stats());
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    let charged = meter.charged_bytes() - before;
    let (syncs, appends) = meter.with(|c| (c.syncs, c.appends));
    eprintln!(
        "{changes} lone acked changes, {payload_bytes} payload bytes: {charged} bytes charged \
         ({} pages), {appends} appends, {syncs} syncs",
        charged / MACOS_PAGE
    );
    assert!(
        charged <= changes * MACOS_PAGE,
        "{changes} lone changes were charged {} pages ({charged} bytes for {payload_bytes} bytes \
         of payload): more than one each",
        charged / MACOS_PAGE
    );
}
