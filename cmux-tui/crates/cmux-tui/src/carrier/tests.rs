use std::time::Duration;

use cmux_remote::connection::ConnectionError;
use cmux_remote::crypto::CryptoError;
use cmux_remote::link::LinkError;
use cmux_remote::provider::ProviderError;
use serde_json::{Value, json};

use super::answer::{
    Prefetched, TicketCache, grant_vmk, key_text, parse_answer, read_reply, token_subject,
};
use super::client::{Marks, classify, pinned_daemon, resume_outcome};
use super::contract::{
    Backoff, Failure, INITIAL_BACKOFF, MAX_BACKOFF, Phase, PhaseTimes, PhasesOf, StdinLine, Step,
    Vmk, answer_line, connected_line, detail_code, failure_line, parse_deadline, phases_line,
    route_line, served_line, serving_line, stdin_line,
};
use super::{
    DialArgs, DialService, ServeArgs, desktop_failure, parse, parse_key, parse_serve,
    public_key_line, with_team_env,
};

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
    let served: Value = serde_json::from_str(served_line(None).trim()).unwrap();
    assert_eq!(served, json!({"ok": true, "route": "carrier"}));
    let served: Value = serde_json::from_str(served_line(Some(Vmk::Team)).trim()).unwrap();
    assert_eq!(served, json!({"ok": true, "route": "carrier", "vmk": "team"}));
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
    assert_eq!((Step::Service.error_code(), Step::Service.exit_code()), ("service_refused", 6));
}

#[test]
fn the_route_line_is_pinned() {
    assert_eq!(
        route_line(VM, Phase::Connect, None, None, Duration::from_millis(1234)),
        format!("cloud.connect route=carrier machine={VM} phase=connect outcome=ok ms=1234\n")
    );
    assert_eq!(
        route_line(VM, Phase::of_attempt(2), Some(Step::Parked), None, Duration::from_millis(7)),
        format!(
            "cloud.connect route=carrier machine={VM} phase=reconnect outcome=parked_timeout ms=7\n"
        )
    );
    assert_eq!(
        route_line(VM, Phase::Resume, Some(Step::Handshake), None, Duration::ZERO),
        format!("cloud.connect route=carrier machine={VM} phase=resume outcome=handshake ms=0\n")
    );
    assert_eq!(Phase::of_attempt(1), Phase::Connect);
}

/// A failed attempt's route line ends in ` detail=<code>` after `ms`, so a
/// parser of `outcome=(\S+) ms=(\d+)` still reads it; an ok one has none.
#[test]
fn a_failed_route_line_names_its_detail_code_after_ms() {
    let closed = "link transport failed: relay WebSocket closed (close 1013)";
    assert_eq!(
        route_line(
            VM,
            Phase::of_attempt(2),
            Some(Step::Relay),
            Some(closed),
            Duration::from_millis(541)
        ),
        format!(
            "cloud.connect route=carrier machine={VM} phase=reconnect outcome=relay ms=541 detail=1013\n"
        )
    );
    assert_eq!(
        route_line(VM, Phase::Connect, None, Some(closed), Duration::from_millis(9)),
        format!("cloud.connect route=carrier machine={VM} phase=connect outcome=ok ms=9\n")
    );
    // No text, no detail field at all.
    assert_eq!(
        route_line(VM, Phase::Resume, Some(Step::Relay), Some("  "), Duration::ZERO),
        format!("cloud.connect route=carrier machine={VM} phase=resume outcome=relay ms=0\n")
    );
}

/// Each detail is one short `[a-z0-9_]` code, and none carries the failure
/// text (a ticket or grant in it stays out).
#[test]
fn detail_codes_are_short_tokens_and_never_the_text() {
    let cases = [
        ("link transport failed: relay WebSocket closed (close 1013)", "1013"),
        ("relay WebSocket closed (close 4003)", "4003"),
        (
            "link transport failed: relay WebSocket connection failed: HTTP status 409 Conflict",
            "http_409",
        ),
        ("cmux-platform answered 503 carrier.unavailable: no route", "http_503"),
        ("relay allocation is temporarily unavailable (relay code slot-busy)", "slot_busy"),
        ("relay circuit is temporarily unavailable (relay code other)", "other"),
        ("relay allocation is temporarily unavailable (relay code Bad.Code)", "other"),
        (
            "relay WebSocket connection failed: I/O error: Connection refused (os error 111)",
            "connect_refused",
        ),
        ("relay WebSocket connection failed: TLS error: invalid peer certificate", "tls"),
        ("link transport failed: relay allocation timed out", "timeout"),
        ("relay circuit join timed out", "timeout"),
        ("the deadline passed", "deadline"),
        ("link transport failed: relay WebSocket closed", "closed"),
        ("relay WebSocket read failed", "closed"),
        ("relay WebSocket authentication was rejected", "rejected"),
        ("the machine has no daemon key", "daemon_key"),
        ("unexpected Bearer eyJhbGciOi.secret-ticket", "other"),
    ];
    let token = |code: &str| {
        (1..=24).contains(&code.len())
            && code.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    };
    for (text, want) in cases {
        let code = detail_code(text).unwrap_or_else(|| panic!("no code for {text:?}"));
        assert_eq!(code, want, "{text:?}");
        assert!(token(&code), "{code:?} is not ^[a-z0-9_]{{1,24}}$");
    }
    assert_eq!(detail_code(""), None);
    assert_eq!(detail_code(" \n"), None);
}

#[test]
fn the_phases_line_is_pinned_and_never_a_route_line() {
    let ms = Duration::from_millis;
    let times = PhaseTimes {
        ticket: ms(310),
        relay: ms(42),
        parked: ms(120),
        handshake: ms(250),
        mux: ms(30),
        lanes: 3,
    };
    let line = phases_line(VM, PhasesOf::Attempt(Phase::Connect), None, times, ms(760));
    assert_eq!(
        line,
        format!(
            "carrier.phases machine={VM} phase=connect carrier=relay:0 outcome=ok ticket_ms=310 relay_ms=42 parked_ms=120 handshake_ms=250 mux_ms=30 lanes=3 ms=760\n"
        )
    );
    let stream = phases_line(
        VM,
        PhasesOf::Stream,
        None,
        PhaseTimes { mux: ms(4), ..PhaseTimes::default() },
        ms(4),
    );
    assert!(stream.contains(" phase=stream "), "{stream}");
    let failed = phases_line(
        VM,
        PhasesOf::Attempt(Phase::of_attempt(2)),
        Some(Step::Parked),
        PhaseTimes::default(),
        ms(9),
    );
    assert!(failed.contains(" phase=reconnect ") && failed.contains(" outcome=parked_timeout "));
    // cmuxterm-hq's start matrix fails a row on any cloud.connect line that
    // is not exactly a route line.
    for line in [line, stream, failed] {
        assert!(!line.contains("cloud.connect"), "{line}");
    }
}

#[test]
fn phase_times_run_mark_to_mark_and_the_open_step_to_now() {
    let t0 = tokio::time::Instant::now();
    let at = |ms| Some(t0 + Duration::from_millis(ms));
    let done = Marks {
        started: at(0),
        answered: at(300),
        relay_up: at(340),
        first_open: at(341),
        first_allocated: at(460),
        connected: at(700),
        mux_open: at(730),
        lanes: 3,
    };
    let now = t0 + Duration::from_millis(5000);
    let ms = Duration::from_millis;
    assert_eq!(
        done.times(now),
        PhaseTimes {
            ticket: ms(300),
            relay: ms(40),
            parked: ms(119),
            handshake: ms(240),
            mux: ms(30),
            lanes: 3
        }
    );
    // Cut while parked: the park runs to now, later steps are zero.
    let parked = Marks { first_allocated: None, connected: None, mux_open: None, lanes: 1, ..done };
    let times = parked.times(now);
    assert_eq!((times.parked, times.handshake, times.mux), (ms(4659), ms(0), ms(0)));
    assert_eq!(Marks::default().times(now), PhaseTimes::default());
}

#[test]
fn a_credential_s_subject_is_its_jwt_sub_claim_or_none() {
    use base64::Engine as _;
    let encode =
        |value: Value| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value.to_string());
    let jwt = |claims: Value| format!("{}.{}.sig", encode(json!({"alg": "ES256"})), encode(claims));
    assert_eq!(token_subject(&jwt(json!({"sub": "user-1", "exp": 1}))), Some("user-1".into()));
    assert_eq!(token_subject(&jwt(json!({"exp": 1}))), None);
    assert_eq!(token_subject(&jwt(json!({"sub": ""}))), None);
    assert_eq!(token_subject(&jwt(json!({"sub": 7}))), None);
    assert_eq!(token_subject("opaque-token"), None);
    assert_eq!(token_subject("a.!!!.c"), None);
    // Only a three-segment credential with a JWT header has a `sub`.
    let claims = encode(json!({"sub": "user-1"}));
    let header = encode(json!({"alg": "ES256"}));
    assert_eq!(token_subject(&format!("opaque.{claims}.sig")), None);
    assert_eq!(token_subject(&format!("{}.{claims}.sig", encode(json!({"typ": "JWT"})))), None);
    assert_eq!(token_subject(&format!("{header}.{claims}")), None);
    assert_eq!(token_subject(&format!("{header}.{claims}.sig.extra")), None);
}

#[test]
fn arguments_are_the_machine_and_one_deadline() {
    assert_eq!(
        parse(&words(&format!("dial --machine {VM}"))),
        Some(DialArgs {
            machine: VM.into(),
            service: DialService::Mux,
            deadline: Duration::from_secs(180),
            api: None,
            token_file: None,
            team: None,
            answer_fd: None,
        })
    );
    for (fd, want) in [("0", 0), ("3", 3), ("17", 17)] {
        let args = parse(&words(&format!("dial --machine {VM} --answer-fd {fd}"))).unwrap();
        assert_eq!(args.answer_fd, Some(want), "{fd}");
    }
    let full = parse(&words(&format!(
        "dial --deadline-ms 5000 --machine {VM} --cloud-api https://api.example --cloud-token-file /t"
    )))
    .unwrap();
    assert_eq!(full.deadline, Duration::from_millis(5000));
    assert_eq!(full.api.as_deref(), Some("https://api.example"));
    assert_eq!(
        parse(&words(&format!("dial --machine {VM} --service desktop"))).unwrap().service,
        DialService::Desktop
    );
    assert_eq!(
        parse(&words(&format!("dial --service mux --machine {VM}"))).unwrap().service,
        DialService::Mux
    );
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
        format!("dial --machine {VM} --service ssh"),
        format!("dial --machine {VM} --service desktop --service desktop"),
        format!("dial --machine {VM} --team team_0123"),
        format!("dial --machine {VM} --team team_0123456789ABCDEF0123"),
        format!("dial --machine {VM} --team user_0123456789abcdef0123"),
        format!("dial --machine {VM} --team {TEAM} --team {TEAM}"),
        format!("dial --machine {VM} --answer-fd 1"),
        format!("dial --machine {VM} --answer-fd 2"),
        format!("dial --machine {VM} --answer-fd -1"),
        format!("dial --machine {VM} --answer-fd x"),
        format!("dial --machine {VM} --answer-fd 0 --answer-fd 0"),
    ] {
        assert_eq!(parse(&words(&bad)), None, "{bad}");
    }
    assert_eq!(
        parse_serve(&words(&format!("serve --machine {VM} --socket /s --answer-fd 0"))),
        None
    );
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
        format!("serve --machine {VM} --socket /a --service mux"),
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

#[test]
fn a_handed_over_answer_is_a_checked_answer_with_a_grant() {
    let line = json!({ "carrier_answer": answer_value() }).to_string();
    match stdin_line(line.as_bytes()) {
        StdinLine::Answer(answer) => {
            assert_eq!(answer.slot, "AbC-_123");
            assert_eq!(answer.daemon_key, Some([7; 32]));
            let debug = format!("{answer:?}");
            assert!(!debug.contains("h.c.s") && !debug.contains("v2.claims"), "{debug}");
        }
        other => panic!("{other:?}"),
    }
    assert!(answer_line(line.as_bytes()).is_ok());
    let mut grantless = answer_value();
    grantless.as_object_mut().unwrap().remove("grant");
    let grantless = json!({ "carrier_answer": grantless }).to_string();
    assert_eq!(stdin_line(grantless.as_bytes()), StdinLine::Invalid("carrier_answer has no grant"));
    for bad in [&br#"{"carrier_answer":{}}"#[..], br#"{"carrier_answer":7}"#, b"[]"] {
        assert!(
            matches!(stdin_line(bad), StdinLine::Invalid(_)),
            "{}",
            String::from_utf8_lossy(bad)
        );
        assert!(answer_line(bad).is_err());
    }
}

#[test]
fn a_handed_over_answer_is_taken_once_and_only_while_fresh() {
    let fresh = parse_answer(&answer_value()).unwrap();
    let expires = fresh.expires_at;
    let held = Prefetched::new(Some(fresh.clone()));
    assert!(held.take(expires - 300).is_some());
    assert!(held.take(expires - 300).is_none(), "one attempt takes it");
    held.put(fresh);
    assert!(held.take(expires - 10).is_none(), "a ticket about to expire is dropped");
    assert!(held.take(expires - 300).is_none(), "and not kept");
    let mut grantless = answer_value();
    grantless.as_object_mut().unwrap().remove("grant");
    held.put(parse_answer(&grantless).unwrap());
    assert!(held.take(expires - 300).is_none(), "an answer without a grant is not used");
}

#[test]
fn key_prints_only_the_public_key_as_one_base64url_line() {
    assert!(parse_key(&words("key --public")));
    for bad in ["key", "key --private", "key --public --public", "key --public x", "dial --public"]
    {
        assert!(!parse_key(&words(bad)), "{bad}");
    }
    let identity = cmux_remote::crypto::StaticIdentity::generate().unwrap();
    let line = public_key_line(&identity.public_key());
    let text = line.strip_suffix('\n').unwrap();
    assert_eq!(text.len(), 43);
    assert!(text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'), "{line}");
    assert_eq!(text, key_text(&identity.public_key()), "the platform's noise_key spelling");
    assert_ne!(text, key_text(identity.private_key()), "never the private key");
}

/// The desktop open's own send (or a heartbeat) can meet the lost session
/// before the multiplexer's reader marks it: the error itself says
/// `SessionUnavailable` while `session_unavailable()` is still false. That
/// is still a session the host lost, so the dial takes a fresh one.
#[test]
fn a_carrier_desktop_open_that_its_send_finds_the_session_gone_takes_a_fresh_session() {
    use cmux_remote::bridge::BridgeError;
    use cmux_remote::service::ServiceError;
    let sent = BridgeError::Service(ServiceError::Client(ConnectionError::SessionUnavailable));
    let failure = desktop_failure(sent, false);
    assert!(failure.fresh_session && failure.retryable, "{}", failure.detail);
    assert_eq!(failure.step, Step::Relay);
    let typed = desktop_failure(BridgeError::Service(ServiceError::SessionUnavailable), false);
    assert!(typed.fresh_session, "{}", typed.detail);
    // A session that ended any other way is still the carrier's, and fatal.
    let closed = desktop_failure(BridgeError::Service(ServiceError::Closed), false);
    assert!(!closed.fresh_session && !closed.retryable, "{}", closed.detail);
    // The daemon's refusal is the service's.
    let refused = desktop_failure(BridgeError::Rejected("not the owner".into()), false);
    assert_eq!(refused.step, Step::Service);
    assert!(!refused.fresh_session);
}
