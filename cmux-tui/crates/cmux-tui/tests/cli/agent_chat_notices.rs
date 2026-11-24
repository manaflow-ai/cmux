//! Agent chat notifications (cx-sg1qz): the daemon follows this machine's
//! acpmux chats and posts one notification on one agent tab bound to a chat
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

/// A machine whose killed-agent turn cannot start an automatic retry behind the notice test.
fn machine_with_no_auto_resume(name: &str) -> Daemon {
    let config = json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT], "family": "fake"}},
        "defaultHarness": "fake",
        "webAskingModes": {"fake": ["normal"]},
        "autoResumeDelaysMs": [],
    });
    Daemon::start_with(name, None, Some(config))
}

/// A chat started in a new agent tab of the daemon, with its folder trusted.
fn chat(daemon: &Daemon) -> (u64, String) {
    let work = fs::canonicalize(daemon.dir.join("work")).unwrap();
    let trust = json!({work.to_str().unwrap(): "trusted"});
    fs::write(daemon.dir.join("acpmux/trust.json"), trust.to_string()).unwrap();
    // acpmux refuses a config another user can write; a 002 umask (Ubuntu's default) gives 664.
    std::fs::set_permissions(
        daemon.dir.join("acpmux/trust.json"),
        <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o600),
    )
    .unwrap();
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

    /// Starts a turn that emits its own pid, then kills that stub before it can answer.
    fn prompt_then_kill_agent(&mut self, session: &str) -> Value {
        let id = self.next;
        self.next += 1;
        let request = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": {"sessionId": session, "prompt": [{"type": "text", "text": "works-through-cancel"}]},
        });
        writeln!(self.reader.get_mut(), "{request}").unwrap();

        let mut killed = false;
        loop {
            let mut line = String::new();
            assert_ne!(
                self.reader.read_line(&mut line).unwrap(),
                0,
                "acpmux closed the connection"
            );
            let message: Value = serde_json::from_str(&line).unwrap();
            if !killed
                && let Some(title) = message.pointer("/params/update/title").and_then(Value::as_str)
                && let Some(pid) = title.strip_prefix("step ").and_then(|step| {
                    step.split_once(" pid ").and_then(|(_, pid)| pid.parse::<libc::pid_t>().ok())
                })
            {
                assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0, "kill stub agent {pid}");
                killed = true;
            }
            if message["id"] == id {
                assert!(killed, "the working stub agent never exposed its pid: {message}");
                return message;
            }
        }
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

/// A page that shows the chat stays shown while cmux is behind another app, so a turn that ends
/// there still posts, once: the app reads it on sight when its person can see it (the app active).
#[test]
fn a_turn_that_ends_while_a_pane_shows_the_chat_posts_once() {
    let daemon = machine("notice-shown");
    let (surface, session) = chat(&daemon);
    let (other_surface, other_session) = chat(&daemon);
    // A hidden chat's notice first: the daemon follows acpmux before the shown turn starts.
    let mut other = Acpmux::connect(&daemon, &other_session);
    other.prompt(&other_session, "hello there");
    notice(&daemon, other_surface, |row| row["acknowledged"] == false);

    let mut acpmux = Acpmux::connect(&daemon, &session);
    acpmux.call("_acpmux/view", json!({"sessionId": session, "visible": true}));
    acpmux.prompt(&session, "hello while shown");
    let done = notice(&daemon, surface, |row| {
        row["title"].as_str().is_some_and(|t| t.ends_with("finished"))
    });
    assert!(done["body"].as_str().unwrap().contains("hello while shown"), "{done}");

    // Another hidden turn after it: the shown chat posted nothing more meanwhile.
    other.prompt(&other_session, "hello again");
    notice(&daemon, other_surface, |row| {
        row["body"].as_str().is_some_and(|b| b.contains("hello again"))
    });
    let shown = notices(&daemon, surface);
    assert_eq!(shown.len(), 1, "one notice for the turn: {shown:?}");
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

/// Another agent tab, in a new workspace, on `session`, a chat that already runs (one chat open
/// in two windows).
fn second_tab(daemon: &Daemon, session: &str) -> u64 {
    let identity = daemon.rpc(json!({"id": 1, "cmd": "identify"}));
    let host = format!("registry:{}", identity["data"]["session_id"].as_str().unwrap());
    assert_eq!(daemon.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
    let tab = daemon.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
        "agent_session": {"host": host, "session": session, "harness": "fake"}}));
    assert_eq!(tab["ok"], true, "{tab}");
    tab["data"]["surface"].as_u64().unwrap()
}

/// Every notification on `surfaces` whose title ends with `suffix`.
fn titled(daemon: &Daemon, surfaces: &[u64], suffix: &str) -> Vec<Value> {
    all_notices(daemon)
        .into_iter()
        .filter(|row| surfaces.iter().any(|surface| row["surface"] == *surface))
        .filter(|row| row["title"].as_str().is_some_and(|t| t.ends_with(suffix)))
        .collect()
}

/// One chat open in two tabs is still one chat: its finished turn and its wait each post one
/// notification (one banner on the Mac, one push), on a tab that shows it, not one per tab
/// (goal notify-every-finish: 0 duplicates).
#[test]
fn a_chat_open_in_two_tabs_posts_one_notice_per_turn_and_per_wait() {
    let daemon = machine("notice-two-tabs");
    let (surface, session) = chat(&daemon);
    let other_surface = second_tab(&daemon, &session);
    let (marker_surface, marker_session) = chat(&daemon);
    let tabs = [surface, other_surface];
    let mut marker = Acpmux::connect(&daemon, &marker_session);

    let mut acpmux = Acpmux::connect(&daemon, &session);
    acpmux.prompt(&session, "hello there");
    // acpmux tells the daemon of every chat in order on one watch, so once another chat's
    // later turn notified, every notice of this turn was posted.
    marker.prompt(&marker_session, "marker one");
    notice(&daemon, marker_surface, |row| {
        row["body"].as_str().is_some_and(|b| b.contains("marker one"))
    });
    let finished = titled(&daemon, &tabs, "finished");
    assert_eq!(finished.len(), 1, "one finished turn, one notice: {finished:?}");

    let asking = {
        let mut asker = Acpmux::connect(&daemon, &session);
        let session = session.clone();
        std::thread::spawn(move || asker.prompt(&session, "ask: write the file"))
    };
    let deadline = Instant::now() + Duration::from_secs(20);
    while titled(&daemon, &tabs, "needs input").is_empty() {
        assert!(Instant::now() < deadline, "no needs-input notice: {:?}", all_notices(&daemon));
        std::thread::sleep(Duration::from_millis(50));
    }
    marker.prompt(&marker_session, "marker two");
    notice(&daemon, marker_surface, |row| {
        row["body"].as_str().is_some_and(|b| b.contains("marker two"))
    });
    let waiting = titled(&daemon, &tabs, "needs input");
    assert_eq!(waiting.len(), 1, "one wait, one notice: {waiting:?}");

    let info = acpmux.call("_acpmux/info", json!({"sessionId": session}));
    let permission = info["result"]["pending"][0]["permissionId"].clone();
    acpmux.call(
        "_acpmux/permission_respond",
        json!({"sessionId": session, "permissionId": permission, "optionId": "no"}),
    );
    asking.join().unwrap();
}

/// A stub agent killed in the middle of a turn posts one error notice for a chat open in two
/// tabs. Replaying the chat after a daemon restart keeps the same durable notification id.
#[test]
fn a_killed_agent_posts_one_notice_and_dedupes_after_daemon_restart() {
    let daemon = machine_with_no_auto_resume("notice-killed");
    let (surface, session) = chat(&daemon);
    let other_surface = second_tab(&daemon, &session);
    let (marker_surface, marker_session) = chat(&daemon);
    let tabs = [surface, other_surface];
    let mut acpmux = Acpmux::connect(&daemon, &session);
    let mut marker = Acpmux::connect(&daemon, &marker_session);

    let killed = acpmux.prompt_then_kill_agent(&session);
    assert!(killed.get("error").is_some(), "the killed turn unexpectedly answered: {killed}");
    let first = notice(&daemon, surface, |row| {
        row["level"] == "error"
            && (row["title"].as_str().is_some_and(|title| title.ends_with("failed"))
                || row["title"].as_str().is_some_and(|title| title.ends_with("stopped responding")))
    });
    let first_id = first["id"].clone();
    let target_errors = |daemon: &Daemon| -> Vec<Value> {
        all_notices(daemon)
            .into_iter()
            .filter(|row| tabs.contains(&row["surface"].as_u64().unwrap_or_default()))
            .filter(|row| row["source"] == "agent" && row["level"] == "error")
            .collect()
    };

    // A later chat change drains the watch, so a second dead-agent notice cannot hide behind the
    // first one before the count is checked.
    marker.prompt(&marker_session, "marker before restart");
    notice(&daemon, marker_surface, |row| {
        row["body"].as_str().is_some_and(|body| body.contains("marker before restart"))
    });
    assert_eq!(
        target_errors(&daemon).len(),
        1,
        "one dead-agent notice: {:?}",
        target_errors(&daemon)
    );

    restart(&daemon);
    marker.prompt(&marker_session, "marker after restart");
    notice(&daemon, marker_surface, |row| {
        row["body"].as_str().is_some_and(|body| body.contains("marker after restart"))
    });
    let after_restart = target_errors(&daemon);
    assert_eq!(
        after_restart.len(),
        1,
        "restart duplicated the dead-agent notice: {after_restart:?}"
    );
    assert_eq!(
        after_restart[0]["id"], first_id,
        "restart changed the dedupe id: {after_restart:?}"
    );
}

/// `list-notifications` with `stats: true` says how often agent notices were read and how fast,
/// per kind (pursuit research:notifications:2026-11-24): a finish a pane showed at once counts
/// as read within 60 s, and a wait nobody answered yet as unread and recent.
#[test]
fn notice_stats_count_reads_per_kind() {
    let daemon = machine("notice-stats");
    let (surface, session) = chat(&daemon);
    let mut acpmux = Acpmux::connect(&daemon, &session);
    acpmux.prompt(&session, "hello there");
    let done = notice(&daemon, surface, |row| row["acknowledged"] == false);
    acpmux.call("_acpmux/view", json!({"sessionId": session, "visible": true}));
    notice(&daemon, surface, |row| row["id"] == done["id"] && row["acknowledged"] == true);
    acpmux.call("_acpmux/view", json!({"sessionId": session, "visible": false}));

    let asking = {
        let mut asker = Acpmux::connect(&daemon, &session);
        let session = session.clone();
        std::thread::spawn(move || asker.prompt(&session, "ask: write the file"))
    };
    notice(&daemon, surface, |row| {
        row["acknowledged"] == false
            && row["title"].as_str().is_some_and(|t| t.ends_with("needs input"))
    });

    let listed = daemon.rpc(json!({"id": 9, "cmd": "list-notifications", "stats": true}));
    let stats = &listed["data"]["agent_notice_stats"];
    // The reading, for a run with --nocapture.
    eprintln!("agent_notice_stats: {stats}");
    let finished = &stats["kinds"]["finished"];
    assert_eq!(finished["posted"], 1, "{stats}");
    assert_eq!(finished["read_within_60s"], 1, "{stats}");
    assert_eq!(finished["acted_rate"], 1.0, "{stats}");
    assert!(finished["read_ms_p50"].as_u64().is_some_and(|ms| ms <= 60_000), "{stats}");
    let waiting = &stats["kinds"]["needs_input"];
    assert_eq!(waiting["posted"], 1, "{stats}");
    assert_eq!(waiting["unread_recent"], 1, "{stats}");
    assert_eq!(waiting["acted_rate"], Value::Null, "{stats}");
    assert_eq!(stats["all"]["posted"], 2, "{stats}");

    // Without `stats` the reply stays as it was.
    let plain = daemon.rpc(json!({"id": 10, "cmd": "list-notifications"}));
    assert!(plain["data"].get("agent_notice_stats").is_none(), "{plain}");

    let info = acpmux.call("_acpmux/info", json!({"sessionId": session}));
    let permission = info["result"]["pending"][0]["permissionId"].clone();
    acpmux.call(
        "_acpmux/permission_respond",
        json!({"sessionId": session, "permissionId": permission, "optionId": "no"}),
    );
    asking.join().unwrap();
}

/// Answers the chat's first pending ask with its reject option (any harness's shape: a
/// permission, a question, a plan approval), else cancels the turn.
fn answer_pending(acpmux: &mut Acpmux, session: &str) {
    let info = acpmux.call("_acpmux/info", json!({"sessionId": session}));
    let pending = info["result"]["pending"][0].clone();
    let options = pending["options"].as_array().cloned().unwrap_or_default();
    let option = options
        .iter()
        .find(|o| o["kind"].as_str().is_some_and(|k| k.starts_with("reject")))
        .or(options.first())
        .and_then(|o| o["optionId"].as_str().map(str::to_owned));
    match (pending["permissionId"].as_str(), option) {
        (Some(permission), Some(option)) => {
            let answered = acpmux.call(
                "_acpmux/permission_respond",
                json!({"sessionId": session, "permissionId": permission, "optionId": option}),
            );
            assert!(answered.get("error").is_none(), "{answered}");
        }
        _ => {
            acpmux.call("session/cancel", json!({"sessionId": session}));
        }
    }
}

/// A question is a wait like a permission (goal notify-every-finish: "every finished turn,
/// permission request and question"): each harness's question, and a plan to approve, posts
/// exactly one "needs input" notice for a chat open in two tabs, and answering it reads it.
#[test]
fn every_kind_of_question_posts_one_needs_input_notice_per_wait() {
    let daemon = machine("notice-questions");
    let (surface, session) = chat(&daemon);
    let other_surface = second_tab(&daemon, &session);
    let (marker_surface, marker_session) = chat(&daemon);
    let tabs = [surface, other_surface];
    let mut marker = Acpmux::connect(&daemon, &marker_session);
    let mut acpmux = Acpmux::connect(&daemon, &session);

    let kinds = [
        "question: which one",
        "plan-ask: read, then fix",
        "xai-question: which one",
        "cursor-question: which one",
    ];
    for (round, kind) in kinds.iter().enumerate() {
        let before: Vec<Value> = titled(&daemon, &tabs, "needs input")
            .into_iter()
            .map(|row| row["id"].clone())
            .collect();
        let fresh = |daemon: &Daemon| -> Vec<Value> {
            titled(daemon, &tabs, "needs input")
                .into_iter()
                .filter(|row| !before.contains(&row["id"]))
                .collect()
        };
        let asking = {
            let mut asker = Acpmux::connect(&daemon, &session);
            let session = session.clone();
            let kind = kind.to_string();
            std::thread::spawn(move || asker.prompt(&session, &kind))
        };
        let deadline = Instant::now() + Duration::from_secs(20);
        while fresh(&daemon).is_empty() {
            assert!(
                Instant::now() < deadline,
                "{kind}: no needs-input notice: {:?}",
                all_notices(&daemon)
            );
            std::thread::sleep(Duration::from_millis(50));
        }
        let fence = format!("marker {round}");
        marker.prompt(&marker_session, &fence);
        notice(&daemon, marker_surface, |row| {
            row["body"].as_str().is_some_and(|b| b.contains(&fence))
        });
        let waiting = fresh(&daemon);
        assert_eq!(waiting.len(), 1, "{kind}: one wait, one notice: {waiting:?}");
        assert_eq!(waiting[0]["source"], "agent", "{kind}: {:?}", waiting[0]);

        answer_pending(&mut acpmux, &session);
        let id = waiting[0]["id"].clone();
        let read = |row: &Value| row["id"] == id && row["acknowledged"] == true;
        let deadline = Instant::now() + Duration::from_secs(20);
        while !all_notices(&daemon).iter().any(read) {
            let all = all_notices(&daemon);
            assert!(Instant::now() < deadline, "{kind}: answered, still unread: {all:?}");
            std::thread::sleep(Duration::from_millis(50));
        }
        asking.join().unwrap();
    }
}
