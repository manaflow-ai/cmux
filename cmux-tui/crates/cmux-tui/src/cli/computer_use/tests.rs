use serde_json::json;

use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn parsed(text: &str) -> Result<Command, String> {
    parse(&words(text))
}

#[test]
fn every_documented_command_parses() {
    assert_eq!(parsed("status"), Ok(Command::Status));
    assert_eq!(parsed("tools"), Ok(Command::Tools));
    assert_eq!(parsed(""), Ok(Command::Help));
    assert_eq!(parsed("--help"), Ok(Command::Help));
    assert_eq!(parsed("approvals list"), Ok(Command::List));
    assert_eq!(parsed("approvals pending"), Ok(Command::Pending));
    assert_eq!(parsed("approvals revoke --all"), Ok(Command::Revoke { app: None }));
    assert_eq!(
        parsed("approvals revoke com.apple.Safari"),
        Ok(Command::Revoke { app: Some("com.apple.Safari".into()) })
    );
    assert_eq!(parsed("approvals approve q7"), Ok(Command::Approve { id: "q7".into() }));
    assert_eq!(parsed("approvals deny q7"), Ok(Command::Deny { id: "q7".into() }));
}

#[test]
fn call_and_screenshot_take_a_json_object() {
    let call = parse(&["call".into(), "click".into(), "--args".into(), r#"{"pid": 42}"#.into()]);
    assert_eq!(call, Ok(Command::Call { tool: "click".into(), arguments: json!({"pid": 42}) }));
    assert_eq!(
        parsed("call click"),
        Ok(Command::Call { tool: "click".into(), arguments: json!({}) })
    );
    assert!(parse(&["call".into(), "click".into(), "--args".into(), "[1]".into()]).is_err());
    assert!(parsed("call --args").is_err());
    assert_eq!(
        parsed("screenshot --out /tmp/s.png"),
        Ok(Command::Screenshot { out: "/tmp/s.png".into(), arguments: json!({}) })
    );
    let screenshot = parse(&words("screenshot --args {} --out a.png"));
    assert_eq!(screenshot, Ok(Command::Screenshot { out: "a.png".into(), arguments: json!({}) }));
    assert!(parsed("screenshot").is_err());
    assert!(parsed("screenshot --out a.png --out b.png").is_err());
}

#[test]
fn approving_takes_no_decision_and_unknown_words_are_refused() {
    for text in [
        "approvals approve q7 --always",
        "approvals approve",
        "approvals allow q7",
        "approvals grant q7",
        "approvals revoke",
        "approvals revoke --everything",
        "mode unrestricted",
        "status extra",
    ] {
        assert!(parsed(text).is_err(), "{text}");
    }
}

#[test]
fn setup_parses_modes_and_keeps_manifests_to_bounded() {
    let setup = |text: &str| match parsed(text) {
        Ok(Command::Setup(setup)) => Ok(setup),
        Ok(other) => panic!("{other:?}"),
        Err(e) => Err(e),
    };
    assert_eq!(setup("setup --mode ask").unwrap().mode, Mode::Ask);
    assert_eq!(setup("setup --mode standard").unwrap().mode, Mode::Standard);
    let bounded = setup("setup --manifest m.json --mode bounded").unwrap();
    assert_eq!(bounded.manifest.as_deref(), Some(std::path::Path::new("m.json")));
    assert!(!bounded.elevated);
    assert!(setup("setup --mode ask --manifest m.json").is_err());
    assert!(setup("setup --mode everything").is_err());
    assert!(setup("setup").is_err());
    let unrestricted = setup("setup --mode unrestricted --i-understand-unrestricted").unwrap();
    assert!(unrestricted.understand_unrestricted);
}

#[test]
fn unrestricted_needs_both_env_vars_and_the_flag() {
    let both = |key: &str| match key {
        "CUA_DRIVER_PERMISSION_MODE" => Some("unrestricted".to_owned()),
        "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS" => Some("1".to_owned()),
        _ => None,
    };
    let one = |key: &str| (key == "CUA_DRIVER_PERMISSION_MODE").then(|| "unrestricted".to_owned());
    let setup = |flag: bool| Setup {
        mode: Mode::Unrestricted,
        manifest: None,
        understand_unrestricted: flag,
        elevated: false,
    };
    assert_eq!(unrestricted_refusal(&setup(true), both), None);
    assert!(unrestricted_refusal(&setup(false), both).is_some());
    assert!(unrestricted_refusal(&setup(true), one).is_some());
    assert!(unrestricted_refusal(&setup(true), |_| None).is_some());
    let ask = Setup { mode: Mode::Ask, ..setup(false) };
    assert_eq!(unrestricted_refusal(&ask, |_| None), None);
}

#[cfg(unix)]
#[test]
fn a_tool_result_prints_text_and_names_images() {
    let result = json!({"content": [
        {"type": "text", "text": "clicked"},
        {"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}]});
    let text = driver::result_text(&result);
    assert!(text.starts_with("clicked\n[image/png image, 12 base64 characters"), "{text}");
}

#[cfg(unix)]
#[test]
fn a_screenshot_is_the_first_image_or_the_refusal_text() {
    let ok = json!({"content": [{"type": "text", "text": "x"},
        {"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}]});
    let (bytes, mime) = driver::screenshot_image(&ok).unwrap();
    assert_eq!(&bytes[..4], b"\x89PNG");
    assert_eq!(mime, "image/png");
    let refused = acpmux::cua_v2::ApprovalRefusal::Timeout.tool_result(Some("Finder"));
    let why = driver::screenshot_image(&refused).unwrap_err();
    assert!(why.contains("stays open there for 10 minutes"), "{why}");
    assert!(driver::screenshot_image(&json!({"content": []})).is_err());
}

#[cfg(not(target_os = "macos"))]
mod system {
    use super::super::system_config::{document, elevated_args, read_manifest};
    use super::*;

    #[test]
    fn the_config_carries_the_mode_manifest_and_unrestricted_opt_in() {
        assert_eq!(document(Mode::Ask, None), json!({"version": 1, "mode": "ask"}));
        let manifest = json!({"version": 3, "resources": {"apps": ["firefox"]}});
        assert_eq!(
            document(Mode::Bounded, Some(manifest.clone())),
            json!({"version": 1, "mode": "bounded", "manifest": manifest})
        );
        assert_eq!(
            document(Mode::Unrestricted, None),
            json!({"version": 1, "mode": "unrestricted", "env": {
                "CUA_DRIVER_PERMISSION_MODE": "unrestricted",
                "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS": "1"}})
        );
        assert!(document(Mode::Standard, None).get("env").is_none());
    }

    #[test]
    fn the_elevated_run_repeats_the_setup_with_an_absolute_manifest() {
        let setup = Setup {
            mode: Mode::Bounded,
            manifest: Some("m.json".into()),
            understand_unrestricted: false,
            elevated: false,
        };
        let args = elevated_args(&setup).unwrap();
        assert_eq!(&args[..4], ["computer-use", "setup", "--mode", "bounded"]);
        assert_eq!(args[4], "--manifest");
        assert!(std::path::Path::new(&args[5]).is_absolute(), "{args:?}");
        assert_eq!(args.last().map(String::as_str), Some(ELEVATED_FLAG));
        // The elevated words parse back to the same setup.
        let Ok(Command::Setup(back)) = parse(&args[1..]) else { panic!("{args:?}") };
        assert_eq!(back.mode, Mode::Bounded);
        assert!(back.elevated);
    }

    #[test]
    fn a_manifest_must_be_a_version_3_object() {
        let dir = std::env::temp_dir().join(format!("cu-manifest-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("m.json");
        for (text, ok) in [
            (r#"{"version": 3, "resources": {}}"#, true),
            (r#"{"version": 2}"#, false),
            ("[]", false),
            ("not json", false),
        ] {
            std::fs::write(&file, text).unwrap();
            assert_eq!(read_manifest(&file).is_ok(), ok, "{text}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
