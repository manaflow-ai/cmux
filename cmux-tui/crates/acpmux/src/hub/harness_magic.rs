//! Part of `Hub`; see `hub/mod.rs`. The harness-magic features' shared seam: which of them a
//! turn ran with, stamped on its `turn_result` (and so the ledger and `acpmux scorecard`), so a
//! before/after reading compares turns that ran with the same features, like with like.
//!
//! Leo, 2026-11-24: each feature measured "before and after on real lanes (tokens per merged PR,
//! steering rate, time to the first useful result)".
//!
//! Every feature has one switch, `agents.harnessMagic.<feature>.enabled` in the settings file
//! (`turnRules` and `pathRules` are on unless `false`: each does nothing with no rules; context
//! surgery and dedupe are off unless `true`, Leo 2026-11-26: "only do it for our personal fleet
//! situation"), and a
//! kill switch, `ACPMUX_HM_<FEATURE>=0` in the daemon's environment
//! (the name upper-cased, every other character `_`). A feature lists itself in [`FEATURES`]
//! with the gate it asks before it acts, so the stamp says exactly what ran: a feature with a
//! switch and no row here ran unseen, and the scorecard could not split its turns on from off
//! (RFD 0159's read-back found verify, prefetch, surgery and dedupe all missing). The test
//! `every_harness_magic_switch_is_a_registered_feature` fails a new switch with no row.
//!
//! A `turn_result` carries `harnessMagic: {"enabled": [..], "<feature>": {"<counter>": n}}`:
//! `enabled` the features on for that turn (an empty list: a build that knows the seam with
//! every feature off or none shipped; no `harnessMagic` at all: an older build, the same
//! baseline), and each feature's own counters for the turn under its name ([`add_counter`]).
//! The scorecard (`crate::scorecard`) sums every numeric counter there, and also reads a flat
//! `"harnessMagic.<feature>.<counter>": n` key, so either shape counts.

use serde_json::{Map, Value, json};

/// One harness-magic feature: the name its setting and counters use, and its own gate (the one
/// the feature itself asks, with its own default: surgery and dedupe are opt-in).
pub(crate) struct Feature {
    pub name: &'static str,
    pub on: fn() -> bool,
}

/// The features this build carries. A builder adds its feature here with its gate; an empty
/// list stamps `enabled: []` and reads no settings.
pub(crate) const FEATURES: &[Feature] = &[
    Feature { name: super::turn_rules::FEATURE, on: || enabled(super::turn_rules::FEATURE) },
    Feature { name: super::cache_alarm::FEATURE, on: || enabled(super::cache_alarm::FEATURE) },
    Feature {
        name: crate::claude_stdio::PATH_RULES_FEATURE,
        on: crate::claude_stdio::path_rules_enabled,
    },
    Feature { name: "verify", on: super::verify::enabled },
    Feature { name: crate::model_router::FEATURE, on: crate::model_router::enabled },
    Feature { name: "prefetch", on: super::prefetch::enabled },
    Feature { name: "surgery", on: super::surgery::enabled },
    Feature { name: "dedupe", on: crate::claude_stdio::dedupe_enabled },
    Feature { name: super::sidecars::FEATURE, on: || enabled(super::sidecars::FEATURE) },
    Feature { name: "dirRules", on: crate::claude_stdio::dir_rules_enabled },
    Feature { name: super::turn_checkpoint::FEATURE, on: super::turn_checkpoint::enabled },
    Feature { name: "sharedCache", on: crate::ci_log_cache::enabled },
    Feature { name: "outputCaps", on: crate::harness_limits::output_caps },
    Feature { name: super::turn_artifacts::FEATURE, on: super::turn_artifacts::enabled },
    Feature { name: "consensus", on: super::surge_triage::consensus_enabled },
];

/// The features the shared gate reads off unless their setting is `true` (opinionated nudges).
pub(crate) const DEFAULT_OFF: &[&str] = &[super::sidecars::FEATURE];

/// The settings key of `feature`'s off switch.
pub(crate) fn setting_key(feature: &str) -> String {
    format!("agents.harnessMagic.{feature}.enabled")
}

/// The environment variable of `feature`'s kill switch: `ACPMUX_HM_` and the name upper-cased,
/// every character that is not a letter or digit `_` (`prefetch-files` is
/// `ACPMUX_HM_PREFETCH_FILES`).
pub(crate) fn env_key(feature: &str) -> String {
    let name: String = feature
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_uppercase() } else { '_' })
        .collect();
    format!("ACPMUX_HM_{name}")
}

/// Whether `feature` is on, given the settings file (`doc`, `None` when missing or unreadable)
/// and an environment lookup: on unless its setting is `false` or its kill switch is `0`,
/// `false` or `off`; a [`DEFAULT_OFF`] feature is off unless its setting is `true`.
pub(crate) fn enabled_in(
    feature: &str,
    doc: Option<&Value>,
    env: &dyn Fn(&str) -> Option<String>,
) -> bool {
    if let Some(v) = env(&env_key(feature)) {
        let v = v.trim().to_ascii_lowercase();
        if matches!(v.as_str(), "0" | "false" | "off" | "no") {
            return false;
        }
    }
    doc.and_then(|d| crate::user_settings::value(d, &setting_key(feature)))
        .and_then(|v| v.as_bool())
        .unwrap_or(!DEFAULT_OFF.contains(&feature))
}

/// Whether `feature` is on now (the settings file read at each call, as every daemon setting is).
pub(crate) fn enabled(feature: &str) -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    enabled_in(feature, doc.as_ref(), &|k| std::env::var(k).ok())
}

/// The features of `features` that are on, in their order (by the shared default gate).
#[cfg(test)]
fn enabled_list(
    features: &[&str],
    doc: Option<&Value>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Vec<String> {
    features.iter().filter(|f| enabled_in(f, doc, env)).map(|f| (*f).to_owned()).collect()
}

/// The features on now, each by its own gate, in [`FEATURES`] order.
fn enabled_now() -> Vec<String> {
    FEATURES.iter().filter(|f| (f.on)()).map(|f| f.name.to_owned()).collect()
}

/// The `harnessMagic` object of a `turn_result` message, made when missing (a message that is
/// not an object is left alone: `None`).
fn object(msg: &mut Value) -> Option<&mut Map<String, Value>> {
    let o = msg.as_object_mut()?;
    let hm = o.entry("harnessMagic").or_insert_with(|| json!({}));
    if !hm.is_object() {
        *hm = json!({});
    }
    hm.as_object_mut()
}

/// Puts `enabled` on a `turn_result` message as `harnessMagic.enabled`, keeping any counters a
/// feature already put there.
pub(crate) fn stamp_with(msg: &mut Value, enabled: Vec<String>) {
    if let Some(hm) = object(msg) {
        hm.insert("enabled".into(), json!(enabled));
    }
}

/// [`stamp_with`] the features on now.
pub(crate) fn stamp(msg: &mut Value) {
    stamp_with(msg, enabled_now());
}

/// Adds `n` to `harnessMagic.<feature>.<counter>` on a `turn_result` message.
#[allow(dead_code)] // the features' own seam; the first feature to land calls it
pub(crate) fn add_counter(msg: &mut Value, feature: &str, counter: &str, n: u64) {
    let Some(hm) = object(msg) else { return };
    let f = hm.entry(feature.to_owned()).or_insert_with(|| json!({}));
    if !f.is_object() {
        *f = json!({});
    }
    if let Some(f) = f.as_object_mut() {
        let now = f.get(counter).and_then(Value::as_u64).unwrap_or(0);
        f.insert(counter.to_owned(), json!(now.saturating_add(n)));
    }
}

#[cfg(test)]
mod tests {
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
}
