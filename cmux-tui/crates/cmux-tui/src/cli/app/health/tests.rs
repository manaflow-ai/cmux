use std::path::Path;

use serde_json::json;

use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn parses_bare_health_and_refuses_extra_arguments() {
    assert_eq!(parse(&args(&["health"])).unwrap(), AppCommand::Health(Command));
    assert!(parse(&args(&["health", "--bogus"])).is_err());
    assert!(parse(&args(&["health", "extra"])).is_err());
}

#[test]
fn app_needs_a_build_and_an_acpmux() {
    let identify = json!({"build": "1.0.0-nightly.900", "version": "1.0.0"});
    assert!(app_verdict(&identify, Some(Path::new("/tmp/a.sock"))).ok);
    assert_eq!(app_verdict(&identify, None).reason, "acpmux.none");
    assert_eq!(app_verdict(&json!({}), Some(Path::new("/tmp/a.sock"))).reason, "app.no_build");
}

#[test]
fn models_pass_only_when_the_default_harness_lists_a_real_model() {
    let good = json!({"harnesses": [
        {"harness": "codex", "models": [{"id": "gpt"}]},
        {"harness": "claude", "isDefault": true, "models": [{"id": "default"}, {"id": "opus"}]},
    ]});
    let verdict = models_verdict(&good);
    assert!(verdict.ok, "{verdict:?}");
    assert_eq!(default_harness_of(&good).as_deref(), Some("claude"));

    // The skeleton the bug showed: the picker read only "Model" (just the default sentinel).
    let sentinel_only = json!({"harnesses": [
        {"harness": "claude", "isDefault": true, "models": [{"id": "default"}], "probeError": "not signed in"},
        {"harness": "codex", "models": [{"id": "gpt"}]},
    ]});
    let verdict = models_verdict(&sentinel_only);
    assert!(!verdict.ok);
    assert_eq!(verdict.reason, "models.empty");
    assert!(verdict.detail.contains("not signed in"), "{}", verdict.detail);

    assert_eq!(models_verdict(&json!({"harnesses": []})).reason, "models.no_harness");
    assert_eq!(models_verdict(&json!({})).reason, "models.no_harness");
}

#[test]
fn default_harness_falls_back_to_the_first() {
    let models = json!({"harnesses": [{"harness": "codex"}, {"harness": "claude"}]});
    assert_eq!(default_harness_of(&models).as_deref(), Some("codex"));
    assert_eq!(default_harness_of(&json!({})), None);
}

#[test]
fn doctor_passes_only_on_ok_true_and_names_failed_steps() {
    assert!(doctor_verdict("claude", &json!({"ok": true, "steps": []})).ok);
    let failed = doctor_verdict(
        "claude",
        &json!({"ok": false, "steps": [
            {"name": "spawn", "ok": true},
            {"name": "session/new", "ok": false, "detail": "exited 1"},
        ]}),
    );
    assert!(!failed.ok);
    assert_eq!(failed.reason, "chat.handshake");
    assert_eq!(failed.detail, "claude: session/new: exited 1");
    // No `ok` at all is a failure, not a pass.
    assert!(!doctor_verdict("claude", &json!({})).ok);
}

#[test]
fn terminal_passes_only_on_matched_true() {
    assert!(terminal_verdict(&json!({"matched": true})).ok);
    assert_eq!(terminal_verdict(&json!({"matched": false})).reason, "terminal.no_echo");
    assert!(!terminal_verdict(&json!({})).ok);
}

#[test]
fn a_pass_after_its_deadline_fails() {
    let check = timed("chat", Duration::ZERO, || {
        std::thread::sleep(Duration::from_millis(2));
        Verdict::pass("late")
    });
    assert!(!check.ok);
    assert_eq!(check.reason, "deadline");
}

#[test]
fn report_is_ok_only_when_every_check_passed() {
    let pass = Check {
        name: "app",
        ok: true,
        reason: "ok".into(),
        detail: String::new(),
        ms: 1,
        deadline_ms: 5000,
    };
    let identify = json!({"build": "900", "version": "1.0.0-nightly.900", "bundle_id": "x"});
    let value = report(&identify, std::slice::from_ref(&pass));
    assert_eq!(value["ok"], true);
    assert_eq!(value["app"]["build"], "900");
    assert_eq!(value["checks"][0]["name"], "app");

    let failed =
        Check { name: "terminal", ok: false, reason: "terminal.no_echo".into(), ..pass.clone() };
    let value = report(&identify, &[pass, failed]);
    assert_eq!(value["ok"], false);
    assert_eq!(value["checks"][1]["reason"], "terminal.no_echo");
    assert!(human(&value).contains("terminal.no_echo"));

    assert_eq!(report(&json!(null), &[])["ok"], false);
}

#[test]
fn terminal_ids_are_uuid_v4_hex() {
    let id = terminal_id();
    assert_eq!(id.len(), 32);
    assert!(id.chars().all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase()));
    assert_eq!(&id[12..13], "4");
    assert!("89ab".contains(&id[16..17]));
    assert_ne!(nonce(), nonce());
}
