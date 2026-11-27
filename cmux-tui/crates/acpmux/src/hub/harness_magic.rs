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
pub(crate) const FEATURES: &[&str] = &["turnRules", "cacheAlarm", "prefetch", "sidecars"];

/// The features that are off unless their setting is `true` (opinionated nudges).
pub(crate) const DEFAULT_OFF: &[&str] = &["sidecars"];

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

/// The features of `features` that are on, in their order.
pub(crate) fn enabled_list(
    features: &[&str],
    doc: Option<&Value>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Vec<String> {
    features.iter().filter(|f| enabled_in(f, doc, env)).map(|f| (*f).to_owned()).collect()
}

/// The opt-in features (off unless their setting is `true`, Leo 2026-11-26: "only do it for our
/// personal fleet situation"), each read by its own module's switch, so the stamp says what the
/// feature itself decided. Without them on the stamp the scorecard has no on-against-off row for
/// context surgery (RFD 0149) or dedupe (RFD 0147): their counters appear only on the turns that
/// masked or stubbed something, and a turn with the feature on that did nothing looked like off.
pub(crate) const OPT_IN: &[&str] = &["surgery", "dedupe"];

/// Whether an [`OPT_IN`] feature is on for `doc` and `env`.
fn opt_in_enabled(
    feature: &str,
    doc: Option<&Value>,
    env: &dyn Fn(&str) -> Option<String>,
) -> bool {
    match feature {
        "surgery" => super::surgery::enabled_with(doc, env(super::surgery::KILL_ENV).as_deref()),
        "dedupe" => {
            crate::claude_stdio::dedupe_enabled_with(doc, env(&env_key("dedupe")).as_deref())
        }
        _ => false,
    }
}

/// [`FEATURES`] on unless switched off, then [`OPT_IN`] on only when switched on, in that order.
pub(crate) fn enabled_all(
    doc: Option<&Value>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Vec<String> {
    let mut on = enabled_list(FEATURES, doc, env);
    on.extend(OPT_IN.iter().filter(|f| opt_in_enabled(f, doc, env)).map(|f| (*f).to_owned()));
    on
}

/// The features on now.
fn enabled_now() -> Vec<String> {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    enabled_all(doc.as_ref(), &|k| std::env::var(k).ok())
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
    fn prefetch_is_stamped_by_its_own_switch() {
        // The scorecard's byFeature splits only on what is stamped; prefetch's module reads the
        // same setting and kill switch (`hub/prefetch.rs`), so the stamp matches what ran.
        assert!(FEATURES.contains(&"prefetch"));
        assert_eq!(setting_key("prefetch"), crate::hub::prefetch::SETTING_ENABLED);
        assert_eq!(env_key("prefetch"), crate::hub::prefetch::ENV_KILL);
        assert!(enabled_list(FEATURES, None, &no_env).contains(&"prefetch".to_owned()));
        let off = json!({"agents": {"harnessMagic": {"prefetch": {"enabled": false}}}});
        assert!(!enabled_list(FEATURES, Some(&off), &no_env).contains(&"prefetch".to_owned()));
    }

    #[test]
    fn opt_in_features_are_stamped_only_when_switched_on() {
        // RFD 0149's read-back: a turn with surgery on must say so even when it masked nothing.
        let default: Vec<String> = FEATURES.iter().map(|f| (*f).to_owned()).collect();
        assert_eq!(enabled_all(None, &no_env), default);
        let on = json!({"agents": {"harnessMagic": {
            "surgery": {"enabled": true}, "dedupe": {"enabled": true}}}});
        let all = enabled_all(Some(&on), &no_env);
        assert!(all.ends_with(&["surgery".to_owned(), "dedupe".to_owned()]), "{all:?}");
        let killed = |k: &str| (k == "ACPMUX_HM_SURGERY").then(|| "0".to_owned());
        assert!(!enabled_all(Some(&on), &killed).contains(&"surgery".to_owned()));
        // Dedupe's daemon switch turns it on too (#58129); surgery's only turns it off.
        let env_on = |k: &str| k.starts_with("ACPMUX_HM_").then(|| "1".to_owned());
        let all = enabled_all(None, &env_on);
        assert!(
            all.contains(&"dedupe".to_owned()) && !all.contains(&"surgery".to_owned()),
            "{all:?}"
        );
    }
}
