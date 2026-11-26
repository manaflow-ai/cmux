use super::*;
use ring::signature::{Ed25519KeyPair, KeyPair};

fn key_pair() -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&[3u8; 32]).unwrap()
}

fn encode(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[test]
fn only_the_key_holder_signs_a_document() {
    let pair = key_pair();
    let key = encode(pair.public_key().as_ref());
    let data = br#"{"version":1}"#;
    let signature = format!("{}\n", encode(pair.sign(data).as_ref()));
    assert!(verify(data, signature.as_bytes(), &key));
    assert!(!verify(br#"{"version":2}"#, signature.as_bytes(), &key));
    assert!(!verify(data, signature.as_bytes(), PUBLIC_KEY));
    assert!(!verify(data, b"not base64!", &key));
}

#[test]
fn a_cohort_replaces_the_default_keys() {
    let document = serde_json::json!({
        "version": 1,
        "default": {"DisabledFeatures": ["a"], "MinimumVersion": "1.0.0"},
        "cohorts": {"wave-1": {"DisabledFeatures": ["b"]}},
    });
    let wave = resolve(&document, "wave-1").unwrap();
    assert_eq!(disabled_features(&wave), ["b"]);
    assert_eq!(wave["MinimumVersion"], "1.0.0");
    assert_eq!(disabled_features(&resolve(&document, "other").unwrap()), ["a"]);
    assert!(resolve(&serde_json::json!({"version": 2}), "wave-1").is_none());
}

#[test]
fn the_cohort_comes_from_the_environment_then_the_settings() {
    let settings = serde_json::json!({"tester": {"cohort": "mac-wave-2"}});
    let none = |_: &str| -> Option<String> { None };
    let set = |name: &str| (name == "CMUX_TUI_COHORT").then(|| "linux-wave-1".to_string());
    assert_eq!(cohort(&set, Some(&settings)), "linux-wave-1");
    assert_eq!(cohort(&none, Some(&settings)), "mac-wave-2");
    assert_eq!(cohort(&none, None), "default");
}

#[test]
fn docked_workspaces_stay_off_unless_requested() {
    let none = |_: &str| -> Option<String> { None };
    let on = |name: &str| (name == DOCKED_WORKSPACES_ENV).then(|| "1".to_string());
    let off = |name: &str| (name == DOCKED_WORKSPACES_ENV).then(|| "0".to_string());
    assert!(!docked_workspaces_enabled(false, &none));
    assert!(!docked_workspaces_enabled(false, &off));
    assert_eq!(docked_workspaces_enabled(false, &on), !disables(DOCKED_WORKSPACES));
    assert_eq!(docked_workspaces_enabled(true, &none), !disables(DOCKED_WORKSPACES));
}

#[test]
fn only_a_verified_document_is_cached() {
    let root = tempfile::tempdir().unwrap();
    let pair = key_pair();
    let key = encode(pair.public_key().as_ref());
    let data = br#"{"version":1,"default":{"DisabledFeatures":["x"]}}"#;
    let signature = encode(pair.sign(data).as_ref());
    assert!(store(root.path(), b"{}", signature.as_bytes(), &key).is_err());
    assert!(cached(root.path(), &key).is_none());
    store(root.path(), data, signature.as_bytes(), &key).unwrap();
    assert!(cached(root.path(), &key).is_some());
    // An edit on disk voids the cache.
    std::fs::write(root.path().join(CACHE_NAME), br#"{"version":1}"#).unwrap();
    assert!(cached(root.path(), &key).is_none());
}

#[test]
fn tmux_control_mode_stays_off_unless_requested() {
    let none = |_: &str| -> Option<String> { None };
    let on = |name: &str| (name == TMUX_CONTROL_MODE_ENV).then(|| "1".to_string());
    let off = |name: &str| (name == TMUX_CONTROL_MODE_ENV).then(|| "0".to_string());
    assert!(!tmux_control_mode_enabled(&none));
    assert!(!tmux_control_mode_enabled(&off));
    assert_eq!(tmux_control_mode_enabled(&on), !disables(TMUX_CONTROL_MODE));
}

#[test]
fn the_hybrid_start_flag_is_the_env_then_the_disabled_list_then_none() {
    let env = |value: &'static str| {
        move |name: &str| (name == HYBRID_CHAT_START_ENV).then(|| value.to_string())
    };
    let none = |_: &str| None;
    let kept = |_: &str| false;
    let dropped = |name: &str| name == HYBRID_CHAT_START;
    let no_key = || None;
    for on in ["1", "true", "on", "yes", " yes "] {
        assert_eq!(hybrid_chat_start_flag(&env(on), &dropped, &no_key), Some(true), "{on}");
    }
    for off in ["0", "false", "off", "no"] {
        assert_eq!(hybrid_chat_start_flag(&env(off), &kept, &no_key), Some(false), "{off}");
    }
    assert_eq!(hybrid_chat_start_flag(&none, &kept, &no_key), None);
    assert_eq!(hybrid_chat_start_flag(&env("maybe"), &kept, &no_key), None);
    assert_eq!(hybrid_chat_start_flag(&none, &dropped, &no_key), Some(false));
    assert_eq!(hybrid_chat_start_flag(&env(""), &dropped, &no_key), Some(false));
}

/// Every combination of `CMUX_HYBRID_START` (on, off, absent, unreadable), cmux-next.json's
/// `cloud.autoCloud` (true, false, absent) and `hybrid-chat-start` disabled or not: the env wins
/// both ways, then disabled is off, then only a `true` key is on; a false or absent key is none,
/// as before the key, so no plan's default moves.
#[test]
fn cloud_auto_cloud_turns_the_hybrid_start_on_below_the_env_and_the_disabled_list() {
    let env = |value: Option<&'static str>| {
        move |name: &str| {
            (name == HYBRID_CHAT_START_ENV).then_some(value).flatten().map(str::to_owned)
        }
    };
    let disabled = |off: bool| move |name: &str| off && name == HYBRID_CHAT_START;
    for (env_value, key, off, expected) in [
        (Some("1"), Some(true), false, Some(true)),
        (Some("1"), Some(false), false, Some(true)),
        (Some("1"), None, false, Some(true)),
        (Some("1"), Some(true), true, Some(true)),
        (Some("1"), Some(false), true, Some(true)),
        (Some("1"), None, true, Some(true)),
        (Some("0"), Some(true), false, Some(false)),
        (Some("0"), Some(false), false, Some(false)),
        (Some("0"), None, false, Some(false)),
        (Some("0"), Some(true), true, Some(false)),
        (Some("0"), Some(false), true, Some(false)),
        (Some("0"), None, true, Some(false)),
        (None, Some(true), false, Some(true)),
        (None, Some(false), false, None),
        (None, None, false, None),
        (None, Some(true), true, Some(false)),
        (None, Some(false), true, Some(false)),
        (None, None, true, Some(false)),
        (Some("maybe"), Some(true), false, Some(true)),
        (Some("maybe"), Some(false), false, None),
        (Some(""), None, false, None),
        (Some(""), Some(true), true, Some(false)),
    ] {
        let reads = std::cell::Cell::new(0);
        let auto_cloud = || {
            reads.set(reads.get() + 1);
            key
        };
        assert_eq!(
            hybrid_chat_start_flag(&env(env_value), &disabled(off), &auto_cloud),
            expected,
            "env {env_value:?}, cloud.autoCloud {key:?}, disabled {off}"
        );
        let decided_above = matches!(env_value, Some("1" | "0")) || off;
        assert_eq!(
            reads.get(),
            usize::from(!decided_above),
            "the key is read only when it decides"
        );
    }
}

/// The key through the real settings reader: a cmux-next.json with `cloud.autoCloud: true` turns
/// the hybrid start on, `false` and no key leave it to the plan.
#[test]
fn a_settings_file_with_auto_cloud_true_turns_the_hybrid_start_on() {
    use cmux_tui_core::user_settings::auto_cloud_from_config_file;
    let path =
        std::env::temp_dir().join(format!("cmux-hybrid-auto-cloud-{}.json", std::process::id()));
    let none = |_: &str| None;
    let kept = |_: &str| false;
    let flag = |text: Option<&str>| {
        match text {
            Some(text) => std::fs::write(&path, text).unwrap(),
            None => {
                let _ = std::fs::remove_file(&path);
            }
        }
        hybrid_chat_start_flag(&none, &kept, &|| auto_cloud_from_config_file(&path))
    };
    assert_eq!(
        flag(Some("{\n  // AutoCloud\n  \"cloud\": {\"autoCloud\": true,},\n}")),
        Some(true)
    );
    assert_eq!(flag(Some(r#"{"cloud": {"autoCloud": false}}"#)), None);
    assert_eq!(flag(Some("{}")), None);
    assert_eq!(flag(None), None);
}
