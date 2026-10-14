//! An open `cmux chief` chat holds the Chief owner's one install-key restart
//! (hq-6d, 2026-10-14). A DEV app restarts a keyless Chief owner once, only
//! while the owner is idle; its idle check (CmuxNextDaemon `OwnerIdleProbe`)
//! reads `client.list`. A chat is a client of kind `chief-chat` for as long as
//! it runs, so the check sees the owner busy and the restart waits; when the
//! chat ends, that client leaves (`client-detached`), which is the event the
//! app tries the restart again on.

use super::*;

/// The daemon's clients as `client.list` (`cmux.protocol/2`) answers them.
fn client_list(server: &HeadlessServer) -> Vec<Value> {
    let request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "chat-kind-clients",
                         "operation": "client.list",
                         "params": {"machine": "current", "session": "current"}});
    let stream = transport::connect(&server.socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    loop {
        let mut line = String::new();
        assert!(
            reader.read_line(&mut line).unwrap() > 0,
            "client.list: the daemon closed the connection"
        );
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply["type"] == "response" && reply["id"] == "chat-kind-clients" {
            assert_eq!(reply["ok"], true, "client.list: {reply}");
            return reply["result"]
                .as_array()
                .cloned()
                .unwrap_or_else(|| panic!("client.list: {reply}"));
        }
    }
}

/// This test's own `cmux chief` child, ended on drop (also when an assertion fails).
struct Chat(Child);

impl Drop for Chat {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The next `client-changed` or `client-detached` event on `watch` (its read times out after 20 s).
fn next_client_event(watch: &mut Conn) -> Value {
    loop {
        let event = watch.event();
        if event["event"] == "client-changed" || event["event"] == "client-detached" {
            return event;
        }
    }
}

#[test]
fn an_open_chief_chat_is_a_chief_chat_client_until_it_ends() {
    let server = HeadlessServer::start("chief-chat-kind");
    let mut home = Conn::open(&server.socket);
    chief_conversation(&mut home);
    let mut watch = Conn::open(&server.socket);
    watch.request("subscribe", json!({}));

    // A chat that stays open: pipe mode waits for the Chief's reply, and no brain answers.
    let chat = Command::new(bin())
        .arg("--socket")
        .arg(&server.socket)
        .args(["chief", "-p", "are you there?", "--timeout", "120"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_CHIEF_OWNER_SOCKET")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let chat = Chat(chat);

    // The chat names itself once it connects (the watch reads its client-changed event).
    let deadline = Instant::now() + Duration::from_secs(15);
    let named = loop {
        assert!(Instant::now() < deadline, "the chat never named itself a chief-chat client");
        let event = next_client_event(&mut watch);
        if event["event"] == "client-changed" && event["kind"] == "chief-chat" {
            break event;
        }
    };
    assert_eq!(named["name"], "cmux chief", "{named}");
    let listed = client_list(&server);
    let chats: Vec<&Value> =
        listed.iter().filter(|client| client["client_kind"] == "chief-chat").collect();
    assert_eq!(chats.len(), 1, "client.list shows one open chat: {listed:?}");
    assert_eq!(chats[0]["transport"], "unix", "{listed:?}");

    // The chat ends (this test's own child): its client leaves, with the id it named.
    drop(chat);
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        assert!(Instant::now() < deadline, "the ended chat's client never left");
        let event = next_client_event(&mut watch);
        if event["event"] == "client-detached" && event["client"] == named["client"] {
            break;
        }
    }
    let listed = client_list(&server);
    assert!(
        listed.iter().all(|client| client["client_kind"] != "chief-chat"),
        "no chief-chat client after the chat ended: {listed:?}"
    );
}
