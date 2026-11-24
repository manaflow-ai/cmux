use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;

const APP: &str = "1111111111111111111111111111111111111111";
const TIP: &str = "2222222222222222222222222222222222222222";

fn payload(committed_at: u64, daemon_from: &[&str]) -> ChannelPayload {
    ChannelPayload {
        schema: 1,
        purpose: live::PURPOSE.to_owned(),
        channel: "nightly-live".to_owned(),
        commit: TIP.to_owned(),
        committed_at,
        published_at: committed_at,
        expires_at: committed_at + 86_400,
        live_from: vec![TIP.to_owned()],
        daemon_from: daemon_from.iter().map(|s| (*s).to_owned()).collect(),
        tree_key: None,
    }
}

struct Inputs {
    settings: Value,
    managed: BTreeMap<String, Value>,
    env: Vec<(&'static str, &'static str)>,
    release: bool,
    bundle: Option<(&'static str, Option<&'static str>)>,
    app_session: bool,
}

impl Inputs {
    fn on() -> Self {
        Self {
            settings: json!({ "updates": { "daemon": "every-merge" } }),
            managed: BTreeMap::new(),
            env: Vec::new(),
            release: true,
            bundle: Some(("com.cmuxterm.app.nightly", None)),
            app_session: true,
        }
    }

    fn gate(&self) -> Result<(), &'static str> {
        let env = |name: &str| {
            self.env.iter().find(|(key, _)| *key == name).map(|(_, value)| (*value).to_owned())
        };
        gate(&Gate {
            settings: Some(&self.settings),
            managed_forced: &self.managed,
            env: &env,
            release_build: self.release,
            bundle: self.bundle,
            app_session: self.app_session,
        })
    }
}

#[test]
fn on_by_default_and_off_for_any_value_but_every_merge() {
    // Leo (cmuxterm-hq#5334): "Every machine does this by itself"; no opt-in on a team build.
    assert!(setting_on(None));
    assert!(setting_on(Some(&json!({}))));
    assert!(setting_on(Some(&json!({ "updates": {} }))));
    assert!(setting_on(Some(&json!({ "updates": { "daemon": null } }))));
    assert!(setting_on(Some(&json!({ "updates": { "daemon": "every-merge" } }))));
    for value in [json!("off"), json!("Every-Merge"), json!(true), json!(false), json!(1)] {
        assert!(!setting_on(Some(&json!({ "updates": { "daemon": value } }))), "{value}");
    }
    let mut inputs = Inputs::on();
    inputs.settings = json!({});
    assert_eq!(inputs.gate(), Ok(()), "a NIGHTLY with no setting takes daemon updates");
    inputs.settings = json!({ "updates": { "daemon": "off" } });
    assert_eq!(inputs.gate(), Err("updates.daemon is off"));
    // A Release build keeps today's behaviour with no setting at all.
    inputs.settings = json!({});
    inputs.bundle = Some(("com.cmuxterm.app", None));
    assert!(inputs.gate().is_err());
}

#[test]
fn on_for_nightly_and_the_tip_app_only() {
    assert_eq!(Inputs::on().gate(), Ok(()));
    for (bundle, feed, takes) in [
        ("com.cmuxterm.app.nightly", None, true),
        ("com.cmuxterm.app.nightly.side", None, true),
        ("com.cmuxterm.app.nightlyx", None, false),
        ("com.cmuxterm.app", None, false),
        ("com.cmuxterm.app.rc", None, false),
        ("com.cmuxterm.app.staging", None, false),
        ("com.cmuxterm.app.debug", None, false),
        ("com.cmuxterm.app.debug.next", None, false),
        ("com.cmuxterm.app.debug.next", Some("https://example.com/appcast.xml"), false),
        (
            "com.cmuxterm.app.debug.next",
            Some("https://files.cmux.com/nightly-next/tip/a.xml"),
            true,
        ),
    ] {
        assert_eq!(bundle_takes_updates(bundle, feed), takes, "{bundle} {feed:?}");
        let mut inputs = Inputs::on();
        inputs.bundle = Some((bundle, feed));
        assert_eq!(inputs.gate().is_ok(), takes, "{bundle} {feed:?}");
    }
    let mut inputs = Inputs::on();
    inputs.bundle = None;
    assert_eq!(inputs.gate(), Err("not in an app bundle"));
}

#[test]
fn policy_environment_build_and_session_turn_it_off() {
    let mut inputs = Inputs::on();
    inputs.managed.insert("DisableAutoUpdate".into(), json!(true));
    assert_eq!(inputs.gate(), Err("managed policy DisableAutoUpdate"));

    let mut inputs = Inputs::on();
    inputs.managed.insert("updates.checkAutomatically".into(), json!(false));
    assert_eq!(inputs.gate(), Err("managed policy DisableAutoUpdate"));

    let mut inputs = Inputs::on();
    inputs.settings =
        json!({ "updates": { "daemon": "every-merge", "checkAutomatically": false } });
    assert_eq!(inputs.gate(), Err("updates.checkAutomatically is false"));

    let mut inputs = Inputs::on();
    inputs.env.push(("CMUX_DAEMON_UPDATES", "off"));
    assert_eq!(inputs.gate(), Err("CMUX_DAEMON_UPDATES"));

    let mut inputs = Inputs::on();
    inputs.env.push(("CI", "true"));
    assert_eq!(inputs.gate(), Err("CI"));

    let mut inputs = Inputs::on();
    inputs.release = false;
    assert_eq!(inputs.gate(), Err("not a release build"));

    let mut inputs = Inputs::on();
    inputs.app_session = false;
    assert_eq!(inputs.gate(), Err("not the app's own daemon"));
}

#[test]
fn takes_a_newer_pointer_whose_daemon_from_lists_the_app() {
    let p = payload(200, &[TIP, APP]);
    assert_eq!(
        look(&p, Some(&APP[..9]), None, None),
        Look::Take { commit: TIP.to_owned(), committed_at: 200 }
    );
    assert_eq!(
        look(&p, Some(APP), Some(100), Some(150)),
        Look::Take { commit: TIP.to_owned(), committed_at: 200 }
    );
}

#[test]
fn never_takes_an_app_outside_daemon_from_or_with_no_commit() {
    let p = payload(200, &[TIP]);
    assert!(
        matches!(look(&p, Some(APP), None, None), Look::Nothing(why) if why.contains("needs a new app"))
    );
    assert!(matches!(look(&p, None, None, None), Look::Nothing(why) if why.contains("CMUXCommit")));
    // A pointer from before daemon_from falls back to live_from.
    let mut old = payload(200, &[]);
    old.live_from = vec![TIP.to_owned(), APP.to_owned()];
    assert!(matches!(look(&old, Some(APP), None, None), Look::Take { .. }));
}

#[test]
fn an_applied_or_attempted_pointer_is_never_taken_again() {
    let p = payload(200, &[TIP, APP]);
    assert!(matches!(look(&p, Some(APP), Some(200), None), Look::Nothing(_)));
    assert!(matches!(look(&p, Some(APP), Some(300), None), Look::Nothing(_)));
    // A rolled-back or failed attempt holds that commit; the next newer one goes.
    assert!(matches!(look(&p, Some(APP), Some(100), Some(200)), Look::Nothing(_)));
    let next = payload(201, &[TIP, APP]);
    assert!(matches!(look(&next, Some(APP), Some(100), Some(200)), Look::Take { .. }));
}

#[test]
fn swaps_with_agents_running_and_holds_on_typing_for_at_most_two_minutes() {
    let now = 1_000_000_000;
    let quiet = json!({ "live_agents": 0, "last_user_input_at_ms": now - 31_000 });
    assert_eq!(safe_point(Some(&quiet), now, now), Ok(()));
    let never_typed = json!({ "live_agents": 0, "last_user_input_at_ms": null });
    assert_eq!(safe_point(Some(&never_typed), now, now), Ok(()));
    // Leo: "The daemon updates itself without waiting for idle": a working agent never holds it.
    let agents = json!({ "live_agents": 3, "last_user_input_at_ms": null });
    assert_eq!(safe_point(Some(&agents), now, now), Ok(()));
    assert_eq!(safe_point(Some(&json!({})), now, now), Ok(()));
    let typing = json!({ "live_agents": 0, "last_user_input_at_ms": now - 5_000 });
    assert!(safe_point(Some(&typing), now, now).is_err());
    assert!(safe_point(Some(&json!("busy")), now, now).is_err());
    assert!(safe_point(None, now, now).is_err());
    // Two minutes on, the commit goes even while a person types.
    let held = now - INPUT_HOLD_MAX.as_millis() as u64;
    assert_eq!(safe_point(Some(&typing), now, held), Ok(()));
    assert_eq!(safe_point(None, now, held), Ok(()));
    assert!(safe_point(Some(&typing), now, held + 1).is_err());
}

#[test]
fn a_team_signed_app_waits_for_its_trees_team_signed_set() {
    let key = "c".repeat(40);
    let found = |_: &str| Ok(true);
    // An ad-hoc (local) app takes the ad-hoc build as before, tree or none.
    assert_eq!(team_set_ready(false, None, |_| panic!("no read")), Ok(()));
    assert_eq!(team_set_ready(true, Some(&key), found), Ok(()));
    assert!(team_set_ready(true, None, |_| panic!("no read")).is_err());
    assert!(team_set_ready(true, Some("C".repeat(40).as_str()), |_| panic!("no read")).is_err());
    assert!(team_set_ready(true, Some(&key), |_| Ok(false)).unwrap_err().contains("waits"));
    assert!(team_set_ready(true, Some(&key), |_| Err("404".into())).is_err());
}

#[test]
fn the_attempt_record_round_trips_and_a_bad_one_reads_as_none() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store { root: dir.path().join("app-try") };
    assert_eq!(last_attempt(&store), None);
    record_attempt(&store, TIP, 200, 1).unwrap();
    assert_eq!(last_attempt(&store), Some(200));
    std::fs::write(store.root.join(ATTEMPT_FILE), b"{").unwrap();
    assert_eq!(last_attempt(&store), None);
}

#[test]
fn looks_every_15_to_19_seconds() {
    for draw in [0, 1, 3_750, 3_751, u64::MAX] {
        let wait = next_wait(draw);
        assert!(
            wait >= Duration::from_secs(15) && wait <= Duration::from_millis(18_750),
            "{wait:?}"
        );
    }
}
