//! The alert tools on the fake desktop. The cases are the build fleet's own
//! (cmuxterm-hq build-fleet/pr_capture/popup_shot_test.py and the incidents
//! in docs/handbook/prompt-on-an-unattended-screen.md), so the fleet's
//! `clear-alerts` can call these tools and keep what it learned.

use std::sync::Arc;

use serde_json::{Value, json};

use crate::alerts::{self, RawAlert};
use crate::desktop::fake::{Event, FakeDesktop};
use crate::engine::{CallContext, Engine, EngineParts, OriginKind, ToolOutput};
use crate::policy::{Mode, PolicyConfig};

fn ctx() -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: None,
        origin: OriginKind::Local,
        tag: None,
    }
}

fn on() -> PolicyConfig {
    PolicyConfig { alerts: true, ..PolicyConfig::default() }
}

fn alert(id: &str, owner: &str, texts: &[&str], buttons: &[&str]) -> RawAlert {
    RawAlert {
        window_id: id.into(),
        pid: 500,
        owner: owner.into(),
        layer: 8,
        texts: texts.iter().map(|t| (*t).to_string()).collect(),
        buttons: buttons.iter().map(|b| (*b).to_string()).collect(),
        ..RawAlert::default()
    }
}

fn engine(config: PolicyConfig, alerts: Vec<RawAlert>) -> (Arc<FakeDesktop>, Engine) {
    let d = Arc::new(FakeDesktop::standard());
    *d.alerts.lock().unwrap() = alerts;
    let mut parts = EngineParts::new(d.clone());
    parts.config = config;
    parts.sleep = Arc::new(|_| {});
    (d, Engine::new(parts))
}

fn dismiss(e: &Engine, id: &str, button: &str) -> ToolOutput {
    e.call(&ctx(), "dismiss_alert", &json!({"alert_id": id, "button": button}))
}

fn presses(d: &FakeDesktop) -> Vec<(String, String)> {
    d.events()
        .into_iter()
        .filter_map(|e| match e {
            Event::AlertPress { alert, button } => Some((alert, button)),
            _ => None,
        })
        .collect()
}

fn code(out: &ToolOutput) -> Option<&str> {
    out.code.as_deref()
}

/// One alert on screen: the buttons that put it off, then every button it
/// has that must be refused.
fn case(a: RawAlert, class: &str, put_off: &[&str]) {
    let (d, e) = engine(on(), vec![a.clone()]);
    let listed = e.call(&ctx(), "list_alerts", &json!({}));
    assert!(!listed.is_error, "{:?}", listed.body);
    let row = &listed.body["alerts"][0];
    assert_eq!(row["class"], class, "{row}");
    assert_eq!(row["put_off"], json!(put_off), "{row}");
    assert_eq!(row["owner"], json!(a.owner));
    for button in &a.buttons {
        if put_off.contains(&button.as_str()) {
            continue;
        }
        let out = dismiss(&e, &a.window_id, button);
        assert!(out.is_error, "{button} on {class}: {:?}", out.body);
        let want: &[&str] = if put_off.is_empty() {
            &[alerts::CODE_UNKNOWN, alerts::CODE_BUTTON]
        } else {
            &[alerts::CODE_BUTTON]
        };
        assert!(want.contains(&code(&out).unwrap()), "{button} on {class}: {:?}", out.body);
        let message = out.body["error"].as_str().unwrap();
        assert!(message.contains(&a.owner) && message.contains(class), "{message}");
        assert_eq!(out.body["alert"]["alert_id"], json!(a.window_id));
    }
    assert!(presses(&d).is_empty(), "{class}: {:?}", d.events());
    if let Some(first) = put_off.first() {
        let out = dismiss(&e, &a.window_id, first);
        assert!(!out.is_error, "{first} on {class}: {:?}", out.body);
        assert_eq!(out.body["pressed"], json!(first));
        assert_eq!(out.body["dismissed"], true);
        assert_eq!(presses(&d), [(a.window_id, (*first).to_string())]);
        assert_eq!(e.call(&ctx(), "list_alerts", &json!({})).body["alerts"], json!([]));
    }
}

#[test]
fn off_by_default_both_tools_answer_alerts_off_naming_the_setting() {
    let a = alert(
        "900",
        "UserNotificationCenter",
        &["cmux quit unexpectedly."],
        &["Ignore", "Report…"],
    );
    let (d, e) = engine(PolicyConfig::default(), vec![a]);
    for (tool, args) in [
        ("list_alerts", json!({})),
        ("dismiss_alert", json!({"alert_id": "900", "button": "Ignore"})),
        // The gate answers before the arguments are read.
        ("dismiss_alert", json!({})),
    ] {
        let out = e.call(&ctx(), tool, &args);
        assert_eq!(code(&out), Some("alerts_off"), "{tool}: {:?}", out.body);
        assert_eq!(out.body["setting"], "computerUse.alerts");
        assert!(out.body["error"].as_str().unwrap().contains("computerUse.alerts"));
        assert!(out.body.get("alerts").is_none(), "nothing is read while off");
    }
    assert!(d.events().is_empty());
    assert_eq!(e.call(&ctx(), "status", &json!({})).body["alerts"], false);
    assert!(!PolicyConfig::default().alerts && !PolicyConfig::cloud_vm().alerts);
}

/// popup_shot_test.py test_cmux19s_redacted_keychain_not_found_gets_cancel_never_reset_to_defaults:
/// cmux19's panel read no text at all, only its two buttons.
#[test]
fn cmux19s_redacted_keychain_not_found_gets_cancel_never_reset_to_defaults() {
    case(
        alert("901", "SecurityAgent", &[], &["Cancel", "Reset To Defaults"]),
        "keychain-not-found",
        &["Cancel"],
    );
    case(
        alert(
            "902",
            "SecurityAgent",
            &["Keychain Not Found", "A keychain cannot be found to store “Chromium”."],
            &["Reset To Defaults", "Cancel"],
        ),
        "keychain-not-found",
        &["Cancel"],
    );
    let (d, e) =
        engine(on(), vec![alert("901", "SecurityAgent", &[], &["Cancel", "Reset To Defaults"])]);
    let out = dismiss(&e, "901", "Reset To Defaults");
    assert_eq!(code(&out), Some("alert_button_refused"), "{:?}", out.body);
    assert!(out.body["error"].as_str().unwrap().contains("SecurityAgent"));
    assert!(presses(&d).is_empty());
}

/// Every other SecurityAgent or coreautha panel asks for a password: no
/// button of it is pressed, Cancel included.
#[test]
fn a_password_panel_is_never_pressed() {
    case(
        alert(
            "903",
            "SecurityAgent",
            &[
                "cmux wants to use your confidential information stored in “login” in your keychain.",
            ],
            &["Always Allow", "Deny", "Allow"],
        ),
        "keychain",
        &[],
    );
    // Cancel beside Reset To Defaults, but a password field: not Keychain Not Found.
    let mut field = alert("904", "SecurityAgent", &[], &["Cancel", "Reset To Defaults"]);
    field.secure_field = true;
    case(field, "keychain", &[]);
    // A text that is not the missing-keychain one.
    case(
        alert(
            "905",
            "SecurityAgent",
            &["Enter your password to allow this."],
            &["Cancel", "Reset To Defaults", "OK"],
        ),
        "keychain",
        &[],
    );
    case(
        alert(
            "906",
            "coreautha",
            &["Touch ID or enter your password"],
            &["Cancel", "Use Password…"],
        ),
        "password",
        &[],
    );
    // An Apple Account ask shown by SecurityAgent is a password panel too.
    case(
        alert(
            "907",
            "SecurityAgent",
            &["Enter the password for your Apple Account"],
            &["Cancel", "Sign In"],
        ),
        "apple-password",
        &[],
    );
    // A password field on any owner's panel: nothing is pressed, though the
    // same ask with no field is put off with Not Now.
    for owner in ["UserNotificationCenter", "AuthKitUIService", "akd", "loginwindow"] {
        let mut field = alert(
            "908",
            owner,
            &["Enter the password for your Apple Account “a@b.c”."],
            &["Not Now", "Cancel", "Continue"],
        );
        field.secure_field = true;
        let class = alerts::classify(&field);
        case(field.clone(), class, &[]);
        let (d, e) = engine(on(), vec![field]);
        let out = dismiss(&e, "908", "Not Now");
        assert_eq!(code(&out), Some("alert_unknown"), "{owner}: {:?}", out.body);
        assert!(presses(&d).is_empty());
    }
}

/// popup_shot_test.py test_app_not_responding_is_put_off_with_ok.
#[test]
fn app_not_responding_is_put_off_with_ok() {
    case(
        alert(
            "910",
            "CoreServicesUIAgent",
            &["You can’t open the application “Safari” because it is not responding."],
            &["OK"],
        ),
        "not-responding",
        &["OK"],
    );
}

#[test]
fn the_fleets_known_alerts_are_put_off_with_their_own_button() {
    case(
        alert(
            "911",
            "UserNotificationCenter",
            &[
                "This Mac can’t connect to iCloud because of a problem with a@b.c.",
                "Open iCloud settings to fix this problem.",
            ],
            &["Later", "iCloud Settings…"],
        ),
        "icloud-sign-in",
        &["Later"],
    );
    case(
        alert(
            "912",
            "CoreServicesUIAgent",
            &["The application “cmux DEV” can’t be opened."],
            &["OK"],
        ),
        "cant-be-opened",
        &["OK"],
    );
    // A crash notice: Ignore (or OK), never Report or Reopen.
    case(
        alert(
            "913",
            "UserNotificationCenter",
            &["cmux quit unexpectedly."],
            &["Ignore", "Report…", "Reopen"],
        ),
        "crash-report",
        &["Ignore"],
    );
    case(
        alert("914", "UserNotificationCenter", &["Finder quit unexpectedly."], &["OK", "Reopen"]),
        "crash-report",
        &["OK"],
    );
    // An Apple Account password ask: Not Now, never Sign In or Continue.
    case(
        alert(
            "915",
            "UserNotificationCenter",
            &["Enter the password for your Apple Account “a@b.c” in System Settings."],
            &["Not Now", "Continue"],
        ),
        "apple-password",
        &["Not Now"],
    );
    // Gatekeeper: Cancel, never Open.
    case(
        alert(
            "916",
            "CoreServicesUIAgent",
            &["“cmux” is an app downloaded from the Internet. Are you sure you want to open it?"],
            &["Cancel", "Open", "Show Web Page"],
        ),
        "gatekeeper",
        &["Cancel"],
    );
    // The out-of-memory panel: Cancel or its close button, never Force Quit or Relaunch.
    case(
        alert(
            "917",
            "loginwindow",
            &["Your system has run out of application memory."],
            &["Force Quit", "Relaunch", "Resume", "Close"],
        ),
        "out-of-memory",
        &["Close"],
    );
    // Privacy asks: refuse, never Allow or Open System Settings.
    case(
        alert(
            "918",
            "universalAccessAuthWarn",
            &["“bash” would like to record this computer’s screen and audio."],
            &["Open System Settings", "Deny"],
        ),
        "screen-recording",
        &["Deny"],
    );
    case(
        alert(
            "919",
            "UserNotificationCenter",
            &["“worker-1a2b” would like to access your photo library."],
            &["Don’t Allow", "Allow Full Access", "Limit Access…"],
        ),
        "protected-folder",
        &["Don’t Allow"],
    );
}

/// What the fleet leaves for a person stays for a person, by name.
#[test]
fn an_alert_with_no_put_off_rule_is_refused_by_name() {
    // The screen-capture picker ask has only Allow and Open System Settings.
    case(
        alert(
            "920",
            "UserNotificationCenter",
            &[
                "“bash” is requesting to bypass the system private window picker and directly access your screen and audio.",
            ],
            &["Allow", "Open System Settings"],
        ),
        "screen-picker",
        &[],
    );
    case(
        alert(
            "921",
            "UserNotificationCenter",
            &["“Tailscale” Would Like to Add VPN Configurations"],
            &["Allow", "Don’t Allow"],
        ),
        "vpn-configuration",
        &[],
    );
    case(
        alert(
            "922",
            "UserNotificationCenter",
            &["Something nobody has seen before"],
            &["OK", "Cancel"],
        ),
        "other",
        &[],
    );
    // Gatekeeper with no Cancel: its only button opens the app.
    case(
        alert(
            "923",
            "CoreServicesUIAgent",
            &["“cmux” is an app downloaded from the Internet."],
            &["Open"],
        ),
        "gatekeeper",
        &[],
    );
    let unknown = alert(
        "922",
        "UserNotificationCenter",
        &["Something nobody has seen before"],
        &["OK", "Cancel"],
    );
    let (d, e) = engine(on(), vec![unknown]);
    let out = dismiss(&e, "922", "OK");
    assert_eq!(code(&out), Some("alert_unknown"), "{:?}", out.body);
    let message = out.body["error"].as_str().unwrap();
    assert!(message.contains("alert 922 of UserNotificationCenter"), "{message}");
    assert!(message.contains("something nobody has seen before"), "{message}");
    assert!(presses(&d).is_empty());
}

#[test]
fn a_gone_alert_and_missing_arguments_are_typed() {
    let a = alert("930", "UserNotificationCenter", &["cmux quit unexpectedly."], &["Ignore"]);
    let (d, e) = engine(on(), vec![a]);
    assert_eq!(code(&dismiss(&e, "931", "Ignore")), Some("alert_not_found"));
    assert_eq!(
        code(&e.call(&ctx(), "dismiss_alert", &json!({"alert_id": "930"}))),
        Some("invalid_arguments")
    );
    assert_eq!(
        code(&e.call(&ctx(), "dismiss_alert", &json!({"button": "Ignore"}))),
        Some("invalid_arguments")
    );
    assert!(presses(&d).is_empty());
    // A second press of the same alert finds it gone.
    assert!(!dismiss(&e, "930", "Ignore").is_error);
    assert_eq!(code(&dismiss(&e, "930", "Ignore")), Some("alert_not_found"));
    assert_eq!(presses(&d).len(), 1);
}

/// The setting adds two tools and changes nothing else: the mode still
/// applies to them, and every other tool still refuses those processes.
#[test]
fn the_mode_still_applies_and_other_tools_still_refuse_the_protected_processes() {
    let a = alert("940", "UserNotificationCenter", &["cmux quit unexpectedly."], &["Ignore"]);
    let (d, e) = engine(PolicyConfig { mode: Mode::Off, ..on() }, vec![a.clone()]);
    assert_eq!(code(&e.call(&ctx(), "list_alerts", &json!({}))), Some("computer_use_off"));
    assert_eq!(code(&dismiss(&e, "940", "Ignore")), Some("computer_use_off"));
    assert!(d.events().is_empty());
    let (d, e) = engine(PolicyConfig { mode: Mode::LookOnly, ..on() }, vec![a.clone()]);
    assert!(!e.call(&ctx(), "list_alerts", &json!({})).is_error);
    assert_eq!(code(&dismiss(&e, "940", "Ignore")), Some("look_only"));
    assert!(d.events().is_empty());

    // A window of each alert owner, as the window list would give it.
    let mut fake = FakeDesktop::standard();
    let owners =
        ["com.apple.SecurityAgent", "com.apple.UserNotificationCenter", "com.apple.loginwindow"];
    for (i, owner) in owners.iter().enumerate() {
        let mut w = fake.windows[1].clone();
        w.id = format!("5{i}");
        w.app_id = (*owner).to_string();
        w.pid = 600 + i as u32;
        fake.windows.push(w);
    }
    *fake.alerts.lock().unwrap() = vec![a];
    let d = Arc::new(fake);
    let mut parts = EngineParts::new(d.clone());
    parts.config = on();
    parts.sleep = Arc::new(|_| {});
    let e = Engine::new(parts);
    for (i, owner) in owners.iter().enumerate() {
        let id = format!("5{i}");
        let calls: [(&str, Value); 4] = [
            ("click", json!({"window_id": id, "x": 10.0, "y": 300.0})),
            ("type_text", json!({"window_id": id, "text": "hunter2"})),
            ("get_ui_tree", json!({"window_id": id})),
            ("screenshot", json!({"window_id": id})),
        ];
        for (tool, args) in calls {
            let out = e.call(&ctx(), tool, &args);
            assert_eq!(code(&out), Some("app_protected"), "{tool} on {}: {:?}", owner, out.body);
        }
    }
    assert!(d.events().is_empty(), "{:?}", d.events());
}
