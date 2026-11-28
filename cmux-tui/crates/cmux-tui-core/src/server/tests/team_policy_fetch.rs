//! RFD 0211: a `team.device.policy` read the app makes through `cloud.owner.op` reaches the
//! settings owner's team layer, so the policy is enforced (server/cloud_api.rs
//! `learn_team_policy`).

use super::*;
use crate::mux::settings::SettingsPaths;

fn owner(name: &str) -> (Arc<Mux>, cmux_unix_socket::TestDir) {
    let dir = cmux_unix_socket::short_test_dir(&format!("tpf-{name}"));
    let mux = test_mux();
    assert!(mux.start_settings_owner(SettingsPaths {
        config: dir.path().join("cmux-next.json"),
        seed: None,
        state_dir: Some(dir.path().to_path_buf()),
        reader: Box::new(cmux_config::managed::FixedManagedReader::default()),
        watch: false,
    }));
    (mux, dir)
}

fn read_args() -> serde_json::Map<String, Value> {
    json!({"route": "read", "body": {"op": "team.device.policy", "params": {}}})
        .as_object()
        .unwrap()
        .clone()
}

fn managed(version: i64) -> Value {
    json!({"status": 200, "reply": {"ok": true, "value": {
        "managed": true, "team": "t-1", "team_name": "Acme", "version": version,
        "defaults": {}, "enforced": {"browser.searchEngine": "duckduckgo"}}}})
}

fn enforced(mux: &Arc<Mux>) -> Option<cmux_config::ManagedSource> {
    mux.with_settings(|s| s.effective().managed_keys.get("browser.searchEngine").cloned())
}

#[test]
fn a_fetched_team_policy_is_enforced_and_saved() {
    let (mux, dir) = owner("on");
    assert_eq!(enforced(&mux), None);
    assert!(super::super::cloud_api::learn_team_policy(&mux, &read_args(), &managed(1)));
    assert_eq!(enforced(&mux), Some(cmux_config::ManagedSource::Team("Acme".into())));
    let root = mux.with_settings(|s| s.effective().root.clone());
    assert_eq!(root.pointer("/browser/searchEngine"), Some(&json!("duckduckgo")));
    // A write of the enforced key from the file is refused: the policy holds.
    let refused = mux.settings_apply(cmux_config::Op::Set {
        target: cmux_config::Target::Key("browser.searchEngine".into()),
        value: json!("google"),
        meta: cmux_config::WriteMeta {
            origin: cmux_config::Origin::User,
            idempotency_key: None,
            if_revision: None,
        },
    });
    assert!(matches!(refused, Err(cmux_config::Refusal::Managed { .. })), "{refused:?}");
    // The owner saved it for the next start.
    let saved = std::fs::read_to_string(dir.path().join("settings").join("team-policy.json"))
        .expect("team-policy.json");
    assert!(saved.contains("duckduckgo"), "{saved}");
}

#[test]
fn an_unmanaged_answer_lifts_the_policy_and_other_calls_do_not() {
    let (mux, _dir) = owner("off");
    assert!(super::super::cloud_api::learn_team_policy(&mux, &read_args(), &managed(1)));
    let feed = json!({"route": "read", "body": {"op": "feed.list", "params": {}}});
    let unmanaged = json!({"status": 200, "reply": {"ok": true, "value": {"managed": false}}});
    assert!(!super::super::cloud_api::learn_team_policy(
        &mux,
        feed.as_object().unwrap(),
        &unmanaged
    ));
    let refused = json!({"status": 401, "reply": null});
    assert!(!super::super::cloud_api::learn_team_policy(&mux, &read_args(), &refused));
    assert!(enforced(&mux).is_some());
    assert!(super::super::cloud_api::learn_team_policy(&mux, &read_args(), &unmanaged));
    assert_eq!(enforced(&mux), None);
}

#[test]
fn the_daemon_reads_the_policy_again_only_every_fifteen_minutes() {
    use super::super::cloud_api::{TEAM_POLICY_EVERY_SECS, team_policy_due};
    let clock = std::sync::atomic::AtomicU64::new(0);
    assert!(team_policy_due(&clock, 1_000));
    assert!(!team_policy_due(&clock, 1_001));
    assert!(!team_policy_due(&clock, 1_000 + TEAM_POLICY_EVERY_SECS - 1));
    assert!(team_policy_due(&clock, 1_000 + TEAM_POLICY_EVERY_SECS));
}

#[test]
fn only_an_install_token_reads_the_policy() {
    use super::super::cloud_api::{is_install_token, team_policy_read_args};
    use base64::Engine as _;
    let jwt = |claims: Value| {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(serde_json::to_vec(&claims).unwrap());
        format!("e30.{payload}.sig")
    };
    assert!(is_install_token(&jwt(json!({"inst": "i-1", "sub": "u"}))));
    assert!(!is_install_token(&jwt(json!({"sub": "u"}))));
    assert!(!is_install_token(&jwt(json!({"inst": ""}))));
    assert!(!is_install_token("stack-session-opaque"));
    // The read the daemon sends is the one `learn_team_policy` applies.
    let args = team_policy_read_args(Some(&json!("0.9.1 (123)")));
    assert_eq!(args.get("client_version"), Some(&json!("0.9.1 (123)")));
    let (mux, _dir) = owner("read");
    assert!(super::super::cloud_api::learn_team_policy(&mux, &args, &managed(2)));
    assert_eq!(enforced(&mux), Some(cmux_config::ManagedSource::Team("Acme".into())));
}
