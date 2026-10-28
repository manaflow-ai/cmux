//! A record change that moves the engine and a prompt field restarts the
//! brain: the supervisor writes the engine file before it handles that
//! change, so the restarted brain reads the new engine (the file wins over
//! the record's env). p02-threads 220 review: the write was a work item that
//! nothing ordered before the restart.

use super::*;
use crate::chief_registry::Engine;

const CHIEF: &str = "agent_01ABCDEFGHJKMNPQRSTVWXYZ12";

fn engine(harness: &str) -> Engine {
    Engine { harness: Some(harness.into()), model: None, effort: None }
}

fn record(harness: &str) -> ChiefRecord {
    ChiefRecord {
        id: CHIEF.into(),
        display_name: "Scout".into(),
        role: "Researcher".into(),
        personality: String::new(),
        instructions: "new instructions".into(),
        avatar: None,
        tools: Vec::new(),
        harnesses: Vec::new(),
        engine: engine(harness),
        self_edit: Vec::new(),
        locked: false,
        is_default: false,
        rev: 2,
        created_at: String::new(),
        updated_at: String::new(),
        created_by: None,
    }
}

#[test]
fn the_engine_reaches_the_supervisor_before_the_record_change() {
    let slot = Slot::default();
    let (sender, inbox) = mpsc::channel();
    *slot.sender.lock().unwrap_or_else(PoisonError::into_inner) = Some(sender);
    assert!(slot.engine_changed(CHIEF, &engine("codex")));
    assert!(slot.chief_written(&record("codex"), false, false).is_none());
    match inbox.try_recv() {
        Ok(Signal::Engine(chief, engine)) => {
            assert_eq!(chief, CHIEF);
            assert_eq!(engine.harness.as_deref(), Some("codex"));
        }
        _ => panic!("the engine is the first signal"),
    }
    assert!(matches!(inbox.try_recv(), Ok(Signal::Updated(record)) if record.id == CHIEF));
}

#[test]
fn a_stopped_supervisor_leaves_the_engine_to_the_caller() {
    let slot = Slot::default();
    slot.stopped.store(true, std::sync::atomic::Ordering::Release);
    assert!(!slot.engine_changed(CHIEF, &engine("codex")));
}

#[test]
fn the_supervisor_writes_the_engine_file_before_its_next_signal() {
    let home =
        std::env::temp_dir().join(format!("cmux-brain-engine-{}-{}", std::process::id(), line!()));
    let (sender, _inbox) = mpsc::channel();
    let mut supervisor = Supervisor {
        mux: Weak::new(),
        socket: home.join("s.sock"),
        config: BrainsConfig {
            executable: PathBuf::from("/bin/false"),
            home: home.clone(),
            app: AppValues::default(),
        },
        brains: BTreeMap::new(),
        sender,
        live: Arc::default(),
    };
    let file = brain_home(&home, CHIEF).join("optchat/engine.json");
    std::fs::create_dir_all(file.parent().expect("parent")).expect("dir");
    std::fs::write(&file, r#"{"harness": "claude", "speed": "fast"}"#).expect("seed");
    supervisor.handle(Signal::Engine(CHIEF.into(), engine("codex")));
    let written: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&file).expect("read")).expect("json");
    assert_eq!(written, serde_json::json!({"harness": "codex", "speed": "fast"}));
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_record_harness_becomes_the_brains_starting_harness() {
    let engine =
        Engine { harness: Some("unii".into()), model: None, effort: Some("default".into()) };
    assert_eq!(
        record_engine_env(&engine),
        vec![("OPTCHAT_CHIEF_HARNESS".to_owned(), "unii".to_owned())]
    );
    assert!(record_engine_env(&Engine::default()).is_empty());
    let full = Engine {
        harness: Some("codex".into()),
        model: Some("gpt-5.5".into()),
        effort: Some("high".into()),
    };
    assert_eq!(record_engine_env(&full).len(), 3);
}
