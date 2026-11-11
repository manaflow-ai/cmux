//! A chat's large, rarely-changing metadata in `session.parts.json` (`store/meta_parts.rs`): a
//! save's bytes do not grow with them, they read back whole, and older files read as before.

use super::*;
use crate::store::{LocalStore, META_SCHEMA, SessionMeta, Store, ToolRow};
use serde_json::json;
use std::path::Path;

const CHAT: &str = "chat-parts";

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": id,
        "name": "chat",
        "harness": "claude",
        "family": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap_or_else(|e| panic!("a test meta: {e}"))
}

/// A chat whose agent lists ~700 KB of slash commands and ~250 KB of tool rows, as one with many
/// skills and MCP servers does (a 1.09 MB `session.json` on 2026-11-10, 93% these two).
fn god(id: &str) -> SessionMeta {
    let mut m = meta(id);
    let commands: Vec<Value> = (0..3_500)
        .map(|i| {
            json!({
                "name": format!("skill-{i:05}"),
                "description": format!("{i:05} {}", "does a thing the person asked for, at length. ".repeat(3)),
                "input": {"hint": "what to do"},
            })
        })
        .collect();
    m.available_commands =
        Some(json!({"sessionUpdate": "available_commands_update", "availableCommands": commands}));
    m.tools.rows = (0..1_250)
        .map(|i| ToolRow {
            id: format!("mcp:server-{i:05}"),
            name: format!("server-{i:05} with a long display name for its tools"),
            kind: "mcp".into(),
            source: "claude".into(),
            enabled: true,
            can_toggle: true,
            status: Some("connected".into()),
        })
        .collect();
    m.tools.mutable = true;
    m.tools.off = vec!["mcp:server-00001".into()];
    m
}

fn written() -> u64 {
    WRITTEN.with(Cell::get)
}

fn reset() {
    WRITTEN.with(|w| w.set(0));
}

fn session_json(dir: &Path, id: &str) -> Value {
    let bytes = std::fs::read(dir.join(id).join("session.json")).unwrap_or_else(|e| panic!("{e}"));
    serde_json::from_slice(&bytes).unwrap_or_else(|e| panic!("{e}"))
}

/// Bytes per composer-draft save, after the chat's first save, over `saves` saves.
fn per_draft_save(store: &dyn Store, mut m: SessionMeta, saves: u64) -> u64 {
    store.save(&m).unwrap_or_else(|e| panic!("first save: {e:#}"));
    reset();
    for n in 0..saves {
        m.composer_draft = Some(format!("a draft, keystroke {n}"));
        m.updated_at = 2 + n;
        store.save_kept(&m).unwrap_or_else(|e| panic!("draft save: {e:#}"));
    }
    written() / saves
}

fn local(dir: &Path) -> LocalStore {
    LocalStore::new(dir.to_path_buf(), 1 << 20).unwrap_or_else(|e| panic!("{e:#}"))
}

#[cfg(unix)]
fn journal(home: &Path, storage: &cmux_journal::SimStorage) -> Box<dyn Store> {
    crate::store::open_with_journal(
        &crate::config::StoreConfig::default(),
        home,
        std::sync::Arc::new(storage.clone()),
        cmux_journal::Config::default(),
    )
    .unwrap_or_else(|e| panic!("open the store: {e:#}"))
}

/// The harness of the before and after: bytes one composer-draft save writes, a small chat (no
/// commands, no tools) beside a god chat, on both store paths (`LocalStore::save`'s
/// `session.json`, and the event journal's `meta` record the daemon writes). Before is the whole
/// metadata, which every save wrote. The god chat may cost at most 1.2x the small one.
#[cfg(unix)]
#[test]
fn a_draft_save_costs_the_same_for_a_god_chat_as_for_a_small_one() {
    const SAVES: u64 = 50;
    let small = meta("small");
    let big = god("god");
    let before_small = serde_json::to_vec(&small).unwrap_or_default().len() as u64;
    let before_god = serde_json::to_vec(&big).unwrap_or_default().len() as u64;
    let before_small_pretty = serde_json::to_string_pretty(&small).unwrap_or_default().len() as u64;
    let before_god_pretty = serde_json::to_string_pretty(&big).unwrap_or_default().len() as u64;

    let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
    let store = local(dir.path());
    let local_small = per_draft_save(&store, small.clone(), SAVES);
    let local_god = per_draft_save(&store, big.clone(), SAVES);

    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
    let storage = cmux_journal::SimStorage::new(71);
    let store = journal(home.path(), &storage);
    let journal_small = per_draft_save(store.as_ref(), small, SAVES);
    let journal_god = per_draft_save(store.as_ref(), big, SAVES);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let checkpoint_god = std::fs::metadata(home.path().join("sessions/god/session.json"))
        .map(|m| m.len())
        .unwrap_or_default();

    eprintln!("bytes written per composer-draft save ({SAVES} saves)");
    eprintln!("path               small   god       god/small");
    eprintln!(
        "session.json before {before_small_pretty:>6} {before_god_pretty:>9} {:>8.2}x",
        before_god_pretty as f64 / before_small_pretty as f64
    );
    eprintln!(
        "session.json after  {local_small:>6} {local_god:>9} {:>8.2}x",
        local_god as f64 / local_small as f64
    );
    eprintln!(
        "journal before      {before_small:>6} {before_god:>9} {:>8.2}x",
        before_god as f64 / before_small as f64
    );
    eprintln!(
        "journal after       {journal_small:>6} {journal_god:>9} {:>8.2}x",
        journal_god as f64 / journal_small as f64
    );
    eprintln!("checkpoint's god session.json after: {checkpoint_god} bytes");

    assert!(before_god > 900_000, "the god fixture is {before_god} bytes");
    assert!(
        local_god * 10 <= local_small * 12,
        "session.json: god {local_god} bytes per save, small {local_small}"
    );
    assert!(
        journal_god * 10 <= journal_small * 12,
        "journal: god {journal_god} bytes per save, small {journal_small}"
    );
    assert!(checkpoint_god < 4_000, "the checkpoint wrote {checkpoint_god} bytes of session.json");
}

/// A god chat's parts are written once, read back whole, and kept out of `session.json`; a
/// change to them writes the parts file again, a draft does not.
#[test]
fn the_parts_read_back_whole_and_are_written_only_when_they_change() {
    let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
    let store = local(dir.path());
    let mut m = god(CHAT);
    reset();
    store.save(&m).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(written() > 900_000, "the first save wrote the parts");
    let on_disk = session_json(dir.path(), CHAT);
    assert!(on_disk.get("availableCommands").is_none(), "session.json inlines the commands");
    assert_eq!(on_disk["tools"], json!({"mutable": true, "off": ["mcp:server-00001"]}));
    assert!(on_disk["metaParts"].is_string());
    assert!(dir.path().join(CHAT).join(PARTS_FILE).exists());

    let again = local(dir.path());
    let loaded = again.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).unwrap_or_else(|| panic!());
    assert_eq!(loaded.available_commands, m.available_commands);
    assert_eq!(loaded.tools, m.tools);
    let listed = again.list().unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].tools, m.tools);
    assert_eq!(listed[0].available_commands, m.available_commands);

    // A store that read the parts writes none for a draft.
    m.composer_draft = Some("hello".into());
    reset();
    again.save_kept(&m).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(written() < 4_000, "a draft after a reload wrote {} bytes", written());

    // A new tool row: the parts again.
    m.tools.rows[0].status = Some("failed".into());
    reset();
    again.save(&m).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(written() > 200_000, "a changed row was not written");
    let loaded = local(dir.path()).load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).unwrap();
    assert_eq!(loaded.tools.rows[0].status.as_deref(), Some("failed"));

    // The parts file removed under the store: the next save writes it again.
    std::fs::remove_file(dir.path().join(CHAT).join(PARTS_FILE)).unwrap_or_else(|e| panic!("{e}"));
    again.save(&m).unwrap_or_else(|e| panic!("{e:#}"));
    let loaded = local(dir.path()).load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).unwrap();
    assert_eq!(loaded.available_commands, m.available_commands);
}

/// A `session.json` an older build wrote, its commands and tools inline, reads as before; its
/// next save moves them out and they still read back.
#[test]
fn an_older_session_json_with_inline_parts_reads_as_before() {
    let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
    let m = god(CHAT);
    let folder = dir.path().join(CHAT);
    crate::config::private_state_dir(&folder).unwrap_or_else(|e| panic!("{e:#}"));
    // Whole, as every build before this one wrote it.
    let whole = serde_json::to_string_pretty(&m).unwrap_or_else(|e| panic!("{e}"));
    assert!(whole.contains("availableCommands") && whole.contains("server-00002"));
    crate::config::write_atomic(&folder.join("session.json"), whole.as_bytes())
        .unwrap_or_else(|e| panic!("{e:#}"));
    // A stale parts file is not taken over inline fields.
    std::fs::write(folder.join(PARTS_FILE), br#"{"fingerprint":"x","toolRows":[]}"#)
        .unwrap_or_else(|e| panic!("{e}"));

    let store = local(dir.path());
    let loaded = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).unwrap();
    assert_eq!(loaded.available_commands, m.available_commands);
    assert_eq!(loaded.tools, m.tools);
    store.save(&loaded).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(session_json(dir.path(), CHAT).get("availableCommands").is_none());
    let reloaded = local(dir.path()).load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).unwrap();
    assert_eq!(reloaded.available_commands, m.available_commands);
    assert_eq!(reloaded.tools, m.tools);
}

/// An older build reads a split `session.json` (it knows no `metaParts`): the chat lists, its
/// tool settings (`off`, `mutable`) stay, and only the agent-reported lists are empty until the
/// agent's next report.
#[test]
fn an_older_build_reads_a_split_session_json() {
    let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
    let m = god(CHAT);
    local(dir.path()).save(&m).unwrap_or_else(|e| panic!("{e:#}"));
    let bytes = std::fs::read(dir.path().join(CHAT).join("session.json")).unwrap();
    // What an older build does: a plain parse, no parts file.
    let old: SessionMeta = serde_json::from_slice(&bytes).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(old.id, CHAT);
    assert!(old.available_commands.is_none());
    assert!(old.tools.rows.is_empty());
    assert!(old.tools.mutable);
    assert_eq!(old.tools.off, m.tools.off);
}

/// Every other serialization of the metadata (a bundle, an export, the protocol) is whole.
#[test]
fn only_the_store_s_own_writes_split() {
    let m = god(CHAT);
    let whole = serde_json::to_value(&m).unwrap_or_else(|e| panic!("{e}"));
    assert!(whole["availableCommands"].is_object());
    assert_eq!(whole["tools"]["rows"].as_array().map(Vec::len), Some(1_250));
    let split: Value =
        serde_json::from_slice(&to_vec(&m, "f").unwrap_or_else(|e| panic!("{e}"))).unwrap();
    assert!(split.get("availableCommands").is_none());
    assert!(split["tools"].get("rows").is_none());
    // The thread is back to whole after.
    let after = serde_json::to_value(&m).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(after, whole);
}

/// Through the event journal: a god chat's image is split, the parts read back before and after
/// the checkpoint, and after a crash's replay.
#[cfg(unix)]
#[test]
fn the_journal_keeps_the_parts_through_a_checkpoint_and_a_replay() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
    let storage = cmux_journal::SimStorage::new(72);
    let store = journal(home.path(), &storage);
    let mut m = god(CHAT);
    store.save(&m).unwrap_or_else(|e| panic!("{e:#}"));
    let loaded = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).unwrap();
    assert_eq!(loaded.tools, m.tools);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let on_disk = session_json(&home.path().join("sessions"), CHAT);
    assert!(on_disk.get("availableCommands").is_none());
    assert!(on_disk["metaParts"].is_string());

    // A draft after the checkpoint, then a process crash: the replay's image is split and its
    // parts come from the parts file.
    m.composer_draft = Some("after the checkpoint".into());
    store.save_kept(&m).unwrap_or_else(|e| panic!("{e:#}"));
    assert!(store.wait_durable(std::time::Duration::from_secs(10)).unwrap_or(false));
    let crashed = storage.restart(cmux_journal::Crash::Process);
    drop(store);
    let store = journal(home.path(), &crashed);
    let loaded = store.load(CHAT).unwrap_or_else(|e| panic!("{e:#}")).unwrap();
    assert_eq!(loaded.composer_draft.as_deref(), Some("after the checkpoint"));
    assert_eq!(loaded.available_commands, m.available_commands);
    assert_eq!(loaded.tools, m.tools);
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let listed = store.list().unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(listed.iter().find(|l| l.id == CHAT).map(|l| l.tools.clone()), Some(m.tools));
}
