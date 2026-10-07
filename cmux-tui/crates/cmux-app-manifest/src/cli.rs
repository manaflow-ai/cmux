//! App CLI commands and MCP tools (plans/cmux-next/app-commands-codemode.md
//! sections 1 and 2). An app's ops are offered as `cmux <cli.name> <path>`
//! and `cmux apps run <app id> <path>`, and as MCP tools named after the op.
//! The validator checks one app. Clashes between installed apps are not a
//! validator rule: the registry and the app supervisor decide them, and
//! [`conflicts`] is the shared helper they call.

use crate::issue::Issue;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::OnceLock;

/// Words no app may take as its `cli.name`, embedded like the schemas.
pub const CLI_RESERVED: &str = include_str!("../../cmux-app-host/schema/v2/cli-reserved.json");

/// The longest MCP tool name an app op may produce. MCP clients cap names at
/// 64 characters and prefix them (`mcp__cmux__`), so 48 leaves room.
pub const MCP_TOOL_NAME_MAX: usize = 48;

struct Reserved {
    names: HashSet<String>,
    first_party: BTreeMap<String, String>,
}

fn reserved() -> &'static Reserved {
    static TABLE: OnceLock<Reserved> = OnceLock::new();
    TABLE.get_or_init(|| {
        let table: Value = serde_json::from_str(CLI_RESERVED).expect("cli-reserved.json is JSON");
        let names = table["names"]
            .as_array()
            .expect("cli-reserved.json has names")
            .iter()
            .map(|n| n.as_str().expect("reserved names are strings").to_owned())
            .collect();
        let first_party = table["firstParty"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(word, app)| {
                (word.clone(), app.as_str().expect("firstParty maps to app ids").to_owned())
            })
            .collect();
        Reserved { names, first_party }
    })
}

/// True when `name` is a built-in or reserved top-level CLI word.
pub fn is_reserved_cli_name(name: &str) -> bool {
    reserved().names.contains(name)
}

/// The first-party app id that may claim the reserved word `name` as its
/// `cli.name` (for example `cloud` -> `cmux/cloud`), if any.
pub fn first_party_cli_owner(name: &str) -> Option<&'static str> {
    reserved().first_party.get(name).map(String::as_str)
}

/// Every reserved word a first-party app may claim, with that app's id.
pub fn first_party_cli_names() -> impl Iterator<Item = (&'static str, &'static str)> {
    reserved().first_party.iter().map(|(word, app)| (word.as_str(), app.as_str()))
}

/// The MCP tool name of an op: its full name with `.` and `-` as `_`.
pub fn mcp_tool_name(op_name: &str) -> String {
    op_name.replace(['.', '-'], "_")
}

/// True when the op declares itself as an MCP tool (`mcp.expose` is
/// `default` or `opt_in`). An op without `mcp` is not a tool.
pub fn is_mcp_tool(op: &Value) -> bool {
    matches!(op.pointer("/mcp/expose").and_then(Value::as_str), Some("default" | "opt_in"))
}

pub(crate) fn check_manifest(m: &Value) -> Vec<Issue> {
    let id = m["id"].as_str().unwrap_or_default();
    match m.pointer("/cli/name").and_then(Value::as_str) {
        Some(name) if is_reserved_cli_name(name) && first_party_cli_owner(name) != Some(id) => {
            vec![Issue::error(
                "/cli/name",
                "cli.nameReserved",
                format!("{name} is a built-in or reserved cmux command; use another cli.name"),
            )]
        }
        _ => Vec::new(),
    }
}

/// Per-fragment state for [`check_op`]: CLI paths and tool names seen so far.
#[derive(Default)]
pub(crate) struct Seen<'a> {
    paths: HashSet<&'a str>,
    tools: HashSet<String>,
}

pub(crate) fn check_op<'a>(at: &str, op: &'a Value, seen: &mut Seen<'a>) -> Vec<Issue> {
    let mut out = Vec::new();
    if let Some(path) = op.pointer("/cli/path").and_then(Value::as_str)
        && !seen.paths.insert(path)
    {
        out.push(Issue::error(
            format!("{at}/cli/path"),
            "cli.duplicate",
            format!("another op already uses the CLI path {path}"),
        ));
    }
    let properties = op.pointer("/input/properties").and_then(Value::as_object);
    let positionals = op.pointer("/cli/positional").and_then(Value::as_array);
    let last = positionals.map_or(0, |p| p.len().saturating_sub(1));
    let mut positional = HashSet::new();
    for (j, name) in positionals.into_iter().flatten().filter_map(Value::as_str).enumerate() {
        if !positional.insert(name) {
            out.push(Issue::error(
                format!("{at}/cli/positional/{j}"),
                "cli.duplicate",
                format!("{name} is listed twice"),
            ));
        } else if let Some(property) = properties.and_then(|p| p.get(name)) {
            match positional_shape(property) {
                Shape::Scalar => {}
                Shape::Array if j == last => {}
                Shape::Array => out.push(Issue::error(
                    format!("{at}/cli/positional/{j}"),
                    "cli.positionalType",
                    format!("{name} is an array; only the last positional may be one"),
                )),
                Shape::Other => out.push(Issue::error(
                    format!("{at}/cli/positional/{j}"),
                    "cli.positionalType",
                    format!("{name} is not a string, number, integer, boolean or array"),
                )),
            }
        } else {
            out.push(Issue::error(
                format!("{at}/cli/positional/{j}"),
                "cli.positionalUnknown",
                format!("{name} is not a top-level property of the op's input"),
            ));
        }
    }
    if is_mcp_tool(op) {
        let tool = mcp_tool_name(op["name"].as_str().unwrap_or_default());
        if tool.len() > MCP_TOOL_NAME_MAX {
            out.push(Issue::error(
                format!("{at}/name"),
                "mcp.toolNameLength",
                format!("the MCP tool name {tool} is longer than {MCP_TOOL_NAME_MAX} characters"),
            ));
        }
        if op["gesture"].as_str() == Some("required") {
            out.push(Issue::warning(
                format!("{at}/mcp/expose"),
                "mcp.gestureRequired",
                "the op needs a live gesture, so an agent call always fails; set mcp.expose to never",
            ));
        }
        if !seen.tools.insert(tool.clone()) {
            out.push(Issue::error(
                format!("{at}/name"),
                "mcp.toolNameCollision",
                format!("another op in this app is also the MCP tool {tool}"),
            ));
        }
    }
    out
}

enum Shape {
    Scalar,
    Array,
    Other,
}

/// How a positional input property is typed. An `enum` or `const` without a
/// `type` takes one value on the command line, so it is a scalar.
fn positional_shape(property: &Value) -> Shape {
    match property["type"].as_str() {
        Some("string" | "number" | "integer" | "boolean") => Shape::Scalar,
        Some("array") => Shape::Array,
        None if property.get("enum").is_some() || property.get("const").is_some() => Shape::Scalar,
        _ => Shape::Other,
    }
}

/// What two or more installed apps both claim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictKind {
    /// The same `cli.name`: none of the apps gets the short form; the CLI
    /// prints each `cmux apps run <id> ...` form instead.
    CliName,
    /// The same MCP tool name; the registry and the supervisor decide which
    /// app keeps the tool.
    McpTool,
}

/// One name that more than one installed app claims.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conflict {
    pub kind: ConflictKind,
    pub name: String,
    /// App ids, sorted.
    pub apps: Vec<String>,
}

/// Names claimed by more than one app. `apps` holds each installed and
/// enabled app's manifest and parsed catalog fragment (if any).
pub fn conflicts(apps: &[(&Value, Option<&Value>)]) -> Vec<Conflict> {
    let mut cli: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut tools: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (manifest, catalog) in apps {
        let id = manifest["id"].as_str().unwrap_or_default().to_owned();
        if let Some(name) = manifest.pointer("/cli/name").and_then(Value::as_str) {
            cli.entry(name.to_owned()).or_default().push(id.clone());
        }
        let own: BTreeSet<String> = catalog
            .and_then(|c| c["operations"].as_array())
            .into_iter()
            .flatten()
            .filter(|op| is_mcp_tool(op))
            .map(|op| mcp_tool_name(op["name"].as_str().unwrap_or_default()))
            .collect();
        for tool in own {
            tools.entry(tool).or_default().push(id.clone());
        }
    }
    let collect = |kind: ConflictKind, map: BTreeMap<String, Vec<String>>| {
        map.into_iter()
            .filter(|(_, apps)| apps.len() > 1)
            .map(move |(name, mut apps)| {
                apps.sort();
                Conflict { kind: kind.clone(), name, apps }
            })
            .collect::<Vec<_>>()
    };
    let mut out = collect(ConflictKind::CliName, cli);
    out.extend(collect(ConflictKind::McpTool, tools));
    out
}
