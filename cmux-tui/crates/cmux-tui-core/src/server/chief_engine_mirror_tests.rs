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
    let dir =
        std::env::temp_dir().join(format!("cmux-engine-mirror-{}-{}", std::process::id(), line!()));
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
    use super::super::request_thread_tests::on_request_thread;
    use cmux_threads::work::WorkConfig;

    let dir =
        std::env::temp_dir().join(format!("cmux-engine-mirror-{}-{}", std::process::id(), line!()));
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
