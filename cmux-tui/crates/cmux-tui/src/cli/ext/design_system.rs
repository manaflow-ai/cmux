//! The design system a design check holds a scene to: cmux's own, or a person's
//! `cmux-design.json` (`cmux.design/1`) on top of it. A person's file renames nothing it does
//! not set: it overrides or adds type roles, replaces the spacing scale, names cmux color
//! roles and moves the limits. The SDK reads the same file (`defineDesign`, `design.ts`) and
//! draws its viewer (`DesignSystemView`).

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::Value;

use super::design::Finding;
use super::scene_type;

/// The file a folder's own design system lives in.
pub(super) const FILE: &str = "cmux-design.json";

/// The format a design system file declares.
const FORMAT: &str = "cmux.design/1";

/// cmux's spacing scale, in points (the SDK's `SPACE`): a 4 pt grid with 2 and 6 for tight rows.
const CMUX_SPACE: [f64; 11] = [0.0, 2.0, 4.0, 6.0, 8.0, 12.0, 16.0, 20.0, 24.0, 32.0, 48.0];

/// The cmux color roles a person's color names may stand for (the ones that keep contrast).
const COLOR_ROLES: [&str; 8] =
    ["primary", "secondary", "tertiary", "accent", "success", "warning", "danger", "separator"];

const WEIGHTS: [&str; 4] = ["regular", "medium", "semibold", "bold"];

/// Type roles a system may have in all.
const MAX_ROLES: usize = 12;

/// One type role.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Role {
    pub name: String,
    /// The SDK helper that draws it, for cmux's roles a person's file leaves alone.
    pub helper: Option<&'static str>,
    pub size: f64,
    pub weight: String,
}

impl Role {
    /// How a fix names the call that draws this role (a person's role: their `defineDesign` system's
    /// `text`).
    pub(super) fn call(&self) -> String {
        match self.helper {
            Some(helper) => format!("{helper}(...) ({} pt)", self.size),
            None => format!("design.text(\"{}\", ...) ({} pt)", self.name, self.size),
        }
    }
}

/// A design system: cmux's, or a person's merged over it.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct System {
    pub name: String,
    pub roles: Vec<Role>,
    pub space: Vec<f64>,
    /// A person's color names, each a cmux color role.
    pub colors: BTreeMap<String, String>,
    /// Text styles one view may use.
    pub max_roles: usize,
    /// Accent colors one view may use (the theme accent counts as one).
    pub max_accents: usize,
}

impl System {
    /// cmux's own system.
    pub(super) fn cmux() -> Self {
        Self {
            name: "cmux".into(),
            // cmux's type roles come from the one scene type table both renderers draw
            // (`scene_type.rs`, schemas/type-scale/scene-type.json).
            roles: scene_type::roles()
                .iter()
                .map(|role| Role {
                    name: role.name.clone(),
                    helper: role.helper.as_deref(),
                    size: role.size,
                    weight: role.weight.clone(),
                })
                .collect(),
            space: CMUX_SPACE.to_vec(),
            colors: BTreeMap::new(),
            max_roles: 4,
            max_accents: 2,
        }
    }

    /// The system folder `dir` declares in `cmux-design.json`, or cmux's when it has none.
    /// A file that does not read is a `system` finding, and the check uses cmux's system.
    pub(super) fn load(dir: &Path) -> (Self, Option<Finding>) {
        let path = dir.join(FILE);
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return (Self::cmux(), None),
            Err(e) => return (Self::cmux(), Some(problem_finding(&e.to_string()))),
        };
        match serde_json::from_str::<Value>(&text)
            .map_err(|e| e.to_string())
            .and_then(|value| Self::from_json(&value))
        {
            Ok(system) => (system, None),
            Err(problem) => (Self::cmux(), Some(problem_finding(&problem))),
        }
    }

    /// A `cmux.design/1` document merged over cmux's system; the error names the field and its fix.
    pub(super) fn from_json(value: &Value) -> Result<Self, String> {
        let mut system = Self::cmux();
        let doc = value.as_object().ok_or("the file is not a JSON object")?;
        match doc.get("design").and_then(Value::as_str) {
            Some(FORMAT) => {}
            _ => return Err(format!("\"design\" must be \"{FORMAT}\"")),
        }
        if let Some(name) = doc.get("name") {
            system.name = name.as_str().ok_or("\"name\" must be a string")?.to_string();
        }
        if let Some(types) = doc.get("type") {
            let types = types.as_object().ok_or("\"type\" must be an object of roles")?;
            for (name, role) in types {
                let size = role
                    .get("size")
                    .and_then(Value::as_f64)
                    .filter(|s| (9.0..=64.0).contains(s))
                    .ok_or_else(|| {
                        format!("type.{name}.size must be a number of points, 9 to 64")
                    })?;
                let weight = match role.get("weight") {
                    None | Some(Value::Null) => "regular",
                    Some(weight) => {
                        weight.as_str().filter(|w| WEIGHTS.contains(w)).ok_or_else(|| {
                            format!("type.{name}.weight must be one of {}", WEIGHTS.join(", "))
                        })?
                    }
                };
                if role.get("monospaced").is_some_and(|m| !m.is_boolean()) {
                    return Err(format!("type.{name}.monospaced must be true or false"));
                }
                let role = Role { name: name.clone(), helper: None, size, weight: weight.into() };
                match system.roles.iter_mut().find(|r| r.name == *name) {
                    Some(existing) => *existing = role,
                    None => system.roles.push(role),
                }
            }
            if system.roles.len() > MAX_ROLES {
                return Err(format!(
                    "{} type roles in all; a system has {MAX_ROLES} at most",
                    system.roles.len()
                ));
            }
        }
        if let Some(space) = doc.get("space") {
            let steps: Vec<f64> = space
                .as_array()
                .ok_or("\"space\" must be a list of points")?
                .iter()
                .map(|n| n.as_f64().filter(|n| (0.0..=64.0).contains(n)))
                .collect::<Option<_>>()
                .ok_or("space steps must be numbers of points, 0 to 64")?;
            let ascending = steps.windows(2).all(|pair| matches!(pair, [low, high] if low < high));
            if steps.first() != Some(&0.0) || !ascending || !(2..=16).contains(&steps.len()) {
                return Err("\"space\" must start at 0 and go up, 2 to 16 steps".into());
            }
            system.space = steps;
        }
        if let Some(colors) = doc.get("colors") {
            let colors = colors.as_object().ok_or("\"colors\" must be an object of names")?;
            for (name, role) in colors {
                let role = role.as_str().filter(|r| COLOR_ROLES.contains(r)).ok_or_else(|| {
                    format!("colors.{name} must name a cmux color role: {}", COLOR_ROLES.join(", "))
                })?;
                system.colors.insert(name.clone(), role.into());
            }
        }
        if let Some(limits) = doc.get("limits") {
            let limit = |key: &str,
                         range: std::ops::RangeInclusive<u64>|
             -> Result<Option<usize>, String> {
                match limits.get(key) {
                    None => Ok(None),
                    Some(n) => n
                        .as_f64()
                        .filter(|n| n.fract() == 0.0 && *n >= 0.0)
                        .map(|n| n as u64)
                        .filter(|n| range.contains(n))
                        .map(|n| Some(n as usize))
                        .ok_or_else(|| {
                            format!("limits.{key} must be {} to {}", range.start(), range.end())
                        }),
                }
            };
            if let Some(n) = limit("typeRoles", 1..=8)? {
                system.max_roles = n;
            }
            if let Some(n) = limit("accents", 1..=4)? {
                system.max_accents = n;
            }
        }
        Ok(system)
    }

    /// The role a point size and weight are, if any.
    pub(super) fn role_of(&self, size: f64, weight: &str) -> Option<&Role> {
        let weight = if weight.is_empty() { "regular" } else { weight };
        self.roles.iter().find(|r| r.size == size && r.weight == weight)
    }

    pub(super) fn has_size(&self, size: f64) -> bool {
        self.roles.iter().any(|r| r.size == size)
    }

    /// The two roles nearest an off-scale size, as a fix names them.
    pub(super) fn nearest_roles(&self, size: f64) -> String {
        let mut roles: Vec<&Role> = self.roles.iter().collect();
        roles.sort_by(|a, b| (a.size - size).abs().total_cmp(&(b.size - size).abs()));
        roles.iter().take(2).map(|r| r.call()).collect::<Vec<_>>().join(" or ")
    }

    /// The step of the spacing scale nearest `value`: the larger one on a tie, so a gap never
    /// vanishes (the SDK's viewer rounds the same way).
    pub(super) fn nearest_step(&self, value: f64) -> f64 {
        self.space
            .iter()
            .rev()
            .min_by(|a, b| (*a - value).abs().total_cmp(&(*b - value).abs()))
            .copied()
            .unwrap_or(0.0)
    }

    /// The scale as a fix prints it: `SPACE: 0 2 4 ...` for cmux's, `space: ...` for a person's.
    pub(super) fn scale_text(&self) -> String {
        let steps = self.space.iter().map(|s| s.to_string()).collect::<Vec<_>>().join(" ");
        if self.name == "cmux" {
            format!("SPACE: {steps}")
        } else {
            format!("{} space: {steps}", self.name)
        }
    }
}

fn problem_finding(problem: &str) -> Finding {
    Finding {
        check: "system",
        node: None,
        message: format!("{FILE}: {problem}; checking against cmux's design system instead"),
        fix: format!("fix {FILE} (format {FORMAT}: type, space, colors, limits)"),
        count: 1,
    }
}

#[cfg(test)]
#[path = "design_system_tests.rs"]
mod tests;
