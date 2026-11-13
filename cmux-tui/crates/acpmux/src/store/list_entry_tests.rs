//! One chat folder that the store refuses or cannot read (a link, a folder another user can
//! write, metadata that is not UTF-8, a read error) is left out of the list, and only it: before,
//! its error failed the whole list, so the daemon showed no chat at all.

use super::*;
use serde_json::json;
use std::os::unix::fs::PermissionsExt;

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

#[test]
fn a_chat_folder_the_store_refuses_hides_only_that_chat() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let root = home.path().join("sessions");
    let store = LocalStore::new(root.clone(), StoreConfig::default().segment_bytes)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    for id in ["good-1", "good-2", "loose-mode", "not-utf8"] {
        store.save(&meta(id)).unwrap_or_else(|e| panic!("save {id}: {e:#}"));
    }
    // Another user may write it: refused.
    std::fs::set_permissions(root.join("loose-mode"), std::fs::Permissions::from_mode(0o775))
        .unwrap_or_else(|e| panic!("{e}"));
    // Metadata that does not read as text.
    std::fs::write(root.join("not-utf8").join("session.json"), b"{\"id\": \"\xff\xfe\"}")
        .unwrap_or_else(|e| panic!("{e}"));
    // A link: never read through.
    let outside = home.path().join("outside");
    std::fs::create_dir_all(&outside).unwrap_or_else(|e| panic!("{e}"));
    std::os::unix::fs::symlink(&outside, root.join("linked")).unwrap_or_else(|e| panic!("{e}"));

    let listed = store.list().unwrap_or_else(|e| panic!("one bad chat failed the list: {e:#}"));
    let mut ids: Vec<String> = listed.into_iter().map(|m| m.id).collect();
    ids.sort();
    assert_eq!(ids, ["good-1", "good-2"]);
    let mut unlisted = store.unlisted();
    unlisted.sort();
    assert_eq!(unlisted, ["linked", "loose-mode", "not-utf8"], "a refused chat counts as unread");
}

/// A sessions folder that exists and cannot be read is a failed list, never an empty one: an
/// empty list proves every chat gone, and the start's adoption ends the agents of chats it
/// does not know (`hub/hosts.rs` `purged_at_start`).
#[test]
fn a_sessions_folder_that_cannot_be_read_fails_the_list() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let root = home.path().join("sessions");
    let store = LocalStore::new(root.clone(), StoreConfig::default().segment_bytes)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    store.save(&meta("good-1")).unwrap_or_else(|e| panic!("{e:#}"));
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o300))
        .unwrap_or_else(|e| panic!("{e}"));
    let listed = store.list();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(listed.is_err(), "an unreadable sessions folder listed as empty: {listed:?}");
}

/// A chat stored before the agent-to-harness rename (`"agent"`, `"agentArgv"`) still reads. It
/// did not (the rename's alias named the new key, `harness`), and such a chat, left out of the
/// list, then refused every purge in the daemon: it "may be a fork" of each chat a purge ends
/// (`fork_view.rs` `forks_of`). Chief's compactor sessions were never deleted, so their names
/// stayed taken, and its summaries stopped for good.
#[test]
fn a_chat_stored_with_the_old_agent_keys_still_reads_and_does_not_block_a_purge() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let root = home.path().join("sessions");
    let store = LocalStore::new(root.clone(), StoreConfig::default().segment_bytes)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    store.save(&meta("old-agent")).unwrap_or_else(|e| panic!("save: {e:#}"));
    // The metadata as a build before the rename wrote it.
    let old = json!({
        "schema": "acpmux.session.v1",
        "id": "old-agent",
        "name": "opencode",
        "agent": "opencode",
        "agentArgv": ["/usr/local/bin/opencode", "acp"],
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    });
    std::fs::write(
        root.join("old-agent").join("session.json"),
        serde_json::to_vec_pretty(&old).unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap_or_else(|e| panic!("{e}"));

    let loaded = store
        .load("old-agent")
        .unwrap_or_else(|e| panic!("an old chat's metadata does not read: {e:#}"))
        .unwrap_or_else(|| panic!("the old chat is gone"));
    assert_eq!(loaded.harness, "opencode");
    assert_eq!(loaded.harness_argv, ["/usr/local/bin/opencode", "acp"]);
    let listed = store.list().unwrap_or_else(|e| panic!("list: {e:#}"));
    assert!(listed.iter().any(|m| m.id == "old-agent"), "the old chat is listed");
    assert!(store.unlisted().is_empty(), "no chat is left out: {:?}", store.unlisted());
}
