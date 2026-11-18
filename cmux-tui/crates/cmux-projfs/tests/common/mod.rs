//! Shared test helpers: a temporary directory and an in-memory [`Source`].

#![allow(dead_code)]

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use cmux_projfs::{Builder, ChunkCache, Config, Core, Got, Manifest, Source, Stat, Version, Want};

/// A directory under the system temp dir, removed on drop.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> TempDir {
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("cmux-projfs-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp dir");
        TempDir(dir)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Deterministic bytes for a file: depends on a seed and the position.
pub fn bytes(seed: u8, len: usize) -> Vec<u8> {
    (0..len).map(|i| (i as u32).wrapping_mul(31).wrapping_add(u32::from(seed)) as u8).collect()
}

pub const T0: i64 = 1_700_000_000_000_000_000;

pub fn file_stat(len: usize, mtime: i64) -> Stat {
    Stat::file(0o644, len as u64, mtime, mtime)
}

/// The Mac as a map of path -> (stat, bytes), with knobs for the failure cases.
#[derive(Default)]
pub struct MemSource {
    files: Mutex<HashMap<String, (Stat, Vec<u8>)>>,
    pub calls: Mutex<Vec<Vec<Want>>>,
    pub away: AtomicBool,
    /// Scripted answers for a path, used before the real one.
    scripted: Mutex<HashMap<String, VecDeque<Got>>>,
    gate: Mutex<bool>,
    gate_cv: Condvar,
    pub gated: AtomicBool,
}

impl MemSource {
    pub fn new() -> Arc<MemSource> {
        Arc::new(MemSource::default())
    }

    pub fn put(&self, path: &str, stat: Stat, data: Vec<u8>) {
        self.files.lock().unwrap().insert(path.to_owned(), (stat, data));
    }

    pub fn remove(&self, path: &str) {
        self.files.lock().unwrap().remove(path);
    }

    pub fn script(&self, path: &str, got: Got) {
        self.scripted.lock().unwrap().entry(path.to_owned()).or_default().push_back(got);
    }

    pub fn fetches(&self) -> usize {
        self.calls.lock().unwrap().len()
    }

    pub fn wants(&self) -> Vec<Vec<Want>> {
        self.calls.lock().unwrap().clone()
    }

    /// Makes every fetch block until [`MemSource::open_gate`].
    pub fn close_gate(&self) {
        *self.gate.lock().unwrap() = false;
        self.gated.store(true, Ordering::SeqCst);
    }

    pub fn open_gate(&self) {
        *self.gate.lock().unwrap() = true;
        self.gate_cv.notify_all();
    }

    fn wait_gate(&self) {
        if !self.gated.load(Ordering::SeqCst) {
            return;
        }
        let g = self.gate.lock().unwrap();
        let _ = self.gate_cv.wait_timeout_while(g, Duration::from_secs(10), |open| !*open).unwrap();
    }

    /// A manifest of every file this source holds (directories are implied by the paths).
    pub fn manifest(&self) -> Manifest {
        let mut b = Builder::new("/Users/test/folder");
        let mut dirs = std::collections::BTreeSet::new();
        for (path, (stat, _)) in self.files.lock().unwrap().iter() {
            let mut cur = path.as_str();
            while let Some((dir, _)) = cur.rsplit_once('/') {
                dirs.insert(dir.to_owned());
                cur = dir;
            }
            b.add(path, stat.clone()).unwrap();
        }
        for d in dirs {
            b.add(&d, Stat::dir(0o755, T0, T0)).unwrap();
        }
        b.build().unwrap()
    }

    fn answer(&self, w: &Want) -> Got {
        if let Some(got) =
            self.scripted.lock().unwrap().get_mut(&w.path).and_then(VecDeque::pop_front)
        {
            return got;
        }
        if self.away.load(Ordering::SeqCst) {
            return Got::Away;
        }
        let files = self.files.lock().unwrap();
        let Some((stat, data)) = files.get(&w.path) else {
            return Got::Gone;
        };
        if stat.withheld {
            return Got::Withheld;
        }
        if stat.version() != w.version {
            return Got::Changed(stat.clone());
        }
        let start = (w.offset as usize).min(data.len());
        let end = (start + w.len as usize).min(data.len());
        Got::Bytes(data[start..end].to_vec())
    }
}

impl Source for MemSource {
    fn fetch(&self, wants: &[Want]) -> Vec<Got> {
        self.calls.lock().unwrap().push(wants.to_vec());
        self.wait_gate();
        wants.iter().map(|w| self.answer(w)).collect()
    }
}

/// A core over `source`'s own manifest with a fresh cache.
pub fn core_for(source: &Arc<MemSource>, cache_dir: &Path, config: Config) -> Arc<Core> {
    let cache = ChunkCache::open(cache_dir, 1 << 30).unwrap();
    Core::new(source.manifest(), cache, source.clone(), config)
}

/// A config without background read-ahead, so fetch counts are exact.
pub fn quiet_config() -> Config {
    Config {
        readahead_chunks: 0,
        away_wait: Duration::from_millis(300),
        away_retry: Duration::from_millis(20),
        ..Config::default()
    }
}

pub fn version(size: u64, mtime: i64) -> Version {
    Version { size, mtime_ns: mtime, ctime_ns: mtime }
}
