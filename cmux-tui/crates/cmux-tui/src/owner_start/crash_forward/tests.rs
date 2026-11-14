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
fn consent_sends_only_when_nothing_turns_it_off() {
    let none: BTreeMap<String, Value> = BTreeMap::new();
    let no_env = |_: &str| -> Option<String> { None };
    assert_eq!(consent(&inputs(&none, None, &no_env)), Consent::Send);

    let app = ConsentInputs { channel: InstallChannel::App, ..inputs(&none, None, &no_env) };
    assert!(matches!(consent(&app), Consent::Off(_)));

    let forced = BTreeMap::from([("DisableTelemetry".to_string(), Value::Bool(true))]);
    assert!(matches!(consent(&inputs(&forced, None, &no_env)), Consent::Off(_)));

    let off = json!({"app": {"sendAnonymousTelemetry": false}});
    assert_eq!(
        consent(&inputs(&none, Some(&off), &no_env)),
        Consent::Off("app.sendAnonymousTelemetry is false")
    );
    let on = json!({"app": {"sendAnonymousTelemetry": true}});
    assert_eq!(consent(&inputs(&none, Some(&on), &no_env)), Consent::Send);

    let dnt = |name: &str| (name == "DO_NOT_TRACK").then(|| "1".to_string());
    assert_eq!(consent(&inputs(&none, None, &dnt)), Consent::Off("DO_NOT_TRACK"));
    let telemetry_off = |name: &str| (name == "CMUX_TUI_TELEMETRY").then(|| "off".to_string());
    assert_eq!(consent(&inputs(&none, None, &telemetry_off)), Consent::Off("CMUX_TUI_TELEMETRY"));
    let ci = |name: &str| (name == "CI").then(|| "true".to_string());
    assert_eq!(consent(&inputs(&none, None, &ci)), Consent::Off("CI"));

    let unreleased = ConsentInputs { release_build: false, ..inputs(&none, None, &no_env) };
    assert_eq!(consent(&unreleased), Consent::Off("not a release build"));
}

#[test]
fn a_test_line_is_never_an_event_and_home_is_scrubbed() {
    assert_eq!(event_for(r#"{"message":"x","location":"a.rs:1","test":true}"#, None), None);
    assert_eq!(event_for("not json", None), None);
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
    for kind in ["panic", "memory"] {
        let line = json!({"message": text, "location": text, "backtrace": text, "kind": kind});
        let event = event_for(&line.to_string(), Some("/home/other")).unwrap();
        let sent = String::from_utf8(envelope(&event)).unwrap();
        for [_, _, marker] in SEEDS {
            assert!(!sent.contains(marker), "{kind}: {marker} survived: {sent}");
        }
    }
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
