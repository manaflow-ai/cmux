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

#[test]
fn a_chat_entry_stat_error_hides_only_that_chat() {
    for code in [libc::EIO, libc::ESTALE] {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join("sessions");
        let store = LocalStore::new(root.clone(), 64 * 1024).unwrap();
        for id in ["good-1", "good-2", "stat-error"] {
            store.save(&meta(id)).unwrap();
        }
        let guard =
            crate::config::startup_seams::on_entry_stat_error(&root.join("stat-error"), code);
        let mut ids: Vec<_> = store.list().unwrap().into_iter().map(|meta| meta.id).collect();
        ids.sort();
        assert_eq!(ids, ["good-1", "good-2"]);
        assert_eq!(store.unlisted(), ["stat-error"]);

        drop(guard);
        assert_eq!(store.list().unwrap().len(), 3);
        assert!(store.unlisted().is_empty());
    }
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

/// Ancestor checks belong to the store pass, not to each chat or its events folder.
#[test]
fn listing_chats_checks_store_ancestors_once() {
    for n in [1, 64] {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join("sessions");
        let store = LocalStore::new(root.clone(), 64 * 1024).unwrap();
        for i in 0..n {
            let id = format!("chat-{i}");
            let dir = root.join(&id);
            std::fs::create_dir_all(dir.join("events")).unwrap();
            std::fs::write(dir.join("session.json"), serde_json::to_vec(&meta(&id)).unwrap())
                .unwrap();
        }
        let checks = crate::config::startup_seams::Count::ancestors(&root);
        assert_eq!(store.list().unwrap().len(), n);
        assert_eq!(checks.get(), 1, "{n} chats repeated the store's ancestor walk");
        assert!(store.unlisted().is_empty());
    }
}

/// A held store and chat keep their original files when their names are replaced.
#[test]
fn a_held_store_reads_the_checked_folders_after_their_names_are_swapped() {
    use std::ffi::OsStr;
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("sessions");
    let store = LocalStore::new(root.clone(), 64 * 1024).unwrap();
    let mut original = meta("chat");
    original.available_commands = Some(json!([{"name": "original"}]));
    store.save(&original).unwrap();
    let held = crate::home_fs::PrivateDir::open(&root).unwrap();
    let entries = held.names().unwrap();
    let moved = home.path().join("moved-store");
    std::fs::rename(&root, &moved).unwrap();
    let replacement = LocalStore::new(root.clone(), 64 * 1024).unwrap();
    let mut other = meta("chat");
    other.name = "replacement".into();
    other.available_commands = Some(json!([{"name": "replacement"}]));
    replacement.save(&other).unwrap();
    let entry = entries.iter().find(|name| name.as_os_str() == OsStr::new("chat")).unwrap();
    assert_eq!(store.list_entry(&held, entry).unwrap(), Some(original.clone()));

    let chat = store.validate_session_dir(&held, OsStr::new("chat")).unwrap();
    std::fs::rename(moved.join("chat"), moved.join("old-chat")).unwrap();
    std::os::unix::fs::symlink(root.join("chat"), moved.join("chat")).unwrap();
    let mut text = String::new();
    chat.private_file(OsStr::new("session.json")).unwrap().read_to_string(&mut text).unwrap();
    let mut loaded: SessionMeta = serde_json::from_str(&text).unwrap();
    store.parts.merge_held(&chat, text.as_bytes(), &mut loaded);
    assert_eq!(loaded, original);
    assert!(store.validate_session_dir(&held, OsStr::new("chat")).is_err());
}

/// A child replaced during its permission check is refused, even by another real folder.
#[test]
fn a_chat_swapped_during_its_private_check_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("sessions");
    let store = LocalStore::new(root, 64 * 1024).unwrap();
    store.save(&meta("chat")).unwrap();
    let session = store.dir("chat");
    let moved = home.path().join("moved");
    let _guard = crate::config::startup_seams::on_dir_checked(move |path| {
        if path == session.as_path() {
            std::fs::rename(path, &moved).unwrap();
            std::fs::create_dir(path).unwrap();
        }
    });
    let error = store.load("chat").unwrap_err();
    assert!(error.to_string().contains("changed while"), "{error:#}");
}

#[test]
fn a_held_store_accepts_only_one_plain_child_name() {
    use std::ffi::OsStr;
    let home = tempfile::tempdir().unwrap();
    let store = LocalStore::new(home.path().join("sessions"), 64 * 1024).unwrap();
    store.save(&meta("chat")).unwrap();
    let held = crate::home_fs::PrivateDir::open(&store.root).unwrap();
    for name in [".", "..", "chat/.", "chat/", "chat/events", "/tmp"] {
        assert!(held.child(OsStr::new(name)).is_err(), "accepted {name}");
        assert!(held.private_file(OsStr::new(name)).is_err(), "accepted {name}");
    }
}

/// A read that fails after yielding names is still an error, never a partial or empty list.
#[test]
fn a_directory_read_error_does_not_return_a_partial_chat_list() {
    let home = tempfile::tempdir().unwrap();
    let store = LocalStore::new(home.path().join("sessions"), 64 * 1024).unwrap();
    store.save(&meta("chat")).unwrap();
    let _guard = crate::config::startup_seams::on_directory_read_error(std::io::ErrorKind::Other);
    assert!(store.list().is_err());
}
