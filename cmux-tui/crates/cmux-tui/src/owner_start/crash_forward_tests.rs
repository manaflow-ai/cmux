use super::*;
use std::collections::BTreeMap;

fn inputs<'a>(
    forced: &'a BTreeMap<String, Value>,
    settings: Option<&'a Value>,
    env: &'a dyn Fn(&str) -> Option<String>,
) -> ConsentInputs<'a> {
    ConsentInputs {
        channel: InstallChannel::Npm,
        managed_forced: forced,
        settings,
        release_build: true,
        env,
    }
}

#[test]
fn the_dsn_names_the_envelope_endpoint() {
    let dsn = Dsn::parse("https://abc@o1.ingest.us.sentry.io/42").unwrap();
    assert_eq!(dsn.endpoint, "https://o1.ingest.us.sentry.io/api/42/envelope/");
    assert_eq!(dsn.public_key, "abc");
    assert!(Dsn::parse(DSN).is_some());
    assert_eq!(Dsn::parse("ftp://a@b/1"), None);
    assert_eq!(Dsn::parse("https://b/1"), None);
    assert_eq!(Dsn::parse("https://a@b/x"), None);
}

#[test]
fn consent_sends_only_after_opt_in_and_when_nothing_turns_it_off() {
    let none: BTreeMap<String, Value> = BTreeMap::new();
    let no_env = |_: &str| -> Option<String> { None };
    // A fresh install (no setting) sends nothing; only an explicit opt-in sends.
    assert_eq!(
        consent(&inputs(&none, None, &no_env)),
        Consent::Off("app.sendAnonymousTelemetry is not turned on")
    );
    assert!(matches!(consent(&inputs(&none, Some(&json!({})), &no_env)), Consent::Off(_)));
    let on_settings = json!({"app": {"sendAnonymousTelemetry": true}});
    assert_eq!(consent(&inputs(&none, Some(&on_settings), &no_env)), Consent::Send);

    let app = ConsentInputs { channel: InstallChannel::App, ..inputs(&none, None, &no_env) };
    assert!(matches!(consent(&app), Consent::Off(_)));

    let forced = BTreeMap::from([("DisableTelemetry".to_string(), Value::Bool(true))]);
    assert!(matches!(consent(&inputs(&forced, Some(&on_settings), &no_env)), Consent::Off(_)));

    let off = json!({"app": {"sendAnonymousTelemetry": false}});
    assert_eq!(
        consent(&inputs(&none, Some(&off), &no_env)),
        Consent::Off("app.sendAnonymousTelemetry is false")
    );

    let dnt = |name: &str| (name == "DO_NOT_TRACK").then(|| "1".to_string());
    assert_eq!(consent(&inputs(&none, Some(&on_settings), &dnt)), Consent::Off("DO_NOT_TRACK"));
    let telemetry_off = |name: &str| (name == "CMUX_TUI_TELEMETRY").then(|| "off".to_string());
    assert_eq!(
        consent(&inputs(&none, Some(&on_settings), &telemetry_off)),
        Consent::Off("CMUX_TUI_TELEMETRY")
    );
    let ci = |name: &str| (name == "CI").then(|| "true".to_string());
    assert_eq!(consent(&inputs(&none, Some(&on_settings), &ci)), Consent::Off("CI"));

    let unreleased =
        ConsentInputs { release_build: false, ..inputs(&none, Some(&on_settings), &no_env) };
    assert_eq!(consent(&unreleased), Consent::Off("not a release build"));
}

#[test]
fn a_test_line_is_never_an_event_and_home_is_scrubbed() {
    assert_eq!(
        event_for(r#"{"message":"x","location":"a.rs:1","test":true}"#, &Source::OWNER, None),
        None
    );
    assert_eq!(event_for("not json", &Source::OWNER, None), None);
    let event = event_for(
        r#"{"message":"open /home/maya/x failed","location":"a.rs:1","version":"0.13.5","os":"linux","backtrace":"at /home/maya/src"}"#,
        Some("/home/maya"),
    )
    .unwrap();
    assert_eq!(event["exception"]["values"][0]["value"], "open ~/x failed");
    assert_eq!(event["extra"]["backtrace"], "at ~/src");
    assert_eq!(event["tags"]["process"], "cmux-tui");
    assert_eq!(event["tags"]["tui_version"], "0.13.5");
    assert_eq!(event["release"], "cmux-tui@0.13.5");
    assert_eq!(event["fingerprint"], json!(["owner-panic", "a.rs:1"]));
}

/// docs/privacy.md, Telemetry: the app's SeededSecretTests seeds, each a prefix, the rest and
/// the part that must not be sent (split so secret scanning does not read them as real tokens).
const SEEDS: [[&str; 3]; 17] = [
    ["sk-", "ant-api03-SEEDanthropicKEY0123456789abcdef", "SEEDanthropicKEY"],
    ["gh", "p_SEEDgithubPAT0123456789abcdefABCD", "SEEDgithubPAT"],
    ["github", "_pat_11SEEDGITHUBFINE0123456789_ab", "SEEDGITHUBFINE"],
    ["gl", "pat-SEEDgitlab0123456789abcd", "SEEDgitlab"],
    ["np", "m_SEEDnpmTOKEN0123456789abcdefghijklmn", "SEEDnpmTOKEN"],
    ["hf", "_SEEDhuggingface0123456789abcdefghij", "SEEDhuggingface"],
    ["AI", "zaSEEDgoogleKey0123456789abcdefghijklm", "SEEDgoogleKey"],
    ["xo", "xb-SEEDslack-0123456789-abcdefABCDEF", "SEEDslack"],
    ["AK", "IASEEDAWSKEY012345", "SEEDAWSKEY"],
    ["ey", "JhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzZWVkIn0.SEEDjwtSignature0123", "SEEDjwtSignature"],
    ["Authorization: ", "Bearer SEEDbearer0123456789abcdef", "SEEDbearer"],
    ["password=", "SEEDpasswordValue99", "SEEDpasswordValue"],
    ["https://", "seeduser:SEEDurlPassword99@git.corp.dev/r.git", "SEEDurlPassword"],
    ["https://", "seeduser:SEEDurlPassword99@git.corp.dev/r.git", "seeduser"],
    ["seeded", ".person@corp-mail.dev", "seeded.person"],
    ["/Users/", "seededalice/plan.txt", "seededalice"],
    ["/home/", "seededbob/.ssh/id_ed25519", "seededbob"],
];

#[test]
fn seeded_secrets_never_leave_in_a_panic_event() {
    let text = SEEDS.map(|[prefix, rest, _]| format!("{prefix}{rest}")).join(" | ");
    for kind in ["panic", "memory", "client-hang"] {
        let line = json!({
            "message": text, "location": text, "backtrace": text, "kind": kind,
            "waits": [text], "cancelled": [text],
        });
        let event = event_for(&line.to_string(), &Source::OWNER, Some("/home/other")).unwrap();
        let sent = String::from_utf8(envelope(&event)).unwrap();
        for [_, _, marker] in SEEDS {
            assert!(!sent.contains(marker), "{kind}: {marker} survived: {sent}");
        }
    }
}

/// The seeded secrets through the real send: the envelope the gated client puts
/// on the wire to Sentry (body, headers and URL) carries none of them.
#[cfg(unix)]
#[test]
fn seeded_secrets_never_reach_the_wire() {
    cmux_egress::capture::install().unwrap();
    let dir =
        std::env::temp_dir().join(format!("cmux-cf-seeded-{}", uuid::Uuid::new_v4().simple()));
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("owner-panics-seeded.jsonl");
    let text = SEEDS.map(|[prefix, rest, _]| format!("{prefix}{rest}")).join(" | ");
    let line =
        |kind: &str| json!({"message": text, "location": text, "backtrace": text, "kind": kind});
    std::fs::write(&log, format!("{}\n{}\n", line("panic"), line("memory"))).unwrap();
    let dsn = Dsn::parse(DSN).unwrap();
    assert_eq!(send_all(&log, &dsn, Some("/home/other")).unwrap(), 2);
    let host = "o4507547940749312.ingest.us.sentry.io";
    assert!(
        cmux_egress::capture::requests_to(host).len() >= 2,
        "the envelopes reached the capture server"
    );
    for [_, _, marker] in SEEDS {
        let leaks = cmux_egress::capture::leaks(marker);
        assert!(leaks.is_empty(), "{marker} left: {leaks:?}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_client_hang_line_is_a_warning_grouped_by_its_top_frame() {
    let line = json!({
        "kind": "client-hang", "at_ms": 1_000, "message": "cmux-tui UI loop stalled 2.4s in f",
        "location": "cmux::app::f", "duration_ms": 2400, "backtrace": "#0 0x1 cmux::app::f",
        "waits": ["daemon request tree (waited 2.4s of 5.0s)"], "cancelled": [], "version": "1.2.3",
    });
    let event = event_for(&line.to_string(), &Source::OWNER, None).unwrap();
    assert_eq!(event["level"], "warning");
    assert_eq!(event["exception"]["values"][0]["type"], "ClientHang");
    assert_eq!(event["fingerprint"], json!(["client-hang", "cmux::app::f"]));
    assert_eq!(event["tags"]["crash_source"], "client_hang_log");
    assert_eq!(event["extra"]["duration_ms"], 2400);
    assert_eq!(event["extra"]["waits"][0], "daemon request tree (waited 2.4s of 5.0s)");
    assert_eq!(event["release"], "cmux-tui@1.2.3");
}

#[test]
fn each_line_goes_once_and_a_failed_send_retries_next_time() {
    let dir = std::env::temp_dir().join(format!("cmux-cf-unit-{}", uuid::Uuid::new_v4().simple()));
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("owner-panics-s.jsonl");
    let state = state_path(&log);
    let line = |message: &str| format!("{{\"message\":\"{message}\",\"location\":\"a.rs:1\"}}\n");
    std::fs::write(&log, format!("{}{}", line("one"), line("two"))).unwrap();

    let mut bodies = Vec::new();
    let result = forward_new(&log, &state, 10, None, |body| {
        let text = String::from_utf8_lossy(body).into_owned();
        if text.contains("two") {
            return Err("offline".into());
        }
        bodies.push(text);
        Ok(())
    });
    assert!(result.is_err());
    assert_eq!(bodies.len(), 1);

    let mut again = Vec::new();
    let sent = forward_new(&log, &state, 10, None, |body| {
        again.push(String::from_utf8_lossy(body).into_owned());
        Ok(())
    })
    .unwrap();
    assert_eq!(sent, 1);
    assert!(again[0].contains("two"));
    assert_eq!(forward_new(&log, &state, 10, None, |_| Ok(())).unwrap(), 0);

    // An unfinished last line waits for its newline.
    std::fs::write(&log, format!("{}{}{}three-partial", line("one"), line("two"), "")).unwrap();
    assert_eq!(forward_new(&log, &state, 10, None, |_| Ok(())).unwrap(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The home the scrubber turns into `~`: `HOME`, else on Windows the profile (RFD 0157).
#[test]
fn home_dir_falls_back_to_the_windows_profile() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |name: &str| {
            pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| value.to_string())
        }
    };
    assert_eq!(home_dir(&env(&[("HOME", "/home/maya")])), Some("/home/maya".into()));
    assert_eq!(
        home_dir(&env(&[("HOME", "/home/maya"), ("USERPROFILE", r"C:\Users\maya")])),
        Some("/home/maya".into())
    );
    let profile_only = home_dir(&env(&[("HOME", ""), ("USERPROFILE", r"C:\Users\maya")]));
    assert_eq!(profile_only, cfg!(windows).then(|| r"C:\Users\maya".to_string()));
}

/// The acpmux daemon's panic log goes as the app sends it (`RustPanicSource.acpmux`, RFD 0157).
#[test]
fn an_acpmux_panic_line_is_tagged_as_the_app_tags_it() {
    let log = Path::new("/tmp/acpmux-home/panics.jsonl");
    assert_eq!(Source::of(log), Source::ACPMUX);
    assert_eq!(Source::of(Path::new("/tmp/s/owner-panics-s.jsonl")), Source::OWNER);
    let line = json!({
        "message": "boom", "location": "acpmux/src/daemon.rs:9", "thread": "main",
        "process": "acpmux", "pid": 7, "version": "0.1.0", "at_ms": 2_000, "test": false,
    });
    let event = event_for(&line.to_string(), &Source::of(log), None).unwrap();
    assert_eq!(event["level"], "error");
    assert_eq!(event["logger"], "acpmux");
    assert_eq!(event["tags"]["process"], "acpmux");
    assert_eq!(event["tags"]["crash_source"], "acpmux_panic_log");
    assert_eq!(event["tags"]["acpmux_version"], "0.1.0");
    assert_eq!(event["tags"].get("tui_version"), None);
    assert_eq!(event["fingerprint"], json!(["acpmux-panic", "acpmux/src/daemon.rs:9"]));
    assert_eq!(
        event["message"]["formatted"],
        "acpmux daemon panic at acpmux/src/daemon.rs:9: boom"
    );
    assert_eq!(event["release"], format!("cmux-tui@{DISTRIBUTION_VERSION}"));
    // A debug test trigger's line never goes.
    let test_line = json!({"message": "boom", "location": "a.rs:1", "test": true});
    assert_eq!(event_for(&test_line.to_string(), &Source::ACPMUX, None), None);
}

/// Every owner reads acpmux's one log: while one holds the lock beside it, another sends nothing.
#[test]
fn one_process_at_a_time_sends_a_shared_log() {
    let dir = std::env::temp_dir().join(format!("cmux-cf-lock-{}", uuid::Uuid::new_v4().simple()));
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("panics.jsonl");
    let held = try_lock_beside(&log).unwrap();
    assert!(held.is_some());
    assert!(try_lock_beside(&log).unwrap().is_none());
    drop(held);
    assert!(try_lock_beside(&log).unwrap().is_some());
    assert!(try_lock_beside(&dir.join("missing").join("panics.jsonl")).unwrap().is_none());
    let _ = std::fs::remove_dir_all(&dir);
}
