//! Which app refusal is asked again. The app marks a refusal that changed
//! nothing with `data.not_run`, and says in `data.state` who refused:
//! `rejected` is the app's own decision (a pane that cannot split, a
//! person-only action), which no second try changes; `not_run` is a request
//! the app did not get to (a reconnecting daemon, a full queue), which may
//! pass. Only the second is asked again: a refusal the app decided is the
//! answer at once, never held to the request's deadline (45 s for a run).

use std::io::{BufRead as _, BufReader, Write as _};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::{connect, request_with_retry_within, retry_before_running};

/// What the app answers to `cmux action run splitDown` on the agent chat.
fn decided(data: Value) -> Value {
    json!({ "code": "unavailable", "data": data,
        "message": "splitDown unavailable: The agent chat can't be split." })
}

#[test]
fn a_refusal_the_app_decided_is_not_asked_again() {
    let reason = "The agent chat can't be split.";
    let rejected = json!({ "action": "splitDown", "reason": reason,
        "not_run": true, "state": "rejected" });
    assert!(!retry_before_running(&decided(rejected)));
    // An app from before `state: rejected`: its own refusals carry no state.
    let unmarked = json!({ "action": "splitDown", "reason": reason, "not_run": true });
    assert!(!retry_before_running(&decided(unmarked)));
}

#[test]
fn a_request_the_app_did_not_get_to_is_asked_again() {
    // The read barrier on a reconnecting daemon (#32724), as the app sends it.
    let barrier = json!({ "code": "unavailable", "message": "the daemon connection closed",
        "data": { "not_run": true, "state": "not_run", "retry_after_ms": 200 } });
    assert!(retry_before_running(&barrier));
    // A full queue and a timeout before the work started keep both marks.
    assert!(retry_before_running(&json!({ "code": "busy", "data": { "not_run": true } })));
    assert!(retry_before_running(&json!({ "code": "busy", "data": { "state": "not_run" } })));
    assert!(retry_before_running(&json!({ "code": "timeout", "data": { "state": "not_run" } })));
}

/// The MCP tool path (`mcp/transport.rs::app_method`) shares the retry: a refusal the app
/// decided is asked once and answered at once, not at the tool call's budget.
#[test]
fn a_refusal_the_app_decided_is_asked_once_by_a_tool_call() {
    use std::os::unix::net::UnixListener;
    let dir = cmux_unix_socket::short_test_dir("cmux-app-decided");
    let socket = dir.path().join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let app = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let (mut line, mut asked) = (String::new(), 0);
        while reader.read_line(&mut line).unwrap_or(0) > 0 {
            line.clear();
            asked += 1;
            let error =
                decided(json!({ "action": "splitDown", "not_run": true, "state": "rejected",
                "reason": "The agent chat can't be split." }));
            let refused = json!({ "id": 1, "ok": false, "error": error });
            if writeln!(writer, "{refused}").is_err() {
                break;
            }
        }
        drop(dir);
        asked
    });
    let mut stream = connect(&socket).unwrap();
    let budget = Duration::from_secs(3);
    let started = Instant::now();
    let answer = request_with_retry_within(
        &mut stream,
        "action.run",
        &json!({ "action": "splitDown" }),
        budget,
    );
    let took = started.elapsed();
    drop(stream);
    let asked = app.join().unwrap();
    let refusal = answer.unwrap().unwrap_err();
    assert_eq!(asked, 1, "asked {asked} times in {took:?}: {refusal}");
    assert!(took < Duration::from_secs(1), "{took:?}");
    assert_eq!(refusal["message"], "splitDown unavailable: The agent chat can't be split.");
    assert!(refusal.pointer("/data/not_run_waited_ms").is_none(), "{refusal}");
}
