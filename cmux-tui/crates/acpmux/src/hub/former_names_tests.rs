//! `former_names.rs`: a renamed session still answers to its old names.

use super::*;
use crate::session_identity::SessionReceipt;

pub(crate) fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

pub(crate) fn chat(hub: &Hub, id: &str, name: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name, "harness": "pi",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    hub.insert_test_session(meta)
}

fn id_of(found: Result<Arc<Session>, RpcError>) -> String {
    found.map(|s| s.id.clone()).unwrap_or_else(|e| format!("error: {}", e.message))
}

#[test]
fn a_rename_keeps_the_old_name_newest_last_without_repeats() {
    let mut former = vec!["a".to_owned(), "b".to_owned()];
    push_former(&mut former, "a", "c");
    assert_eq!(former, ["b", "a"], "a name taken again moves to the end");
    push_former(&mut former, "c", "b");
    assert_eq!(former, ["a", "c"], "the new name is no former name");
    for n in 0..20 {
        push_former(&mut former, &format!("n{n}"), "z");
    }
    assert_eq!(former.len(), KEPT);
    assert_eq!(former.last().map(String::as_str), Some("n19"));
    push_former(&mut former, "z", "z");
    assert!(!former.iter().any(|n| n == "z"), "a rename to the same name keeps nothing");
}

#[tokio::test]
async fn an_old_name_finds_the_session_after_a_rename() {
    let hub = hub();
    let s = chat(&hub, "s1", "claude-3");
    hub.rename(&s, "fix-sidebar-spinner".into()).await.unwrap();
    assert_eq!(s.meta().former_names, ["claude-3"]);
    assert_eq!(id_of(hub.resolve("claude-3")), "s1");
    assert_eq!(id_of(hub.resolve("fix-sidebar-spinner")), "s1");
    assert_eq!(hub.key_route("claude-3").unwrap().as_deref(), Some("s1"));
    let own = crate::pairing::machine_name();
    assert_eq!(id_of(hub.resolve(&format!("{own}/claude-3"))), "s1");
    // The list and `session info` show it.
    assert_eq!(hub.session_summary(&s)["formerNames"], json!(["claude-3"]));
    // A second rename keeps both.
    hub.rename(&s, "ship-the-docs".into()).await.unwrap();
    assert_eq!(s.meta().former_names, ["claude-3", "fix-sidebar-spinner"]);
    assert_eq!(id_of(hub.resolve("fix-sidebar-spinner")), "s1");
}

#[tokio::test]
async fn a_current_name_wins_over_a_former_one() {
    let hub = hub();
    let a = chat(&hub, "a1", "alpha");
    hub.rename(&a, "beta".into()).await.unwrap();
    chat(&hub, "b1", "alpha");
    assert_eq!(id_of(hub.resolve("alpha")), "b1");
    assert_eq!(id_of(hub.resolve_here("alpha")), "b1");
    // A prefix of another name does not hide a former name either.
    chat(&hub, "c1", "gamma-long");
    let g = chat(&hub, "g1", "gamma");
    hub.rename(&g, "delta".into()).await.unwrap();
    assert_eq!(id_of(hub.resolve("gamma")), "g1");
}

#[tokio::test]
async fn a_rename_takes_another_sessions_former_name_and_refuses_its_current_one() {
    let hub = hub();
    let a = chat(&hub, "a1", "alpha");
    let b = chat(&hub, "b1", "gamma");
    hub.rename(&a, "beta".into()).await.unwrap();
    // `beta` is a's name now: refused.
    let e = hub.rename(&b, "beta".into()).await.unwrap_err();
    assert!(e.message.contains("taken"), "{}", e.message);
    // `alpha` is only a's former name: b takes it, and a gives it up.
    hub.rename(&b, "alpha".into()).await.unwrap();
    assert!(a.meta().former_names.is_empty(), "{:?}", a.meta().former_names);
    assert_eq!(id_of(hub.resolve("alpha")), "b1");
    // b's old name is b's alone.
    assert_eq!(id_of(hub.resolve("gamma")), "b1");
}

#[tokio::test]
async fn a_former_name_two_sessions_kept_is_refused_with_both() {
    let hub = hub();
    let a = chat(&hub, "a1", "one");
    let b = chat(&hub, "b1", "two");
    hub.edit_test_meta(&a, |m| m.former_names = vec!["shared".into()]);
    hub.edit_test_meta(&b, |m| m.former_names = vec!["shared".into()]);
    let Err(e) = hub.resolve("shared") else { panic!("an old name two sessions kept resolved") };
    assert!(e.message.contains("one (a1)") && e.message.contains("two (b1)"), "{}", e.message);
    // Closed ones give way to a live one.
    hub.edit_test_meta(&a, |m| m.status = SessionStatus::Closed);
    assert_eq!(id_of(hub.resolve("shared")), "b1");
}

#[tokio::test]
async fn a_peer_sessions_former_name_routes_to_it() {
    let hub = hub();
    let row = RemoteSession {
        peer: "hb".into(),
        summary: json!({"sessionId": "0199aaaa", "name": "hb/new-name", "status": "idle",
                        "formerNames": ["old-name"]})
        .into(),
        receipt: SessionReceipt {
            host_id: "hb".into(),
            mux_session_id: "0199aaaa".into(),
            agent_session_id: None,
            generation: 1,
        },
    };
    hub.remote_sessions.write().insert("hb/0199aaaa".into(), row);
    assert!(matches!(hub.former_remote_route("hb/old-name"), Some(Ok(r)) if r == "hb/0199aaaa"));
    assert!(matches!(hub.former_remote_route("old-name"), Some(Ok(r)) if r == "hb/0199aaaa"));
    assert!(hub.former_remote_route("other/old-name").is_none());
    assert_eq!(hub.key_route("old-name").unwrap().as_deref(), Some("hb/0199aaaa"));
    // A session here named so now wins.
    chat(&hub, "l1", "old-name");
    assert_eq!(hub.key_route("old-name").unwrap().as_deref(), Some("l1"));
}

#[tokio::test]
async fn a_hand_rename_titles_the_chat_by_the_name_in_words() {
    let hub = hub();
    let s = chat(&hub, "s1", "claude-3");
    hub.edit_test_meta(&s, |m| {
        m.title = Some("Session restrictions and stalled PR batch".into());
        m.title_source = Some("generated".into());
    });
    hub.rename(&s, "session-name-aliases".into()).await.unwrap();
    let m = s.meta();
    assert_eq!(m.title.as_deref(), Some("Session name aliases"));
    assert_eq!(m.title_source.as_deref(), Some(super::super::titles::NAMED));
    // `register` renames an address and leaves the title.
    hub.rename_as(&s, "lane-7".into(), super::super::task_names::Naming::Address).await.unwrap();
    assert_eq!(s.meta().title.as_deref(), Some("Session name aliases"));
}
