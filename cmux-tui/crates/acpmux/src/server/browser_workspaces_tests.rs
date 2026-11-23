//! Who may set the browser workspace source and read the workspaces, and what a read shows.

use super::*;

const HOST: &str = "install:this-mac";

fn source() -> Source {
    Source { socket: PathBuf::from("/tmp/cmux-app.sock"), host: HOST.to_owned() }
}

#[test]
fn only_the_person_on_the_local_socket_or_app_sets_the_source() {
    assert!(admits_set(Origin::Local, ConnAuth::LocalSocket, true));
    assert!(admits_set(Origin::LocalApp, ConnAuth::LocalApp, true));
    // Not proven as the person: an agent or a script on the same socket.
    assert!(!admits_set(Origin::Local, ConnAuth::LocalSocket, false));
    assert!(!admits_set(Origin::LocalApp, ConnAuth::LocalApp, false));
    // Never a remote connection, whatever it holds.
    for auth in [
        ConnAuth::ListenerToken,
        ConnAuth::WebDevice,
        ConnAuth::Device,
        ConnAuth::ReadOnlyDevice,
        ConnAuth::CarrierTeam,
        ConnAuth::None,
    ] {
        assert!(!admits_set(Origin::Web, auth, true), "{auth:?}");
    }
    assert!(!admits_set(Origin::Peer, ConnAuth::PeerToken, true));
    assert!(!admits_set(Origin::Peer, ConnAuth::CarrierOwner, true));
    // A proof that does not match its listener is not the app's.
    assert!(!admits_set(Origin::Web, ConnAuth::LocalApp, true));
    assert!(!admits_set(Origin::LocalApp, ConnAuth::ListenerToken, true));
}

#[test]
fn set_takes_a_source_and_an_empty_set_clears_it() {
    let sources = Sources::default();
    let set = sources
        .set_admitted(&json!({"socket": "/tmp/cmux-app.sock", "host": HOST}))
        .expect("a source is taken");
    assert_eq!(set, json!({"set": true}));
    assert_eq!(sources.current(), Some(source()));
    assert_eq!(sources.set_admitted(&json!({})).expect("a clear"), json!({"set": false}));
    assert_eq!(sources.current(), None);
    let null = json!({"socket": null, "host": null});
    assert_eq!(sources.set_admitted(&null).expect("a clear"), json!({"set": false}));
}

#[test]
fn set_refuses_a_malformed_source_and_keeps_the_last() {
    let sources = Sources::default();
    sources.set_admitted(&json!({"socket": "/tmp/cmux-app.sock", "host": HOST})).expect("set");
    for params in [
        json!({"socket": "relative.sock", "host": HOST}),
        json!({"socket": "/tmp/cmux-app.sock"}),
        json!({"host": HOST}),
        json!({"socket": "/tmp/a\nb", "host": HOST}),
        json!({"socket": "/tmp/cmux-app.sock", "host": ""}),
        json!({"socket": 7, "host": HOST}),
        json!({"socket": format!("/{}", "a".repeat(MAX_SOCKET_BYTES)), "host": HOST}),
    ] {
        assert!(sources.set_admitted(&params).is_err(), "{params}");
    }
    assert_eq!(sources.current(), Some(source()));
}

#[tokio::test]
async fn read_is_refused_without_a_presented_device() {
    let sources = Sources::default();
    sources.set_admitted(&json!({"socket": "/tmp/cmux-app.sock", "host": HOST})).expect("set");
    for proof in [
        ConnAuth::ListenerToken,
        ConnAuth::LocalSocket,
        ConnAuth::LocalApp,
        ConnAuth::PeerToken,
        ConnAuth::Device,
        ConnAuth::ReadOnlyDevice,
        ConnAuth::CarrierOwner,
        ConnAuth::CarrierTeam,
        ConnAuth::None,
    ] {
        let refused = sources.read_as(proof).await.expect_err("refused");
        let reason = refused.data.as_ref().and_then(|data| data["reason"].as_str());
        assert_eq!(reason, Some("device.required"), "{proof:?}");
    }
}

#[tokio::test]
async fn read_without_a_source_or_daemon_is_unavailable() {
    let sources = Sources::default();
    let none = sources.read_as(ConnAuth::WebDevice).await.expect("answered");
    assert_eq!(none, json!({"available": false, "registryId": null, "workspaces": []}));
    let dir = tempfile::tempdir().expect("temp dir");
    let socket = dir.path().join("gone.sock");
    let socket = socket.to_str().expect("utf-8 path");
    sources.set_admitted(&json!({"socket": socket, "host": HOST})).expect("set");
    let gone = sources.read_as(ConnAuth::WebDevice).await.expect("answered");
    assert_eq!(gone, json!({"available": false, "registryId": HOST, "workspaces": []}));
}

fn agent_tab(id: &str, host: &str, session: Option<&str>, name: &str) -> Value {
    json!({
        "id": 9,
        "tab_resource_id": id,
        "kind": "conversation",
        "name": null,
        "title": name,
        "title_text": name,
        "conversation": {"agent_session": {
            "host": host, "session": session, "harness": "codex", "host_name": "Other Mac",
        }},
    })
}

fn tree() -> Value {
    json!({"workspaces": [
        {"id": 1, "resource_id": "ws-a", "name": "cmux", "title": "Browser work", "screens": [
            {"panes": [{"tabs": [
                agent_tab("tab-1", HOST, Some("acp:chat-1"), "Fix the sidebar"),
                {"id": 3, "tab_resource_id": "tab-term", "kind": "pty", "title": "zsh"},
            ]}, {"tabs": [
                agent_tab("tab-2", "install:other-mac", Some("chat-2"), "Remote chat"),
                agent_tab("tab-3", HOST, None, ""),
            ]}]},
        ]},
        {"id": 2, "name": "empty", "screens": [{"panes": [{"tabs": []}]}]},
        {"name": "no id"},
    ]})
}

#[test]
fn project_groups_agent_chat_tabs_by_workspace() {
    let shown = project(&tree(), &source());
    assert_eq!(
        shown,
        json!({"available": true, "registryId": HOST, "workspaces": [
            {"id": "ws-a", "name": "cmux", "title": "Browser work", "chats": [
                {"tabId": "tab-1", "sessionId": "chat-1", "local": true,
                 "title": "Fix the sidebar", "host": "Other Mac", "harness": "codex"},
                {"tabId": "tab-2", "sessionId": "chat-2", "local": false,
                 "title": "Remote chat", "host": "Other Mac", "harness": "codex"},
                {"tabId": "tab-3", "local": true, "title": "", "host": "Other Mac",
                 "harness": "codex"},
            ]},
            {"id": "2", "name": "empty", "title": null, "chats": []},
        ]})
    );
}

#[cfg(unix)]
#[tokio::test]
async fn read_asks_the_app_daemon_as_a_remote_device_and_reuses_a_fresh_read() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("app.sock");
    let listener = tokio::net::UnixListener::bind(&path).expect("bind");
    let daemon = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        let hello: Value =
            serde_json::from_str(&lines.next_line().await.expect("read").expect("hello"))
                .expect("json");
        assert_eq!(hello["cmd"], "set-client-info", "{hello}");
        assert_eq!(hello["remote"], true, "{hello}");
        let capabilities = hello["capabilities"].as_array().expect("capabilities");
        assert!(capabilities.contains(&json!("agent-session-tabs-v1")), "{hello}");
        let reply = json!({"id": hello["id"], "ok": true, "data": {}});
        write.write_all(format!("{reply}\n").as_bytes()).await.expect("write");
        let list: Value =
            serde_json::from_str(&lines.next_line().await.expect("read").expect("list"))
                .expect("json");
        assert_eq!(list["cmd"], "list-workspaces", "{list}");
        // An event first, then the answer.
        let event = json!({"type": "event", "event": "tab-added"});
        let reply = json!({"id": list["id"], "ok": true, "data": tree()});
        write.write_all(format!("{event}\n{reply}\n").as_bytes()).await.expect("write");
        // Only one connection: a second read inside READ_REUSE is answered from the first.
        drop(listener_closed(lines).await);
    });
    let sources = Sources::default();
    let socket = path.to_str().expect("utf-8 path");
    sources.set_admitted(&json!({"socket": socket, "host": HOST})).expect("set");
    let first = sources.read_as(ConnAuth::WebDevice).await.expect("answered");
    assert_eq!(first, project(&tree(), &source_at(socket)));
    let again = sources.read_as(ConnAuth::WebDevice).await.expect("answered");
    assert_eq!(again, first);
    daemon.await.expect("the fake daemon");
}

#[cfg(unix)]
async fn listener_closed(
    mut lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
) -> Option<String> {
    lines.next_line().await.ok().flatten()
}

fn source_at(socket: &str) -> Source {
    Source { socket: PathBuf::from(socket), host: HOST.to_owned() }
}

#[test]
fn project_stops_at_its_byte_budget() {
    let title = "t".repeat(4096);
    let rows: Vec<Value> = (0..400)
        .map(|n| {
            json!({"resource_id": format!("ws-{n}"), "name": title, "screens": [{"panes": [
                {"tabs": [agent_tab(&format!("tab-{n}"), HOST, Some("chat"), &title)]},
            ]}]})
        })
        .collect();
    let shown = project(&json!({"workspaces": rows}), &source());
    assert_eq!(shown["truncated"], true);
    assert!(shown.to_string().len() <= REPLY_BUDGET + 1024, "{}", shown.to_string().len());
    assert!(!shown["workspaces"].as_array().expect("workspaces").is_empty());
}
