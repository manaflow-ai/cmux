//! `AcpmuxLink::call_whole_list` against a scripted acpmux: the pages of a list too large for
//! one reply are joined newest first, and a page it cannot trust fails the list.

use super::*;
use std::os::unix::net::UnixListener;

/// A fake acpmux on a fresh socket that answers its requests, in order, with `results`
/// (`{"$error": message}` answers with that error).
/// Returns the link to it and the params of each request it read.
fn scripted(results: Vec<Value>) -> (Arc<AcpmuxLink>, Receiver<Value>, cmux_unix_socket::TestDir) {
    let dir = cmux_unix_socket::short_test_dir("aslink");
    let socket = dir.path().join("acpmux.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (asked, params) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut lines = BufReader::new(stream).lines();
        for result in results {
            let Some(Ok(line)) = lines.next() else { return };
            let request: Value = serde_json::from_str(&line).unwrap();
            let _ = asked.send(json!({"method": request["method"], "params": request["params"]}));
            let reply = match result.get("$error") {
                Some(message) => json!({"jsonrpc": "2.0", "id": request["id"],
                                        "error": {"code": -32000, "message": message}}),
                None => json!({"jsonrpc": "2.0", "id": request["id"], "result": result}),
            };
            if writeln!(writer, "{reply}").is_err() {
                return;
            }
        }
    });
    let link = AcpmuxLink::connect(&socket, |_| {}).unwrap();
    (link, params, dir)
}

fn row(id: &str, updated: u64) -> Value {
    json!({"sessionId": id, "updatedAt": updated})
}

fn ids(reply: &Value) -> Vec<&str> {
    reply["sessions"].as_array().unwrap().iter().map(|r| r["sessionId"].as_str().unwrap()).collect()
}

const WAIT: Duration = Duration::from_secs(5);

#[test]
fn pages_in_byte_page_order_are_joined_newest_first() {
    let (link, asked, _dir) = scripted(vec![
        json!({"sessions": [row("old", 1), row("b", 5)], "nextCursor": "p1"}),
        json!({"sessions": [{"sessionId": "a", "updatedAt": 5, "peer": "mac"}, row("new", 9)],
               "nextCursor": "p2"}),
        json!({"sessions": [row("a", 5)], "nextCursor": null}),
    ]);
    let reply = link.call_whole_list("_acpmux/watch", json!({"enabled": true}), WAIT).unwrap();
    assert_eq!(ids(&reply), ["new", "a", "a", "b", "old"]);
    assert_eq!(reply["sessions"][1].get("peer"), None, "this machine's row before a peer's copy");
    assert_eq!(asked.recv().unwrap()["method"], "_acpmux/watch");
    let rest = asked.recv().unwrap();
    assert_eq!(rest, json!({"method": "_acpmux/sessions", "params": {"cursor": "p1"}}));
}

#[test]
fn an_empty_page_with_a_cursor_is_followed() {
    let (link, _asked, _dir) = scripted(vec![
        json!({"sessions": [row("a", 2)], "nextCursor": "p1"}),
        json!({"sessions": [], "nextCursor": "p2"}),
        json!({"sessions": [row("b", 3)]}),
    ]);
    let reply = link.call_whole_list("_acpmux/sessions", json!({}), WAIT).unwrap();
    assert_eq!(ids(&reply), ["b", "a"]);
}

#[test]
fn a_cursor_given_twice_fails_the_list() {
    let (link, _asked, _dir) = scripted(vec![
        json!({"sessions": [row("a", 2)], "nextCursor": "p1"}),
        json!({"sessions": [row("b", 1)], "nextCursor": "p1"}),
        json!({"sessions": [row("c", 1)], "nextCursor": "p1"}),
    ]);
    let err = link.call_whole_list("_acpmux/sessions", json!({}), WAIT).unwrap_err();
    assert!(matches!(&err, LinkError::BadList(why) if why.contains("twice")), "{err:?}");
}

#[test]
fn a_cursor_that_is_not_a_string_fails_the_list() {
    let (link, _asked, _dir) = scripted(vec![json!({"sessions": [row("a", 2)], "nextCursor": 7})]);
    let err = link.call_whole_list("_acpmux/sessions", json!({}), WAIT).unwrap_err();
    assert!(matches!(&err, LinkError::BadList(why) if why.contains("page cursor 7")), "{err:?}");
}

#[test]
fn a_page_with_no_sessions_fails_the_list() {
    let (link, _asked, _dir) = scripted(vec![
        json!({"sessions": [row("a", 2)], "nextCursor": "p1"}),
        json!({"nextCursor": null}),
    ]);
    let err = link.call_whole_list("_acpmux/sessions", json!({}), WAIT).unwrap_err();
    assert!(
        matches!(&err, LinkError::BadList(why) if why.contains("lists no sessions")),
        "{err:?}"
    );
}

#[test]
fn a_sessions_reply_with_no_list_fails_and_a_watch_reply_without_one_is_as_before() {
    let (link, _asked, _dir) = scripted(vec![json!({})]);
    let err = link.call_whole_list("_acpmux/sessions", json!({}), WAIT).unwrap_err();
    assert!(
        matches!(&err, LinkError::BadList(why) if why.contains("lists no sessions")),
        "{err:?}"
    );
    // A watch from before watches answered with the list.
    let (link, _asked, _dir) = scripted(vec![json!({})]);
    assert_eq!(
        link.call_whole_list("_acpmux/watch", json!({"enabled": true}), WAIT).unwrap(),
        json!({})
    );
}

#[test]
fn a_page_after_the_first_that_fails_fails_the_list_as_not_whole() {
    let (link, _asked, _dir) = scripted(vec![
        json!({"sessions": [row("a", 2)], "nextCursor": "p1"}),
        json!({"$error": "list.paced"}),
    ]);
    let err = link.call_whole_list("_acpmux/watch", json!({"enabled": true}), WAIT).unwrap_err();
    assert!(
        matches!(&err, LinkError::BadList(why) if why.contains("after cursor \"p1\" failed")),
        "{err:?}"
    );
    // The first page's own error is the call's, as before.
    let (link, _asked, _dir) = scripted(vec![json!({"$error": "no"})]);
    let err = link.call_whole_list("_acpmux/sessions", json!({}), WAIT).unwrap_err();
    assert!(matches!(err, LinkError::Rpc(..)), "{err:?}");
}

/// Review of cmux#40640 at 00411eb5: a start that stopped waiting for `session/new` left the
/// agent acpmux spawned anyway bound to no tab. The late answer still comes to the caller (here
/// after the call timed out and the caller closed the link), and what the late handler sends on
/// the link reaches acpmux; then the link closes.
#[test]
fn a_reply_after_the_timeout_goes_to_the_late_handler_on_a_link_kept_open_for_it() {
    let dir = cmux_unix_socket::short_test_dir("aslate");
    let socket = dir.path().join("acpmux.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (asked, methods) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut writer = stream.try_clone().unwrap();
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { return };
            let request: Value = serde_json::from_str(&line).unwrap();
            let _ = asked.send(request["method"].as_str().unwrap_or_default().to_owned());
            if request["method"] == "session/new" {
                std::thread::sleep(Duration::from_millis(400));
                let result = json!({"sessionId": "late-1"});
                let _ = writeln!(
                    writer,
                    "{}",
                    json!({"jsonrpc": "2.0", "id": request["id"], "result": result})
                );
            } else {
                let _ = writeln!(
                    writer,
                    "{}",
                    json!({"jsonrpc": "2.0", "id": request["id"], "result": {}})
                );
            }
        }
    });
    let link = AcpmuxLink::connect(&socket, |_| {}).unwrap();
    let (ended, late) = std::sync::mpsc::channel();
    // acpmux is silent beside the spawn: the liveness probe goes unanswered and the call fails.
    let silent = Patience {
        quiet: Duration::from_millis(50),
        probe: Duration::from_millis(50),
        ceiling: WAIT,
    };
    let answer = link.call_while_alive_or_late(
        "session/new",
        json!({}),
        silent,
        Instant::now() + WAIT,
        WAIT,
        move |link, reply| {
            let killed = link.call("_acpmux/kill", json!({"sessionId": reply["sessionId"]}), WAIT);
            let _ = ended.send((reply, killed.is_ok()));
        },
    );
    assert_eq!(answer, Err(LinkError::Timeout));
    link.close();
    let (reply, killed) = late.recv_timeout(WAIT).unwrap();
    assert_eq!(reply["sessionId"], "late-1");
    assert!(killed, "the late handler's call reached acpmux");
    assert_eq!(methods.recv_timeout(WAIT).unwrap(), "session/new");
    assert_eq!(methods.recv_timeout(WAIT).unwrap(), LIVENESS_PROBE);
    assert_eq!(methods.recv_timeout(WAIT).unwrap(), "_acpmux/kill");
    let deadline = Instant::now() + WAIT;
    while !link.closed.load(Ordering::Acquire) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(link.closed.load(Ordering::Acquire), "the late wait closes the link when it ends");
}

/// A reply inside the timeout is the call's own answer, and the late handler never runs.
#[test]
fn a_reply_in_time_never_reaches_the_late_handler() {
    let (link, _asked, _dir) = scripted(vec![json!({"sessionId": "s-1"})]);
    let patience = Patience { quiet: WAIT, probe: WAIT, ceiling: WAIT };
    let until = Instant::now() + WAIT;
    let answer =
        link.call_while_alive_or_late("session/new", json!({}), patience, until, WAIT, |_, _| {
            panic!("not late")
        });
    assert_eq!(answer.unwrap()["sessionId"], "s-1");
    link.close();
    assert!(link.closed.load(Ordering::Acquire));
}

/// A fake acpmux that serves each request on its own thread, as acpmux does: `slow` is answered
/// after `after`, `_acpmux/status` at once while `alive`, and nothing else is answered. Returns the
/// link and how many status questions it was asked.
fn paced(
    slow: &'static str,
    after: Duration,
    alive: bool,
) -> (Arc<AcpmuxLink>, Arc<std::sync::atomic::AtomicUsize>, cmux_unix_socket::TestDir) {
    let dir = cmux_unix_socket::short_test_dir("aspace");
    let socket = dir.path().join("acpmux.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let probes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = probes.clone();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let writer = Arc::new(Mutex::new(stream.try_clone().unwrap()));
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { return };
            let request: Value = serde_json::from_str(&line).unwrap();
            let (writer, counted) = (writer.clone(), counted.clone());
            std::thread::spawn(move || {
                let wait = match request["method"].as_str() {
                    Some(LIVENESS_PROBE) => {
                        counted.fetch_add(1, Ordering::SeqCst);
                        if !alive {
                            return;
                        }
                        Duration::ZERO
                    }
                    Some(method) if method == slow => after,
                    _ => return,
                };
                std::thread::sleep(wait);
                let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": {"ok": true}});
                let _ = writeln!(writer.lock().unwrap(), "{reply}");
            });
        }
    });
    let link = AcpmuxLink::connect(&socket, |_| {}).unwrap();
    (link, probes, dir)
}

/// `session/new` through [`AcpmuxLink::call_while_alive_until`] with `patience`'s own ceiling.
fn alive_call(link: &AcpmuxLink, patience: Patience) -> Result<Value, LinkError> {
    let until = Instant::now() + patience.ceiling;
    link.call_while_alive_until("session/new", json!({}), patience, until)
}

/// [`super::Patience`] compressed a thousandfold: a 10 ms quiet stands for the start's 10 s.
const MS: Patience = Patience {
    quiet: Duration::from_millis(10),
    probe: Duration::from_millis(200),
    ceiling: Duration::from_secs(20),
};

/// A harness that answers `session/new` after 90 s at full scale (90 ms here) while acpmux answers
/// its status beside it: the start waits and gets its session. The old fixed 60 s bound (60 ms
/// here) failed the same start.
#[test]
fn a_slow_start_whose_acpmux_still_answers_waits_for_it() {
    let (link, probes, _dir) = paced("session/new", Duration::from_millis(90), true);
    let started = Instant::now();
    let reply = alive_call(&link, MS).unwrap();
    assert_eq!(reply, json!({"ok": true}));
    assert!(started.elapsed() >= Duration::from_millis(90));
    assert!(probes.load(Ordering::SeqCst) >= 2, "acpmux was asked whether it still answers");
    let (link, _probes, _dir) = paced("session/new", Duration::from_millis(90), true);
    let fixed = link.call("session/new", json!({}), Duration::from_millis(60));
    assert_eq!(fixed, Err(LinkError::Timeout));
}

/// An acpmux that stopped answering fails the call within one quiet period and one probe, long
/// before the ceiling.
#[test]
fn a_silent_acpmux_fails_the_call_fast() {
    let (link, probes, _dir) = paced("session/new", Duration::from_secs(3600), false);
    let started = Instant::now();
    let err = alive_call(&link, MS).unwrap_err();
    assert_eq!(err, LinkError::Timeout);
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    assert_eq!(probes.load(Ordering::SeqCst), 1);
}

/// However alive acpmux stays, the call ends at its ceiling.
#[test]
fn a_live_acpmux_that_never_answers_the_call_ends_at_the_ceiling() {
    let (link, _probes, _dir) = paced("session/new", Duration::from_secs(3600), true);
    let ceiling = Patience { ceiling: Duration::from_millis(300), ..MS };
    let started = Instant::now();
    let err = alive_call(&link, ceiling).unwrap_err();
    assert_eq!(err, LinkError::Timeout);
    let took = started.elapsed();
    assert!(took >= Duration::from_millis(300) && took < Duration::from_secs(3), "{took:?}");
}

/// A link that closes under the call fails it as closed, not as a timeout.
#[test]
fn a_link_closed_under_the_call_fails_it_as_closed() {
    let (link, _probes, _dir) = paced("session/new", Duration::from_secs(3600), true);
    let closer = link.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        closer.close();
    });
    let err = alive_call(&link, MS).unwrap_err();
    assert_eq!(err, LinkError::Closed);
}
