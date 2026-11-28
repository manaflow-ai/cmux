use super::*;

fn no_env(_: &str) -> Option<String> {
    None
}

#[test]
fn a_feature_is_on_unless_its_setting_or_kill_switch_turns_it_off() {
    assert!(enabled_in("prefetch", None, &no_env));
    let off = json!({"agents": {"harnessMagic": {"prefetch": {"enabled": false}}}});
    assert!(!enabled_in("prefetch", Some(&off), &no_env));
    let on = json!({"agents": {"harnessMagic": {"prefetch": {"enabled": true}}}});
    assert!(enabled_in("prefetch", Some(&on), &no_env));
    let killed = |k: &str| (k == "ACPMUX_HM_PREFETCH").then(|| "0".to_owned());
    assert!(!enabled_in("prefetch", Some(&on), &killed));
    let kept = |k: &str| (k == "ACPMUX_HM_PREFETCH").then(|| "1".to_owned());
    assert!(enabled_in("prefetch", None, &kept));
}

#[test]
fn the_kill_switch_name_upper_cases_the_feature() {
    assert_eq!(env_key("prefetch-files"), "ACPMUX_HM_PREFETCH_FILES");
    assert_eq!(setting_key("verify"), "agents.harnessMagic.verify.enabled");
}

#[test]
fn stamp_and_counters_share_one_object() {
    let mut msg = json!({"status": "completed"});
    add_counter(&mut msg, "verify", "runs", 2);
    add_counter(&mut msg, "verify", "runs", 1);
    stamp_with(&mut msg, vec!["verify".into()]);
    assert_eq!(msg["harnessMagic"], json!({"enabled": ["verify"], "verify": {"runs": 3}}));
    let off = json!({"agents": {"harnessMagic": {"b": {"enabled": false}}}});
    assert_eq!(enabled_list(&["a", "b"], Some(&off), &no_env), vec!["a".to_owned()]);
}

#[test]
fn the_stamp_lists_only_registered_features() {
    let mut msg = json!({});
    stamp(&mut msg);
    let names: Vec<&str> = FEATURES.iter().map(|f| f.name).collect();
    for v in msg["harnessMagic"]["enabled"].as_array().expect("a list") {
        assert!(names.contains(&v.as_str().unwrap_or_default()), "{v} is not registered");
    }
}

/// Every `agents.harnessMagic.<name>.enabled` switch in this crate's sources is a row of
/// [`FEATURES`], so no feature runs without the stamp saying so (RFD 0159 read-back).
#[test]
fn every_harness_magic_switch_is_a_registered_feature() {
    let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let re = regex::Regex::new(r#""agents\.harnessMagic\.([A-Za-z0-9_-]+)\.enabled""#).unwrap();
    let mut stack = vec![src];
    let mut seen = std::collections::BTreeSet::new();
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).expect("read src").flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "rs")
                && !path.to_string_lossy().ends_with("_tests.rs")
                && !path.ends_with("harness_magic.rs")
            {
                let text = std::fs::read_to_string(&path).unwrap_or_default();
                for c in re.captures_iter(&text) {
                    seen.insert(c[1].to_owned());
                }
            }
        }
    }
    assert!(seen.contains("verify"), "the scan found no switches: {seen:?}");
    let names: Vec<&str> = FEATURES.iter().map(|f| f.name).collect();
    let missing: Vec<&String> = seen.iter().filter(|n| !names.contains(&n.as_str())).collect();
    assert!(missing.is_empty(), "harness-magic switches with no FEATURES row: {missing:?}");
}

#[test]
fn prefetch_is_stamped_by_its_own_switch() {
    // The scorecard's byFeature splits only on what is stamped; prefetch's row asks its own
    // gate, which reads this setting and kill switch (`hub/prefetch.rs`).
    assert!(FEATURES.iter().any(|f| f.name == "prefetch"));
    assert_eq!(setting_key("prefetch"), crate::hub::prefetch::SETTING_ENABLED);
    assert_eq!(env_key("prefetch"), crate::hub::prefetch::ENV_KILL);
    assert!(crate::hub::prefetch::enabled_by(None, None));
    let off = json!({"agents": {"harnessMagic": {"prefetch": {"enabled": false}}}});
    assert!(!crate::hub::prefetch::enabled_by(Some(&off), None));
}

#[test]
fn opt_in_features_are_off_unless_switched_on() {
    // Surgery and dedupe are opt-in (Leo 2026-11-26: "only do it for our personal fleet
    // situation"): their own gates, which their FEATURES rows ask, read off by default.
    let names: Vec<&str> = FEATURES.iter().map(|f| f.name).collect();
    assert!(names.contains(&"surgery") && names.contains(&"dedupe"), "{names:?}");
    assert!(!super::super::surgery::enabled_with(None, None));
    assert!(!crate::claude_stdio::dedupe_enabled_with(None, None));
    let on = json!({"agents": {"harnessMagic": {
        "surgery": {"enabled": true}, "dedupe": {"enabled": true}}}});
    assert!(super::super::surgery::enabled_with(Some(&on), None));
    assert!(crate::claude_stdio::dedupe_enabled_with(Some(&on), None));
    assert!(!super::super::surgery::enabled_with(Some(&on), Some("0")));
    // Dedupe's daemon switch turns it on too (#58129); surgery's only turns it off.
    assert!(crate::claude_stdio::dedupe_enabled_with(None, Some("1")));
    assert!(!super::super::surgery::enabled_with(None, Some("1")));
}
