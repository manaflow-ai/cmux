//! CMUX-672: session bundles under `<home>/bundles` are bounded by age (`transfer.rs`
//! `sweep_bundles`), and the sweep never takes one an export or import is using, nor anything
//! a chat still needs.

use super::*;

const DAY: u64 = 24 * 60 * 60 * 1000;

/// Sets the modification time of `dir`, its `session.json` and `manifest.json` to `ms_ago` before
/// `now`, as if the bundle were exported then.
fn age(dir: &Path, now: u64, ms_ago: u64) {
    let at = std::time::UNIX_EPOCH + std::time::Duration::from_millis(now - ms_ago);
    for name in ["session.json", "manifest.json"] {
        if let Ok(file) = std::fs::File::options().write(true).open(dir.join(name)) {
            file.set_modified(at).unwrap();
        }
    }
    std::fs::File::open(dir).unwrap().set_modified(at).unwrap();
}

fn memory_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    Hub::new(
        config.clone(),
        crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap(),
    )
}

fn chat(hub: &Hub, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.append(&session, "mux", "created", json!({"harness": "fake"}));
    session
}

/// An old bundle goes; a new one, an old one an import or export just marked used, a folder
/// that is not a bundle and a link stay. The chat an old bundle was exported from keeps its
/// whole log, and a kept bundle still imports.
#[tokio::test]
async fn the_bundle_sweep_deletes_only_old_unused_bundles() {
    let root = tempfile::tempdir().unwrap();
    let root = root.path();
    let source = memory_hub();
    let old = source.export(&chat(&source, "bundle-old"), root).unwrap();
    let new = source.export(&chat(&source, "bundle-new"), root).unwrap();
    let importing = source.export(&chat(&source, "bundle-importing"), root).unwrap();
    let now = crate::store::now_ms();
    age(&old, now, 40 * DAY);
    age(&importing, now, 40 * DAY);
    age(&new, now, DAY);
    // An import of it began just now (`import_into` marks it before it reads it).
    mark_bundle_used_in(root, &importing);
    let notes = root.join("notes");
    std::fs::create_dir_all(&notes).unwrap();
    std::fs::write(notes.join("todo.txt"), b"x").unwrap();
    age(&notes, now, 90 * DAY);
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("session.json"), b"{}").unwrap();
    age(outside.path(), now, 90 * DAY);
    #[cfg(unix)]
    std::os::unix::fs::symlink(outside.path(), root.join("linked")).unwrap();

    let (removed, bytes) = sweep_bundles(root, now, std::time::Duration::from_millis(30 * DAY));
    assert_eq!(removed, 1);
    assert!(bytes > 0);
    assert!(!old.exists(), "the old bundle stayed");
    assert!(new.exists() && importing.exists(), "a new or in-use bundle went");
    assert!(notes.join("todo.txt").exists(), "a folder that is no bundle went");
    assert!(outside.path().join("session.json").exists(), "the sweep followed a link");
    // A bundle is a copy: its chat still has every record.
    let events = source.store.events("bundle-old", 0, 100).unwrap();
    assert!(events.iter().any(|e| e.kind == "created"), "the chat lost its log");
    // The kept bundle still imports whole.
    let here = memory_hub();
    let imported = here.import(&importing, None).await.unwrap();
    assert_eq!(imported.id, "bundle-importing");
    assert_eq!(sweep_bundles(root, now, std::time::Duration::from_millis(30 * DAY)).0, 0);
}

/// A bundle outside the bundle folder (an export's `dest`, a move's transfer folder) is never
/// marked: it is not the sweep's.
#[test]
fn only_a_bundle_inside_the_folder_is_marked_used() {
    let root = tempfile::tempdir().unwrap();
    let elsewhere = tempfile::tempdir().unwrap();
    let outside = elsewhere.path().join("chat");
    std::fs::create_dir_all(&outside).unwrap();
    mark_bundle_used_in(root.path(), &outside);
    assert!(!outside.join(BUNDLE_USED).exists());
    mark_bundle_used_in(root.path(), root.path());
    assert!(!root.path().join(BUNDLE_USED).exists(), "the folder itself is no bundle");
    let inside = root.path().join("chat");
    mark_bundle_used_in(root.path(), &inside);
    assert!(inside.join(BUNDLE_USED).exists());
}

/// The harness behind the PR's numbers: one 1 MiB bundle exported a day for 120 days, with and
/// without the daily sweep at the 30-day default, and the bytes left on disk.
#[test]
fn bundle_bound_bench_120_days_of_daily_exports() {
    let unbounded = tempfile::tempdir().unwrap();
    let bounded = tempfile::tempdir().unwrap();
    let start = crate::store::now_ms() - 120 * DAY;
    let max_age = std::time::Duration::from_millis(30 * DAY);
    let payload = vec![b'x'; 1 << 20];
    for day in 0..120u64 {
        let now = start + day * DAY;
        for root in [unbounded.path(), bounded.path()] {
            let dir = root.join(format!("chat-{day:03}"));
            std::fs::create_dir_all(dir.join("events")).unwrap();
            std::fs::write(dir.join("session.json"), b"{}").unwrap();
            std::fs::write(dir.join("manifest.json"), b"{}").unwrap();
            std::fs::write(dir.join("events").join("000001.ndjson"), &payload).unwrap();
            // Its files were written at `now`; the sweep's clock is the simulated day's.
            let real_now = crate::store::now_ms();
            age(&dir, real_now, real_now - now);
        }
        sweep_bundles(bounded.path(), now, max_age);
    }
    let (before, after) = (tree_bytes(unbounded.path()), tree_bytes(bounded.path()));
    eprintln!("bundle bound: 120 days, 1 MiB/day: unbounded {before} bytes, bounded {after} bytes");
    assert!(before >= 120 << 20);
    // The last 30 days and today: 31 bundles.
    assert!(after <= 32 << 20, "{after} bytes left");
}
