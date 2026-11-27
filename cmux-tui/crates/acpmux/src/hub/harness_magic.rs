//! Part of `Hub`; see `hub/mod.rs`. The harness-magic features' shared seam: which of them a
//! turn ran with, stamped on its `turn_result` (and so the ledger and `acpmux scorecard`), so a
//! before/after reading compares turns that ran with the same features, like with like.
//!
//! Leo, 2026-11-24: each feature measured "before and after on real lanes (tokens per merged PR,
//! steering rate, time to the first useful result)".
//!
//! Every feature has one switch, `agents.harnessMagic.<feature>.enabled` in the settings file
//! (`turnRules` is on unless `false`: it does nothing with no rules; context surgery and dedupe
//! are off unless `true`, Leo 2026-11-26: "only do it for our personal fleet situation"), and a
//! kill switch, `ACPMUX_HM_<FEATURE>=0` in the daemon's environment
//! (the name upper-cased, every other character `_`). A feature lists itself in [`FEATURES`]
//! and asks [`enabled`] before it acts.
//!
//! A `turn_result` carries `harnessMagic: {"enabled": [..], "<feature>": {"<counter>": n}}`:
//! `enabled` the features on for that turn (an empty list: a build that knows the seam with
//! every feature off or none shipped; no `harnessMagic` at all: an older build, the same
//! baseline), and each feature's own counters for the turn under its name ([`add_counter`]).
//! The scorecard (`crate::scorecard`) sums every numeric counter there, and also reads a flat
//! `"harnessMagic.<feature>.<counter>": n` key, so either shape counts.

use serde_json::{Map, Value, json};

/// The features this build carries, by the name their setting and counters use. A builder adds
/// its feature here; an empty list stamps `enabled: []` and reads no settings.
pub(crate) const FEATURES: &[&str] = &["turnRules"];

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
/// `false` or `off`.
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
        .unwrap_or(true)
}

/// Whether `feature` is on now (the settings file read at each call, as every daemon setting is).
#[allow(dead_code)] // the features' own seam; the first feature to land calls it
pub(crate) fn enabled(feature: &str) -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    enabled_in(feature, doc.as_ref(), &|k| std::env::var(k).ok())
}

/// The features of `features` that are on, in their order.
pub(crate) fn enabled_list(
    features: &[&str],
    doc: Option<&Value>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Vec<String> {
    features.iter().filter(|f| enabled_in(f, doc, env)).map(|f| (*f).to_owned()).collect()
}

/// The features on now; with none in this build, an empty list and no settings read.
fn enabled_now() -> Vec<String> {
    if FEATURES.is_empty() {
        return Vec::new();
    }
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    enabled_list(FEATURES, doc.as_ref(), &|k| std::env::var(k).ok())
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
    fn this_build_stamps_an_empty_list_without_reading_settings() {
        let mut msg = json!({});
        if FEATURES.is_empty() {
            stamp(&mut msg);
            assert_eq!(msg["harnessMagic"]["enabled"], json!([]));
        }
    }
}
