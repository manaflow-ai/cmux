use super::*;

fn words(n: usize) -> String {
    vec!["word"; n].join(" ")
}

#[test]
fn plan_first_is_off_unless_turned_on_and_the_kill_switch_wins() {
    assert!(!enabled_by(None, None));
    let on = json!({"agents": {"harnessMagic": {"planFirst": {"enabled": true}}}});
    assert!(enabled_by(Some(&on), None));
    assert!(!enabled_by(Some(&on), Some("0")));
    let off = json!({"agents": {"harnessMagic": {"planFirst": {"enabled": false}}}});
    assert!(!enabled_by(Some(&off), None));
}

#[test]
fn its_switches_are_the_shared_harness_magic_names() {
    use crate::hub::harness_magic::{FEATURES, env_key, setting_key};
    assert!(FEATURES.iter().any(|f| f.name == FEATURE));
    assert_eq!(setting_key(FEATURE), SETTING_ENABLED);
    assert_eq!(env_key(FEATURE), ENV_KILL);
}

#[test]
fn a_short_ask_or_a_just_do_it_task_goes_straight_to_work() {
    assert!(!wants_plan("fix the typo in the README"));
    assert!(!wants_plan(&words(MIN_WORDS - 1)));
    assert!(wants_plan(&words(MIN_WORDS)));
    assert!(!wants_plan(&format!("{} just do it", words(MIN_WORDS))));
    assert!(!wants_plan(&format!("{} Don\u{2019}t ask, decide.", words(MIN_WORDS))));
}

#[test]
fn the_reply_window_defaults_and_is_clamped() {
    assert_eq!(reply_window_in(None), Duration::from_secs(120));
    let short = json!({"agents": {"harnessMagic": {"planFirst": {"replySeconds": 1}}}});
    assert_eq!(reply_window_in(Some(&short)), Duration::from_secs(15));
    let long = json!({"agents": {"harnessMagic": {"planFirst": {"replySeconds": 99999}}}});
    assert_eq!(reply_window_in(Some(&long)), Duration::from_secs(1800));
}

#[test]
fn only_the_planning_turn_arms_once() {
    ASKED.lock().unwrap().insert("s-plan".into(), "t1".into());
    assert!(!take("s-plan", "t0"));
    assert!(take("s-plan", "t1"));
    assert!(!take("s-plan", "t1"), "a turn arms its reply point once");
}

#[test]
fn the_go_prompt_is_known_by_its_provenance_and_names_the_window() {
    assert!(is_go(Some(&json!({"kind": GO_KIND}))));
    assert!(!is_go(Some(&json!({"kind": "auto_resume"}))));
    assert!(!is_go(None));
    assert!(go_text(Duration::from_secs(120)).contains("120s"));
    assert!(instruction(Duration::from_secs(90)).contains("90s"));
}
