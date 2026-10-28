//! A Chief's backend lives in its registry record (`harness`, `model`,
//! `effort`; Lawrence 2026-10-19, u2586: "choose the backend per Chief").
//! The brain reads its engine from `<brain home>/optchat/engine.json` at each
//! turn start (optchat-chief engine.rs), so a committed write that changes
//! the record's engine writes those three fields there; the file's other
//! fields (compactor, speed) stay. `chief engine show` then shows the
//! record's engine.
//!
//! The brain home: the Chief home root for the default Chief (the brains
//! config's `home`, else the directory of the configured tools socket
//! `<home>/optchat/tools.sock`), `<home>/c/<last 8 of id>` for another Chief
//! (chief_brains.rs `brain_home`). A daemon that knows neither writes
//! nothing (the record still holds the engine).
//!
//! The record commits on a request thread under the registry lock, so the
//! file write never runs there. A daemon that runs brains hands the engine
//! to its brain supervisor (`chief_brains::Slot::engine_changed`), which
//! writes it on its own thread before it handles the record's change, so a
//! brain it starts or restarts for that change reads the new engine. A
//! daemon without one (the app's default Chief) writes it in a work item
//! ([`EngineMirror`]): one write at a time per file, the latest engine wins.
//! Both are a single writer per file, as Chrome's ImportantFileWriter writes
//! on its own sequence (base/files/important_file_writer.h).

use cmux_threads::sync::Mutex;
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_threads::checked::fs as files;
use cmux_threads::work::{Lane, Priority, Shutdown, Work};
use serde_json::{Map, Value};

use crate::chief_registry::{ChiefRecord, DEFAULT_CHIEF, Engine};
use crate::panic_free::RecoverPoison;

/// The engine file of Chief `chief`: from the brains home when the daemon
/// runs brains, else (the default Chief only) from the tools socket's home.
pub(crate) fn engine_file(
    chief: &str,
    brains_home: Option<&Path>,
    tools_socket: Option<&Path>,
) -> Option<PathBuf> {
    let home = match (chief == DEFAULT_CHIEF, brains_home) {
        (true, Some(home)) => home.to_path_buf(),
        (true, None) => tools_socket?.parent()?.parent()?.to_path_buf(),
        (false, Some(home)) => crate::chief_brains::brain_home(home, chief),
        (false, None) => return None,
    };
    Some(home.join("optchat").join("engine.json"))
}

/// `existing` (the file's JSON object, or none) with the record's engine:
/// each set field written, each unset field removed (the brain's default).
pub(super) fn merged(existing: Option<Map<String, Value>>, engine: &Engine) -> Map<String, Value> {
    let mut file = existing.unwrap_or_default();
    for (key, value) in
        [("harness", &engine.harness), ("model", &engine.model), ("effort", &engine.effort)]
    {
        match value {
            Some(value) => {
                file.insert(key.into(), Value::String(value.clone()));
            }
            None => {
                file.remove(key);
            }
        }
    }
    file
}

/// The engine-file writes not yet made, by file. A file has at most one
/// work item at a time; it writes the latest engine, then any that came
/// while it wrote. The lock never covers the write.
#[derive(Default)]
pub(crate) struct EngineMirror {
    files: Arc<Mutex<HashMap<PathBuf, Queued>>>,
}

struct Queued {
    chief: String,
    /// The engine to write next; `None` while the item writes the last one.
    engine: Option<Engine>,
}

impl EngineMirror {
    /// Queues `record`'s engine for its Chief's engine file and returns at
    /// once: a request thread calls it under the registry lock. Best effort:
    /// a failed write is logged, the record write stands.
    pub(super) fn mirror(&self, work: &Work, record: &ChiefRecord) {
        let brains_home = crate::chief_brains::configured_home();
        let socket = super::chief_inspect::tools_socket();
        let Some(path) = engine_file(&record.id, brains_home.as_deref(), socket.as_deref()) else {
            return;
        };
        self.queue(work, path, &record.id, record.engine.clone());
    }

    fn queue(&self, work: &Work, path: PathBuf, chief: &str, engine: Engine) {
        {
            let mut files = self.files.lock().recover_poison();
            let queued = Queued { chief: chief.to_owned(), engine: Some(engine) };
            // A file with an item already: that item writes this engine next.
            if files.insert(path.clone(), queued).is_some() {
                return;
            }
        }
        let files = Arc::clone(&self.files);
        let item_path = path.clone();
        // A person picked the engine and the brain reads it at its next turn:
        // user visible, and one short write that shutdown waits for.
        let posted =
            work.post(Priority::UserVisible, Lane::Files, Shutdown::BlockShutdown, move || {
                write_queued(&files, &item_path);
            });
        if posted.is_err() {
            self.files.lock().recover_poison().remove(&path);
            eprintln!(
                "cmux-tui: Chief {chief} engine to {}: the daemon is stopping",
                path.display()
            );
        }
    }
}

/// The work item: writes `path`'s queued engine until none is left. A panic
/// in a write drops the entry, so the next change starts a new item.
fn write_queued(files: &Mutex<HashMap<PathBuf, Queued>>, path: &Path) {
    struct Forget<'a>(&'a Mutex<HashMap<PathBuf, Queued>>, &'a Path);
    impl Drop for Forget<'_> {
        fn drop(&mut self) {
            if std::thread::panicking() {
                self.0.lock().recover_poison().remove(self.1);
            }
        }
    }
    let _forget = Forget(files, path);
    loop {
        let (chief, engine) = {
            let mut queue = files.lock().recover_poison();
            let Some(queued) = queue.get_mut(path) else { return };
            let Some(engine) = queued.engine.take() else {
                queue.remove(path);
                return;
            };
            (queued.chief.clone(), engine)
        };
        if let Err(error) = write(path, &engine) {
            eprintln!("cmux-tui: Chief {chief} engine to {}: {error:#}", path.display());
        }
    }
}

/// One engine-file write: the supervisor's, or a mirror work item's.
pub(crate) fn write(path: &Path, engine: &Engine) -> anyhow::Result<()> {
    let existing = files::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.as_object().cloned());
    let file = merged(existing, engine);
    if let Some(dir) = path.parent() {
        files::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut options = fs::File::options();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut out = files::open_with(&options, &tmp)?;
    let mut bytes = serde_json::to_vec_pretty(&Value::Object(file))?;
    bytes.push(b'\n');
    crate::request_path::note(crate::request_path::BlockingKind::FsWrite);
    out.write_all(&bytes)?;
    files::sync_all(&out)?;
    drop(out);
    files::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
#[path = "chief_engine_mirror_tests.rs"]
mod tests;
