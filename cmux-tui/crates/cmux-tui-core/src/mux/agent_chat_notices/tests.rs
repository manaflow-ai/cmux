use super::*;

/// A chat as acpmux summarizes it at `seq`.
fn chat(indicator: &str, seq: u64) -> Chat {
    Chat::of(&json!({
        "sessionId": "chat-1",
        "title": "Review",
        "indicator": indicator,
        "lastSeq": seq,
        "lastMessage": {"text": "Run npm test?"},
    }))
    .expect("a local chat")
}

/// The `_acpmux/permission_pending` a watcher gets for a new ask (a `permission_request`
/// record: it names its turn and its group, null when none).
fn ask(permission: &str, group: Option<&str>, seq: u64) -> Value {
    json!({"permissionId": permission, "groupId": group, "turnId": "turn-1", "seq": seq,
               "sessionId": "chat-1", "via": "watch", "request": {}})
}

/// The same ask re-issued by an acpmux that restarted (`permission_reissued`: no turn, no group).
fn reissued(permission: &str, seq: u64) -> Value {
    json!({"permissionId": permission, "seq": seq, "sessionId": "chat-1", "via": "watch", "request": {}})
}

/// A chat whose turn `turn` ended, hidden, `unread`, with or without work below it.
fn ended(turn: &str, unread: bool, works_below: bool) -> Chat {
    Chat::of(&json!({
            "sessionId": "chat-1",
            "title": "Review",
            "indicator": if works_below { "working" } else { "done" },
            "unread": unread,
            "lastSeq": 20,
            "lastTurn": {"turnId": turn, "status": "completed"},
            "subagentsWorkingSince": if works_below { json!(1_700_000_000_000_u64) } else { Value::Null },
        }))
        .expect("a local chat")
}

fn key(notice: Option<Notice>) -> Option<String> {
    notice.map(|notice| notice.key)
}

/// The watch's chat after a change from `before`, as `apply` keeps it.
fn after(before: &Chat, indicator: &str, seq: u64) -> Chat {
    let mut next = chat(indicator, seq);
    next.keep_asks(Some(before));
    next
}

/// A fake acpmux on one end of a socket pair. It answers each list request
/// (`_acpmux/watch`, then `_acpmux/sessions`) with the next of `replies`, written
/// as is, and ends the connection after the last one, or when the client asks for
/// nothing more. The thread returns the requests it read.
fn fake_acpmux(replies: Vec<String>) -> (UnixStream, std::thread::JoinHandle<Vec<Value>>) {
    let (client, server) = UnixStream::pair().expect("a socket pair");
    server.set_read_timeout(Some(Duration::from_secs(5))).expect("a read timeout");
    let serve = std::thread::spawn(move || {
        let mut writer = server.try_clone().expect("a writer");
        let mut replies = replies.into_iter();
        let mut requests = Vec::new();
        for line in BufReader::new(server).lines() {
            let Ok(line) = line else { break };
            let request: Value = serde_json::from_str(&line).expect("a JSON request");
            let lists = ["_acpmux/watch", "_acpmux/sessions"]
                .contains(&request["method"].as_str().unwrap_or_default());
            requests.push(request);
            if lists {
                let Some(reply) = replies.next() else { break };
                // The client may stop reading a reply it cannot use.
                let _ = writer.write_all(reply.as_bytes());
                if replies.as_slice().is_empty() {
                    break;
                }
            }
        }
        requests
    });
    (client, serve)
}

/// One page of the session list as acpmux answers request `id`.
fn list_reply(id: u64, sessions: &[Value], next: Option<&str>) -> String {
    let mut result = json!({"sessions": sessions});
    if let Some(next) = next {
        result["nextCursor"] = json!(next);
    }
    format!("{}\n", json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

fn local(session: &str) -> Value {
    json!({"sessionId": session, "title": session, "indicator": "idle", "lastSeq": 1})
}

fn test_mux(name: &str) -> Arc<Mux> {
    Mux::new_for_test(name, crate::SurfaceOptions::default())
}

/// Starts `watch` on a missing socket under a fresh folder and returns
/// once the thread waits for the socket to appear (its sender is in place).
fn waiting_watch(mux: &Arc<Mux>, name: &str) -> std::thread::JoinHandle<()> {
    let dir = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a test folder");
    let socket = dir.join("acpmux.sock");
    let weak = Arc::downgrade(mux);
    let thread = std::thread::spawn(move || watch(&weak, &socket));
    let deadline = Instant::now() + Duration::from_secs(5);
    while mux.agent_chat_notices.lock().hint.is_none() {
        assert!(Instant::now() < deadline, "the watch never armed");
        std::thread::sleep(Duration::from_millis(10));
    }
    thread
}

fn ends_within(thread: &std::thread::JoinHandle<()>, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    while !thread.is_finished() {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    true
}

#[test]
fn shutdown_ends_a_watch_that_waits_for_acpmux() {
    // A missing socket leaves the thread blocked on its hints with no
    // timer: shutdown must end that wait, or the thread and its file
    // watch outlive the daemon's shutdown.
    let mux = test_mux("notices-shutdown");
    let thread = waiting_watch(&mux, "cmux-notices-shutdown");
    mux.shutting_down.store(true, std::sync::atomic::Ordering::Release);
    mux.stop_agent_chat_notices();
    assert!(ends_within(&thread, Duration::from_secs(5)), "the watch outlived shutdown");
}

#[test]
fn dropping_the_mux_ends_a_watch_that_waits_for_acpmux() {
    // The watch holds no sender of its own, so the last mux reference
    // going away disconnects the hints and ends the thread.
    let mux = test_mux("notices-drop");
    let thread = waiting_watch(&mux, "cmux-notices-drop");
    drop(mux);
    assert!(ends_within(&thread, Duration::from_secs(5)), "the watch outlived its mux");
}

/// Starts `watch` on a socket a silent acpmux listens on, and returns once
/// the thread is connected and waits for acpmux's reply. The listener is
/// returned too: dropping it would end the connection on its own.
fn connected_watch(
    mux: &Arc<Mux>,
    name: &str,
) -> (std::thread::JoinHandle<()>, std::os::unix::net::UnixListener, UnixStream) {
    let dir = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("a test folder");
    let socket = dir.join("acpmux.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).expect("a listener");
    let weak = Arc::downgrade(mux);
    let thread = std::thread::spawn(move || watch(&weak, &socket));
    let (accepted, _) = listener.accept().expect("the watch connects");
    accepted.set_read_timeout(Some(Duration::from_secs(5))).expect("a read timeout");
    let mut first = String::new();
    BufReader::new(accepted.try_clone().expect("a clone"))
        .read_line(&mut first)
        .expect("the initialize request");
    assert!(first.contains("initialize"), "{first}");
    (thread, listener, accepted)
}

#[test]
fn shutdown_ends_a_watch_connected_to_a_silent_acpmux() {
    // Connected, the thread blocks reading acpmux's next line with no
    // timeout: shutdown must end that read too.
    let mux = test_mux("notices-connected-shutdown");
    let (thread, _listener, _acpmux) = connected_watch(&mux, "cmux-notices-conn-shutdown");
    mux.shutting_down.store(true, std::sync::atomic::Ordering::Release);
    mux.stop_agent_chat_notices();
    assert!(ends_within(&thread, Duration::from_secs(5)), "the read outlived shutdown");
}

#[test]
fn dropping_the_mux_ends_a_watch_connected_to_a_silent_acpmux() {
    let mux = test_mux("notices-connected-drop");
    let (thread, _listener, _acpmux) = connected_watch(&mux, "cmux-notices-conn-drop");
    drop(mux);
    assert!(ends_within(&thread, Duration::from_secs(5)), "the read outlived its mux");
}

#[test]
fn only_a_missing_listener_counts_toward_giving_up_on_a_hint() {
    use std::io::{Error, ErrorKind};
    assert!(no_listener(&Error::from(ErrorKind::ConnectionRefused)));
    assert!(no_listener(&Error::from(ErrorKind::NotFound)));
    // Out of descriptors or a permission error says nothing of acpmux:
    // the watch keeps retrying instead of waiting for the next change.
    assert!(!no_listener(&Error::from_raw_os_error(24)));
    assert!(!no_listener(&Error::from(ErrorKind::PermissionDenied)));
}

#[test]
fn a_list_past_four_mib_is_read_whole_and_an_at_once_end_is_no_success() {
    // cosmic-gray (2026-10-27): 2786 sessions were one 14.7 MB line. A 4 MiB read
    // cut it, counted the cut as a success and reconnected every second.
    let filler = "x".repeat(4096);
    let mut sessions: Vec<Value> = (0..1500)
        .map(|n| json!({"sessionId": format!("peer-{n}"), "peer": "builder", "title": filler}))
        .collect();
    sessions.push(local("chat-1"));
    let reply = list_reply(2, &sessions, None);
    assert!(reply.len() > 4 << 20);
    let mux = test_mux("notices-long-list");
    let mut chats = HashMap::new();
    let (client, serve) = fake_acpmux(vec![reply]);
    let followed = follow(&Arc::downgrade(&mux), client, &mut chats, &mut None);
    serve.join().expect("the fake acpmux");
    assert!(chats.contains_key("chat-1"), "the whole list was read");
    assert!(followed.is_err(), "a connection that ends right after its list keeps the backoff");
}

#[test]
fn a_closed_or_removed_chat_ends_its_link_shares() {
    let change = |kind: &str, status: &str| json!({"sessionId": "chat-1", "kind": kind, "session": {"status": status}});
    assert!(closes_chat(&change("updated", "closed")));
    assert!(closes_chat(&json!({"sessionId": "chat-1", "kind": "purged"})));
    for status in ["idle", "running", "disconnected"] {
        assert!(!closes_chat(&change("updated", status)), "{status}");
    }
}

#[test]
fn a_line_cut_short_is_a_failure() {
    let mux = test_mux("notices-cut-line");
    let mut chats = HashMap::new();
    let (client, serve) =
        fake_acpmux(vec![r#"{"jsonrpc":"2.0","id":2,"result":{"sessions":["#.to_owned()]);
    let followed = follow(&Arc::downgrade(&mux), client, &mut chats, &mut None);
    serve.join().expect("the fake acpmux");
    assert!(followed.is_err());
}

/// R-LIFECYCLE ORPHANS: the notices connection only watches, so it says so in its
/// `initialize`: once the app that started acpmux has quit, it keeps no acpmux daemon (this
/// daemon stays after a Keep Sessions quit with live shells, and so did acpmux and its router).
#[test]
fn the_notices_connection_says_it_only_observes() {
    let mux = test_mux("notices-observer");
    let mut chats = HashMap::new();
    let (client, serve) = fake_acpmux(vec![list_reply(2, &[local("chat-1")], None)]);
    let _ = follow(&Arc::downgrade(&mux), client, &mut chats, &mut None);
    let requests = serve.join().expect("the fake acpmux");
    assert_eq!(requests[0]["method"], "initialize");
    assert_eq!(requests[0]["params"]["_meta"]["acpmux"]["observer"], true, "{}", requests[0]);
}

#[test]
fn the_list_comes_a_page_at_a_time() {
    let mux = test_mux("notices-pages");
    let mut chats = HashMap::new();
    let (client, serve) = fake_acpmux(vec![
        list_reply(2, &[local("chat-1")], Some("k5.1")),
        list_reply(3, &[local("chat-2")], None),
    ]);
    let followed = follow(&Arc::downgrade(&mux), client, &mut chats, &mut None);
    let requests = serve.join().expect("the fake acpmux");
    assert!(followed.is_err(), "it ended right after its list");
    assert_eq!(requests[1]["method"], "_acpmux/watch");
    assert_eq!(requests[1]["params"]["limit"], PAGE_SESSIONS);
    assert_eq!(requests[2]["method"], "_acpmux/sessions");
    assert_eq!(requests[2]["params"], json!({"limit": PAGE_SESSIONS, "cursor": "k5.1"}));
    let mut known: Vec<_> = chats.keys().cloned().collect();
    known.sort();
    assert_eq!(known, ["chat-1", "chat-2"]);
}

/// acpmux's `initialize` reply, naming [`ACPMUX_LIST_FOLLOW`] when `follows`.
fn initialized(follows: bool) -> String {
    let capabilities = if follows { json!([ACPMUX_LIST_FOLLOW]) } else { json!([]) };
    format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "id": 1, "result": {"_meta": {"acpmux": {"capabilities": capabilities}}}})
    )
}

/// A follow's reply to request `id`: the rows changed and gone, current to `seq`.
fn follow_reply(id: u64, sessions: &[Value], gone: &[&str], seq: u64, more: bool) -> String {
    let gone: Vec<Value> = gone.iter().map(|id| json!({"sessionId": id})).collect();
    format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "id": id, "result": {"follow": true, "listEpoch": "run-1",
                "listSeq": seq, "more": more, "gone": gone, "sessions": sessions}})
    )
}

fn cursor_at(seq: u64) -> Option<ListCursor> {
    Some(ListCursor { epoch: "run-1".to_owned(), seq })
}

fn held(sessions: &[&str], list_seq: u64) -> HashMap<String, Chat> {
    sessions
        .iter()
        .map(|session| {
            let mut chat = Chat::of(&local(session)).expect("a local chat");
            chat.list_seq = list_seq;
            (session.to_string(), chat)
        })
        .collect()
}

/// A reconnect with a cursor asks for the rows changed since it, once, and never the list:
/// the rows it names change, the ones gone go, the rest stand, and the cursor moves on. A
/// push older than a row the follow brought changes nothing; a newer one does.
#[test]
fn a_reconnect_follows_from_its_cursor() {
    let mux = test_mux("notices-follow");
    let mut chats = held(&["chat-1", "chat-2"], 4);
    let mut cursor = cursor_at(7);
    let mut working = local("chat-3");
    working["indicator"] = json!("working");
    let push = |seq: u64, indicator: &str| {
        let mut session = local("chat-3");
        session["indicator"] = json!(indicator);
        format!(
            "{}\n",
            json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed",
                "params": {"sessionId": "chat-3", "kind": "updated", "session": session, "listSeq": seq}})
        )
    };
    let reply = format!(
        "{}{}{}",
        initialized(true),
        follow_reply(2, &[working], &["chat-2"], 9, false),
        push(8, "input"),
    );
    let (client, serve) = fake_acpmux(vec![reply]);
    let _ = follow(&Arc::downgrade(&mux), client, &mut chats, &mut cursor);
    let requests = serve.join().expect("the fake acpmux");
    let lists: Vec<_> = requests.iter().filter(|r| r["method"] != "initialize").collect();
    assert_eq!(lists.len(), 1, "{requests:?}");
    assert_eq!(lists[0]["method"], "_acpmux/watch");
    assert_eq!(lists[0]["params"]["afterSeq"], 7);
    assert_eq!(lists[0]["params"]["listEpoch"], "run-1");
    assert!(chats.contains_key("chat-1"), "a row no follow named stands");
    assert!(!chats.contains_key("chat-2"), "a row gone goes");
    assert_eq!(chats["chat-3"].indicator, "working", "an older push does not undo the follow");
    assert_eq!(cursor, cursor_at(9));
    assert!(older_than_held(chats.get("chat-3"), 0, &json!({"listSeq": 8})));
    assert!(!older_than_held(chats.get("chat-3"), 0, &json!({"listSeq": 9})));
    assert!(!older_than_held(chats.get("chat-3"), 0, &json!({})), "no position: as before");
    assert!(!older_than_held(None, 0, &json!({"listSeq": 1})));
    assert!(older_than_held(None, 9, &json!({"listSeq": 8})), "the list's position holds it");
}

/// A follow cut at its size (`more`) goes on from the position it reached, and a watch acpmux
/// says lagged follows from the cursor instead of reading the list again.
#[test]
fn a_follow_goes_on_from_where_it_was_cut_and_a_lag_follows() {
    let mux = test_mux("notices-follow-more");
    let mut chats = held(&["chat-1"], 4);
    let mut cursor = cursor_at(5);
    let lagged = json!({"jsonrpc": "2.0", "method": "_acpmux/lagged", "params": {"watch": true}});
    let (client, serve) = fake_acpmux(vec![
        format!("{}{}", initialized(true), follow_reply(2, &[local("chat-2")], &[], 6, true)),
        format!("{}{lagged}\n", follow_reply(3, &[local("chat-3")], &[], 8, false)),
        follow_reply(4, &[], &["chat-1"], 9, false),
    ]);
    let _ = follow(&Arc::downgrade(&mux), client, &mut chats, &mut cursor);
    let requests = serve.join().expect("the fake acpmux");
    let after: Vec<_> = requests
        .iter()
        .filter(|r| r["method"] == "_acpmux/watch")
        .map(|r| r["params"]["afterSeq"].clone())
        .collect();
    assert_eq!(after, [json!(5), json!(6), json!(8)]);
    assert!(requests.iter().all(|r| r["method"] != "_acpmux/sessions"));
    let mut known: Vec<_> = chats.keys().cloned().collect();
    known.sort();
    assert_eq!(known, ["chat-2", "chat-3"]);
    assert_eq!(cursor, cursor_at(9));
}

/// A cursor acpmux cannot follow (another run) is answered with the list's first page and
/// `reset`: it is read as a first list, so a row it leaves out is gone.
#[test]
fn a_reset_reads_the_list_as_a_first_list() {
    let mux = test_mux("notices-follow-reset");
    let mut chats = held(&["chat-1"], 4);
    let mut cursor = cursor_at(7);
    let reset = format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "id": 2, "result": {"reset": true, "listEpoch": "run-2",
                "listSeq": 3, "sessions": [local("chat-2")]}})
    );
    let (client, serve) = fake_acpmux(vec![format!("{}{reset}", initialized(true))]);
    let _ = follow(&Arc::downgrade(&mux), client, &mut chats, &mut cursor);
    serve.join().expect("the fake acpmux");
    assert!(!chats.contains_key("chat-1"), "the reset list left it out");
    assert_eq!(chats["chat-2"].list_seq, 3);
    assert_eq!(cursor, Some(ListCursor { epoch: "run-2".to_owned(), seq: 3 }));
}

/// A reset list at position 5 leaves out chat-1, removed before it. Pushes about chat-1 from
/// before it (positions 3 and 4) come late, one while the list is still paging and one after
/// it is whole: neither brings it back. A push past the list's position still counts.
#[test]
fn a_push_older_than_a_reset_list_does_not_bring_back_a_chat_it_left_out() {
    let mux = test_mux("notices-follow-reset-race");
    let mut chats = held(&["chat-1"], 4);
    let mut cursor = cursor_at(7);
    let push = |session: &str, seq: u64| {
        format!(
            "{}\n",
            json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed",
                "params": {"sessionId": session, "kind": "updated", "session": local(session),
                    "listSeq": seq}})
        )
    };
    let first = format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "id": 2, "result": {"reset": true, "listEpoch": "run-2",
                "listSeq": 5, "sessions": [local("chat-2")], "nextCursor": "page-2"}})
    );
    let (client, serve) = fake_acpmux(vec![
        format!("{}{first}{}", initialized(true), push("chat-1", 3)),
        format!("{}{}{}", list_reply(3, &[], None), push("chat-1", 4), push("chat-3", 6)),
    ]);
    let _ = follow(&Arc::downgrade(&mux), client, &mut chats, &mut cursor);
    serve.join().expect("the fake acpmux");
    assert!(!chats.contains_key("chat-1"), "an older push brought back a chat the list left out");
    assert!(chats.contains_key("chat-2"));
    assert!(chats.contains_key("chat-3"), "a push past the list's position counts");
}

/// An acpmux without the capability keeps no cursor: the next connection reads the list
/// whole, as before.
#[test]
fn an_acpmux_that_cannot_follow_keeps_no_cursor() {
    let mux = test_mux("notices-follow-older");
    let mut chats = HashMap::new();
    let mut cursor = cursor_at(7);
    let (client, serve) = fake_acpmux(vec![format!(
        "{}{}",
        initialized(false),
        list_reply(2, &[local("chat-1")], None)
    )]);
    let _ = follow(&Arc::downgrade(&mux), client, &mut chats, &mut cursor);
    serve.join().expect("the fake acpmux");
    assert_eq!(cursor, None);
    assert!(chats.contains_key("chat-1"));
    assert_eq!(watch_request(2, None)["params"], json!({"enabled": true, "limit": PAGE_SESSIONS}));
}

#[test]
fn a_connection_that_ends_mid_list_keeps_what_the_watch_knew() {
    let mux = test_mux("notices-mid-list");
    let mut chats = HashMap::from([("chat-1".to_owned(), chat("idle", 3))]);
    let (client, serve) = fake_acpmux(vec![
        list_reply(2, &[local("chat-2")], Some("k5.1")),
        r#"{"jsonrpc":"2.0","id":3,"result":"#.to_owned(),
    ]);
    let followed = follow(&Arc::downgrade(&mux), client, &mut chats, &mut None);
    serve.join().expect("the fake acpmux");
    assert!(followed.is_err());
    assert!(chats.contains_key("chat-1"), "no page reached it: the next connection compares");
    assert!(chats.contains_key("chat-2"));
}

#[test]
fn a_page_older_than_a_push_before_it_does_not_undo_the_push() {
    // acpmux turns the watch on, then reads its page: the push of a change made
    // in between can come first, and the page still shows the chat before it.
    let mux = test_mux("notices-push-first");
    let mut chats = HashMap::new();
    let waiting =
        json!({"sessionId": "chat-1", "title": "chat-1", "indicator": "input", "lastSeq": 5});
    let push = json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed",
            "params": {"sessionId": "chat-1", "kind": "updated", "session": waiting}});
    let mut stale = local("chat-1");
    stale["indicator"] = json!("working");
    let (client, serve) = fake_acpmux(vec![format!("{push}\n{}", list_reply(2, &[stale], None))]);
    let followed = follow(&Arc::downgrade(&mux), client, &mut chats, &mut None);
    serve.join().expect("the fake acpmux");
    assert!(followed.is_err());
    assert_eq!(chats["chat-1"].indicator, "input");
}

#[test]
fn an_unreadable_line_or_cursor_is_a_failure() {
    for reply in [
        "not json\n".to_owned(),
        format!(
            "{}\n",
            json!({"jsonrpc": "2.0", "id": 2, "result": {"sessions": [], "nextCursor": 7}})
        ),
    ] {
        let mux = test_mux("notices-unreadable");
        let mut chats = HashMap::from([("chat-1".to_owned(), chat("idle", 3))]);
        let (client, serve) = fake_acpmux(vec![reply]);
        let followed = follow(&Arc::downgrade(&mux), client, &mut chats, &mut None);
        serve.join().expect("the fake acpmux");
        assert!(followed.is_err());
        assert!(chats.contains_key("chat-1"), "an unfinished list drops no chat");
    }
}

#[test]
fn a_turn_that_ends_while_its_subagents_run_finishes_when_they_end() {
    // manaflow-ai/cmux#25563: the parent's turn ended unseen, its background work runs on.
    let working = chat("working", 8);
    let mut waiting = ended("turn-1", false, true);
    waiting.notified_turn = working.notified_turn.clone();
    assert!(waiting.notices(Some(&working)).is_empty(), "not done while its subagents run");
    // The last of the work ends and acpmux marks the chat unread: now it finished.
    let mut done = ended("turn-1", true, false);
    done.notified_turn = waiting.notified_turn.clone();
    let keys: Vec<_> = done.notices(Some(&waiting)).into_iter().map(|n| n.key).collect();
    assert_eq!(keys, ["done-turn-1"]);
}

/// What the watch posts for `changes` of one chat, as `apply` runs them; each change is
/// heard twice (a replay after a reconnect), so a notice posted twice shows in the result.
fn posted(changes: &[Value]) -> Vec<Notice> {
    let mut before: Option<Chat> = None;
    let mut notices = Vec::new();
    for change in changes.iter().flat_map(|change| [change, change]) {
        let mut next = Chat::of(change).expect("a local chat");
        next.notified_turn = before.as_ref().and_then(|chat| chat.notified_turn.clone());
        next.keep_asks(before.as_ref());
        notices.extend(next.notices(before.as_ref()));
        before = Some(next);
    }
    notices
}

/// One acpmux summary of `chat-1`: `shown` is what acpmux reports for a pane that is on
/// screen while cmux is not the active app (the page stays visible behind another app).
/// acpmux marks a chat no pane shows unread once its turn and the work below it ended.
fn summary(
    indicator: &str,
    seq: u64,
    shown: bool,
    turn: Option<(&str, &str)>,
    below: bool,
) -> Value {
    json!({
        "sessionId": "chat-1",
        "title": "Review",
        "indicator": indicator,
        "shown": shown,
        "unread": !shown && turn.is_some() && !below,
        "lastSeq": seq,
        "lastMessage": {"text": "All tests pass."},
        "lastTurn": turn.map(|(id, status)| json!({"turnId": id, "status": status,
            "errorText": (status == "failed").then_some("You've hit your usage limit")})),
        "subagentsWorkingSince": if below { json!(1_700_000_000_000_u64) } else { Value::Null },
    })
}

#[test]
fn a_background_app_probe_notifies_every_finish_and_needs_input_once() {
    // Each transition the person must hear about while cmux is in the background, with
    // the chat's pane on screen (acpmux `shown`) or not: the notice keys it must post.
    let working = |shown| summary("working", 8, shown, None, false);
    let transitions: Vec<(&str, Vec<Value>, Vec<&str>)> = [true, false]
        .into_iter()
        .flat_map(|shown| {
            [
                (
                    "finished",
                    vec![
                        working(shown),
                        summary("done", 10, shown, Some(("t1", "completed")), false),
                    ],
                    vec!["done-t1"],
                ),
                (
                    "quota error",
                    vec![working(shown), summary("done", 10, shown, Some(("t1", "failed")), false)],
                    vec!["failed-t1"],
                ),
                (
                    "background work ended",
                    vec![
                        working(shown),
                        summary("working", 10, shown, Some(("t1", "completed")), true),
                        summary("done", 12, shown, Some(("t1", "completed")), false),
                    ],
                    vec!["done-t1"],
                ),
                (
                    "permission",
                    vec![working(shown), summary("input", 10, shown, None, false)],
                    vec!["input-10"],
                ),
                (
                    "question",
                    vec![working(shown), summary("input", 11, shown, None, false)],
                    vec!["input-11"],
                ),
            ]
        })
        .collect();
    let (mut notified, mut duplicates, mut missed) = (0, 0, Vec::new());
    for (name, changes, want) in &transitions {
        let keys: Vec<String> = posted(changes).into_iter().map(|notice| notice.key).collect();
        let unique: HashSet<&String> = keys.iter().collect();
        duplicates += keys.len() - unique.len();
        if want.iter().all(|key| unique.contains(&key.to_string())) {
            notified += 1;
        } else {
            missed.push(format!("{name} {:?}: {keys:?}", changes[0]["shown"]));
        }
    }
    let total = transitions.len();
    println!(
        "agent chat notices, background app: notified {notified}/{total} ({}%), duplicates {duplicates}",
        notified * 100 / total
    );
    assert_eq!(missed, Vec::<String>::new(), "transitions with no notice");
    assert_eq!(duplicates, 0, "notices posted twice");
}

#[test]
fn a_failed_turn_says_why_it_failed() {
    let notices = posted(&[
        summary("working", 8, false, None, false),
        summary("done", 10, false, Some(("t1", "failed")), false),
    ]);
    assert_eq!(notices.len(), 1);
    assert_eq!(notices[0].title, "Review failed");
    assert_eq!(notices[0].body, "You've hit your usage limit");
}

#[test]
fn the_ask_that_starts_a_wait_notifies_through_the_wait_alone() {
    let working = chat("working", 8);
    let mut waiting = after(&working, "input", 10);
    assert_eq!(waiting.notices(Some(&working)).len(), 1);
    assert_eq!(key(waiting.asked(&ask("p1", None, 10))), None);
}

#[test]
fn a_second_ask_while_the_chat_waits_notifies_again() {
    let mut waiting = after(&chat("working", 8), "input", 10);
    waiting.asked(&ask("p1", None, 10));
    let mut later = after(&waiting, "input", 12);
    assert_eq!(key(later.asked(&ask("p2", None, 12))), Some("input-12".into()));
    // The same ask heard again is not new.
    assert_eq!(key(later.asked(&ask("p2", None, 12))), None);
}

#[test]
fn a_burst_grouped_on_one_card_notifies_once() {
    let mut waiting = after(&chat("working", 8), "input", 10);
    waiting.asked(&ask("p1", None, 10));
    assert_eq!(key(waiting.asked(&ask("p2", Some("g1"), 12))), Some("input-12".into()));
    assert_eq!(key(waiting.asked(&ask("p3", Some("g1"), 13))), None);
    assert_eq!(key(waiting.asked(&ask("p4", Some("g1"), 14))), None);
}

#[test]
fn asks_an_acpmux_restart_reissues_post_nothing_new() {
    let mut waiting = after(&chat("idle", 8), "input", 10);
    assert_eq!(key(waiting.asked(&reissued("p1", 10))), None);
    assert_eq!(key(waiting.asked(&reissued("p2", 11))), None);
}

#[test]
fn a_new_wait_starts_counting_again() {
    let mut waiting = after(&chat("working", 8), "input", 10);
    waiting.asked(&ask("p1", None, 10));
    waiting.asked(&ask("p2", None, 11));
    let answered = after(&waiting, "working", 12);
    let mut again = after(&answered, "input", 14);
    assert_eq!(key(again.asked(&ask("p3", None, 14))), None);
}

#[test]
fn cache_ttl_settings_parse_per_family_and_ignore_bad_entries() {
    let settings = json!({
        "notifications": {"agentIdleTimers": {
            "Claude": [
                {"afterSeconds": 3420, "id": "cache-ttl"},
                {"afterSeconds": 0, "id": "bad"},
                {"afterSeconds": 10, "id": "cache-ttl"}
            ],
            "codex": [{"afterSeconds": 1680, "id": "cache-ttl"}],
            "broken": "not-an-array"
        }}
    });
    let parsed = parse_cache_ttl_timers(&settings);
    assert_eq!(parsed["claude"][0].after, Duration::from_secs(3420));
    assert_eq!(parsed["claude"].len(), 1);
    assert_eq!(parsed["codex"][0].id, "cache-ttl");
    assert!(!parsed.contains_key("broken"));
}

#[test]
fn cache_ttl_queue_cancels_on_state_change_and_fires_once() {
    let now = Instant::now();
    let spec = CacheTtlSpec { id: "cache-ttl".into(), after: Duration::from_secs(60) };
    let mut queue = CacheTtlQueue::default();
    let target = CacheTtlTarget {
        session: "chat-1".into(),
        name: "Claude".into(),
        kind: "claude".into(),
        idle_since: 100,
        works_below: false,
        muted: false,
        timers: vec![spec],
    };
    queue.observe(target.clone(), now, 100);
    assert!(queue.take_due(now + Duration::from_secs(59)).is_empty());
    assert_eq!(queue.take_due(now + Duration::from_secs(60)).len(), 1);
    assert!(queue.take_due(now + Duration::from_secs(61)).is_empty());

    queue.observe(target.clone(), now, 100);
    let mut working = target;
    working.idle_since = 200;
    working.works_below = true;
    queue.observe(working, now + Duration::from_secs(1), 200);
    assert!(queue.take_due(now + Duration::from_secs(120)).is_empty());
}
