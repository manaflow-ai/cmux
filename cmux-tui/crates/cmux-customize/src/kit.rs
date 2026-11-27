//! The component kit, read for agents: its tokens and its components
//! (cmuxterm-hq `docs/rfd/drafts/component-libraries.md`, item 6). Behind
//! `cmux customize tokens|components` and the `customize_tokens` and
//! `customize_components` MCP tools, so an agent asks which token or prop
//! exists instead of guessing one.
//!
//! **Tokens** are built in: Instrument's token file (RFD 0034) and the app's
//! own scales (spacing, radius, type, control, icon, motion), the same JSON
//! files the CSS and Swift generators read. `test` says whether a length is a
//! step of a family, and the nearest step when it is not.
//!
//! **Components** come from the kit's manifest,
//! `webviews/src/ui/components.generated.json`, a build output that
//! `bun webviews/scripts/gen-component-manifest.ts` writes from the kit's
//! sources. It is read where it lies (`CMUX_COMPONENT_MANIFEST`, or the
//! nearest checkout above the working directory); with none, the answer says
//! how to make one. `test` checks a props object against a component's
//! declared props, so a prop that does not exist is named before it ships.
//!
//! Nothing here writes a file or changes what the app draws.

use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

const INSTRUMENT: &str = include_str!("../../../../schemas/instrument/instrument.json");
const DESIGN_SCALE: &str = include_str!("../../../../schemas/design-scale/design-scale.json");
const TYPE_SCALE: &str = include_str!("../../../../schemas/type-scale/type-scale.json");
const SCENE_TYPE: &str = include_str!("../../../../schemas/type-scale/scene-type.json");
const LAYOUT_GRID: &str = include_str!("../../../../schemas/layout-grid/layout-grid.json");
const MOTION_SCALE: &str = include_str!("../../../../schemas/motion-scale/motion-scale.json");

/// Where the component manifest is, relative to a checkout's root.
pub const MANIFEST_PATH: &str = "webviews/src/ui/components.generated.json";
/// Names a component manifest file to read instead of looking for one.
pub const MANIFEST_OVERRIDE: &str = "CMUX_COMPONENT_MANIFEST";
/// How to make the manifest when there is none.
pub const MANIFEST_HOW: &str = "cd webviews && bun scripts/gen-component-manifest.ts (writes src/ui/components.generated.json)";

/// The scale families `tokens test` checks a value against.
pub const FAMILIES: &[&str] = &["spacing", "radius", "type", "control", "icon", "motion"];

/// What `tokens` or `components` was asked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    /// Every row, or one group's (`tokens list ink`, `components list kit`).
    List(Option<String>),
    /// One row whole.
    Show(String),
    /// `tokens test VALUE [--as FAMILY]`, `components test NAME [PROPS_JSON]`.
    Test { subject: String, with: Option<String> },
}

/// Parses the words after `tokens` or `components`. `what` names the verb in
/// errors.
pub fn parse(what: &str, words: &[String]) -> Result<Request, String> {
    let usage = || match what {
        "tokens" => {
            "customize tokens list [GROUP] | show NAME | test VALUE [--as FAMILY]".to_owned()
        }
        _ => "customize components list [TIER|STATUS] | show NAME | test NAME [PROPS_JSON]"
            .to_owned(),
    };
    let Some((action, rest)) = words.split_first() else { return Ok(Request::List(None)) };
    match (action.as_str(), rest) {
        ("list" | "ls", []) => Ok(Request::List(None)),
        ("list" | "ls", [group]) => Ok(Request::List(Some(group.clone()))),
        ("show", [name]) => Ok(Request::Show(name.clone())),
        ("test" | "check", [subject]) => Ok(Request::Test { subject: subject.clone(), with: None }),
        ("test" | "check", [subject, flag, family]) if what == "tokens" && flag == "--as" => {
            Ok(Request::Test { subject: subject.clone(), with: Some(family.clone()) })
        }
        ("test" | "check", [subject, props @ ..]) if what == "components" && !props.is_empty() => {
            Ok(Request::Test { subject: subject.clone(), with: Some(props.join(" ")) })
        }
        _ => Err(format!("{}; got {:?}", usage(), words.join(" "))),
    }
}

/// An answer: the JSON an agent reads and the lines a person reads.
pub struct Answer {
    pub json: Value,
    pub human: String,
}

fn parsed(text: &str) -> Value {
    serde_json::from_str(text).unwrap_or(Value::Null)
}

fn sources() -> &'static [Value; 6] {
    static SOURCES: OnceLock<[Value; 6]> = OnceLock::new();
    SOURCES.get_or_init(|| {
        [INSTRUMENT, DESIGN_SCALE, TYPE_SCALE, SCENE_TYPE, LAYOUT_GRID, MOTION_SCALE].map(parsed)
    })
}

/// One step of a scale family: its name, value and what it is for.
#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    pub name: String,
    pub value: f64,
    pub for_: Option<String>,
}

fn steps(list: &Value, value_key: &str) -> Vec<Step> {
    list.as_array()
        .into_iter()
        .flatten()
        .filter_map(|row| {
            Some(Step {
                name: row.get("name")?.as_str()?.to_owned(),
                value: row.get(value_key)?.as_f64()?,
                for_: row.get("for").and_then(Value::as_str).map(str::to_owned),
            })
        })
        .collect()
}

/// A family's steps, smallest first, from the app's own scale files.
#[allow(
    clippy::indexing_slicing,
    reason = "embedded design-scale JSON has the documented family paths"
)]
pub fn family(name: &str) -> Option<(Vec<Step>, &'static str, &'static str)> {
    let [_, design, type_scale, _, _, motion] = sources();
    let (mut list, unit, source) = match name {
        "spacing" => (
            steps(&design["spacing"]["steps"], "px"),
            "px",
            "schemas/design-scale/design-scale.json spacing.steps",
        ),
        "radius" => {
            let mut list = steps(&design["radii"], "px");
            list.extend(steps(&design["namedRadii"], "px"));
            (list, "px", "schemas/design-scale/design-scale.json radii, namedRadii")
        }
        "type" => {
            (steps(&type_scale["steps"], "size"), "px", "schemas/type-scale/type-scale.json steps")
        }
        "control" => (
            steps(&design["controls"], "px"),
            "px",
            "schemas/design-scale/design-scale.json controls",
        ),
        "icon" => {
            (steps(&design["icons"], "px"), "px", "schemas/design-scale/design-scale.json icons")
        }
        "motion" => {
            (steps(&motion["steps"], "ms"), "ms", "schemas/motion-scale/motion-scale.json steps")
        }
        _ => return None,
    };
    list.sort_by(|a, b| a.value.total_cmp(&b.value));
    Some((list, unit, source))
}

fn step_json(step: &Step) -> Value {
    json!({ "name": step.name, "value": step.value, "for": step.for_ })
}

fn family_json(name: &str) -> Option<Value> {
    let (list, unit, source) = family(name)?;
    Some(json!({
        "family": name,
        "unit": unit,
        "source": source,
        "steps": list.iter().map(step_json).collect::<Vec<_>>(),
    }))
}

fn instrument() -> &'static Value {
    &sources()[0]
}

/// Instrument's tokens, each with its group, CSS property and whether the
/// app draws Instrument's value yet.
#[allow(
    clippy::indexing_slicing,
    reason = "embedded token JSON's today/file path is part of the schema"
)]
fn token_rows() -> Vec<Value> {
    instrument()["tokens"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|token| {
            let name = token.get("name")?.as_str()?;
            let group = name.split('.').next().unwrap_or(name);
            let wanted = token.get("instrument");
            let today = token.get("today").and_then(|t| t.get("value"));
            let drawn = match (wanted, today) {
                (Some(want), Some(now)) => Some(same(want, now)),
                _ => None,
            };
            let mut row = Map::new();
            row.insert("name".into(), json!(name));
            row.insert("group".into(), json!(group));
            for key in ["instrument", "unit", "waits", "rule", "drawnOn", "note"] {
                if let Some(value) = token.get(key) {
                    row.insert(key.into(), value.clone());
                }
            }
            if let Some(now) = today {
                row.insert("today".into(), now.clone());
                row.insert("source".into(), token["today"]["file"].clone());
            }
            if wanted.is_some() {
                row.insert("css".into(), json!(format!("--instrument-{}", name.replace('.', "-"))));
            }
            row.insert("drawn".into(), json!(drawn));
            Some(Value::Object(row))
        })
        .collect()
}

/// Whether today's value is Instrument's (a range holds it, numbers match).
fn same(want: &Value, now: &Value) -> bool {
    if let (Some(min), Some(max), Some(n)) = (want.get("min"), want.get("max"), now.as_f64()) {
        return min.as_f64().is_some_and(|min| min <= n)
            && max.as_f64().is_some_and(|max| n <= max);
    }
    match (want.as_f64(), now.as_f64()) {
        (Some(a), Some(b)) => (a - b).abs() < 1e-9,
        _ => want == now,
    }
}

fn number(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => "-".to_owned(),
        other => other.to_string(),
    }
}

/// `tokens list|show|test`.
pub fn tokens(request: &Request) -> Result<Answer, String> {
    let rows = token_rows();
    match request {
        Request::List(group) => {
            let picked: Vec<&Value> = rows
                .iter()
                .filter(|row| group.as_deref().is_none_or(|g| row["group"] == g))
                .collect();
            if let Some(g) = group
                && picked.is_empty()
            {
                if let Some(scale) = family_json(g) {
                    return Ok(scale_answer(scale));
                }
                return Err(format!(
                    "no token group or scale family {g:?}; families: {}",
                    FAMILIES.join(", ")
                ));
            }
            let mut human = format!(
                "{} {} tokens ({} of {}); value today, then Instrument's where it differs:\n",
                instrument()["system"].as_str().unwrap_or("Instrument"),
                instrument()["version"].as_str().unwrap_or(""),
                picked.len(),
                rows.len(),
            );
            for row in &picked {
                let now = row.get("today").map(number).unwrap_or_else(|| "-".to_owned());
                let later = match row["drawn"] {
                    Value::Bool(false) => format!("  -> {}", number(&row["instrument"])),
                    _ => String::new(),
                };
                human.push_str(&format!("  {:<28} {now}{later}\n", number(&row["name"])));
            }
            human.push_str(&format!(
                "Scales: {}. Next: cmux customize tokens show NAME, or tokens test 14 --as spacing\n",
                FAMILIES.join(", ")
            ));
            let families: Map<String, Value> =
                FAMILIES.iter().filter_map(|f| Some(((*f).to_owned(), family_json(f)?))).collect();
            Ok(Answer {
                json: json!({
                    "system": instrument()["system"],
                    "version": instrument()["version"],
                    "rfd": instrument()["rfd"],
                    "tokens": picked,
                    "families": families,
                }),
                human,
            })
        }
        Request::Show(name) => {
            if let Some(row) =
                rows.iter().find(|row| row["name"] == name.as_str() || row["css"] == name.as_str())
            {
                let human = serde_json::to_string_pretty(row).unwrap_or_default() + "\n";
                return Ok(Answer { json: json!({ "token": row }), human });
            }
            if let Some(scale) = family_json(name) {
                return Ok(scale_answer(scale));
            }
            let close: Vec<&str> = rows
                .iter()
                .filter_map(|row| row["name"].as_str())
                .filter(|n| n.contains(name.as_str()))
                .take(8)
                .collect();
            Err(format!(
                "no token {name:?}{}; `cmux customize tokens list` lists them",
                if close.is_empty() {
                    String::new()
                } else {
                    format!(" (did you mean {})", close.join(", "))
                }
            ))
        }
        Request::Test { subject, with } => test_value(subject, with.as_deref()),
    }
}

#[allow(
    clippy::indexing_slicing,
    reason = "scale_answer consumes the schema produced by family_json"
)]
fn scale_answer(scale: Value) -> Answer {
    let mut human = format!(
        "{} ({}, from {}):\n",
        number(&scale["family"]),
        number(&scale["unit"]),
        number(&scale["source"])
    );
    for step in scale["steps"].as_array().into_iter().flatten() {
        human.push_str(&format!(
            "  {:<10} {:>6}  {}\n",
            number(&step["name"]),
            number(&step["value"]),
            step["for"].as_str().unwrap_or("")
        ));
    }
    Answer { json: json!({ "scale": scale }), human }
}

/// The verdict on one value in one family.
pub fn verdict(value: f64, family_name: &str) -> Option<Value> {
    let (list, unit, source) = family(family_name)?;
    let exact: Vec<&Step> = list.iter().filter(|s| (s.value - value).abs() < 1e-9).collect();
    let nearest = list.iter().min_by(|a, b| {
        (a.value - value)
            .abs()
            .total_cmp(&(b.value - value).abs())
            .then(a.value.total_cmp(&b.value))
    });
    let ok = !exact.is_empty();
    let fix = match (ok, nearest) {
        (false, Some(near)) => Some(format!(
            "{value}{unit} is not a {family_name} step; use {} ({}{unit})",
            near.name, near.value
        )),
        _ => None,
    };
    Some(json!({
        "family": family_name,
        "unit": unit,
        "source": source,
        "ok": ok,
        "steps": exact.iter().map(|s| step_json(s)).collect::<Vec<_>>(),
        "nearest": nearest.map(step_json),
        "fix": fix,
    }))
}

fn test_value(subject: &str, family_name: Option<&str>) -> Result<Answer, String> {
    let trimmed =
        subject.trim().trim_end_matches("px").trim_end_matches("ms").trim_end_matches("pt");
    let Ok(value) = trimmed.parse::<f64>() else {
        // A token name or CSS property: say whether it exists.
        let rows = token_rows();
        let found = rows.iter().find(|row| row["name"] == subject || row["css"] == subject);
        return match found {
            Some(row) => Ok(Answer {
                json: json!({ "value": subject, "ok": true, "token": row }),
                human: format!("{subject} is an Instrument token\n"),
            }),
            None => Ok(Answer {
                json: json!({ "value": subject, "ok": false,
                    "fix": "not a token; `cmux customize tokens list` lists every one" }),
                human: format!(
                    "{subject} is not a token; `cmux customize tokens list` lists them\n"
                ),
            }),
        };
    };
    let families: Vec<&str> = match family_name {
        Some(name) if FAMILIES.contains(&name) => vec![name],
        Some(name) => {
            return Err(format!("no scale family {name:?}; families: {}", FAMILIES.join(", ")));
        }
        None if subject.ends_with("ms") => vec!["motion"],
        None => FAMILIES.iter().copied().filter(|f| *f != "motion").collect(),
    };
    let verdicts: Vec<Value> = families.iter().filter_map(|f| verdict(value, f)).collect();
    let ok = verdicts.iter().any(|v| v["ok"] == true);
    let mut human = String::new();
    for v in &verdicts {
        match v["fix"].as_str() {
            Some(fix) => human.push_str(&format!("  {fix}\n")),
            None => human.push_str(&format!(
                "  {value} is {} {}\n",
                number(&v["family"]),
                v["steps"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|s| number(&s["name"]))
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        }
    }
    Ok(Answer { json: json!({ "value": value, "ok": ok, "families": verdicts }), human })
}

/// Where the component manifest is: `CMUX_COMPONENT_MANIFEST`, else the
/// nearest checkout at or above `start` that has one.
pub fn manifest_path(start: &Path) -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(MANIFEST_OVERRIDE) {
        return Some(PathBuf::from(path));
    }
    start.ancestors().map(|dir| dir.join(MANIFEST_PATH)).find(|path| path.is_file())
}

/// `components list|show|test` against a manifest read from `path` (None:
/// there is none here, and the answer says how to make one).
pub fn components(request: &Request, path: Option<&Path>) -> Result<Answer, String> {
    let Some(path) = path else {
        return Ok(Answer {
            json: json!({ "available": false, "manifest": MANIFEST_PATH, "make": MANIFEST_HOW }),
            human: format!(
                "No component manifest here ({MANIFEST_PATH}). Make it: {MANIFEST_HOW}\n"
            ),
        });
    };
    let text = std::fs::read_to_string(path).map_err(|error| {
        format!("cannot read the component manifest {}: {error}", path.display())
    })?;
    let manifest: Value = serde_json::from_str(&text).map_err(|error| {
        format!("the component manifest {} is not JSON: {error}", path.display())
    })?;
    components_in(request, &manifest, path)
}

fn component_list(manifest: &Value) -> Vec<&Value> {
    manifest["components"].as_array().into_iter().flatten().collect()
}

/// `components` over a manifest already read.
pub fn components_in(request: &Request, manifest: &Value, path: &Path) -> Result<Answer, String> {
    let all = component_list(manifest);
    let find = |name: &str| {
        all.iter()
            .copied()
            .find(|c| c["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(name)))
    };
    let missing = |name: &str| {
        let close: Vec<&str> = all
            .iter()
            .filter_map(|c| c["name"].as_str())
            .filter(|n| n.to_lowercase().contains(&name.to_lowercase()))
            .take(8)
            .collect();
        format!(
            "no component {name:?}{}; `cmux customize components list` lists them",
            if close.is_empty() {
                String::new()
            } else {
                format!(" (did you mean {})", close.join(", "))
            }
        )
    };
    match request {
        Request::List(filter) => {
            let picked: Vec<Value> = all
                .iter()
                .filter(|c| filter.as_deref().is_none_or(|f| c["tier"] == f || c["status"] == f))
                .map(|c| {
                    json!({
                        "name": c["name"], "tier": c["tier"], "status": c["status"],
                        "summary": c["summary"], "kitExport": c["kitExport"], "doc": c["doc"],
                        "props": c["props"].as_array().map_or(0, Vec::len),
                    })
                })
                .collect();
            let mut human = format!("{} components ({}):\n", picked.len(), path.display());
            for c in &picked {
                human.push_str(&format!(
                    "  {:<22} {:<4} {:<12} {}\n",
                    number(&c["name"]),
                    number(&c["tier"]),
                    number(&c["status"]),
                    c["summary"].as_str().unwrap_or("")
                ));
            }
            human.push_str("Next: cmux customize components show NAME\n");
            Ok(Answer {
                json: json!({ "available": true, "manifest": path, "gallery": manifest["galleryPath"], "components": picked }),
                human,
            })
        }
        Request::Show(name) => {
            let component = find(name).ok_or_else(|| missing(name))?;
            let human = serde_json::to_string_pretty(component).unwrap_or_default() + "\n";
            Ok(Answer { json: json!({ "available": true, "component": component }), human })
        }
        Request::Test { subject, with } => {
            let component = find(subject).ok_or_else(|| missing(subject))?;
            let props: Map<String, Value> = match with.as_deref() {
                None => Map::new(),
                Some(text) => match serde_json::from_str(text) {
                    Ok(Value::Object(props)) => props,
                    _ => return Err(format!("props must be a JSON object, got {text:?}")),
                },
            };
            Ok(test_props(component, &props))
        }
    }
}

/// Checks a props object against what a component declares: a prop it does
/// not declare, and a required one left out.
pub fn test_props(component: &Value, props: &Map<String, Value>) -> Answer {
    let declared: Vec<&Value> = component["props"].as_array().into_iter().flatten().collect();
    let declared_name = |name: &str| declared.iter().any(|p| p["name"] == name);
    let extends: Vec<&str> =
        component["extends"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut problems = Vec::new();
    for key in props.keys() {
        if declared_name(key)
            || key == "children"
            || key == "className"
            || key.starts_with("data-")
            || key.starts_with("aria-")
        {
            continue;
        }
        if extends.is_empty() {
            problems.push(json!({ "prop": key, "problem": "unknown",
                "fix": format!("{} declares no prop {key:?}; drop it", number(&component["name"])) }));
        } else {
            problems.push(json!({ "prop": key, "problem": "inherited?",
                "fix": format!("{} does not declare {key:?}; it passes through only if {} has it", number(&component["name"]), extends.join(" or ")) }));
        }
    }
    for prop in &declared {
        let name = prop["name"].as_str().unwrap_or_default();
        if prop["optional"] == false && !props.contains_key(name) {
            problems.push(json!({ "prop": name, "problem": "missing",
                "fix": format!("{name} is required ({})", number(&prop["type"])) }));
        }
    }
    let ok = !problems.iter().any(|p| p["problem"] != "inherited?");
    let mut human = format!(
        "{}: {}\n",
        number(&component["name"]),
        if problems.is_empty() {
            "every prop is declared"
        } else if ok {
            "check these"
        } else {
            "fix these"
        }
    );
    for p in &problems {
        human.push_str(&format!("  {}\n", number(&p["fix"])));
    }
    Answer {
        json: json!({ "component": component["name"], "ok": ok, "problems": problems,
            "declared": declared.iter().map(|p| p["name"].clone()).collect::<Vec<_>>() }),
        human,
    }
}

#[cfg(test)]
#[path = "kit_tests.rs"]
mod tests;
