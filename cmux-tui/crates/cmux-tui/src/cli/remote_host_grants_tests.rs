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
