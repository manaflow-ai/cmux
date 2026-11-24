//! Supervisor tests of `cmux safe-mode bisect` (`safe_mode_bisect.rs`).

use super::*;

const OFF: &str = "off: safe mode";

fn bisect(
    f: &Fixture,
    step: &str,
    origin: Origin,
) -> Result<Value, super::super::supervisor::ApiError> {
    f.supervisor.safe_mode_call("safe_mode.bisect", json!({ "step": step }), origin)
}

fn names(answer: &Value, key: &str) -> Vec<String> {
    answer["bisect"][key]
        .as_array()
        .unwrap_or_else(|| panic!("{key} in {answer}"))
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect()
}

fn refused_mount(f: &Fixture, mount_id: &str, app: &str) -> bool {
    f.supervisor
        .mount(CLIENT, mount_id, app, "cmux.section/1", json!({}))
        .is_err_and(|e| e.code == "apps.safe_mode" && e.message == OFF)
}

#[test]
fn a_bisect_runs_half_the_extensions_and_names_the_culprit() {
    let f = fixture();
    f.install("cmux/demo");
    f.install("local/spy");
    // Only in safe mode.
    let off = bisect(&f, "start", Origin::Cli).unwrap_err();
    assert_eq!(off.code, "apps.safe_mode.off");
    f.supervisor.set_safe_mode(true, Origin::Cli).unwrap();
    // It runs extensions, so only you start it and answer it; anyone ends it.
    for origin in [Origin::Mcp, Origin::Script, Origin::Remote] {
        assert_eq!(bisect(&f, "start", origin).unwrap_err().code, "apps.safe_mode.origin");
    }
    assert_eq!(bisect(&f, "good", Origin::Cli).unwrap_err().code, "apps.safe_mode.bisect");
    let started = bisect(&f, "start", Origin::Cli).unwrap();
    let suspects = names(&started, "suspects");
    assert!(suspects.iter().any(|a| a == "local/spy") && suspects.iter().any(|a| a == "cmux/demo"));
    assert_eq!(f.supervisor.safe_mode_json()["bisect"], started["bisect"], "get says it too");
    // Answer as a person whose cmux local/spy breaks.
    let mut answer = started;
    for step in 0.. {
        assert!(step < 16, "no answer: {answer}");
        if answer["bisect"].get("found").is_some() {
            break;
        }
        let running = names(&answer, "running");
        let held = names(&answer, "held");
        // What runs mounts and lists no run state; the rest stays off.
        for app in held.iter().filter(|a| *a == "local/spy" || *a == "cmux/demo") {
            assert!(refused_mount(&f, &format!("held-{step}-{app}"), app), "{app} is held");
            assert_eq!(app_entry(&f.supervisor.list(), app)["run_state"], OFF);
        }
        if running.iter().any(|a| a == "local/spy") {
            f.mount(&format!("run-{step}"), "local/spy", "cmux.section/1", json!({}));
            assert!(app_entry(&f.supervisor.list(), "local/spy").get("run_state").is_none());
            answer = bisect(&f, "bad", Origin::Cli).unwrap();
            // The half that ran stops when it is no longer the half under test.
            if !names(&answer, "running").iter().any(|a| a == "local/spy") {
                let failed = f.wait("spy stops", |e| {
                    e["event"] == "apps-mount-failed" && e["mount_id"] == format!("run-{step}")
                });
                assert_eq!(failed["reason"], OFF);
            }
        } else {
            answer = bisect(&f, "good", Origin::Cli).unwrap();
        }
    }
    assert_eq!(answer["bisect"]["found"], "local/spy");
    assert!(refused_mount(&f, "after", "local/spy"), "nothing runs once it is named");
    // Leaving safe mode ends the bisect.
    f.supervisor.set_safe_mode(false, Origin::User).unwrap();
    assert!(f.supervisor.safe_mode_json().get("bisect").is_none());
    assert!(!f._root.0.join("apps-bisect.json").exists());
}

#[test]
fn a_bisect_survives_a_restart_and_reset_holds_everything_off_again() {
    let f = fixture();
    f.install("local/spy");
    f.supervisor.set_safe_mode(true, Origin::Cli).unwrap();
    let started = bisect(&f, "start", Origin::Cli).unwrap();
    let Fixture { supervisor, _root, .. } = f;
    drop(supervisor);
    let f = fixture_with(&[], Duration::from_secs(60), _root);
    assert_eq!(f.supervisor.safe_mode_json()["bisect"], started["bisect"]);
    // Reset takes any origin.
    let reset = bisect(&f, "reset", Origin::Mcp).unwrap();
    assert!(reset.get("bisect").is_none() && reset["on"] == true, "{reset}");
    assert!(refused_mount(&f, "m1", "local/spy"));
    assert!(!f._root.0.join("apps-bisect.json").exists());
    assert_eq!(bisect(&f, "status", Origin::Mcp).unwrap(), reset);
}
