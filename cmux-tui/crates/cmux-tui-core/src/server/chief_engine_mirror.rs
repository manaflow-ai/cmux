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

use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::chief_registry::{ChiefRecord, DEFAULT_CHIEF, Engine};

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

/// Writes `record`'s engine into its Chief's engine file (through a 0600
/// temporary file and a rename). Best effort: a failure is logged, the
/// record write stands.
pub(super) fn mirror(record: &ChiefRecord) {
    let brains_home = crate::chief_brains::configured_home();
    let socket = super::chief_inspect::tools_socket();
    let Some(path) = engine_file(&record.id, brains_home.as_deref(), socket.as_deref()) else {
        return;
    };
    if let Err(error) = write(&path, &record.engine) {
        eprintln!("cmux-tui: Chief {} engine to {}: {error:#}", record.id, path.display());
    }
}

/// [`mirror`]'s write.
pub(super) fn write(path: &Path, engine: &Engine) -> anyhow::Result<()> {
    let existing = std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.as_object().cloned());
    let file = merged(existing, engine);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut out = options.open(&tmp)?;
    let mut bytes = serde_json::to_vec_pretty(&Value::Object(file))?;
    bytes.push(b'\n');
    out.write_all(&bytes)?;
    out.sync_all()?;
    drop(out);
    std::fs::rename(&tmp, path)?;
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
        let value: Value =
            serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");
        assert_eq!(value["harness"], "opencode");
        assert_eq!(value["model"], "byo/llama");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).expect("meta").permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
