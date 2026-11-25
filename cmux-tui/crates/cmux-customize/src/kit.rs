//! What an agent customizing cmux can build with: the web kit's components
//! (`customize_components`) and the design tokens (`customize_tokens`), for
//! the MCP tools of the same names (cmuxterm-hq RFD
//! `docs/rfd/drafts/component-libraries.md`, adoption 6).
//!
//! Both read the sources themselves, compiled into this binary, so an answer
//! is the code this build ships and never a copy that drifts from it:
//! components from `webviews/src/kit/index.ts`, the files it re-exports and
//! the gallery entries that cover them; tokens from `schemas/design-scale`,
//! `design-roles`, `type-scale`, `motion-scale`, `instrument` and
//! `agent-pane/style-tokens.json`. The generated component manifest
//! (adoption 1, `webviews/src/ui/components.generated.json`) is made on
//! demand and not committed, so it is not in the build; when it is, these
//! read it instead of parsing the TypeScript here.

use serde_json::{Map, Value, json};

mod sources;
mod ts;

pub use sources::{GALLERIES, SOURCES};

/// Where component answers come from, as the result says.
const COMPONENT_SOURCE: &str = "webviews/src/kit/index.ts, the files it re-exports and the *.gallery.tsx entries covering them, compiled into this cmux";

/// The token groups `tokens` answers, in its order.
pub const TOKEN_GROUPS: &[&str] = &[
    "radius",
    "spacing",
    "controls",
    "icons",
    "type",
    "motion",
    "color",
    "elevation",
    "glass",
    "roles",
    "instrument",
    "look",
];

/// Every component the kit barrel exports, or the one named `name`
/// (case-insensitive), each with its props, variants, gallery entries and
/// one example.
pub fn components(name: Option<&str>) -> Result<Value, String> {
    let all = ts::kit_components();
    let names: Vec<String> = all.iter().map(|c| c.name.clone()).collect();
    let chosen: Vec<&ts::Component> = match name {
        None => all.iter().collect(),
        Some(want) => {
            let found: Vec<_> = all.iter().filter(|c| c.name.eq_ignore_ascii_case(want)).collect();
            if found.is_empty() {
                return Err(format!(
                    "no kit component {want:?}; the kit exports {}",
                    names.join(", ")
                ));
            }
            found
        }
    };
    Ok(json!({
        "import": "webviews/src/kit/index.ts",
        "source": COMPONENT_SOURCE,
        "rules": [
            "Import from kit/index.ts only; the files behind it may move.",
            "Color comes from the theme: use the tokens (customize_tokens) or the --cmux-* variables, never a literal color.",
            "Don't restyle .kit-* or .ui-* classes; a variant a page needs belongs in the kit.",
            "Visible text comes from the caller, in the page's language. The kit holds no strings."
        ],
        "count": chosen.len(),
        "components": chosen.iter().map(|c| c.to_json()).collect::<Vec<_>>(),
    }))
}

/// The design tokens with today's values, every group or the one named.
pub fn tokens(group: Option<&str>) -> Result<Value, String> {
    let groups: Vec<&str> = match group {
        None => TOKEN_GROUPS.to_vec(),
        Some(want) => match TOKEN_GROUPS.iter().find(|g| **g == want) {
            Some(g) => vec![*g],
            None => {
                return Err(format!(
                    "no token group {want:?}; groups are {}",
                    TOKEN_GROUPS.join(", ")
                ));
            }
        },
    };
    let mut out = Map::new();
    out.insert(
        "source".into(),
        json!("schemas/design-scale, design-roles, type-scale, motion-scale, instrument and agent-pane/style-tokens.json, compiled into this cmux"),
    );
    out.insert(
        "use".into(),
        json!("In a kit page, the helpers in kit/tokens.ts (radius(\"md\"), space(\"2\"), control(\"row\"), icon(\"16\"), text(\"caption\"), motion(\"quick\"), color(\"muted\")) give each token's var(); in CSS use the `var` named here. A look's stylesheet may set only the `look` group."),
    );
    for g in groups {
        out.insert(g.to_owned(), token_group(g)?);
    }
    Ok(Value::Object(out))
}

fn schema(path: &str) -> Result<Value, String> {
    let text = sources::schema(path).ok_or_else(|| format!("{path} is not compiled in"))?;
    serde_json::from_str(text).map_err(|e| format!("{path}: {e}"))
}

fn list(value: &Value, key: &str) -> Vec<Value> {
    value.get(key).and_then(Value::as_array).cloned().unwrap_or_default()
}

fn str_of<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// One named step: its name, value, CSS variable and what it is for.
fn step(item: &Value, var: String, value_key: &str, unit: &str) -> Value {
    let mut out = Map::new();
    out.insert("name".into(), item.get("name").cloned().unwrap_or(Value::Null));
    if let Some(v) = item.get(value_key) {
        out.insert(unit.into(), v.clone());
    }
    out.insert("var".into(), json!(var));
    if let Some(about) = str_of(item, "for") {
        out.insert("for".into(), json!(about));
    }
    Value::Object(out)
}

fn token_group(group: &str) -> Result<Value, String> {
    let scale = || schema("schemas/design-scale/design-scale.json");
    Ok(match group {
        "radius" => {
            let scale = scale()?;
            let mut items: Vec<Value> = list(&scale, "radii")
                .iter()
                .map(|r| {
                    step(r, format!("--ds-radius-{}", str_of(r, "name").unwrap_or("")), "px", "px")
                })
                .collect();
            for r in list(&scale, "namedRadii") {
                let mut v = step(
                    &r,
                    format!("--ds-radius-{}", str_of(&r, "name").unwrap_or("")),
                    "px",
                    "px",
                );
                if let (Some(obj), Some(from)) = (v.as_object_mut(), str_of(&r, "var")) {
                    obj.insert("value".into(), json!(from));
                }
                items.push(v);
            }
            json!(items)
        }
        "spacing" => {
            let scale = scale()?;
            let spacing = scale.get("spacing").cloned().unwrap_or(Value::Null);
            let steps: Vec<Value> = list(&spacing, "steps")
                .iter()
                .map(|s| {
                    step(s, format!("--ds-space-{}", str_of(s, "name").unwrap_or("")), "px", "px")
                })
                .collect();
            let layout: Vec<Value> = list(&spacing, "layout")
                .iter()
                .map(|px| json!({"name": px.to_string(), "px": px, "var": format!("--ds-space-{px}"), "for": "layout gaps"}))
                .collect();
            json!({"unit": spacing.get("unit"), "steps": steps, "layout": layout})
        }
        "controls" => json!(
            list(&scale()?, "controls")
                .iter()
                .map(|c| step(
                    c,
                    format!("--ds-control-{}", str_of(c, "name").unwrap_or("")),
                    "px",
                    "px"
                ))
                .collect::<Vec<_>>()
        ),
        "icons" => json!(
            list(&scale()?, "icons")
                .iter()
                .map(|c| step(
                    c,
                    format!("--ds-icon-{}", str_of(c, "name").unwrap_or("")),
                    "px",
                    "px"
                ))
                .collect::<Vec<_>>()
        ),
        "type" => {
            let t = schema("schemas/type-scale/type-scale.json")?;
            let steps: Vec<Value> = list(&t, "steps")
                .iter()
                .map(|s| {
                    let name = str_of(s, "name").unwrap_or("");
                    json!({
                        "name": name,
                        "px": s.get("size"),
                        "lineHeight": s.get("lineHeight"),
                        "var": format!("--text-{name}"),
                        "lineHeightVar": format!("--text-{name}--line-height"),
                        "for": s.get("for"),
                    })
                })
                .collect();
            json!({
                "font": t.get("font").and_then(|f| f.get("stack")),
                "fontVar": "--font-ui",
                "steps": steps,
                "weights": t.get("weights"),
            })
        }
        "motion" => {
            let m = schema("schemas/motion-scale/motion-scale.json")?;
            let steps: Vec<Value> = list(&m, "steps")
                .iter()
                .map(|s| {
                    step(
                        s,
                        format!("--cmux-motion-{}", str_of(s, "name").unwrap_or("")),
                        "ms",
                        "ms",
                    )
                })
                .collect();
            json!({
                "steps": steps,
                "easeOut": m.get("easeOut"),
                "spring": m.get("spring").map(|s| json!({"step": s.get("step"), "for": s.get("for")})),
                "settle": m.get("settle").map(|s| json!({"ms": s.get("ms"), "for": s.get("for")})),
                "reduceMotion": "The host applies Reduce Motion and ui.animationSpeed; a page never reads them itself.",
            })
        }
        "color" => {
            let items: Vec<Value> = list(&scale()?, "colors")
                .iter()
                .map(|c| {
                    let name = str_of(c, "name").unwrap_or("");
                    json!({
                        "name": name,
                        "var": format!("--ds-color-{name}"),
                        "value": format!("var({})", str_of(c, "var").unwrap_or("")),
                        "app": c.get("app"),
                        "fallback": c.get("fallback"),
                        "for": c.get("for"),
                    })
                })
                .collect();
            json!({
                "about": "Color roles are never literals: each reads the variable the host derives from the active theme (light and dark follow it); `fallback` draws on a page with no host yet. Change colors with a theme file, not a stylesheet.",
                "roles": items,
            })
        }
        "elevation" => json!(
            list(&scale()?, "elevation")
                .iter()
                .map(|e| json!({
                    "name": e.get("name"),
                    "var": format!("--elevation-{}", str_of(e, "name").unwrap_or("")),
                    "tailwind": format!("shadow-elevation-{}", str_of(e, "name").unwrap_or("")),
                    "geometry": e.get("geometry"),
                    "lightAlpha": e.get("light"),
                    "darkAlpha": e.get("dark"),
                    "for": e.get("for"),
                }))
                .collect::<Vec<_>>()
        ),
        "glass" => json!(
            list(&scale()?, "glass")
                .iter()
                .map(|g| json!({
                    "level": g.get("name"),
                    "tint": g.get("tint"),
                    "darkTint": g.get("darkTint"),
                    "blur": g.get("blur"),
                    "for": g.get("for"),
                    "kit": format!("<Glass level=\"{}\">", str_of(g, "name").unwrap_or("")),
                }))
                .collect::<Vec<_>>()
        ),
        "roles" => {
            let r = schema("schemas/design-roles/design-roles.json")?;
            json!({
                "about": "Tier 2: what a thing is made of, as expressions over the scale (space.N, control.NAME, radius.NAME; self.FIELD is the role itself). Each field is the CSS variable --role-<name>-<field>; a component reads --role-* only.",
                "roles": list(&r, "roles").iter().map(|role| {
                    let mut role = role.clone();
                    if let (Some(obj), Some(name)) = (role.as_object_mut(), role_name(&role)) {
                        let vars: Map<String, Value> = obj.keys()
                            .filter(|k| !matches!(k.as_str(), "name" | "for" | "like"))
                            .map(|k| (k.clone(), json!(format!("--role-{name}-{}", kebab(k)))))
                            .collect();
                        obj.insert("vars".into(), Value::Object(vars));
                    }
                    role
                }).collect::<Vec<_>>(),
            })
        }
        "instrument" => {
            let i = schema("schemas/instrument/instrument.json")?;
            json!({
                "system": i.get("system"),
                "version": i.get("version"),
                "about": "Instrument's token table: `today` is what the app draws now; `instrument` is the value the system names, recorded but not applied where they differ.",
                "tokens": list(&i, "tokens").iter().map(|t| json!({
                    "name": t.get("name"),
                    "today": t.get("today").and_then(|d| d.get("value")),
                    "instrument": t.get("instrument"),
                    "unit": t.get("unit"),
                    "drawnOn": t.get("drawnOn"),
                    "waits": t.get("waits"),
                })).collect::<Vec<_>>(),
            })
        }
        "look" => {
            let s = schema("schemas/agent-pane/style-tokens.json")?;
            json!({
                "interface": s.get("interface"),
                "status": s.get("status"),
                "about": "The CSS custom properties a look's agent-pane/theme.css may set, on :root only. They are paint (color, fill, edge, corner); none moves a box. Type, width and spacing are settings (agentPane.display.*).",
                "tokens": list(&s, "tokens").iter().map(|t| json!({
                    "name": t.get("name"),
                    "kind": t.get("kind"),
                    "about": t.get("about"),
                })).collect::<Vec<_>>(),
            })
        }
        other => return Err(format!("no token group {other:?}")),
    })
}

fn role_name(role: &Value) -> Option<String> {
    str_of(role, "name").map(str::to_owned)
}

fn kebab(key: &str) -> String {
    let mut out = String::new();
    for ch in key.chars() {
        if ch.is_ascii_uppercase() {
            out.push('-');
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

#[cfg(test)]
#[path = "kit_tests.rs"]
mod tests;
