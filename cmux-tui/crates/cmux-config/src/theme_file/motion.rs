//! A theme file's `motion` block: named spring presets and overrides of the chrome's
//! design-token springs and fades ([`cmux_app_host::motion_profile`]). The shape and the clamps are
//! the scene motion contract's (`cmux.motion/1`); this reader also checks each `springs` and
//! `fades` name against the design tokens (`design-tokens.json` `motion.springs`, `motion.fades`)
//! and drops an unknown one with a diagnostic, so a typo never silently does nothing. A file
//! without the block leaves every timing at its design-token value.

use std::sync::OnceLock;

use cmux_app_host::motion_profile::{self, MotionProfile};
use serde_json::{Map, Value};

use super::Reader;

/// The key a theme file names its motion under.
pub const KEY: &str = motion_profile::KEY;

/// The design tokens' spring names and fade names, in file order.
pub fn known() -> &'static (Vec<String>, Vec<String>) {
    static KNOWN: OnceLock<(Vec<String>, Vec<String>)> = OnceLock::new();
    KNOWN.get_or_init(|| {
        let tokens: Value =
            serde_json::from_str(cmux_theme_tokens::DESIGN_TOKENS.get()).unwrap_or(Value::Null);
        let names = |group: &str| -> Vec<String> {
            tokens
                .pointer(&format!("/motion/{group}"))
                .and_then(Value::as_object)
                .map(|entries| entries.keys().cloned().collect())
                .unwrap_or_default()
        };
        (names("springs"), names("fades"))
    })
}

/// The `motion` property of the theme file JSON Schema.
pub fn json_schema() -> Value {
    let (springs, fades) = known();
    let springs: Vec<&str> = springs.iter().map(String::as_str).collect();
    let fades: Vec<&str> = fades.iter().map(String::as_str).collect();
    motion_profile::json_schema(&springs, &fades)
}

/// Reads `members`' `motion` into the reader, refusing what the contract or the tokens do not have.
pub(super) fn read(reader: &mut Reader, members: &Map<String, Value>) -> MotionProfile {
    let Some(written) = members.get(KEY) else { return MotionProfile::default() };
    let (mut profile, problems) = MotionProfile::parse(written);
    for problem in problems {
        let value = value_at(written, &problem.path);
        reader.refuse(&problem.path, value, &problem.message);
    }
    let (springs, fades) = known();
    let unknown = |names: &[String], kept: Vec<String>, group: &str| -> Vec<(String, String)> {
        kept.into_iter()
            .filter(|name| !names.contains(name))
            .map(|name| {
                let message =
                    format!("no such design-token {group}; expected one of {}", names.join(", "));
                (format!("{KEY}.{group}.{name}"), message)
            })
            .collect()
    };
    let refused_springs = unknown(springs, profile.springs.keys().cloned().collect(), "springs");
    let refused_fades = unknown(fades, profile.fades.keys().cloned().collect(), "fades");
    for (path, message) in refused_springs.into_iter().chain(refused_fades) {
        reader.refuse(&path, value_at(written, &path), &message);
        let name = path.rsplit('.').next().unwrap_or_default();
        if path.starts_with(&format!("{KEY}.springs.")) {
            profile.springs.remove(name);
        } else {
            profile.fades.remove(name);
        }
    }
    profile
}

/// The written value at a problem's dotted path (`motion.springs.move`), when there is one.
fn value_at<'a>(block: &'a Value, path: &str) -> Option<&'a Value> {
    let rest = path.strip_prefix(KEY)?.strip_prefix('.').unwrap_or_default();
    rest.split('.').filter(|part| !part.is_empty()).try_fold(block, |value, part| value.get(part))
}
