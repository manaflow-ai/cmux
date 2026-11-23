//! The reservation calls on the wire, through the generated client: the same method, path,
//! headers and body as the hand-written calls they replace, and the same reading of an answer
//! and a refusal.

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::TcpListener;

use serde_json::{Value, json};

use super::{Action, Call, answer, unbound};
use crate::cli::PlatformCallError;

/// One request as the server saw it: the request line, lowercased header lines and the body.
struct Seen {
    line: String,
    headers: Vec<String>,
    body: Value,
}

/// Serves `replies` (status, extra header lines, body) one per connection, on a local origin.
fn serve(
    replies: Vec<(u16, &'static str, &'static str)>,
) -> (String, std::thread::JoinHandle<Vec<Seen>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let server = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for (status, extra, body) in replies {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut headers = Vec::new();
            loop {
                let mut header = String::new();
                reader.read_line(&mut header).unwrap();
                if header.trim().is_empty() {
                    break;
                }
                headers.push(header.trim().to_lowercase());
            }
            let length = headers
                .iter()
                .find_map(|h| h.strip_prefix("content-length:"))
                .map_or(0, |n| n.trim().parse().unwrap());
            let mut request = vec![0; length];
            reader.read_exact(&mut request).unwrap();
            seen.push(Seen {
                line: line.trim().to_owned(),
                headers,
                body: serde_json::from_slice(&request).unwrap_or(Value::Null),
            });
            write!(
                stream,
                "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n{extra}\r\n{body}",
                body.len()
            )
            .unwrap();
        }
        seen
    });
    (origin, server)
}

fn call(action: Action, origin: &str) -> Call {
    Call {
        action,
        compose_key: "0123abcd-0000-4000-8000-0123456789ab".into(),
        send_key: Some("feedbeef-0000-4000-8000-0123456789ab".into()),
        environment: Some("env_0123456789abcdef01234567".into()),
        platform: Some(origin.into()),
        team: Some("team_1".into()),
    }
}

#[test]
fn reserve_bind_and_release_send_what_the_hand_written_calls_sent() {
    let (origin, server) = serve(vec![
        (200, "", r#"{"leaseId":"l1","machine":"vm_0123456789abcdef0123","expiresAt":5}"#),
        (200, "", r#"{"leaseId":"l1","machine":"vm_0123456789abcdef0123"}"#),
        (200, "", r#"{"released":true}"#),
    ]);
    let reserved = call(Action::Reserve, &origin).post("stack-session").unwrap();
    assert_eq!(
        reserved,
        json!({"leaseId": "l1", "machine": "vm_0123456789abcdef0123", "expiresAt": 5})
    );
    let bound = call(Action::Bind, &origin).post("stack-session").unwrap();
    assert_eq!(bound["machine"], "vm_0123456789abcdef0123");
    let released = call(Action::Release, &origin).post("stack-session").unwrap();
    assert_eq!(answer(Ok(released)), json!({"released": true, "ok": true}));

    let seen = server.join().unwrap();
    let key = "0123abcd-0000-4000-8000-0123456789ab";
    assert_eq!(seen[0].line, "POST /v1/machines/reservations HTTP/1.1");
    assert_eq!(
        seen[0].body,
        json!({"composeKey": key, "environment": "env_0123456789abcdef01234567"})
    );
    assert_eq!(seen[1].line, format!("POST /v1/machines/reservations/{key}/bind HTTP/1.1"));
    assert_eq!(
        seen[1].body,
        json!({"sendKey": "feedbeef-0000-4000-8000-0123456789ab",
            "environment": "env_0123456789abcdef01234567"})
    );
    assert_eq!(seen[2].line, format!("DELETE /v1/machines/reservations/{key} HTTP/1.1"));
    for request in &seen {
        let has = |want: &str| request.headers.iter().any(|h| h == want);
        assert!(has("authorization: bearer stack-session"), "{:?}", request.headers);
        assert!(has("x-cmux-team: team_1"), "{:?}", request.headers);
        assert!(has("accept: application/json"), "{:?}", request.headers);
        assert!(
            request.headers.iter().any(|h| h.starts_with("user-agent: cmux/")),
            "{:?}",
            request.headers
        );
    }
}

#[test]
fn a_refusal_keeps_its_status_code_and_facts_and_decides_a_cold_create_as_before() {
    let (origin, server) = serve(vec![
        (409, "", r#"{"_tag":"MachineConflict","code":"reservation.expired","message":"m"}"#),
        (429, "retry-after: 7\r\n", r#"{"code":"cloud.rate_limited","retryable":true}"#),
        (502, "", "<html>bad gateway</html>"),
        (200, "", "not json"),
    ]);
    let expired = call(Action::Bind, &origin).post("t").unwrap_err();
    assert!(
        matches!(
            expired,
            PlatformCallError::Status { status: 409, code: "reservation.expired", .. }
        ),
        "{expired:?}"
    );
    assert!(unbound(&expired), "an expired reservation still permits a cold create");
    let limited = call(Action::Bind, &origin).post("t").unwrap_err();
    let PlatformCallError::Status { status: 429, code: "cloud.rate_limited", facts: Some(_) } =
        &limited
    else {
        panic!("{limited:?}");
    };
    assert!(!unbound(&limited));
    let proxy = call(Action::Bind, &origin).post("t").unwrap_err();
    assert!(matches!(proxy, PlatformCallError::Status { status: 502, code: "", .. }), "{proxy:?}");
    assert!(!unbound(&proxy));
    let garbled = call(Action::Reserve, &origin).post("t").unwrap_err();
    assert_eq!(garbled, PlatformCallError::Unreadable(200));
    server.join().unwrap();
}

#[test]
fn no_answer_is_unreachable_and_never_unbound() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    drop(listener);
    let error = call(Action::Bind, &origin).post("t").unwrap_err();
    assert!(matches!(error, PlatformCallError::Unreachable(_)), "{error:?}");
    assert!(!unbound(&error));
}
