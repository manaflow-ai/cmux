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
    Feature { name: "verify", on: super::verify::enabled },
    Feature { name: "prefetch", on: super::prefetch::enabled },
    Feature { name: "surgery", on: super::surgery::enabled },
    Feature { name: "dedupe", on: crate::claude_stdio::dedupe_enabled },
    Feature { name: "dirRules", on: crate::claude_stdio::dir_rules_enabled },
    Feature { name: super::turn_checkpoint::FEATURE, on: super::turn_checkpoint::enabled },
    Feature { name: "sharedCache", on: crate::ci_log_cache::enabled },
    Feature { name: "outputCaps", on: crate::harness_limits::output_caps },
    Feature { name: "consensus", on: super::surge_triage::consensus_enabled },
];

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
#[path = "harness_magic_tests.rs"]
mod tests;
