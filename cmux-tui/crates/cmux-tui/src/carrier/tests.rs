use std::time::Duration;

use cmux_remote::connection::ConnectionError;
use cmux_remote::crypto::CryptoError;
use cmux_remote::link::LinkError;
use cmux_remote::provider::ProviderError;
use serde_json::{Value, json};

use super::answer::{TicketCache, grant_vmk, key_text, parse_answer, read_reply};
use super::client::{classify, pinned_daemon, resume_outcome};
use super::contract::{
    Backoff, Failure, INITIAL_BACKOFF, MAX_BACKOFF, Phase, Step, Vmk, connected_line, failure_line,
    parse_deadline, route_line, serving_line,
};
use super::{DialArgs, ServeArgs, parse, parse_serve, with_team_env};

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

const VM: &str = "vm_0123456789abcdefghij";

#[test]
fn the_reply_line_is_one_json_line_the_app_server_reads() {
    let ok = connected_line(None);
    assert!(ok.ends_with('\n') && ok.matches('\n').count() == 1);
    let value: Value = serde_json::from_str(ok.trim()).unwrap();
    assert_eq!(value, json!({"ok": true, "path_state": "relay", "route": "carrier"}));
    for (vmk, name) in [(Vmk::Owner, "owner"), (Vmk::Team, "team")] {
        let value: Value = serde_json::from_str(connected_line(Some(vmk)).trim()).unwrap();
        assert_eq!(
            value,
            json!({"ok": true, "path_state": "relay", "route": "carrier", "vmk": name})
        );
    }
    let ready: Value = serde_json::from_str(serving_line("/s/carrier.sock").trim()).unwrap();
    assert_eq!(ready, json!({"ok": true, "socket": "/s/carrier.sock", "route": "carrier"}));

    for step in [Step::Ticket, Step::Relay, Step::Parked, Step::Handshake] {
        let line = failure_line(step.error_code(), Some("why\nit\tfailed"));
        assert_eq!(line.matches('\n').count(), 1, "{line}");
        let value: Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["error_code"], step.error_code());
        assert_eq!(value["error_detail"], "whyitfailed");
    }
    let long = failure_line("relay", Some(&"é".repeat(400)));
    assert!(long.len() < 400, "the detail is clipped to one display line");
    let bare: Value = serde_json::from_str(failure_line("bad_request", None).trim()).unwrap();
    assert!(bare.get("error_detail").is_none());
}

#[test]
fn each_step_has_its_own_code_and_exit() {
    let codes: Vec<_> = [Step::Ticket, Step::Relay, Step::Parked, Step::Handshake]
        .into_iter()
        .map(|s| (s.error_code(), s.exit_code()))
        .collect();
    assert_eq!(codes, [("ticket", 2), ("relay", 3), ("parked_timeout", 4), ("handshake", 5)]);
}

#[test]
fn the_route_line_is_pinned() {
    assert_eq!(
        route_line(VM, Phase::Connect, None, Duration::from_millis(1234)),
        format!("cloud.connect route=carrier machine={VM} phase=connect outcome=ok ms=1234\n")
    );
    assert_eq!(
        route_line(VM, Phase::of_attempt(2), Some(Step::Parked), Duration::from_millis(7)),
        format!(
            "cloud.connect route=carrier machine={VM} phase=reconnect outcome=parked_timeout ms=7\n"
        )
    );
    assert_eq!(
        route_line(VM, Phase::Resume, Some(Step::Handshake), Duration::ZERO),
        format!("cloud.connect route=carrier machine={VM} phase=resume outcome=handshake ms=0\n")
    );
    assert_eq!(Phase::of_attempt(1), Phase::Connect);
}

#[test]
fn arguments_are_the_machine_and_one_deadline() {
    assert_eq!(
        parse(&words(&format!("dial --machine {VM}"))),
        Some(DialArgs {
            machine: VM.into(),
            deadline: Duration::from_secs(180),
            api: None,
            token_file: None,
            team: None,
        })
    );
    let full = parse(&words(&format!(
        "dial --deadline-ms 5000 --machine {VM} --cloud-api https://api.example --cloud-token-file /t"
    )))
    .unwrap();
    assert_eq!(full.deadline, Duration::from_millis(5000));
    assert_eq!(full.api.as_deref(), Some("https://api.example"));
    for bad in [
        "dial".to_owned(),
        "connect --machine vm_0123456789abcdefghij".to_owned(),
        "dial --machine vm_short".to_owned(),
        "dial --machine host_0123456789abcdefghij".to_owned(),
        format!("dial --machine {VM} --machine {VM}"),
        format!("dial --machine {VM} --deadline-ms 0"),
        format!("dial --machine {VM} --deadline-ms 600001"),
        format!("dial --machine {VM} --deadline-ms"),
        format!("dial --machine {VM} --host x"),
        format!("dial --machine {VM} --team team_0123"),
        format!("dial --machine {VM} --team team_0123456789ABCDEF0123"),
        format!("dial --machine {VM} --team user_0123456789abcdef0123"),
        format!("dial --machine {VM} --team {TEAM} --team {TEAM}"),
    ] {
        assert_eq!(parse(&words(&bad)), None, "{bad}");
    }
    assert_eq!(parse_deadline("600000"), Some(Duration::from_secs(600)));
}

#[test]
fn serve_takes_the_dial_flags_and_one_absolute_socket() {
    let served = parse_serve(&words(&format!("serve --socket /s/c.sock --machine {VM}"))).unwrap();
    assert_eq!(
        served,
        ServeArgs {
            dial: parse(&words(&format!("dial --machine {VM}"))).unwrap(),
            socket: "/s/c.sock".into()
        }
    );
    let full = parse_serve(&words(&format!(
        "serve --machine {VM} --socket /s/c.sock --deadline-ms 5000 --team {TEAM} --cloud-api https://api.example"
    )))
    .unwrap();
    assert_eq!(full.dial.deadline, Duration::from_millis(5000));
    assert_eq!(full.dial.team.as_deref(), Some(TEAM));
    let long = format!("/{}", "s".repeat(200));
    for bad in [
        format!("serve --machine {VM}"),
        format!("serve --machine {VM} --socket relative.sock"),
        format!("serve --machine {VM} --socket {long}"),
        format!("serve --machine {VM} --socket /a --socket /b"),
        "serve --machine vm_short --socket /a".to_owned(),
        format!("dial --machine {VM} --socket /a"),
    ] {
        assert_eq!(parse_serve(&words(&bad)), None, "{bad}");
    }
    assert_eq!(parse(&words(&format!("dial --machine {VM} --socket /a"))), None);
}

#[test]
fn serve_stdin_lines_are_a_token_or_refused() {
    match stdin_line(br#"{"access_token":" tok.en-1 ","other":1}"#) {
        StdinLine::Token(token) => assert_eq!(token.as_str(), "tok.en-1"),
        other => panic!("{other:?}"),
    }
    assert_eq!(stdin_line(b"  \r"), StdinLine::Blank);
    for bad in [
        &b"not json"[..],
        br#"["access_token"]"#,
        br#"{"token":"x"}"#,
        br#"{"access_token":""}"#,
        br#"{"access_token":"has space"}"#,
        br#"{"access_token":7}"#,
    ] {
        assert!(
            matches!(stdin_line(bad), StdinLine::Invalid(_)),
            "{}",
            String::from_utf8_lossy(bad)
        );
    }
    let long = format!(r#"{{"access_token":"{}"}}"#, "a".repeat(8193));
    assert!(matches!(stdin_line(long.as_bytes()), StdinLine::Invalid(_)));
}

#[test]
fn a_failure_line_never_says_cloud_connect() {
    let line = failure_line("ticket", Some("cmux-platform answered 403 cloud.connect: no"));
    assert!(!line.contains("cloud.connect"), "{line}");
    assert!(line.contains("cloud connect"), "{line}");
}

#[test]
fn the_grant_vmk_claim_is_the_dial_s_ownership_answer() {
    use base64::Engine as _;
    let grant = |claims: Value| {
        let encode =
            |v: &Value| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v.to_string());
        format!("{}.{}.c2ln", encode(&json!({"alg": "EdDSA"})), encode(&claims))
    };
    assert_eq!(grant_vmk(&grant(json!({"vmk": "owner"}))), Some(Vmk::Owner));
    assert_eq!(grant_vmk(&grant(json!({"vmk": "team"}))), Some(Vmk::Team));
    for none in [
        grant(json!({"sub": "user_1"})),
        grant(json!({"vmk": "admin"})),
        grant(json!({"vmk": 1})),
        "h.c.s".to_owned(),
        "one-part".to_owned(),
        format!("{}.x", grant(json!({"vmk": "owner"}))),
    ] {
        assert_eq!(grant_vmk(&none), None, "{none}");
    }
    let mut value = answer_value();
    value["grant"] = json!(grant(json!({"vmk": "owner"})));
    assert_eq!(parse_answer(&value).unwrap().vmk, Some(Vmk::Owner));
    assert_eq!(parse_answer(&answer_value()).unwrap().vmk, None);
}

#[test]
fn backoff_is_full_jitter_doubling_to_a_cap_and_never_past_the_deadline() {
    let mut backoff = Backoff::default();
    let mut ceilings = Vec::new();
    for _ in 0..8 {
        let delay = backoff
            .next(Duration::from_secs(600), |ceiling| {
                ceilings.push(ceiling);
                ceiling
            })
            .unwrap();
        assert_eq!(Some(&delay), ceilings.last());
    }
    assert_eq!(ceilings[0], INITIAL_BACKOFF);
    assert_eq!(ceilings[1], INITIAL_BACKOFF * 2);
    assert_eq!(*ceilings.last().unwrap(), MAX_BACKOFF);
    assert!(ceilings.windows(2).all(|w| w[1] >= w[0]));

    // A draw of zero retries at once; a draw past the ceiling is held to it.
    let mut backoff = Backoff::default();
    assert_eq!(backoff.next(Duration::from_secs(1), |_| Duration::ZERO), Some(Duration::ZERO));
    assert_eq!(
        backoff.next(Duration::from_secs(10), |_| Duration::from_secs(99)),
        Some(INITIAL_BACKOFF * 2)
    );
    // No attempt starts when the delay would reach the deadline.
    let mut backoff = Backoff::default();
    assert_eq!(backoff.next(Duration::from_millis(100), |c| c), None);
    assert_eq!(Backoff::default().next(Duration::ZERO, |_| Duration::ZERO), None);
}

#[test]
fn failures_name_the_step_they_did_not_get_past() {
    let allocation = ConnectionError::Provider(ProviderError::Link(LinkError::Transport(
        "relay allocation timed out".into(),
    )));
    assert_eq!(
        classify(&allocation, Step::Parked),
        Failure::retry(Step::Parked, "link transport failed: relay allocation timed out")
    );
    let dropped = ConnectionError::Provider(ProviderError::Link(LinkError::Closed));
    let relay = classify(&dropped, Step::Parked);
    assert_eq!((relay.step, relay.retryable), (Step::Relay, true));
    let refused = ConnectionError::Provider(ProviderError::Configuration("bad".into()));
    let relay = classify(&refused, Step::Relay);
    assert_eq!((relay.step, relay.retryable), (Step::Relay, false));

    let grant = ConnectionError::Crypto(CryptoError::Unauthorized("carrier grant refused".into()));
    let handshake = classify(&grant, Step::Handshake);
    assert_eq!((handshake.step, handshake.retryable), (Step::Handshake, false));
    let pinned = ConnectionError::Crypto(CryptoError::DaemonKeyMismatch {
        expected: "a".into(),
        actual: "b".into(),
    });
    assert!(!classify(&pinned, Step::Handshake).retryable);
    let slow =
        ConnectionError::Crypto(CryptoError::HandshakeTimeout { timeout: Duration::from_secs(1) });
    let handshake = classify(&slow, Step::Handshake);
    assert_eq!((handshake.step, handshake.retryable), (Step::Handshake, true));
    // A resume names the relay for a relay failure, not the handshake.
    assert_eq!(resume_outcome(&dropped), Step::Relay);
    assert_eq!(resume_outcome(&allocation), Step::Parked);
    assert_eq!(resume_outcome(&slow), Step::Handshake);
    assert_eq!(Failure::deadline(Step::Parked).step.error_code(), "parked_timeout");
    assert!(!Failure::deadline(Step::Ticket).retryable);
}

fn answer_value() -> Value {
    json!({
        "relay": "relay+do://cmux-remote-relay-dev.example.dev",
        "slot": "AbC-_123",
        "ticket": "v2.claims.mac",
        "expires_at": 1_800_000_300_u64,
        "grant": "h.c.s",
        "daemon_key": key_text(&[7; 32]),
    })
}

#[test]
fn the_carrier_answer_is_checked_before_use() {
    let answer = parse_answer(&answer_value()).unwrap();
    assert_eq!(answer.slot, "AbC-_123");
    assert_eq!(answer.daemon_key, Some([7; 32]));
    assert_eq!(answer.grant.as_deref().map(String::as_str), Some("h.c.s"));
    assert!(!format!("{answer:?}").contains("v2.claims.mac"), "Debug never shows the ticket");

    let mut no_extras = answer_value();
    no_extras.as_object_mut().unwrap().remove("grant");
    no_extras["daemon_key"] = Value::Null;
    let answer = parse_answer(&no_extras).unwrap();
    assert!(answer.grant.is_none() && answer.daemon_key.is_none());
    // The dial pins the key: none, or a malformed one, fails at the ticket.
    let none = pinned_daemon(&answer).unwrap_err();
    assert_eq!(none, Failure::fatal(Step::Ticket, "the machine has no daemon key"));
    for malformed in [json!("short"), json!(key_text(&[1; 32]) + "A"), json!(7)] {
        let mut bad = answer_value();
        bad["daemon_key"] = malformed.clone();
        let answer = parse_answer(&bad).unwrap();
        assert_eq!(pinned_daemon(&answer).unwrap_err().step, Step::Ticket, "{malformed}");
    }
    assert_eq!(pinned_daemon(&parse_answer(&answer_value()).unwrap()), Ok([7; 32]));

    // A loopback relay+ws is a local relay; anything else is refused.
    let mut local = answer_value();
    local["relay"] = json!("relay+ws://127.0.0.1:4100");
    assert!(parse_answer(&local).is_ok());
    for (key, value) in [
        ("relay", json!("relay+ws://relay.example")),
        ("relay", json!("wss://relay.example")),
        ("relay", json!("relay+do://relay.example/path")),
        ("relay", json!("relay+do://user@relay.example")),
        ("slot", json!("")),
        ("slot", json!("a/b")),
        ("ticket", json!("has space")),
        ("ticket", json!("")),
        ("expires_at", json!("soon")),
        ("grant", json!(7)),
    ] {
        let mut bad = answer_value();
        bad[key] = value.clone();
        assert!(parse_answer(&bad).is_err(), "{key} = {value}");
    }
}

#[test]
fn platform_refusals_are_retried_only_when_they_can_pass() {
    let ok = json!({"ok": true, "value": answer_value()});
    assert!(read_reply(200, &ok).is_ok());
    let refused = |status, code: &str| {
        read_reply(status, &json!({"ok": false, "error": {"code": code, "message": "m"}}))
            .unwrap_err()
    };
    assert!(!refused(403, "auth.forbidden").retryable);
    assert!(!refused(401, "auth.unauthenticated").retryable);
    assert!(!refused(404, "cloud.machine.not_found").retryable);
    assert!(refused(503, "owner.unreachable").retryable);
    assert!(refused(429, "rate_limited").retryable);
    assert!(refused(502, "http").retryable);
    let error = refused(403, "auth.forbidden");
    assert_eq!(error.detail, "cmux-platform answered 403 auth.forbidden: m");
    let malformed = read_reply(200, &json!({"ok": true, "value": {"relay": "x"}})).unwrap_err();
    assert!(!malformed.retryable);
}

#[test]
fn a_ticket_is_reused_until_shortly_before_it_expires() {
    assert!(TicketCache::usable(1_000, 900));
    assert!(!TicketCache::usable(1_000, 970));
    assert!(!TicketCache::usable(1_000, 1_000));
    assert!(!TicketCache::usable(0, u64::MAX));
}

const TEAM: &str = "team_0123456789abcdef0123";

#[test]
fn the_team_comes_from_the_flag_else_the_environment_and_is_checked() {
    let flagged = parse(&words(&format!("dial --machine {VM} --team {TEAM}"))).unwrap();
    assert_eq!(flagged.team.as_deref(), Some(TEAM));
    // The flag wins over the environment.
    let other = "team_ffffffffffffffffffff".to_owned();
    assert_eq!(with_team_env(flagged.clone(), Some(other.clone())), Some(flagged));
    let bare = parse(&words(&format!("dial --machine {VM}"))).unwrap();
    assert_eq!(with_team_env(bare.clone(), None).unwrap().team, None, "unset sends no team");
    assert_eq!(with_team_env(bare.clone(), Some("  ".into())).unwrap().team, None);
    assert_eq!(with_team_env(bare.clone(), Some(other.clone())).unwrap().team, Some(other));
    assert_eq!(with_team_env(bare, Some("team_nothex".into())), None, "a bad value is refused");
}

#[test]
fn the_connect_log_is_only_appended_and_stops_at_its_cap() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("carrier").join("connect.log");
    super::route_log::append(&path, "a\n");
    super::route_log::append(&path, "b\n");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "a\nb\n");
    std::fs::write(&path, vec![b'x'; super::route_log::MAX_BYTES as usize - 1]).unwrap();
    super::route_log::append(&path, "c\n");
    assert_eq!(std::fs::metadata(&path).unwrap().len(), super::route_log::MAX_BYTES - 1);
}
