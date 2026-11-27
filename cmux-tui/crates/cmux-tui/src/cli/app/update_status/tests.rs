use serde_json::{Value, json};

use super::*;

fn messages() -> &'static UpdateStatusMessages {
    &crate::localization::catalog().app_control.update_status
}

fn words(args: &[&str]) -> Vec<String> {
    args.iter().map(|word| (*word).to_owned()).collect()
}

/// `updates.status` of a NIGHTLY whose updater runs: hourly checks, automatic downloads.
fn running() -> Value {
    json!({
        "track": "nightly-next",
        "ring": "nightly",
        "version": "1.0.0-nightly.4605751670101",
        "build": "4605751670101",
        "feed_url": "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
        "sparkle_enabled": true,
        "sparkle_disabled_reason": null,
        "automatic_checks": true,
        "automatic_downloads": true,
        "phase": "idle",
        "detected_version": null,
        "last_probe": null,
        "last_probe_error": null,
        "relaunch_hold": null,
        "automation": {
            "paused_by_build": false,
            "settings_applied": true,
            "check_interval_seconds": 3600,
            "last_check": "2026-11-27T20:00:00Z",
            "download_setting": true,
            "metered_mode": "defer-low-data",
            "network_constrained": false,
            "network_expensive": false,
            "network_pending": false,
            "download_held_for_deltas": false,
            "off_managed_channel": false,
            "managed_policy_disables": false,
            "required_minimum_version": null,
            "install_when_idle_seconds": null,
            "feed_newest": null,
            "feed_read_at": null,
        },
    })
}

fn codes(report: &Value) -> Vec<&str> {
    report["reasons"].as_array().unwrap().iter().map(|r| r["code"].as_str().unwrap()).collect()
}

#[test]
fn parses_update_and_update_status_only() {
    assert!(parse(&words(&["update"])).is_ok());
    assert!(parse(&words(&["update", "status"])).is_ok());
    assert!(parse(&words(&["update", "install"])).is_err());
    assert!(parse(&words(&["update", "status", "extra"])).is_err());
}

#[test]
fn a_running_updater_is_not_paused() {
    let report = report(&running(), messages());
    assert_eq!(report["paused"], false, "{report}");
    assert!(codes(&report).is_empty());
    assert_eq!(report["checks"]["automatic"], true);
    assert_eq!(report["checks"]["interval_seconds"], 3600.0);
    assert_eq!(report["downloads"]["automatic"], true);
    assert_eq!(report["last_check"]["at"], "2026-11-27T20:00:00Z");
    assert_eq!(report["last_check"]["source"], "updater");
    assert_eq!(report["channel"], "nightly");
    assert_eq!(report["available"], Value::Null);
    let text = human(&report, messages());
    assert!(text.contains("running"), "{text}");
    assert!(text.contains("every 1h"), "{text}");
}

/// The build's pause (AutomaticUpdatePause) is the reason, alone: the settings it
/// overrides are not blamed on the person.
#[test]
fn the_build_pause_is_named_and_alone() {
    let mut status = running();
    status["automation"]["paused_by_build"] = json!(true);
    status["automation"]["check_interval_seconds"] = Value::Null;
    status["automatic_downloads"] = json!(false);
    let report = report(&status, messages());
    assert_eq!(report["paused"], true);
    assert_eq!(codes(&report), ["build_pause"]);
    assert_eq!(report["reasons"][0]["by"], "build");
    assert!(human(&report, messages()).contains("paused"));
}

#[test]
fn notify_only_waits_for_a_click() {
    let mut status = running();
    status["automation"]["download_setting"] = json!(false);
    status["automatic_downloads"] = json!(false);
    let report = report(&status, messages());
    assert_eq!(report["paused"], true);
    assert_eq!(codes(&report), ["downloads_by_click"]);
    assert_eq!(report["checks"]["automatic"], true);
}

#[test]
fn off_stops_checks_and_downloads() {
    let mut status = running();
    status["automation"]["download_setting"] = json!(false);
    status["automation"]["check_interval_seconds"] = Value::Null;
    status["automatic_downloads"] = json!(false);
    let report = report(&status, messages());
    assert_eq!(codes(&report), ["checks_off", "downloads_by_click"]);
}

#[test]
fn low_data_mode_defers_downloads() {
    let mut status = running();
    status["automation"]["network_constrained"] = json!(true);
    status["automatic_downloads"] = json!(false);
    assert_eq!(codes(&report(&status, messages())), ["low_data"]);
    status["automation"]["metered_mode"] = json!("defer-expensive");
    status["automation"]["network_constrained"] = json!(false);
    status["automation"]["network_expensive"] = json!(true);
    assert_eq!(codes(&report(&status, messages())), ["expensive_link"]);
}

#[test]
fn a_managed_policy_and_a_disabled_updater_say_who() {
    let mut status = running();
    status["automation"]["managed_policy_disables"] = json!(true);
    let report_ = report(&status, messages());
    assert_eq!(codes(&report_), ["managed_policy"]);
    assert_eq!(report_["reasons"][0]["by"], "organization");
    let mut status = running();
    status["sparkle_enabled"] = json!(false);
    status["sparkle_disabled_reason"] = json!("development_build");
    let report = report(&status, messages());
    assert_eq!(codes(&report), ["updater_off"]);
    assert!(report["reasons"][0]["text"].as_str().unwrap().contains("development_build"));
}

/// The newer of Sparkle's check and the probe is the last check; a found update is available.
#[test]
fn last_check_and_available_version() {
    let mut status = running();
    status["last_probe"] = json!({
        "result": "update_available",
        "checked_at": "2026-11-27T20:30:00Z",
        "offered": {"version": "4605800000000", "display_version": "1.0.0-nightly.4605800000000"},
    });
    let report = report(&status, messages());
    assert_eq!(
        report["last_check"],
        json!({"at": "2026-11-27T20:30:00Z", "source": "probe", "result": "update_available"})
    );
    assert_eq!(
        report["available"],
        json!({"version": "1.0.0-nightly.4605800000000", "source": "probe"})
    );
    status["detected_version"] = json!("1.0.0-nightly.4605900000000");
    assert_eq!(report_of(&status)["available"]["source"], "updater");
}

fn report_of(status: &Value) -> Value {
    report(status, messages())
}

/// An app older than the `automation` facts: paused follows its two flags, and says it cannot tell why.
#[test]
fn an_older_app_still_answers() {
    let mut status = running();
    status.as_object_mut().unwrap().remove("automation");
    let fine = report_of(&status);
    assert_eq!(fine["paused"], false, "{fine}");
    status["automatic_downloads"] = json!(false);
    let paused = report_of(&status);
    assert_eq!(paused["paused"], true);
    assert_eq!(codes(&paused), ["unknown"]);
}

#[test]
fn an_idle_install_hold_shows() {
    let mut status = running();
    status["relaunch_hold"] = json!({"reason": "agent_turn", "since": "2026-11-27T20:10:00Z", "surfaced": false, "age_seconds": 60});
    let report = report_of(&status);
    assert_eq!(report["paused"], false);
    assert_eq!(report["install_hold"]["reason"], "agent_turn");
    assert!(human(&report, messages()).contains("agent_turn"));
}
