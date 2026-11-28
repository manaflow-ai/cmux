//! The JSON the app asks in: one request object (`op` and its fields) in, one JSON value out.
//! Links are in the shape Swift's synthesized `Codable` gives `DeepLink`: `{"target": {"tab":
//! {"_0": "tab_…"}}, "machine": …, "hostHint": …, "nameHint": …, "message": …}`, nil fields left
//! out.

use super::*;
use serde_json::{Map, Value, json};

fn put(map: &mut Map<String, Value>, key: &str, value: &Option<String>) {
    if let Some(value) = value {
        map.insert(key.to_owned(), Value::String(value.clone()));
    }
}

fn case(name: &str, fields: Map<String, Value>) -> Value {
    let mut outer = Map::new();
    outer.insert(name.to_owned(), Value::Object(fields));
    Value::Object(outer)
}

fn fields(pairs: &[(&str, &String)]) -> Map<String, Value> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), Value::String((*v).clone()))).collect()
}

/// `target` as Swift's `DeepLink.Target` encodes.
pub fn target_value(target: &Target) -> Value {
    match target {
        Target::Workspace(id) => case("workspace", fields(&[("_0", id)])),
        Target::Pane(id) => case("pane", fields(&[("_0", id)])),
        Target::Tab(id) => case("tab", fields(&[("_0", id)])),
        Target::Session { id, turn } => {
            let mut map = fields(&[("_0", id)]);
            put(&mut map, "turn", turn);
            case("session", map)
        }
        Target::ChiefSession { home, session } => {
            case("chiefSession", fields(&[("home", home), ("session", session)]))
        }
        Target::Agent { harness, session } => {
            case("agent", fields(&[("harness", harness), ("session", session)]))
        }
        Target::Group { id, workspace } => {
            let mut map = fields(&[("_0", id)]);
            put(&mut map, "workspace", workspace);
            case("group", map)
        }
        Target::CloudSession { team, machine, session, kind } => {
            let mut map = fields(&[("team", team), ("machine", machine), ("session", session)]);
            map.insert("kind".to_owned(), Value::String(kind.raw().to_owned()));
            case("cloudSession", map)
        }
        Target::LegacyWorkspace { workspace, fallback } => {
            let mut map = fields(&[("_0", workspace)]);
            put(&mut map, "fallback", fallback);
            case("legacyWorkspace", map)
        }
        Target::LegacyPane { workspace, pane } => {
            case("legacyPane", fields(&[("workspace", workspace), ("pane", pane)]))
        }
        Target::LegacySurface { workspace, surface, fallback_workspace, fallback_surface } => {
            let mut map = fields(&[("workspace", workspace), ("surface", surface)]);
            put(&mut map, "fallbackWorkspace", fallback_workspace);
            put(&mut map, "fallbackSurface", fallback_surface);
            case("legacySurface", map)
        }
    }
}

/// `link` as Swift's `DeepLink` encodes.
pub fn link_value(link: &DeepLink) -> Value {
    let mut map = Map::new();
    map.insert("target".to_owned(), target_value(&link.target));
    put(&mut map, "machine", &link.machine);
    put(&mut map, "hostHint", &link.host_hint);
    put(&mut map, "nameHint", &link.name_hint);
    put(&mut map, "message", &link.message);
    Value::Object(map)
}

fn optional_link(link: Option<DeepLink>) -> Value {
    link.as_ref().map_or(Value::Null, link_value)
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn required(value: &Value, key: &str) -> Result<String, String> {
    text(value, key).ok_or_else(|| format!("missing `{key}`"))
}

/// A UUID field: Swift encodes it as its uppercase `uuidString`.
fn uuid_field(value: &Value, key: &str) -> Result<Option<String>, String> {
    match text(value, key) {
        None => Ok(None),
        Some(raw) => uuid(&raw).map(Some).ok_or_else(|| format!("`{key}` is not a UUID")),
    }
}

/// A `DeepLink.Target` as Swift encodes it.
pub fn target_from(value: &Value) -> Result<Target, String> {
    let object = value.as_object().filter(|o| o.len() == 1).ok_or("a target is one case")?;
    let (name, f) = object.iter().next().ok_or("a target is one case")?;
    Ok(match name.as_str() {
        "workspace" => Target::Workspace(required(f, "_0")?),
        "pane" => Target::Pane(required(f, "_0")?),
        "tab" => Target::Tab(required(f, "_0")?),
        "session" => Target::Session { id: required(f, "_0")?, turn: text(f, "turn") },
        "chiefSession" => {
            Target::ChiefSession { home: required(f, "home")?, session: required(f, "session")? }
        }
        "agent" => {
            Target::Agent { harness: required(f, "harness")?, session: required(f, "session")? }
        }
        "group" => Target::Group { id: required(f, "_0")?, workspace: text(f, "workspace") },
        "cloudSession" => Target::CloudSession {
            team: required(f, "team")?,
            machine: required(f, "machine")?,
            session: required(f, "session")?,
            kind: CloudSessionKind::from_raw(&required(f, "kind")?).ok_or("unknown cloud kind")?,
        },
        "legacyWorkspace" => Target::LegacyWorkspace {
            workspace: uuid_field(f, "_0")?.ok_or("missing `_0`")?,
            fallback: uuid_field(f, "fallback")?,
        },
        "legacyPane" => Target::LegacyPane {
            workspace: uuid_field(f, "workspace")?.ok_or("missing `workspace`")?,
            pane: uuid_field(f, "pane")?.ok_or("missing `pane`")?,
        },
        "legacySurface" => Target::LegacySurface {
            workspace: uuid_field(f, "workspace")?.ok_or("missing `workspace`")?,
            surface: uuid_field(f, "surface")?.ok_or("missing `surface`")?,
            fallback_workspace: uuid_field(f, "fallbackWorkspace")?,
            fallback_surface: uuid_field(f, "fallbackSurface")?,
        },
        other => return Err(format!("unknown target `{other}`")),
    })
}

/// A `DeepLink` as Swift encodes it.
pub fn link_from(value: &Value) -> Result<DeepLink, String> {
    Ok(DeepLink {
        target: target_from(value.get("target").ok_or("missing `target`")?)?,
        machine: text(value, "machine"),
        host_hint: text(value, "hostHint"),
        name_hint: text(value, "nameHint"),
        message: text(value, "message"),
    })
}

fn optional_text(value: Option<String>) -> Value {
    value.map_or(Value::Null, Value::String)
}

/// Answers one request. Ops: `read`, `url`, `usedParameters`, `parameters`, `valid`, `appLink`,
/// `groupWeb`, `agentWeb`, `agentWebSession`, `agentReference`, `opensAgentChat`,
/// `settingsPath`, `settingsRoute`, `cloudRoute`, `cloudSession`, `agentTabs`, `export`.
pub fn call(request: &Value) -> Result<Value, String> {
    let op = required(request, "op")?;
    let url = || required(request, "url");
    let scheme = || required(request, "scheme");
    Ok(match op.as_str() {
        "read" => read(&url()?, &scheme()?).map_or(
            Value::Null,
            |parsed| json!({"link": link_value(&parsed.link), "ignoredParameters": parsed.ignored}),
        ),
        "parse" => optional_link(parse(&url()?, &scheme()?)),
        "url" => {
            let link = link_from(request.get("link").ok_or("missing `link`")?)?;
            optional_text(link.url(&scheme()?))
        }
        "usedParameters" => {
            let link = link_from(request.get("link").ok_or("missing `link`")?)?;
            json!(link.used_parameters())
        }
        "parameters" => {
            let target = target_from(request.get("target").ok_or("missing `target`")?)?;
            json!(parameters(&target))
        }
        "valid" => {
            let text = required(request, "text")?;
            let text = text.as_str();
            Value::Bool(match required(request, "rule")?.as_str() {
                "resourceID" => is_resource_id(text, &required(request, "prefix")?),
                "harness" => is_harness(text),
                "agentSession" => is_agent_session(text),
                "hint" => is_hint(text),
                "agentMessage" => is_agent_message(text),
                "cloudVM" => is_cloud_vm(text),
                "cloudSessionID" => is_cloud_session_id(text),
                "agentReference" => is_agent_reference(text),
                other => return Err(format!("unknown rule `{other}`")),
            })
        }
        "appLink" => optional_link(app_link(
            &url()?,
            &scheme()?,
            request.get("chief").and_then(Value::as_bool).unwrap_or(false),
        )),
        "groupWeb" => optional_link(group_web(&url()?)),
        "agentWeb" => optional_link(agent_web(&url()?)),
        "agentWebSession" => optional_text(agent_web_session(&url()?)),
        "agentReference" => optional_text(agent_reference(&url()?, &scheme()?)),
        "opensAgentChat" => Value::Bool(opens_agent_chat(&url()?, &scheme()?)),
        "settingsPath" => optional_text(settings_path(&url()?, &scheme()?)),
        "settingsRoute" => optional_text(settings_route(&url()?, &scheme()?)),
        "cloudRoute" => Value::String(cloud_route(text(request, "row").as_deref())),
        "cloudSession" => optional_link(cloud_session(&required(request, "text")?)),
        "agentTabs" => {
            let terminals: Vec<AgentCandidate> = request
                .get("terminals")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(|row| {
                            Some(AgentCandidate {
                                tab: text(row, "tab")?,
                                harness: text(row, "harness"),
                                session: text(row, "session"),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            json!(agent_tabs(
                &required(request, "harness")?,
                &required(request, "session")?,
                text(request, "adopted").as_deref(),
                &terminals,
            ))
        }
        "export" => {
            let schemes: Vec<ExportScheme> = request
                .get("schemes")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(|row| {
                            Some(ExportScheme {
                                build: text(row, "build")?,
                                bundle_id: text(row, "bundleID"),
                                scheme: text(row, "scheme")?,
                                example_tag: text(row, "exampleTag"),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Value::String(export_json(&schemes))
        }
        other => return Err(format!("unknown op `{other}`")),
    })
}
