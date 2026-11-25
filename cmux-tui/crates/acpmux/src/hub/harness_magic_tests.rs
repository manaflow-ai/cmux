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
fn this_build_stamps_an_empty_list_without_reading_settings() {
    let mut msg = json!({});
    if FEATURES.is_empty() {
        stamp(&mut msg);
        assert_eq!(msg["harnessMagic"]["enabled"], json!([]));
    }
}
