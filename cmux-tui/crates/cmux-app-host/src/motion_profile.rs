//! A look's `motion` block: named spring presets and overrides of the chrome's design-token springs
//! and fades, bounded by the scene motion contract (`cmux.motion/1`, [`crate::motion`]).
//!
//! A theme file (and so a look, a theme pack and a profile, which carry theme files) may write:
//!
//! ```json
//! "motion": {
//!   "presets": { "drawer": { "duration": 0.32, "bounce": 0.1 } },
//!   "springs": { "move": { "duration": 0.2 } },
//!   "fades":   { "fadeIn": 0.16 }
//! }
//! ```
//!
//! A spring is `{duration, bounce}`, SwiftUI's `.spring(duration:bounce:)`: `duration` is the
//! perceptual duration in seconds (SwiftUI's `response`) and `bounce` 0 is critically damped, more
//! overshoots. [`SpringSpec::response`] and [`SpringSpec::damping_fraction`] convert it to the
//! response and damping fraction the renderers and `cmux-motion` step (Apple's mapping, damping
//! fraction = 1 - bounce). Every number is clamped to the contract's ranges ([`crate::motion::TIME_RANGE`],
//! [`crate::motion::DAMPING_RANGE`], so `bounce` is in [`BOUNCE_RANGE`]); a malformed entry is
//! dropped with a [`Problem`] naming it and the others still apply. A file without the block, or
//! with an empty one, changes no timing: every default is the design token's own value.
//!
//! This module checks the block's shape only. Which `springs` and `fades` names exist is the
//! design tokens' (`design-tokens.json` `motion.springs` and `motion.fades`); cmux-config's theme
//! file reader checks the names against them.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use crate::motion::{DAMPING_RANGE, MOTION_TOKENS, TIME_RANGE};

/// The key a theme file writes the block under.
pub const KEY: &str = "motion";
/// `bounce`: 0 is critically damped; the most is the contract's lowest damping fraction.
pub const BOUNCE_RANGE: (f64, f64) = (0.0, 1.0 - DAMPING_RANGE.0);
/// The most presets one block names.
pub const MAX_PRESETS: usize = 64;
/// The longest preset name.
pub const MAX_PRESET_NAME: usize = 48;

/// One spring, as SwiftUI's `.spring(duration:bounce:)`, both values clamped.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpringSpec {
    /// Seconds, in [`TIME_RANGE`].
    pub duration: f64,
    /// In [`BOUNCE_RANGE`]; 0 does not overshoot.
    pub bounce: f64,
}

impl SpringSpec {
    /// The spring with both values clamped to the contract.
    pub fn new(duration: f64, bounce: f64) -> Self {
        Self { duration: clamp(duration, TIME_RANGE), bounce: clamp(bounce, BOUNCE_RANGE) }
    }

    /// SwiftUI's `response`: the duration.
    pub fn response(self) -> f64 {
        self.duration
    }

    /// The damping fraction: 1 - bounce (Apple's mapping for a bounce of 0 or more).
    pub fn damping_fraction(self) -> f64 {
        1.0 - self.bounce
    }

    /// The canonical JSON: `{duration, bounce, response, dampingFraction}`.
    pub fn to_json(self) -> Value {
        json!({
            "duration": self.duration,
            "bounce": self.bounce,
            "response": self.response(),
            "dampingFraction": self.damping_fraction(),
        })
    }
}

/// A part of the block that was left out, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Problem {
    /// Dotted, from the block: `motion.springs.move.duration`.
    pub path: String,
    pub message: String,
}

/// A parsed `motion` block. The default (no block) overrides nothing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MotionProfile {
    /// Named springs an app's nodes and the chrome can share, by name.
    pub presets: BTreeMap<String, SpringSpec>,
    /// Design-token spring overrides by token name (`move`, `appear`, ...).
    pub springs: BTreeMap<String, SpringSpec>,
    /// Design-token fade overrides by token name (`fadeIn`, `hover`, ...), seconds.
    pub fades: BTreeMap<String, f64>,
}

impl MotionProfile {
    /// True when the block changes nothing.
    pub fn is_empty(&self) -> bool {
        self.presets.is_empty() && self.springs.is_empty() && self.fades.is_empty()
    }

    /// Reads a `motion` block: every valid entry, clamped, and a problem per entry left out.
    pub fn parse(value: &Value) -> (Self, Vec<Problem>) {
        let mut profile = Self::default();
        let mut problems = Vec::new();
        let Some(fields) = value.as_object() else {
            problems.push(problem(KEY, "expected an object with presets, springs or fades"));
            return (profile, problems);
        };
        for key in fields.keys() {
            if !matches!(key.as_str(), "presets" | "springs" | "fades") {
                problems.push(problem(
                    &format!("{KEY}.{key}"),
                    "unknown key (presets, springs or fades)",
                ));
            }
        }
        if let Some(presets) = entries(fields, "presets", &mut problems) {
            for (name, value) in presets {
                let path = format!("{KEY}.presets.{name}");
                if let Err(message) = check_preset_name(name) {
                    problems.push(problem(&path, &message));
                } else if profile.presets.len() >= MAX_PRESETS {
                    problems.push(problem(&path, &format!("more than {MAX_PRESETS} presets")));
                } else {
                    match spring(value, &path) {
                        Ok(spec) => {
                            profile.presets.insert(name.clone(), spec);
                        }
                        Err(p) => problems.push(p),
                    }
                }
            }
        }
        if let Some(springs) = entries(fields, "springs", &mut problems) {
            for (name, value) in springs {
                match spring(value, &format!("{KEY}.springs.{name}")) {
                    Ok(spec) => {
                        profile.springs.insert(name.clone(), spec);
                    }
                    Err(p) => problems.push(p),
                }
            }
        }
        if let Some(fades) = entries(fields, "fades", &mut problems) {
            for (name, value) in fades {
                let path = format!("{KEY}.fades.{name}");
                match value.as_f64().filter(|seconds| seconds.is_finite()) {
                    Some(seconds) => {
                        profile.fades.insert(name.clone(), clamp(seconds, TIME_RANGE));
                    }
                    None => problems.push(problem(&path, "expected a number of seconds")),
                }
            }
        }
        (profile, problems)
    }

    /// The canonical JSON: each spring as [`SpringSpec::to_json`], each fade in seconds.
    pub fn to_json(&self) -> Value {
        let springs = |table: &BTreeMap<String, SpringSpec>| -> Map<String, Value> {
            table.iter().map(|(name, spec)| (name.clone(), spec.to_json())).collect()
        };
        json!({
            "presets": springs(&self.presets),
            "springs": springs(&self.springs),
            "fades": self.fades,
        })
    }

    /// The preset `name` as a `cmux.motion/1` spring (`{"spring": {response, dampingFraction}}`),
    /// the form a scene's `animation` prop takes.
    pub fn preset_animation(&self, name: &str) -> Option<Value> {
        self.presets.get(name).map(|spec| {
            json!({ "spring": { "response": spec.response(), "dampingFraction": spec.damping_fraction() } })
        })
    }
}

/// A preset name: a letter, then letters, digits, `-` or `_`, at most [`MAX_PRESET_NAME`], and no
/// `cmux.motion/1` token (`smooth`, `move`, ...), so an `animation` name means one thing.
pub fn check_preset_name(name: &str) -> Result<(), String> {
    let mut chars = name.chars();
    let valid = name.len() <= MAX_PRESET_NAME
        && chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if !valid {
        return Err(format!(
            "a preset name is a letter, then letters, digits, - or _, at most {MAX_PRESET_NAME}"
        ));
    }
    if MOTION_TOKENS.contains(&name) {
        return Err(format!("{name:?} is a cmux.motion/1 token; name the preset otherwise"));
    }
    Ok(())
}

/// The JSON Schema of the block (the theme file schema's `motion` property).
pub fn json_schema(springs: &[&str], fades: &[&str]) -> Value {
    let spring = json!({
        "type": "object",
        "description": "SwiftUI .spring(duration:bounce:): duration in seconds, bounce 0 (no overshoot) up to 0.7.",
        "properties": {
            "duration": { "type": "number", "minimum": TIME_RANGE.0, "maximum": TIME_RANGE.1 },
            "bounce": { "type": "number", "minimum": BOUNCE_RANGE.0, "maximum": BOUNCE_RANGE.1 },
        },
        "additionalProperties": false,
    });
    let named = |names: &[&str], item: &Value| -> Value {
        let properties: Map<String, Value> =
            names.iter().map(|name| ((*name).to_string(), item.clone())).collect();
        json!({ "type": "object", "properties": properties, "additionalProperties": false })
    };
    let fade = json!({ "type": "number", "minimum": TIME_RANGE.0, "maximum": TIME_RANGE.1 });
    let springs = named(springs, &spring);
    json!({
        "type": "object",
        "description": "The look's motion: named spring presets and overrides of the chrome's design-token springs and fades. Absent keys keep the defaults.",
        "properties": {
            "presets": {
                "type": "object",
                "maxProperties": MAX_PRESETS,
                "propertyNames": { "pattern": format!("^[A-Za-z][A-Za-z0-9_-]{{0,{}}}$", MAX_PRESET_NAME - 1) },
                "additionalProperties": spring,
            },
            "springs": springs,
            "fades": named(fades, &fade),
        },
        "additionalProperties": false,
    })
}

fn entries<'a>(
    fields: &'a Map<String, Value>,
    key: &str,
    problems: &mut Vec<Problem>,
) -> Option<&'a Map<String, Value>> {
    let value = fields.get(key)?;
    let entries = value.as_object();
    if entries.is_none() {
        problems.push(problem(&format!("{KEY}.{key}"), "expected an object of name to value"));
    }
    entries
}

fn spring(value: &Value, path: &str) -> Result<SpringSpec, Problem> {
    let fields = value
        .as_object()
        .ok_or_else(|| problem(path, "a spring is {duration, bounce?} (seconds, 0 to 0.7)"))?;
    if let Some(key) = fields.keys().find(|key| !matches!(key.as_str(), "duration" | "bounce")) {
        return Err(problem(&format!("{path}.{key}"), "unknown key (duration or bounce)"));
    }
    let number = |key: &str| -> Result<Option<f64>, Problem> {
        match fields.get(key) {
            None => Ok(None),
            Some(value) => value
                .as_f64()
                .filter(|n| n.is_finite())
                .map(Some)
                .ok_or_else(|| problem(&format!("{path}.{key}"), "expected a number")),
        }
    };
    let duration =
        number("duration")?.ok_or_else(|| problem(path, "duration (seconds) is required"))?;
    Ok(SpringSpec::new(duration, number("bounce")?.unwrap_or(0.0)))
}

fn problem(path: &str, message: &str) -> Problem {
    Problem { path: path.to_string(), message: message.to_string() }
}

fn clamp(value: f64, (low, high): (f64, f64)) -> f64 {
    value.clamp(low, high)
}

#[cfg(test)]
#[path = "motion_profile_tests.rs"]
mod tests;
