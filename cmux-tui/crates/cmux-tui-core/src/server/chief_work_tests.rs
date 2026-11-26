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
fn chief_work_failed_agents_preserve_live_work_and_input_precedence() {
    for indicator in ["failed", "lost"] {
        assert_eq!(agent(&json!({"status": "idle", "indicator": indicator}))["state"], "failed");
    }
    let mut raw = json!({"status": "idle", "lastTurn": {"status": "failed"}});
    assert_eq!(agent(&raw)["state"], "failed");
    raw["status"] = json!("running");
    assert_eq!(agent(&raw)["state"], "working");
    raw["status"] = json!("waiting");
    assert_eq!(agent(&raw)["state"], "waiting");
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

#[test]
fn chief_work_scoped_hello_admits_channels_and_refuses_every_other_page() {
    use crate::server::client_hello::{HelloGate, Peer};
    let mux = Mux::new_for_test("chief-work-hello", crate::SurfaceOptions::default());
    let request = r#"{"id":42,"cmd":"chief-work","chief":"agent_mux"}"#;
    for page in ["home-channels", "history", "agent", "unknown"] {
        let mut gate = HelloGate::new(ClientTransport::WebSocket);
        gate.scope_to_page(page);
        let reply = gate.observe(&mux, u64::MAX, request, Peer::unknown);
        if page == "home-channels" {
            assert!(reply.is_none());
        } else {
            let reply = reply.unwrap();
            assert_eq!(reply["id"], 42);
            assert_eq!(reply["error_code"], "origin.forbidden");
        }
    }
}

#[test]
fn chief_work_a_bounded_snapshot_reads_active_sessions_first_and_reports_truncation() {
    let mut sessions: Vec<Value> = (0..MAX_SESSIONS)
        .map(|n| session(&format!("idle-{n}"), json!({"mux.parent": "optchat-chief:12345678"})))
        .collect();
    let mut active = session("active", json!({"mux.parent": "optchat-chief:12345678"}));
    active.as_object_mut().unwrap().insert("status".into(), json!("running"));
    sessions.push(active);
    let mut read = Vec::new();
    let snapshot = inventory("12345678", |method, params, _| {
        if method == "_acpmux/sessions" {
            return Ok(json!({"sessions": sessions}));
        }
        read.push(params["sessionId"].clone());
        Ok(json!({"processes": []}))
    })
    .unwrap();
    assert_eq!(snapshot["truncated"], true);
    assert_eq!(read.len(), MAX_SESSIONS);
    assert_eq!(read[0], "active");
}

#[test]
fn chief_work_command_bounds_report_only_omitted_rows() {
    for count in [MAX_TASKS, MAX_TASKS + 1] {
        let snapshot = inventory("12345678", |method, _, _| {
            if method == "_acpmux/sessions" {
                return Ok(json!({"sessions": [session("turn", json!({"cmux.chief": "12345678"}))]}));
            }
            let rows: Vec<Value> = (0..count).map(|n| json!({
                "id": format!("turn/{n}"), "sessionId": "turn", "command": "bun test", "state": "running"
            })).collect();
            Ok(json!({"processes": rows}))
        }).unwrap();
        assert_eq!(snapshot["tasks"].as_array().unwrap().len(), MAX_TASKS);
        assert_eq!(snapshot["truncated"], count > MAX_TASKS);
    }
}

/// The Chief's chats through the v2 list against v1's whole list (row 7c part two), through one
/// run of an agent service in this process: the same chats and subagents, but for a closed
/// root and what is under it, which a walk of `live` cannot see (named in [`chief_kin`]).
/// Another Chief's chat under this one's, and a chat under that, are left out on both.
#[cfg(unix)]
#[test]
fn chief_work_finds_the_same_chats_through_the_v2_list_but_a_closed_root() {
    use acpmux::test_support::list_daemon::{self, Serves, insert};
    let home = "0a1b2c3d";
    let fixture = |hub: &acpmux::hub::Hub| {
        let now = acpmux::store::now_ms();
        let at = |n: u64| now - 600_000 + n * 1_000;
        let meta = |id: &str, status: &str, n: u64, tags: Value| {
            list_daemon::meta(id, id, status, at(n), tags).unwrap()
        };
        let under = |mut meta: acpmux::store::SessionMeta, parent: &str| {
            meta.subsession = serde_json::from_value(
                json!({"startedBy": parent, "shortName": &meta.id, "depth": 1}),
            )
            .ok();
            meta
        };
        let rows = [
            meta("turn", "running", 0, json!({"cmux.chief": home})),
            meta("child", "running", 1, json!({"mux.parent": format!("optchat-chief:{home}")})),
            under(meta("grand", "closed", 2, json!({})), "child"),
            under(meta("other", "ready", 3, json!({"cmux.chief": "ffffffff"})), "turn"),
            under(meta("under-other", "ready", 4, json!({})), "other"),
            meta("closed-root", "closed", 5, json!({"cmux.chief": home})),
            under(meta("closed-root-child", "ready", 6, json!({})), "closed-root"),
            meta("spawned", "ready", 7, json!({"spawnedBy": "child"})),
            meta("person", "ready", 8, json!({})),
        ];
        let count = rows.len();
        for row in rows {
            insert(hub, row);
        }
        count
    };
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    let daemon = runtime.block_on(list_daemon::serve(Serves::List, fixture)).unwrap();
    let link = AcpmuxLink::connect(&daemon.path, |_| {}).unwrap();
    let all = link.call_whole_list("_acpmux/sessions", json!({}), TIMEOUT).unwrap();
    let (v1_owned, v1_children) = family(home, all["sessions"].as_array().unwrap());
    let ids =
        |names: &[&str]| -> HashSet<String> { names.iter().map(|n| (*n).to_owned()).collect() };
    assert_eq!(
        v1_owned,
        ids(&["turn", "child", "grand", "closed-root", "closed-root-child", "spawned"])
    );
    let deadline = Instant::now() + TIMEOUT;
    let (rows, owned, children) =
        chief_kin(home, &daemon.path, &link, deadline).unwrap().expect("the daemon serves v2");
    let closed = ids(&["closed-root", "closed-root-child"]);
    assert_eq!(owned, v1_owned.difference(&closed).cloned().collect());
    assert_eq!(children, v1_children.difference(&closed).cloned().collect());
    // The rows the work reads are v1's rows of those chats.
    for id in &owned {
        let row = rows.iter().find(|row| row["sessionId"] == json!(id)).unwrap();
        let v1 = all["sessions"].as_array().unwrap().iter().find(|r| r["sessionId"] == json!(id));
        assert_eq!(Some(row), v1, "{id}");
    }
    // A daemon without the list: v1's path.
    let daemon = runtime.block_on(list_daemon::serve(Serves::NoV2, fixture)).unwrap();
    let link = AcpmuxLink::connect(&daemon.path, |_| {}).unwrap();
    assert!(chief_kin(home, &daemon.path, &link, deadline).unwrap().is_none());
}

#[test]
fn chief_work_carries_each_chats_plan_from_its_row_with_no_extra_read() {
    let list = json!({"source": "agent", "done": 2, "total": 5, "current": "Wire the panel", "next": "Write tests", "updatedAt": 7});
    let mut child = session("child", json!({"mux.parent": "optchat-chief:12345678"}));
    child["taskList"] = list.clone();
    let mut root = session("turn", json!({"cmux.chief": "12345678"}));
    root["taskList"] =
        json!({"source": "chief", "done": 9, "total": 4, "current": "", "updatedAt": 8});
    let quiet = session("quiet", json!({"cmux.chief": "12345678"}));
    let mut reads = Vec::new();
    let snapshot = inventory("12345678", |method, params, _| {
        reads.push(method.to_owned());
        match method {
            "_acpmux/sessions" => {
                Ok(json!({"sessions": [child.clone(), root.clone(), quiet.clone()]}))
            }
            "_acpmux/process/list" => Ok(json!({"processes": []})),
            _ => panic!("unexpected {method} {params}"),
        }
    })
    .unwrap();
    assert_eq!(
        snapshot["agents"][0]["plan"],
        json!({"source": "agent", "done": 2, "total": 5, "current": "Wire the panel", "next": "Write tests", "updatedAt": 7})
    );
    // The Chief's own chats: only those with a plan; done never exceeds total; empty steps drop.
    let plans = snapshot["plans"].as_array().unwrap();
    assert_eq!(plans.len(), 1, "{snapshot}");
    assert_eq!(plans[0]["id"], "turn");
    assert_eq!(
        plans[0]["plan"],
        json!({"source": "chief", "done": 4, "total": 4, "current": null, "next": null, "updatedAt": 8})
    );
    assert!(reads.iter().all(|m| m == "_acpmux/sessions" || m == "_acpmux/process/list"));
    assert_eq!(plan(&json!({"taskList": {"done": 0, "total": 0}})), Value::Null);
    assert_eq!(plan(&json!({})), Value::Null);
}
