//! `cmux remote-host grants`: each missing grant named with its pane, Remote
//! Management read, the pane opened on the Mac that lacks it.

use std::cell::RefCell;

use serde_json::{Value, json};

use super::*;

fn status(screen_recording: bool, accessibility: bool) -> String {
    json!({"state": "running", "host": {"permissions": {
        "screen_recording": screen_recording, "accessibility": accessibility}}})
    .to_string()
}

fn output(status: &str, screensharing: &str, ard: &str, vnc: &str) -> String {
    format!("status\t{status}\nscreensharing\t{screensharing}\nard\t{ard}\nvnc\t{vnc}\n")
}

/// Runs nothing; answers each script with the next canned output and keeps the scripts.
struct Fake {
    answers: RefCell<Vec<String>>,
    scripts: RefCell<Vec<String>>,
}

impl Fake {
    fn new(answers: &[String]) -> Self {
        Self {
            answers: RefCell::new(answers.iter().rev().cloned().collect()),
            scripts: RefCell::default(),
        }
    }
}

impl Shell for Fake {
    fn run(&self, script: &str) -> Result<String, String> {
        self.scripts.borrow_mut().push(script.to_owned());
        let answer = self.answers.borrow_mut().pop().ok_or("no more answers")?;
        // An open script reports the open, as the real probe does.
        let open = script
            .lines()
            .next()
            .and_then(|line| line.strip_prefix("OPEN='"))
            .map(|rest| rest.trim_end_matches('\''));
        Ok(match open {
            Some(word) if !word.is_empty() => format!("{answer}opened\t{word}\n"),
            _ => answer,
        })
    }
}

fn row<'a>(report: &'a Value, key: &str) -> &'a Value {
    report["grants"].as_array().unwrap().iter().find(|row| row["grant"] == key).unwrap()
}

#[test]
fn names_exactly_the_missing_grant_and_its_pane() {
    for (screen, accessibility, missing) in [
        (false, true, vec!["screen-recording"]),
        (true, false, vec!["accessibility"]),
        (false, false, vec!["screen-recording", "accessibility"]),
        (true, true, vec![]),
    ] {
        let probe = parse_probe(&output(&status(screen, accessibility), "", "off", "closed"));
        let report = report(Some("studio"), &probe);
        assert_eq!(report["missing"], json!(missing));
        for grant in &GRANTS {
            let row = row(&report, grant.key);
            let lacks = missing.contains(&grant.key);
            assert_eq!(row["granted"], json!(!lacks), "{}", grant.key);
            assert_eq!(row["pane"], grant.pane);
            if lacks {
                let words = row["missing"].as_str().unwrap();
                assert!(words.contains(grant.name) && words.contains("studio"), "{words}");
                assert!(words.contains("Privacy & Security"), "{words}");
                assert_eq!(row["fix"], "cmux remote-host grants --device studio --open");
            } else {
                assert!(row.get("missing").is_none());
            }
        }
    }
    assert!(GRANTS[0].pane.ends_with("Privacy_ScreenCapture"));
    assert!(GRANTS[1].pane.ends_with("Privacy_Accessibility"));
}

#[test]
fn a_mac_without_cmux_remote_reads_unknown_not_granted() {
    let probe = parse_probe(&output("", "", "off", "closed"));
    let report = report(None, &probe);
    assert_eq!(report["cmux_remote"], false);
    assert_eq!(report["missing"], json!([]));
    let row = row(&report, "screen-recording");
    assert_eq!(row["granted"], Value::Null);
    assert!(row["missing"].as_str().unwrap().starts_with("Unknown on this Mac"));
    assert_eq!(row["fix"], "cmux remote-host open-settings screen-recording");
}

#[test]
fn reads_screen_sharing_and_remote_management() {
    let cases = [
        // (launchd line, ard, vnc) -> (screen_sharing, remote_management, can click)
        (r#""com.apple.screensharing" => enabled"#, "off", "open", Some(true), false, true),
        (r#""com.apple.screensharing" => false"#, "off", "closed", Some(true), false, true),
        (r#""com.apple.screensharing" => disabled"#, "off", "closed", Some(false), false, false),
        (r#""com.apple.screensharing" => true"#, "on", "closed", Some(false), true, true),
        ("", "off", "closed", None, false, false),
    ];
    for (line, ard, vnc, sharing, management, click) in cases {
        let probe = parse_probe(&output(&status(false, true), line, ard, vnc));
        assert_eq!(probe.access.screen_sharing, sharing, "{line}");
        assert_eq!(probe.access.remote_management, Some(management), "{line}");
        let report = report(Some("studio"), &probe);
        assert_eq!(report["screen_access"]["agent_can_click"], click, "{line}");
        let words = report["screen_access"]["words"].as_str().unwrap();
        assert_eq!(
            words.starts_with("An agent can click this grant over screen sharing with your OK"),
            click,
            "{words}"
        );
        if management {
            assert!(words.contains("Remote Management"), "{words}");
        }
    }
}

#[test]
fn open_opens_the_first_missing_grant_on_that_mac() {
    let missing = output(&status(false, false), "", "off", "closed");
    let fake = Fake::new(&[missing.clone(), missing]);
    let report = grants(&fake, Some("studio"), true).unwrap();
    let scripts = fake.scripts.borrow();
    assert_eq!(scripts.len(), 2);
    assert!(scripts[0].starts_with("OPEN=''\n"));
    assert!(scripts[1].starts_with("OPEN='screen-recording'\n"));
    assert_eq!(report["opened"], json!(["screen-recording"]));
}

#[test]
fn open_with_nothing_missing_opens_nothing() {
    let fake = Fake::new(&[output(&status(true, true), "", "off", "closed")]);
    let report = grants(&fake, None, true).unwrap();
    assert_eq!(fake.scripts.borrow().len(), 1);
    assert_eq!(report["opened"], json!([]));
}

#[test]
fn an_unreachable_mac_is_an_error() {
    let fake = Fake::new(&[]);
    let error = grants(&fake, Some("studio"), false).unwrap_err();
    assert_eq!(error["code"], "grants.unreachable");
}

#[test]
fn routes_through_the_devices_acpmux_peer() {
    let peers = json!({"peers": [
        {"name": "studio", "url": "ssh://leo@studio.tail1234.ts.net:2222"},
        {"name": "vm-1", "url": "ssh://[fd7a::1]:22"},
        {"name": "sandbox", "url": "ws://127.0.0.1:47811"}
    ]});
    assert_eq!(
        route(&peers, "Studio"),
        Route { target: "leo@studio.tail1234.ts.net".into(), port: Some(2222) }
    );
    assert_eq!(route(&peers, "peer:studio").target, "leo@studio.tail1234.ts.net");
    assert_eq!(route(&peers, "vm-1"), Route { target: "fd7a::1".into(), port: Some(22) });
    // Not an ssh peer, or not a peer: the name itself, as an ssh host or alias.
    assert_eq!(route(&peers, "sandbox"), Route { target: "sandbox".into(), port: None });
    assert_eq!(route(&Value::Null, "laptop"), Route { target: "laptop".into(), port: None });
}

#[test]
fn the_probe_takes_only_a_fixed_grant_word() {
    assert!(script(None).starts_with("OPEN=''\n"));
    for grant in &GRANTS {
        assert!(script(Some(grant)).starts_with(&format!("OPEN='{}'\n", grant.key)));
    }
}

/// A NIGHTLY-style status: no cmux Remote embedded, the app's own grants (if reported).
fn app_status(app: Option<(bool, bool)>, host: Option<(bool, bool)>, bundled: bool) -> String {
    let mut status = json!({"state": "off", "bundled": bundled});
    if let Some((screen, accessibility)) = app {
        status["app"] = json!({"permissions": {
            "screen_recording": screen, "accessibility": accessibility}});
    }
    if let Some((screen, accessibility)) = host {
        status["state"] = json!("running");
        status["host"] = json!({"permissions": {
            "screen_recording": screen, "accessibility": accessibility}});
    }
    status.to_string()
}

#[test]
fn without_cmux_remote_the_apps_own_grants_answer() {
    let probe =
        parse_probe(&output(&app_status(Some((false, true)), None, false), "", "off", "closed"));
    assert_eq!(
        first_missing(probe.status.as_ref()).map(|grant| grant.key),
        Some("screen-recording")
    );
    let report = report(None, &probe);
    assert_eq!(report["missing"], json!(["screen-recording"]));
    let screen = row(&report, "screen-recording");
    assert_eq!(screen["granted"], false);
    assert_eq!(screen["holder"], "cmux app");
    let words = screen["missing"].as_str().unwrap();
    assert!(words.starts_with("Missing on this Mac: Screen Recording for cmux ("), "{words}");
    assert!(
        words.contains(
            "Turn on cmux in System Settings > Privacy & Security > Screen Recording on this Mac."
        ),
        "{words}"
    );
    assert!(!words.contains("cmux Remote"), "{words}");
    assert_eq!(screen["fix"], format!("open '{}'", GRANTS[0].pane));
    let accessibility = row(&report, "accessibility");
    assert_eq!(accessibility["granted"], true);
    assert_eq!(accessibility["holder"], "cmux app");
    assert!(accessibility.get("missing").is_none());
}

#[test]
fn cmux_remotes_own_reading_wins_over_the_apps() {
    let probe = parse_probe(&output(
        &app_status(Some((true, true)), Some((false, true)), true),
        "",
        "off",
        "closed",
    ));
    let report = report(Some("studio"), &probe);
    let screen = row(&report, "screen-recording");
    assert_eq!(screen["granted"], false);
    assert_eq!(screen["holder"], "cmux Remote");
    assert!(screen["missing"].as_str().unwrap().contains("for cmux Remote ("));
    assert_eq!(report["missing"], json!(["screen-recording"]));
}

#[test]
fn neither_reported_reads_unknown_and_names_the_holder() {
    // No cmux Remote embedded and the app has not reported: unknown, about the app.
    let report =
        report(None, &parse_probe(&output(&app_status(None, None, false), "", "off", "closed")));
    let screen = row(&report, "screen-recording");
    assert_eq!(screen["granted"], Value::Null);
    assert_eq!(screen["holder"], "cmux app");
    assert!(screen["missing"].as_str().unwrap().starts_with("Unknown on this Mac: the cmux app"));
    assert_eq!(report["missing"], json!([]));
    // cmux Remote embedded but stopped: the app's reading is not cmux Remote's grant.
    let probe =
        parse_probe(&output(&app_status(Some((true, true)), None, true), "", "off", "closed"));
    assert_eq!(first_missing(probe.status.as_ref()), None);
    let stopped = super::report(None, &probe);
    let screen = row(&stopped, "screen-recording");
    assert_eq!(screen["granted"], Value::Null);
    assert_eq!(screen["holder"], "cmux Remote");
    assert!(screen["missing"].as_str().unwrap().starts_with("Unknown on this Mac: cmux Remote"));
}

#[test]
fn the_probe_opens_the_same_panes_without_cmux_remote() {
    for grant in &GRANTS {
        assert!(PROBE.contains(&format!("{}) pane='{}'", grant.key, grant.pane)), "{}", grant.key);
    }
}

#[test]
fn the_screen_sharing_helpers_own_reading_names_the_item_that_captures() {
    // NIGHTLY: no cmux Remote; the helper read its own grants when a share started it, and that
    // reading wins over the app's (the app is not what captures a device hub share).
    let share_host = json!({"helper": {"permissions": {
        "screen_recording": false, "accessibility": true, "listed_as": "cmux NIGHTLY Screen Sharing"}}});
    let probe = parse_probe(&format!(
        "{}sharehost\t{share_host}\n",
        output(&app_status(Some((true, true)), None, false), "", "off", "closed")
    ));
    assert_eq!(
        first_missing(probe.status.as_ref()).map(|grant| grant.key),
        Some("screen-recording")
    );
    let report = report(Some("studio"), &probe);
    let screen = row(&report, "screen-recording");
    assert_eq!(screen["granted"], false, "the helper's reading, not the app's");
    assert_eq!(screen["holder"], "Screen Sharing helper");
    assert_eq!(
        screen["missing"],
        "Screen Recording not granted on studio: on studio, open System Settings > Privacy & Security > \
         Screen & System Audio Recording and turn on \"cmux NIGHTLY Screen Sharing\" (Screen Sharing and \
         Computer Use screenshots)."
    );
    assert_eq!(row(&report, "accessibility")["granted"], true);

    // No helper reading yet: the app's reading answers, as before.
    let probe = parse_probe(&format!(
        "{}sharehost\t{}\n",
        output(&app_status(Some((false, true)), None, false), "", "off", "closed"),
        json!({"helper": {"permissions": null}})
    ));
    assert_eq!(row(&super::report(None, &probe), "screen-recording")["holder"], "cmux app");
    // A share host status with no cmux status is not a cmux Remote reading.
    let probe = parse_probe(&format!("status\t\nsharehost\t{share_host}\n"));
    assert_eq!(probe.status, None);
}
