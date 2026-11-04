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

fn plain_setup() -> Setup {
    Setup {
        mode: Mode::Ask,
        manifest: None,
        understand_unrestricted: false,
        elevated: false,
        device_hub: None,
        hub_token_command: None,
        hub_allow_always: false,
        approvers: Vec::new(),
        #[cfg(not(target_os = "macos"))]
        approver_pins: Vec::new(),
        reload_endpoint: None,
    }
}

#[cfg(not(target_os = "macos"))]
#[test]
fn approvers_come_with_a_hub_and_pins_are_checked() {
    let setup = |text: &str| match parsed(text) {
        Ok(Command::Setup(setup)) => Ok(setup),
        Ok(other) => panic!("{other:?}"),
        Err(e) => Err(e),
    };
    let hub = "--device-hub https://hub.example --hub-token-command /usr/bin/hub-token";
    let two = setup(&format!("setup --mode ask {hub} --approver a1 --approver b2")).unwrap();
    assert_eq!(two.approvers, ["a1", "b2"]);
    assert_eq!(two.device_hub.as_deref(), Some("https://hub.example"));
    assert!(setup("setup --mode ask --approver a1").is_err(), "no hub");
    assert!(setup("setup --mode ask --device-hub http://hub.example --hub-token-command /t").is_err());
    assert!(setup("setup --mode ask --device-hub https://hub.example --hub-token-command t").is_err());
    assert!(setup("setup --mode ask --device-hub https://hub.example").is_err());
    let fingerprint = "a".repeat(64);
    let pin = format!(r#"{{"device_id":"d1","approval_key_fingerprint":"{fingerprint}","name":"iPhone","platform":"ios"}}"#);
    let words: Vec<String> = ["setup", "--mode", "ask", "--device-hub", "https://hub.example", "--hub-token-command", "/t", "--approver-pin", &pin]
        .iter()
        .map(|word| (*word).to_owned())
        .collect();
    let Ok(Command::Setup(pinned)) = parse(&words) else { panic!() };
    assert_eq!(pinned.approver_pins[0].device_id, "d1");
    let short = pin.replace(&fingerprint, "abc");
    let mut bad = words;
    if let Some(last) = bad.last_mut() {
        *last = short;
    }
    assert!(parse(&bad).is_err());
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
        understand_unrestricted: flag,
        ..plain_setup()
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
    use super::super::system_config::{
        DeviceHub, Pin, SystemConfig, config, elevated_args, pins_of, read_manifest,
        reload_endpoint_of, render,
    };
    use super::*;

    /// The shared fixture: what setup writes is exactly what the host's
    /// parser reads back (`cmux-remote-host` `config.rs` tests the same files).
    #[test]
    fn setup_writes_the_documents_the_host_reads() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../schemas/computer-use/setup-config");
        let cases: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join("cases.json")).unwrap())
                .unwrap();
        for case in cases["cases"].as_array().unwrap() {
            let file = case["file"].as_str().unwrap();
            let mode = Mode::parse(case["mode"].as_str().unwrap()).unwrap();
            let manifest = case["manifest"].as_str().map(std::path::PathBuf::from);
            let hub: Option<DeviceHub> = serde_json::from_value(case["device_hub"].clone()).unwrap();
            let pins: Vec<Pin> = serde_json::from_value(case["approvers"].clone()).unwrap();
            let written = render(&config(mode, manifest.as_deref(), hub, pins)).unwrap();
            let expected = std::fs::read_to_string(dir.join(file)).unwrap();
            let written: toml::Value = toml::from_str(&written).unwrap();
            let expected: toml::Value = toml::from_str(&expected).unwrap();
            assert_eq!(written, expected, "{file}");
            // And it reads back as setup's own type (setup keeps pins across runs).
            let back: SystemConfig = written.try_into().unwrap();
            assert_eq!(back.mode, mode.name());
        }
    }

    #[test]
    fn the_elevated_run_repeats_the_setup_with_an_absolute_manifest_and_the_pins() {
        let setup = Setup {
            mode: Mode::Bounded,
            manifest: Some("m.json".into()),
            device_hub: Some("https://hub.example".into()),
            hub_token_command: Some("/usr/bin/hub-token".into()),
            hub_allow_always: true,
            approvers: vec!["d1".into()],
            ..plain_setup()
        };
        let pin = Pin {
            device_id: "d1".into(),
            approval_key_fingerprint: "b".repeat(64),
            name: "Aziz's iPhone".into(),
            platform: "ios".into(),
        };
        let endpoint = if cfg!(windows) {
            std::path::PathBuf::from(r"\\.\pipe\cmux-remote-rh-0123")
        } else {
            std::path::PathBuf::from("/run/user/1000/cmux/rh-0123/s.sock")
        };
        let args = elevated_args(&setup, std::slice::from_ref(&pin), Some(&endpoint)).unwrap();
        assert_eq!(&args[..4], ["computer-use", "setup", "--mode", "bounded"]);
        assert_eq!(args[4], "--manifest");
        assert!(std::path::Path::new(&args[5]).is_absolute(), "{args:?}");
        assert!(!args.contains(&"--approver".to_owned()), "the elevated run never asks the hub again");
        assert_eq!(args.last().map(String::as_str), Some(ELEVATED_FLAG));
        // The elevated words parse back to the same setup, with the confirmed pin.
        let Ok(Command::Setup(back)) = parse(&args[1..]) else { panic!("{args:?}") };
        assert_eq!(back.mode, Mode::Bounded);
        assert!(back.elevated && back.hub_allow_always);
        assert_eq!(back.approver_pins, vec![pin]);
        assert_eq!(back.device_hub, setup.device_hub);
        assert_eq!(back.reload_endpoint.as_deref(), Some(endpoint.as_path()), "the elevated run reloads that host");
        let without = elevated_args(&setup, &[], None).unwrap();
        assert!(!without.contains(&RELOAD_FLAG.to_owned()));
    }

    /// sudo always asks (no cached ticket from an earlier command in the
    /// terminal): it, not the typed `yes`, is the gate.
    #[cfg(unix)]
    #[test]
    fn sudo_asks_every_time() {
        let words = system_config::sudo_args(std::path::Path::new("/usr/bin/cmux"), vec!["computer-use".into()]);
        let words: Vec<String> = words.iter().map(|word| word.to_string_lossy().into_owned()).collect();
        assert_eq!(words, ["-k", "--", "/usr/bin/cmux", "computer-use"]);
    }

    /// The elevated run opens only a host supervisor endpoint the status names.
    #[test]
    fn the_reload_endpoint_comes_from_the_hosts_status_and_is_checked() {
        let status = |endpoint: &str| json!({"computer_use": {"reload_endpoint": endpoint}});
        if cfg!(windows) {
            let pipe = r"\\.\pipe\cmux-remote-rh-0123";
            assert_eq!(reload_endpoint_of(&status(pipe)), Some(pipe.into()));
            for bad in [r"\\host\pipe\cmux-remote-x", r"\\.\pipe\other", r"\\.\pipe\cmux-remote-", r"C:\x\s.sock"] {
                assert_eq!(reload_endpoint_of(&status(bad)), None, "{bad}");
            }
        } else {
            let socket = "/run/user/1000/cmux/rh-0123/s.sock";
            assert_eq!(reload_endpoint_of(&status(socket)), Some(socket.into()));
            for bad in ["relative/s.sock", "/etc/shadow", "/tmp/x.sock", ""] {
                assert_eq!(reload_endpoint_of(&status(bad)), None, "{bad}");
            }
        }
        assert_eq!(reload_endpoint_of(&json!({})), None);
    }

    #[test]
    fn only_another_device_with_an_approval_key_can_be_pinned() {
        use base64::Engine as _;
        let signing = base64::engine::general_purpose::STANDARD.encode([4_u8; 65]);
        let mut approval_point = [7_u8; 65];
        approval_point[0] = 4;
        let approval = base64::engine::general_purpose::STANDARD.encode(approval_point);
        let device = |id: &str, platform: &str, approval_key: Option<&str>| -> cmux_device_hub_client::HubDevice {
            serde_json::from_value(json!({"id": id, "name": format!("{platform} {id}"), "platform": platform,
                                           "signingKey": signing, "approvalKey": approval_key}))
            .unwrap()
        };
        let devices = vec![
            device("phone", "ios", Some(&approval)),
            device("old-mac", "macos", None),
            device("box", "linux", None),
            device("pc", "windows", None),
        ];
        let pins = pins_of(&devices, "box", &["PHONE".into()]).unwrap();
        assert_eq!(pins[0].device_id, "phone");
        // The approval key's fingerprint, never the signing key's.
        assert_eq!(pins[0].approval_key_fingerprint, cmux_device_hub_client::key_fingerprint(&approval).unwrap());
        assert_ne!(pins[0].approval_key_fingerprint, cmux_device_hub_client::key_fingerprint(&signing).unwrap());
        let error = pins_of(&devices, "box", &["old-mac".into()]).unwrap_err();
        assert!(error.contains("no approval key"), "{error}");
        assert!(error.contains("only the cmux iPhone app"), "says a Mac cannot be pinned yet: {error}");
        assert!(pins_of(&devices, "box", &["box".into()]).is_err(), "never itself");
        assert!(pins_of(&devices, "box", &["pc".into()]).is_err(), "never a Windows box");
        assert!(pins_of(&devices, "box", &["missing".into()]).is_err());
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
