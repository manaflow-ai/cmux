//! Agent chat notifications (cx-sg1qz): the daemon follows this machine's
//! acpmux chats and posts a notification on every agent tab bound to a chat
//! when its turn ends (done or failed) and when it starts waiting for the
//! person. The app turns those into banners, the Dock badge and a click that
//! opens the tab, as for any notification on a tab; the daemon reads them
//! again when acpmux says a pane showed the chat or the question was answered.
//!
//! A chat muted from its tab's menu (the acpmux session tag
//! `notifications: muted`, so every window and device sees it) posts nothing.
//!
//! Each test runs a real daemon and its acpmux with the test agent, and talks
//! to acpmux the way a pane in a hidden tab does (`visible: false`), so no
//! client shows the chat while its turn runs.

use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use super::*;

/// A machine whose acpmux runs the test agent, whose "normal" mode asks
/// before each action (so the daemon may start it).
fn machine(name: &str) -> Daemon {
    let config = json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT], "family": "fake"}},
        "defaultHarness": "fake",
        "webAskingModes": {"fake": ["normal"]},
    });
    Daemon::start_with(name, None, Some(config))
}

/// A chat started in a new agent tab of the daemon, with its folder trusted.
fn chat(daemon: &Daemon) -> (u64, String) {
    let work = fs::canonicalize(daemon.dir.join("work")).unwrap();
    let trust = json!({work.to_str().unwrap(): "trusted"});
    fs::write(daemon.dir.join("acpmux/trust.json"), trust.to_string()).unwrap();
    let surface = daemon.own_agent_tab();
    let started = daemon.start_chat(surface);
    assert_eq!(started["ok"], true, "{started}");
    (surface, started["data"]["session"].as_str().unwrap().to_owned())
}

/// The daemon's notifications on `surface`.
fn notices(daemon: &Daemon, surface: u64) -> Vec<Value> {
    let listed = daemon.rpc(json!({"id": 9, "cmd": "list-notifications"}));
    let rows = listed["data"]["notifications"].as_array().cloned().unwrap_or_default();
    rows.into_iter().filter(|row| row["surface"] == surface).collect()
}

/// Waits up to twenty seconds for a notification on `surface` that `matches`.
fn notice(daemon: &Daemon, surface: u64, matches: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(found) = notices(daemon, surface).into_iter().find(|row| matches(row)) {
            return found;
        }
        assert!(Instant::now() < deadline, "no such notice: {:?}", notices(daemon, surface));
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// A client of the daemon's acpmux, as a pane in a hidden tab.
struct Acpmux {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Acpmux {
    fn connect(daemon: &Daemon, session: &str) -> Self {
        let stream = UnixStream::connect(daemon.dir.join("acpmux/acpmux.sock")).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut acpmux = Self { reader: BufReader::new(stream), next: 1 };
        acpmux.call("initialize", json!({"protocolVersion": 1, "clientCapabilities": {}}));
        acpmux.call("_acpmux/attach", json!({"sessionId": session, "visible": false}));
        acpmux
    }

    /// One request; its result once acpmux answers (a prompt answers at its turn's end).
    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(
                self.reader.read_line(&mut line).unwrap(),
                0,
                "acpmux closed the connection"
            );
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == id {
                return message;
            }
        }
    }

    fn prompt(&mut self, session: &str, text: &str) -> Value {
        self.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
    }
}

#[test]
fn a_turn_that_ends_unseen_notifies_its_tab_until_a_pane_shows_the_chat() {
    let daemon = machine("notice-done");
    let (surface, session) = chat(&daemon);
    let mut acpmux = Acpmux::connect(&daemon, &session);
    acpmux.prompt(&session, "hello there");

    let done = notice(&daemon, surface, |row| row["acknowledged"] == false);
    assert_eq!(done["source"], "agent", "{done}");
    assert!(done["title"].as_str().unwrap().ends_with("finished"), "{done}");
    assert!(done["body"].as_str().unwrap().contains("hello there"), "{done}");

    // A pane shows the chat: acpmux reads it, and so does the daemon.
    acpmux.call("_acpmux/view", json!({"sessionId": session, "visible": true}));
    notice(&daemon, surface, |row| row["id"] == done["id"] && row["acknowledged"] == true);
}

#[test]
fn a_chat_waiting_for_the_person_notifies_its_tab_until_answered() {
    let daemon = machine("notice-input");
    let (surface, session) = chat(&daemon);
    let mut acpmux = Acpmux::connect(&daemon, &session);
    // The prompt waits for the answer, so it runs on its own connection.
    // The answer is a deny: this plain socket client is not the person.
    let asking = {
        let mut asker = Acpmux::connect(&daemon, &session);
        let session = session.clone();
        std::thread::spawn(move || asker.prompt(&session, "ask: write the file"))
    };

    let waiting = notice(&daemon, surface, |row| {
        row["acknowledged"] == false
            && row["title"].as_str().is_some_and(|t| t.ends_with("needs input"))
    });
    assert_eq!(waiting["source"], "agent", "{waiting}");

    let info = acpmux.call("_acpmux/info", json!({"sessionId": session}));
    let permission = info["result"]["pending"][0]["permissionId"].clone();
    let answered = acpmux.call(
        "_acpmux/permission_respond",
        json!({"sessionId": session, "permissionId": permission, "optionId": "no"}),
    );
    assert!(answered.get("error").is_none(), "{answered}");
    notice(&daemon, surface, |row| row["id"] == waiting["id"] && row["acknowledged"] == true);
    asking.join().unwrap();
}

#[test]
fn a_failed_turn_notifies_its_tab() {
    let daemon = machine("notice-failed");
    let (surface, session) = chat(&daemon);
    let mut acpmux = Acpmux::connect(&daemon, &session);
    acpmux.prompt(&session, "fail-after-update: the disk is full");

    let failed = notice(&daemon, surface, |row| row["acknowledged"] == false);
    assert_eq!(failed["level"], "error", "{failed}");
    assert!(failed["title"].as_str().unwrap().ends_with("failed"), "{failed}");
}

#[test]
fn a_turn_that_ends_while_a_pane_shows_the_chat_posts_nothing() {
    let daemon = machine("notice-shown");
    let (surface, session) = chat(&daemon);
    let (other_surface, other_session) = chat(&daemon);
    let mut acpmux = Acpmux::connect(&daemon, &session);
    acpmux.call("_acpmux/view", json!({"sessionId": session, "visible": true}));
    acpmux.prompt(&session, "hello while shown");

    // acpmux tells the daemon of every chat in order on one watch, so once
    // the other chat's later turn notified, the shown chat's turn was passed over.
    Acpmux::connect(&daemon, &other_session).prompt(&other_session, "hello there");
    notice(&daemon, other_surface, |row| row["acknowledged"] == false);
    assert_eq!(
        notices(&daemon, surface),
        Vec::<Value>::new(),
        "a turn the person watched notified"
    );
}

#[test]
fn a_muted_chat_posts_nothing_until_unmuted() {
    let daemon = machine("notice-muted");
    let (surface, session) = chat(&daemon);
    let (other_surface, other_session) = chat(&daemon);
    let mut acpmux = Acpmux::connect(&daemon, &session);
    let muted = acpmux
        .call("_acpmux/tag", json!({"sessionId": session, "set": {"notifications": "muted"}}));
    assert!(muted.get("error").is_none(), "{muted}");
    acpmux.prompt(&session, "fail-after-update: while muted");
    acpmux.prompt(&session, "hello while muted");

    // acpmux tells the daemon of every chat in order on one watch, so once
    // the other chat's later turn notified, the muted turns were passed over.
    Acpmux::connect(&daemon, &other_session).prompt(&other_session, "hello there");
    notice(&daemon, other_surface, |row| row["acknowledged"] == false);
    assert_eq!(notices(&daemon, surface), Vec::<Value>::new(), "a muted turn notified");

    let unmuted =
        acpmux.call("_acpmux/tag", json!({"sessionId": session, "remove": ["notifications"]}));
    assert!(unmuted.get("error").is_none(), "{unmuted}");
    acpmux.prompt(&session, "hello again");
    notice(&daemon, surface, |row| row["body"].as_str().is_some_and(|b| b.contains("hello again")));
}

/// Stops the daemon and starts a new one on the same state; acpmux and its
/// chats keep running.
fn restart(daemon: &Daemon) {
    for action in ["stop", "ensure"] {
        let output = daemon.server(action).output().unwrap();
        assert!(output.status.success(), "{action}: {}", String::from_utf8_lossy(&output.stderr));
    }
}

/// Every notification of the daemon, on any tab.
fn all_notices(daemon: &Daemon) -> Vec<Value> {
    let listed = daemon.rpc(json!({"id": 9, "cmd": "list-notifications"}));
    listed["data"]["notifications"].as_array().cloned().unwrap_or_default()
}

#[test]
fn a_daemon_restart_while_a_chat_waits_posts_needs_input_once() {
    let daemon = machine("notice-restart");
    let (surface, session) = chat(&daemon);
    let (_, other_session) = chat(&daemon);
    let mut acpmux = Acpmux::connect(&daemon, &session);
    let asking = {
        let mut asker = Acpmux::connect(&daemon, &session);
        let session = session.clone();
        std::thread::spawn(move || asker.prompt(&session, "ask: write the file"))
    };
    notice(&daemon, surface, |row| {
        row["title"].as_str().is_some_and(|t| t.ends_with("needs input"))
    });
    // The chat records more while it waits, so its last record moves on.
    let tagged =
        acpmux.call("_acpmux/tag", json!({"sessionId": session, "set": {"note": "waiting"}}));
    assert!(tagged.get("error").is_none(), "{tagged}");

    restart(&daemon);
    // The new daemon's watch has caught up once the other chat's later turn notified.
    Acpmux::connect(&daemon, &other_session).prompt(&other_session, "hello after restart");
    let deadline = Instant::now() + Duration::from_secs(20);
    while !all_notices(&daemon)
        .iter()
        .any(|row| row["body"].as_str().is_some_and(|b| b.contains("hello after restart")))
    {
        assert!(Instant::now() < deadline, "no notice after restart: {:?}", all_notices(&daemon));
        std::thread::sleep(Duration::from_millis(50));
    }
    let waiting: Vec<Value> = all_notices(&daemon)
        .into_iter()
        .filter(|row| row["title"].as_str().is_some_and(|t| t.ends_with("needs input")))
        .collect();
    assert_eq!(waiting.len(), 1, "one wait, one needs-input notice: {waiting:?}");

    let info = acpmux.call("_acpmux/info", json!({"sessionId": session}));
    let permission = info["result"]["pending"][0]["permissionId"].clone();
    acpmux.call(
        "_acpmux/permission_respond",
        json!({"sessionId": session, "permissionId": permission, "optionId": "no"}),
    );
    asking.join().unwrap();
}
