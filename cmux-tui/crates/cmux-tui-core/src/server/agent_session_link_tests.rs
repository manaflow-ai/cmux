//! `AcpmuxLink::call_whole_list` against a scripted acpmux: the pages of a list too large for
//! one reply are joined newest first, and a page it cannot trust fails the list.

use super::*;
use std::os::unix::net::UnixListener;

/// A fake acpmux on a fresh socket that answers its requests, in order, with `results`
/// (`{"$error": message}` answers with that error).
/// Returns the link to it and the params of each request it read.
fn scripted(
    results: Vec<Value>,
) -> (Arc<AcpmuxLink>, std::sync::mpsc::Receiver<Value>, cmux_unix_socket::TestDir) {
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
