use std::path::PathBuf;

use serde_json::json;

use super::*;
use crate::automation::{AutomationSpec, Body};
use crate::watch::Watches;

fn temp_root(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("cmux-automations-webhook-unit-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

fn spec(name: &str, trigger: Trigger) -> AutomationSpec {
    AutomationSpec {
        name: name.into(),
        trigger,
        body: Body::Command { command: "true".into(), folder: None },
        catch_up: Default::default(),
        timeout_seconds: 60,
        enabled: true,
        gate: Default::default(),
    }
}

fn headers(pairs: &[(&str, &str)]) -> Headers {
    Headers::new(pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())))
}

fn post(id: &str, secret: &str, body: &str, extra: &[(&str, &str)]) -> Request {
    let mut pairs = vec![("X-Cmux-Signature-256", sign(secret, body.as_bytes()))];
    pairs.extend(extra.iter().map(|(k, v)| (*k, v.to_string())));
    Request {
        method: "POST".into(),
        path: format!("/hooks/{id}"),
        headers: Headers::new(pairs.into_iter().map(|(k, v)| (k.to_string(), v))),
        body: body.as_bytes().to_vec(),
    }
}

#[test]
fn sign_matches_a_known_hmac_and_verify_takes_both_headers() {
    // RFC 4231 test case 2.
    assert_eq!(
        sign("Jefe", b"what do ya want for nothing?"),
        "sha256=5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
    );
    let sig = sign("s3cret", b"{}");
    assert!(verify("s3cret", b"{}", &headers(&[("X-Cmux-Signature-256", &sig)])));
    assert!(verify("s3cret", b"{}", &headers(&[("X-Hub-Signature-256", &sig)])));
    let bare = sig.trim_start_matches("sha256=");
    assert!(verify("s3cret", b"{}", &headers(&[("x-cmux-signature-256", bare)])));
    assert!(!verify("other", b"{}", &headers(&[("X-Cmux-Signature-256", &sig)])));
    assert!(!verify("s3cret", b"{ }", &headers(&[("X-Cmux-Signature-256", &sig)])));
    assert!(!verify("s3cret", b"{}", &headers(&[])));
    assert!(!verify("s3cret", b"{}", &headers(&[("X-Cmux-Signature-256", "sha256=zz")])));
}

#[test]
fn delivery_id_prefers_headers_then_hashes_the_body() {
    assert_eq!(delivery_id(&headers(&[("X-GitHub-Delivery", "abc")]), b"x"), "abc");
    assert_eq!(
        delivery_id(&headers(&[("X-GitHub-Delivery", "abc"), ("X-Cmux-Delivery", "mine")]), b"x"),
        "mine"
    );
    let a = delivery_id(&headers(&[]), b"same");
    assert!(a.starts_with("sha256:"));
    assert_eq!(a, delivery_id(&headers(&[]), b"same"));
    assert_ne!(a, delivery_id(&headers(&[]), b"other"));
}

#[test]
fn filters_parse_and_match_json_paths_and_headers() {
    let body = json!({"action": "opened", "pull_request": {"base": {"ref": "main"}, "draft": false},
        "commits": [{"id": "c1"}], "n": 3});
    let h = headers(&[("X-GitHub-Event", "pull_request")]);
    let ok = |f: &str| WebhookFilter::parse_json(f).unwrap().holds(&h, Some(&body));
    assert!(ok("action=opened"));
    assert!(!ok("action=closed"));
    assert!(ok("pull_request.base.ref=main"));
    assert!(ok("pull_request.draft=false"));
    assert!(ok("commits.0.id=c1"));
    assert!(ok("n=3"));
    assert!(ok("action=*"));
    assert!(!ok("missing=*"));
    let header = WebhookFilter::parse_header("X-GitHub-Event=pull_request").unwrap();
    assert_eq!(
        header,
        WebhookFilter::Header { name: "x-github-event".into(), value: "pull_request".into() }
    );
    assert!(header.holds(&h, None));
    assert!(!WebhookFilter::parse_header("X-GitHub-Event=push").unwrap().holds(&h, None));
    assert!(!WebhookFilter::parse_json("action=opened").unwrap().holds(&h, None));
    assert!(WebhookFilter::parse_json("noequals").is_err());
    assert!(WebhookFilter::parse_json("a..b=1").is_err());
    assert!(WebhookFilter::parse_header("bad name=1").is_err());
    assert!(validate(&[], MAX_DEDUPE_SECONDS + 1).is_err());
}

#[test]
fn read_request_bounds_and_parses() {
    let raw = b"POST /hooks/x HTTP/1.1\r\nContent-Length: 5\r\nX-A: b\r\n\r\nhelloEXTRA";
    let req = read_request(&mut &raw[..]).unwrap();
    assert_eq!(req.method, "POST");
    assert_eq!(req.path, "/hooks/x");
    assert_eq!(req.headers.get("x-a"), Some("b"));
    assert_eq!(req.body, b"hello");
    let chunked = b"POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    assert_eq!(
        read_request(&mut &chunked[..]),
        Err(ReadError::Reply(411, "send the body with Content-Length"))
    );
    let big = format!("POST / HTTP/1.1\r\nContent-Length: {}\r\n\r\n", MAX_BODY_BYTES + 1);
    assert!(matches!(read_request(&mut big.as_bytes()), Err(ReadError::Reply(413, _))));
    let short = b"POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc";
    assert_eq!(read_request(&mut &short[..]), Err(ReadError::Gone));
    let huge_head = vec![b'a'; MAX_HEAD_BYTES * 2];
    assert!(matches!(read_request(&mut &huge_head[..]), Err(ReadError::Reply(431, _))));
}

#[test]
fn handler_checks_signature_filters_and_dedupe_in_order() {
    let root = temp_root("handler");
    let store = Store::open(&root).unwrap();
    let hook = Trigger::Webhook {
        filters: vec![
            WebhookFilter::parse_json("action=opened").unwrap(),
            WebhookFilter::parse_header("X-GitHub-Event=pull_request").unwrap(),
        ],
        dedupe_seconds: 60,
    };
    let a = store.create(spec("hook", hook), 0).unwrap();
    let plain = store.create(spec("plain", Trigger::Manual), 0).unwrap();
    let secret = store.webhook_secret(&a.id).unwrap();
    assert_eq!(secret.len(), 64);
    assert_eq!(store.webhook_secret(&a.id).unwrap(), secret, "the secret is kept");
    let mut watches = Watches::new(store.clone());
    let handler = Handler::new(store.clone(), watches.sender());
    let event = [("X-GitHub-Event", "pull_request"), ("X-GitHub-Delivery", "d1")];
    let body = r#"{"action":"opened","number":7}"#;

    assert_eq!(handler.handle(&post(&a.id, "wrong", body, &event), 1_000).status, 401);
    let ignored = handler.handle(&post(&a.id, &secret, r#"{"action":"closed"}"#, &event), 1_000);
    assert_eq!((ignored.status, ignored.outcome()), (200, "ignored"));
    let other_event = [("X-GitHub-Event", "push"), ("X-GitHub-Delivery", "d0")];
    assert_eq!(
        handler.handle(&post(&a.id, &secret, body, &other_event), 1_000).outcome(),
        "ignored"
    );

    let first = handler.handle(&post(&a.id, &secret, body, &event), 1_000);
    assert_eq!((first.status, first.outcome()), (202, "accepted"));
    let again = handler.handle(&post(&a.id, &secret, body, &event), 30_000);
    assert_eq!((again.status, again.outcome()), (200, "duplicate"));
    // A new handler (a restarted runner) still remembers it inside the window.
    let restarted = Handler::new(store.clone(), watches.sender());
    assert_eq!(
        restarted.handle(&post(&a.id, &secret, body, &event), 40_000).outcome(),
        "duplicate"
    );
    // Past the window it runs again.
    assert_eq!(restarted.handle(&post(&a.id, &secret, body, &event), 62_000).outcome(), "accepted");

    // An automation with no webhook, an unknown id, and a GET all start nothing.
    assert_eq!(handler.handle(&post(&plain.id, &secret, body, &event), 1_000).status, 404);
    assert_eq!(
        handler.handle(&post("auto_aaaaaaaaaaaaaaaaaaaa", &secret, body, &event), 1_000).status,
        404
    );
    let mut get = post(&a.id, &secret, body, &event);
    get.method = "GET".into();
    assert_eq!(handler.handle(&get, 1_000).status, 405);

    watches.wait(Duration::from_millis(50), &|| 0);
    let events = watches.due_events(0);
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].automation, a.id);
    let line: Value = serde_json::from_str(&events[0].text).unwrap();
    assert_eq!(line["delivery"], "d1");
    assert_eq!(line["event"], "pull_request");
    assert_eq!(line["body"]["number"], 7);
    assert_ne!(events[0].key, events[1].key, "a rerun past the window is its own run");

    let rotated = store.rotate_webhook_secret(&a.id).unwrap();
    assert_ne!(rotated, secret);
    let d2 = [("X-GitHub-Event", "pull_request"), ("X-GitHub-Delivery", "d2")];
    assert_eq!(handler.handle(&post(&a.id, &secret, body, &d2), 1_000).status, 401);
    assert_eq!(handler.handle(&post(&a.id, &rotated, body, &d2), 1_000).status, 202);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn the_trigger_round_trips_and_older_definitions_get_defaults() {
    let t: Trigger = serde_json::from_value(json!({"type": "webhook"})).unwrap();
    assert_eq!(t, Trigger::Webhook { filters: vec![], dedupe_seconds: DEFAULT_DEDUPE_SECONDS });
    let t = Trigger::Webhook {
        filters: vec![WebhookFilter::parse_json("action=opened").unwrap()],
        dedupe_seconds: 5,
    };
    let back: Trigger = serde_json::from_value(serde_json::to_value(&t).unwrap()).unwrap();
    assert_eq!(back, t);
    assert_eq!(t.next_after(0).unwrap(), None);
    assert_eq!(t.describe(), "webhook (--match action=opened)");
    assert!(!t.is_watched());
}
