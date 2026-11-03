use super::*;

fn session(id: &str, tags: Value) -> Value {
    json!({"sessionId": id, "name": id, "status": "idle", "tags": tags})
}

#[test]
fn chief_work_follows_owned_children_at_any_depth_and_excludes_other_chiefs_and_peers() {
    let mut grandchild = session("grandchild", json!({}));
    grandchild.as_object_mut().unwrap().insert("parent".into(), json!("child"));
    let mut unrelated = session("other-chief", json!({"cmux.chief": "87654321"}));
    unrelated.as_object_mut().unwrap().insert("parent".into(), json!("child"));
    let mut peer = session("peer", json!({"mux.parent": "optchat-chief:12345678"}));
    peer.as_object_mut().unwrap().insert("peer".into(), json!("remote"));
    let rows = vec![
        grandchild,
        unrelated,
        peer,
        session("child", json!({"mux.parent": "optchat-chief:12345678"})),
        session("turn", json!({"cmux.chief": "12345678"})),
        session("person", json!({})),
    ];
    let (owned, children) = family("12345678", &rows);
    assert_eq!(owned, HashSet::from_iter(["turn", "child", "grandchild"].map(str::to_owned)));
    assert_eq!(children, HashSet::from_iter(["child", "grandchild"].map(str::to_owned)));
}

#[test]
fn chief_work_reads_paged_sessions_and_commands_with_no_unrelated_task_reads() {
    let mut calls = Vec::new();
    let snapshot = inventory("12345678", |method, params, _| {
        calls.push((method.to_owned(), params.clone()));
        match (method, params.get("cursor").and_then(Value::as_str)) {
            ("_acpmux/sessions", None) => Ok(json!({"sessions": [session("person", json!({}))], "nextCursor": "s2"})),
            ("_acpmux/sessions", Some("s2")) => Ok(json!({"sessions": [session("child", json!({"mux.parent": "optchat-chief:12345678"}))]})),
            ("_acpmux/process/list", None) => Ok(json!({"processes": [{"id": "child/build", "sessionId": "child", "command": "bun run build", "state": "running"}], "nextCursor": "p2"})),
            ("_acpmux/process/list", Some("p2")) => Ok(json!({"processes": [{"id": "child/test", "sessionId": "child", "command": "bun test", "state": "exited", "exitCode": 1}]})),
            _ => panic!("unexpected {method} {params}"),
        }
    }).unwrap();
    assert_eq!(snapshot["agents"][0]["name"], "child");
    assert_eq!(snapshot["tasks"][0]["status"], "running");
    assert_eq!(snapshot["tasks"][1]["status"], "failed");
    assert_eq!(snapshot["truncated"], false);
    assert_eq!(snapshot["taskSources"], json!(["harness"]));
    assert_eq!(calls.len(), 4);
    assert!(
        calls
            .iter()
            .filter(|(method, _)| method == "_acpmux/process/list")
            .all(|(_, params)| params["sessionId"] == "child")
    );
}

#[test]
fn chief_work_a_failed_or_repeated_page_is_not_empty_success() {
    for fail_process in [false, true] {
        let result = inventory("12345678", |method, params, _| {
            if method == "_acpmux/sessions" {
                if !fail_process {
                    return Ok(json!({"sessions": [], "nextCursor": "again"}));
                }
                return Ok(
                    json!({"sessions": [session("turn", json!({"cmux.chief": "12345678"}))]}),
                );
            }
            if params.get("cursor").is_some() {
                return Err(UNAVAILABLE);
            }
            Ok(json!({"processes": [], "nextCursor": "later"}))
        });
        assert_eq!(result.unwrap_err(), UNAVAILABLE);
    }
    assert!(
        inventory("12345678", |method, _, _| {
            if method == "_acpmux/sessions" {
                Ok(json!({"sessions": [session("turn", json!({"cmux.chief": "12345678"}))]}))
            } else {
                Ok(json!({"processes": [{"id": "person/x", "sessionId": "person"}]}))
            }
        })
        .is_err()
    );
}

#[test]
fn chief_work_lost_and_failed_commands_do_not_look_completed() {
    assert_eq!(task(&json!({"state": "lost"}))["status"], "unknown");
    assert_eq!(task(&json!({"state": "failed"}))["status"], "failed");
    assert_eq!(task(&json!({"state": "exited", "exitCode": 0}))["status"], "done");
    assert_eq!(task(&json!({"state": "killed"}))["status"], "cancelled");
    assert_eq!(agent(&json!({"status": "idle", "state": "stuck"}))["state"], "failed");
}

#[test]
fn chief_work_a_moved_home_keeps_its_pinned_identity() {
    let dir = cmux_unix_socket::short_test_dir("chief-work");
    std::fs::create_dir(dir.path().join("optchat")).unwrap();
    let file = dir.path().join("optchat/home-id");
    std::fs::write(&file, "0123abcd\n").unwrap();
    assert_eq!(home_id(dir.path()), "0123abcd");
    std::fs::write(&file, "../../other").unwrap();
    assert_ne!(home_id(dir.path()), "../../other");
}

#[test]
fn chief_work_admits_the_owner_channels_page_and_refuses_other_devices_and_agents() {
    use crate::server::origin_gate::{set_page, set_scoped_page};
    use crate::server::{BoundedOutbound, QueuedSink};
    let mux = Mux::new_for_test("chief-work-access", crate::SurfaceOptions::default());
    let connect = |transport| {
        let writer = MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        });
        mux.control_clients.register(transport, writer)
    };
    let local = connect(ClientTransport::Unix);
    assert!(reader(&mux, local));
    let page = connect(ClientTransport::WebSocket);
    set_scoped_page(&mux, page, "home-channels".to_owned());
    assert!(reader(&mux, page));
    let paired = connect(ClientTransport::WebSocket);
    mux.control_clients.mark_person(paired);
    set_page(&mux, paired, "home-channels".to_owned());
    assert!(!reader(&mux, paired));
    let other = connect(ClientTransport::WebSocket);
    set_scoped_page(&mux, other, "history".to_owned());
    assert!(!reader(&mux, other));
    mux.bind_conversation_principal(page, "agent_other".to_owned()).unwrap();
    assert!(!reader(&mux, page));
    assert!(!reader(&mux, u64::MAX));
}
