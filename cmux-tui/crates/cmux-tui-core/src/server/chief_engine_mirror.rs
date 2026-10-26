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
//! file write is a work item ([`EngineMirror`]): one write at a time per
//! file, the latest engine wins, as Chrome's ImportantFileWriter writes on
//! its own sequence (base/files/important_file_writer.h).

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use cmux_threads::checked::fs as files;
use cmux_threads::work::{Lane, Priority, Shutdown, Work};
use serde_json::{Map, Value};

use crate::chief_registry::{ChiefRecord, DEFAULT_CHIEF, Engine};
use crate::panic_free::RecoverPoison;

/// The engine file of Chief `chief`: from the brains home when the daemon
/// runs brains, else (the default Chief only) from the tools socket's home.
pub(super) fn engine_file(
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

    fn queue(&self, _work: &Work, path: PathBuf, chief: &str, engine: Engine) {
        if let Err(error) = write(&path, &engine) {
            eprintln!("cmux-tui: Chief {chief} engine to {}: {error:#}", path.display());
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

/// [`mirror`]'s write.
pub(super) fn write(path: &Path, engine: &Engine) -> anyhow::Result<()> {
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
mod tests {
    use super::*;

    fn engine(harness: Option<&str>, model: Option<&str>, effort: Option<&str>) -> Engine {
        Engine {
            harness: harness.map(str::to_owned),
            model: model.map(str::to_owned),
            effort: effort.map(str::to_owned),
        }
    }

    #[test]
    fn the_default_chief_uses_the_chief_home_root_and_another_its_brain_home() {
        let home = Path::new("/h");
        assert_eq!(
            engine_file(DEFAULT_CHIEF, Some(home), None),
            Some(PathBuf::from("/h/optchat/engine.json"))
        );
        assert_eq!(
            engine_file(DEFAULT_CHIEF, None, Some(Path::new("/x/optchat/tools.sock"))),
            Some(PathBuf::from("/x/optchat/engine.json"))
        );
        let other = "agent_01ABCDEFGHJKMNPQRSTVWXYZ12";
        assert_eq!(
            engine_file(other, Some(home), None),
            Some(crate::chief_brains::brain_home(home, other).join("optchat/engine.json"))
        );
        assert_eq!(engine_file(other, None, None), None);
    }

    #[test]
    fn the_record_engine_replaces_the_three_fields_and_keeps_the_rest() {
        let mut existing = Map::new();
        existing.insert("harness".into(), "codex".into());
        existing.insert("model".into(), "gpt-5".into());
        existing.insert("compactor_harness".into(), "claude".into());
        existing.insert("speed".into(), "fast".into());
        let file = merged(Some(existing), &engine(Some("claude-sr2"), None, Some("high")));
        assert_eq!(file.get("harness"), Some(&Value::from("claude-sr2")));
        assert_eq!(file.get("model"), None, "an unset field is the brain default");
        assert_eq!(file.get("effort"), Some(&Value::from("high")));
        assert_eq!(file.get("compactor_harness"), Some(&Value::from("claude")));
        assert_eq!(file.get("speed"), Some(&Value::from("fast")));
    }

    #[test]
    fn write_makes_an_owner_only_file_the_brain_parses() {
        let dir = std::env::temp_dir().join(format!(
            "cmux-engine-mirror-{}-{}",
            std::process::id(),
            line!()
        ));
        let path = dir.join("optchat").join("engine.json");
        write(&path, &engine(Some("opencode"), Some("byo/llama"), None)).expect("write");
        let value: Value = serde_json::from_slice(&fs::read(&path).expect("read")).expect("json");
        assert_eq!(value["harness"], "opencode");
        assert_eq!(value["model"], "byo/llama");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&path).expect("meta").permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        let _ = fs::remove_dir_all(&dir);
    }

    /// A registry commit queues the engine on a request thread, under the
    /// registry lock: the file write is a work item, and the last engine
    /// queued is the one on disk (p02-threads 220). Panic mode: a write left
    /// on the request thread fails here at its call site.
    #[test]
    fn a_queued_engine_is_written_off_the_request_thread_and_the_last_wins() {
        use super::super::request_thread_test_support::on_request_thread;
        use cmux_threads::work::WorkConfig;

        let dir = std::env::temp_dir().join(format!(
            "cmux-engine-mirror-{}-{}",
            std::process::id(),
            line!()
        ));
        let path = dir.join("optchat").join("engine.json");
        let work = Arc::new(Work::new(WorkConfig::default()).expect("work"));
        let mirror = Arc::new(EngineMirror::default());
        let (request_work, request_mirror, request_path) =
            (Arc::clone(&work), Arc::clone(&mirror), path.clone());
        on_request_thread(move || {
            for harness in ["codex", "opencode", "claude"] {
                let engine = engine(Some(harness), None, None);
                request_mirror.queue(&request_work, request_path.clone(), "chief_1", engine);
            }
        });
        // Shutdown waits for block items: the queued write is done after it.
        work.shutdown();
        let value: Value = serde_json::from_slice(&fs::read(&path).expect("read")).expect("json");
        assert_eq!(value["harness"], "claude");
        assert!(mirror.files.lock().recover_poison().is_empty(), "no write left queued");
        let _ = fs::remove_dir_all(&dir);
    }
}
