use super::*;
use std::path::PathBuf;

fn peer(name: Option<&str>) -> Peer {
    Peer {
        pid: 42,
        session_id: "sid".into(),
        cwd: Some(PathBuf::from("/Users/leo/fun/cmux")),
        entrypoint: Some("claude-desktop".into()),
        kind: Some("interactive".into()),
        name: name.map(str::to_owned),
        version: Some("2.1.310".into()),
        socket: None,
    }
}

#[test]
fn a_chat_is_named_by_the_session_else_its_folder() {
    assert_eq!(name_of(&peer(Some("fix the sidebar"))), "fix the sidebar");
    assert_eq!(name_of(&peer(None)), "desktop cmux");
    assert_eq!(name_of(&peer(Some("  "))), "desktop cmux");
}

#[test]
fn a_name_another_chat_has_gets_the_pid() {
    assert_eq!(unique_name("desktop cmux", "42", |_| false), "desktop cmux");
    assert_eq!(unique_name("desktop cmux", "42", |n| n == "desktop cmux"), "desktop cmux (42)");
    let both = |n: &str| n == "desktop cmux" || n == "desktop cmux (42)";
    assert_eq!(unique_name("desktop cmux", "42", both), "desktop cmux (42) 2");
}

fn thread(name: Option<&str>) -> Thread {
    Thread {
        id: "01a1bf30-e092-7232-aca1-16444234c40f".into(),
        originator: "codex_desktop".into(),
        cwd: Some(PathBuf::from("/Users/leo/fun/cmux")),
        name: name.map(str::to_owned),
        title: Some("fix the sidebar".into()),
        version: Some("0.164.0".into()),
    }
}

#[test]
fn a_codex_chat_is_named_by_the_thread_else_its_folder_and_tagged_from_its_row() {
    assert_eq!(codex_name_of(&thread(Some("sidebar"))), "sidebar");
    assert_eq!(codex_name_of(&thread(None)), "codex cmux");
    assert_eq!(
        codex_tags_of(&thread(None)),
        json!({"bridge": "codex", "origin": "codex_desktop", "origin.version": "0.164.0"})
    );
}

#[test]
fn a_send_is_bound_only_to_the_chat_whose_live_app_is_its_ancestor() {
    let chats = vec![("chat-1".to_owned(), "sid".to_owned())];
    let live = vec![peer(None)];
    let listed = vec!["claude-desktop".to_owned()];
    let none = |_: &str, _: &Peer| false;
    // acpmux (50) under bash (45) under the desktop session's claude (42).
    assert_eq!(
        bound_chat(&[50, 45, 42, 1], &chats, &live, &listed, &[], none).as_deref(),
        Some("chat-1")
    );
    // Another process tree: nothing.
    assert_eq!(bound_chat(&[50, 45, 7], &chats, &live, &listed, &[], none), None);
    // An entrypoint the setting does not list: nothing.
    assert_eq!(bound_chat(&[50, 42], &chats, &live, &["cli".to_owned()], &[], none), None);
    // A live app with no chat the bridge made: nothing.
    let other = vec![("chat-2".to_owned(), "other".to_owned())];
    assert_eq!(bound_chat(&[50, 42], &other, &live, &listed, &[], none), None);
    // A chat its session registered is bound whatever its entrypoint, by the process its
    // registration recorded.
    let recorded = |id: &str, p: &Peer| id == "chat-1" && p.pid == 42;
    let registered = ["chat-1".to_owned()];
    assert_eq!(
        bound_chat(&[50, 42], &chats, &live, &["cli".to_owned()], &registered, recorded).as_deref(),
        Some("chat-1")
    );
    // Repro: another process writes an entry naming the registered chat's session id; with
    // the setting off it is not the recorded process, so its sends are not that chat's.
    let forged = |_: &str, p: &Peer| p.pid == 99;
    assert_eq!(
        bound_chat(&[50, 42], &chats, &live, &["cli".to_owned()], &registered, forged),
        None
    );
    // Repro: the forged entry names the default listed entrypoint (claude-desktop, the one
    // `listed` holds here); a registered chat still binds only its recorded process.
    assert_eq!(bound_chat(&[50, 42], &chats, &live, &listed, &registered, forged), None);
}

#[test]
fn a_bridged_sender_is_read_from_the_daemon_stamp() {
    let params = json!({"_meta": {"acpmux": {BRIDGED_KEY: "chat-1"}}});
    assert_eq!(bridged_sender(&params), Some("chat-1"));
    assert_eq!(bridged_sender(&json!({})), None);
}

#[test]
fn provenance_tags_come_from_the_registry_entry() {
    assert_eq!(
        tags_of(&peer(None)),
        json!({"bridge": "claude", "origin": "claude-desktop", "origin.pid": "42", "origin.version": "2.1.310"})
    );
}
