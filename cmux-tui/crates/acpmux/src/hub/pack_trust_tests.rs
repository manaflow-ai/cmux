//! The trust in a chat's sealed segments kept across daemons (`hub/pack_trust.rs`).

use super::*;
use crate::store::{LocalStore, META_SCHEMA, SessionMeta};

/// A log segment as the daemon rolls it (`config.rs`'s 8 MiB).
const LOG_SEGMENT: u64 = 8 << 20;

fn hub(sessions: &Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, Box::new(LocalStore::new(sessions.to_owned(), LOG_SEGMENT).unwrap()))
}

fn chat(hub: &Hub, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "fake", "cwd": "/w",
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    session
}

/// About 2 KiB of agent text a record, `records` of them.
fn append(hub: &Hub, session: &Session, records: u64, seed: &mut u64) {
    for _ in 0..records {
        let mut words = String::with_capacity(2100);
        while words.len() < 2000 {
            *seed ^= *seed << 13;
            *seed ^= *seed >> 7;
            *seed ^= *seed << 17;
            let n = 2 + (*seed % 9) as usize;
            words.extend((0..n).map(|i| char::from(b'a' + ((*seed >> (i * 5)) % 26) as u8)));
            words.push(' ');
        }
        let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": session.id, "update": {"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": words}}}});
        hub.append(session, "in", "agent_message_chunk", msg);
    }
}

fn trust_file(hub: &Hub, id: &str) -> PathBuf {
    hub.pack_store(id).unwrap().root().join(TRUST_FILE)
}

/// A daemon that sealed a chat's pack leaves its trust in the pack store, and the next daemon
/// (here: the same hub with its memory of the check cleared) extends the pack from its sealed
/// end at its first seal instead of checking the whole log again. A bumped stamp, another
/// build's trust, a manifest whose sealed segments are not the ones checked, and a failed seal
/// each make that first seal whole again.
#[test]
fn a_restarted_daemon_extends_from_the_kept_trust() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-trust-a";
    let session = chat(&hub, id);
    let mut seed = 0x9e37_79b9_7f4a_7c15u64;
    append(&hub, &session, 4_500, &mut seed);
    let first = hub.seal_pack(id).unwrap().unwrap();
    assert!(!first.extended, "a chat's first seal is whole");
    let kept: KeptTrust = serde_json::from_slice(&std::fs::read(trust_file(&hub, id)).unwrap())
        .expect("the seal keeps its trust in the pack store");
    assert_eq!(kept.build, crate::build_info::build());
    assert_eq!(kept.sealed, first.manifest.segments.iter().filter(|s| s.sealed).count());
    assert!(kept.sealed >= 2, "{kept:?}");

    // A restart: nothing in memory, the kept trust holds.
    append(&hub, &session, 2_500, &mut seed);
    hub.pack_checked.lock().unwrap().clear();
    let next = hub.seal_pack(id).unwrap().unwrap();
    assert!(next.extended, "the first seal after a restart extends from the kept trust");
    let store = hub.pack_store(id).unwrap();
    let through = session.read_meta(|m| m.last_seq);
    // A pack through the newest record, as a compaction's, keeps every sealed segment trusted.
    hub.pack_checked.lock().unwrap().clear();
    let (m, stats, _) = hub.pack_through(&session, through, &store, &root.path().join("w1")).unwrap();
    assert_eq!(stats.kept_segments as usize, m.segments.iter().filter(|s| s.sealed).count());
    assert!(hub.pack_checked.lock().unwrap().contains_key(id), "trusted from the store");

    // A rewritten log: the kept stamp no longer holds.
    hub.pack_checked.lock().unwrap().clear();
    hub.store.bump_log_stamp(id, 1).unwrap();
    append(&hub, &session, 2_500, &mut seed);
    assert!(!hub.seal_pack(id).unwrap().unwrap().extended, "a bumped stamp packs whole");

    // Another build's trust is not this one's.
    hub.pack_checked.lock().unwrap().clear();
    let path = trust_file(&hub, id);
    let mut other: KeptTrust = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    other.build = "0000000 2026-01-01".into();
    std::fs::write(&path, serde_json::to_vec(&other).unwrap()).unwrap();
    append(&hub, &session, 2_500, &mut seed);
    assert!(!hub.seal_pack(id).unwrap().unwrap().extended, "another build's trust packs whole");

    // A manifest whose first sealed segment is not the one checked.
    hub.pack_checked.lock().unwrap().clear();
    let mut bent = pack::Manifest::load(&store, id).unwrap().unwrap();
    let good = bent.segments[0].raw_hash.clone();
    bent.segments[0].raw_hash = "0".repeat(64);
    bent.save(&store).unwrap();
    assert!(!hub.pack_trusted(id, &store, hub.store.log_stamp(id).unwrap()));
    bent.segments[0].raw_hash = good;
    bent.save(&store).unwrap();
    assert!(hub.pack_trusted(id, &store, hub.store.log_stamp(id).unwrap()));

    // A failed seal forgets the kept trust too.
    let manifest = store.root().join("sessions").join(format!("{id}.json"));
    let saved = std::fs::read(&manifest).unwrap();
    std::fs::write(&manifest, b"{ not a manifest").unwrap();
    append(&hub, &session, 2_500, &mut seed);
    assert!(hub.seal_pack(id).is_err());
    assert!(!path.exists(), "a failed seal removes the kept trust");
    std::fs::write(&manifest, saved).unwrap();
    assert!(!hub.seal_pack(id).unwrap().unwrap().extended);
}

/// A purged chat's kept trust goes with its entry.
#[test]
fn a_purged_chat_forgets_its_kept_trust() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-trust-b";
    let session = chat(&hub, id);
    let mut seed = 7u64;
    append(&hub, &session, 2_500, &mut seed);
    assert!(hub.seal_pack(id).unwrap().is_some());
    assert!(trust_file(&hub, id).exists());
    session.purged.store(true, Ordering::SeqCst);
    assert!(hub.seal_pack(id).unwrap().is_none());
    assert!(!trust_file(&hub, id).exists());
}

/// Seal scratch a gone daemon left in a pack store is removed; this daemon's, a live process's,
/// and one named before pids that is newer than this daemon are kept.
#[cfg(unix)]
#[test]
fn a_gone_daemons_seal_scratch_is_swept() {
    super::transfer_out::note_started();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path();
    let status = std::process::Command::new("sh")
        .arg("-c")
        .arg(r#"d="$1/work-$$-0190aaaabbbbccccddddeeeeffff0000"; mkdir "$d"; head -c 65536 /dev/zero > "$d/history.ndjson"; kill -9 $$"#)
        .arg("sh")
        .arg(store)
        .status()
        .unwrap();
    assert!(!status.success());
    let own = pack_work_dir(store);
    let old_legacy = store.join("work-01a21af97680716f93be95f70720972d");
    let fresh_legacy = store.join("work-01a21fabc179756f8925135f884633b3");
    let chunks = store.join("chunks");
    for d in [&own, &old_legacy, &fresh_legacy, &chunks] {
        std::fs::create_dir(d).unwrap();
    }
    let long_ago = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000);
    std::fs::File::open(&old_legacy).unwrap().set_modified(long_ago).unwrap();
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
    std::fs::File::open(&fresh_legacy).unwrap().set_modified(later).unwrap();
    sweep_pack_work_in(store);
    let mut left: Vec<String> = std::fs::read_dir(store)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    let mut want = vec![
        "chunks".to_owned(),
        fresh_legacy.file_name().unwrap().to_string_lossy().into_owned(),
        own.file_name().unwrap().to_string_lossy().into_owned(),
    ];
    want.sort();
    assert_eq!(left, want);
}
