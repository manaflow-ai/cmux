//! Merging IR fragments (app catalogs, cloud ops) into one IR, and checking
//! that a fragment has the IR's shape before it is merged.
//!
//! A fragment has the IR's top-level keys (all optional). Schemas may use
//! only the JSON Schema subset every generator supports (TS lane wire
//! decision 9): codegen refuses anything else, so the merge does too.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};

use crate::router::within;

/// Keywords the generators compile.
pub const SUPPORTED_KEYWORDS: &[&str] = &[
    "type",
    "$ref",
    "properties",
    "required",
    "additionalProperties",
    "items",
    "enum",
    "const",
    "anyOf",
    "oneOf",
    "allOf",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "minLength",
    "maxLength",
    "pattern",
    "minItems",
    "maxItems",
    "format",
    "x-cmux-secret",
];

/// Keywords generators ignore.
pub const ANNOTATION_KEYWORDS: &[&str] = &[
    "$schema",
    "$id",
    "$comment",
    "title",
    "description",
    "default",
    "examples",
    "deprecated",
    "readOnly",
    "writeOnly",
];

const TOP_LEVEL: &[&str] = &["version", "namespaces", "ops", "events", "interfaces", "types"];
const OP_KINDS: &[&str] = &["read", "mutation", "stream"];

/// Why a fragment cannot be merged; every problem found, not only the first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MergeError {
    pub problems: Vec<String>,
}

impl std::fmt::Display for MergeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.problems.join("; "))
    }
}

impl std::error::Error for MergeError {}

/// Checks a fragment before it is merged. The default is [`ShapeValidator`];
/// a loader may add its own rules (signatures, publisher checks) on top.
pub trait FragmentValidator {
    fn validate(&self, fragment: &Value) -> Result<(), Vec<String>>;
}

/// The IR shape rules.
#[derive(Debug, Clone, Copy, Default)]
pub struct ShapeValidator;

/// Check that `schema` uses only supported keywords and `#/types/<Name>` refs.
pub fn schema_keywords_supported(schema: &Value, at: &str) -> Result<(), String> {
    let Value::Object(map) = schema else {
        return if schema.is_boolean() {
            Ok(())
        } else {
            Err(format!("{at}: a schema must be an object or a boolean"))
        };
    };
    for (key, value) in map {
        let here = format!("{at}/{key}");
        if !SUPPORTED_KEYWORDS.contains(&key.as_str())
            && !ANNOTATION_KEYWORDS.contains(&key.as_str())
        {
            return Err(format!("{here}: keyword {key:?} is outside the supported subset"));
        }
        match key.as_str() {
            "$ref" => {
                let target =
                    value.as_str().and_then(|r| r.strip_prefix("#/types/")).unwrap_or_default();
                if !is_identifier(target) {
                    return Err(format!("{here}: only #/types/<Name> refs are supported"));
                }
            }
            "properties" => {
                let properties =
                    value.as_object().ok_or_else(|| format!("{here}: must be an object"))?;
                for (name, property) in properties {
                    schema_keywords_supported(property, &format!("{here}/{name}"))?;
                }
            }
            "items" | "additionalProperties" => schema_keywords_supported(value, &here)?,
            "allOf" if value.as_array().is_none_or(|branches| branches.len() != 1) => {
                return Err(format!("{here}: only a single-schema allOf is supported"));
            }
            "x-cmux-secret" if !value.is_boolean() => {
                return Err(format!("{here}: must be a boolean"));
            }
            "pattern" => {
                let pattern = value.as_str().ok_or_else(|| format!("{here}: must be a string"))?;
                portable_pattern(pattern).map_err(|reason| format!("{here}: {reason}"))?;
            }
            "anyOf" | "oneOf" | "allOf" => {
                let branches = value
                    .as_array()
                    .filter(|b| !b.is_empty())
                    .ok_or_else(|| format!("{here}: must be a non-empty array"))?;
                for (index, branch) in branches.iter().enumerate() {
                    schema_keywords_supported(branch, &format!("{here}/{index}"))?;
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// A regex inside the subset RE2 and ECMA-262 agree on (decision 19): no
/// lookaround, no backreferences, no named groups (their syntax differs).
pub fn portable_pattern(pattern: &str) -> Result<(), String> {
    let bytes = pattern.as_bytes();
    let mut index = 0;
    let mut in_class = false;
    while index < bytes.len() {
        match bytes[index] {
            b'\\' => {
                match bytes.get(index + 1) {
                    Some(b'1'..=b'9') => return Err("backreferences are not portable".into()),
                    Some(b'k') => return Err("named backreferences are not portable".into()),
                    _ => {}
                }
                index += 2;
                continue;
            }
            b'[' => in_class = true,
            b']' => in_class = false,
            b'(' if !in_class && bytes.get(index + 1) == Some(&b'?') => {
                let rest = &pattern[index + 2..];
                if rest.starts_with('=')
                    || rest.starts_with('!')
                    || rest.starts_with("<=")
                    || rest.starts_with("<!")
                {
                    return Err("lookaround is not portable".into());
                }
                if rest.starts_with('<') || rest.starts_with('P') || rest.starts_with('\'') {
                    return Err("named groups are not portable".into());
                }
            }
            _ => {}
        }
        index += 1;
    }
    Ok(())
}

fn is_identifier(name: &str) -> bool {
    let mut bytes = name.bytes();
    matches!(bytes.next(), Some(b'A'..=b'Z' | b'a'..=b'z' | b'_'))
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// The MCP tool name of an op: `.` and `-` become `_` (decision 21).
pub fn mcp_tool_name(op: &str) -> String {
    op.replace(['.', '-'], "_")
}

/// The longest MCP tool name.
pub const MAX_MCP_TOOL_NAME: usize = 48;

/// `^[a-z][a-z0-9-]*( [a-z][a-z0-9-]*){0,2}$`: one to three words.
pub fn valid_cli_path(path: &str) -> bool {
    let words: Vec<&str> = path.split(' ').collect();
    words.len() <= 3
        && words.iter().all(|word| {
            word.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
                && word.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}

/// Whether any schema reachable from `schema` (through `#/types/` refs)
/// carries `x-cmux-secret: true`.
pub fn secret_output(schema: &Value, types: &Map<String, Value>) -> bool {
    fn walk<'a>(
        value: &'a Value,
        types: &'a Map<String, Value>,
        seen: &mut BTreeSet<&'a str>,
    ) -> bool {
        match value {
            Value::Object(map) => {
                if map.get("x-cmux-secret") == Some(&Value::Bool(true)) {
                    return true;
                }
                if let Some(name) =
                    map.get("$ref").and_then(Value::as_str).and_then(|r| r.strip_prefix("#/types/"))
                    && seen.insert(name)
                    && types.get(name).is_some_and(|target| walk(target, types, seen))
                {
                    return true;
                }
                map.values().any(|child| walk(child, types, seen))
            }
            Value::Array(items) => items.iter().any(|child| walk(child, types, seen)),
            _ => false,
        }
    }
    walk(schema, types, &mut BTreeSet::new())
}

const MCP_EXPOSE: &[&str] = &["default", "opt_in", "never"];

fn check_mcp_and_cli(op: &Map<String, Value>, at: &str) -> Vec<String> {
    let mut problems = Vec::new();
    if let Some(mcp) = op.get("mcp") {
        let Some(mcp) = mcp.as_object() else { return vec![format!("{at}.mcp must be an object")] };
        if !text(mcp, "expose").is_some_and(|expose| MCP_EXPOSE.contains(&expose)) {
            problems.push(format!("{at}.mcp.expose must be default, opt_in or never"));
        }
        if mcp.contains_key("group") && text(mcp, "group").is_none() {
            problems.push(format!("{at}.mcp.group must be a non-empty string"));
        }
        if let Some(key) = mcp.keys().find(|key| !["expose", "group"].contains(&key.as_str())) {
            problems.push(format!("{at}.mcp has unknown key {key:?}"));
        }
    }
    if let Some(cli) = op.get("cli") {
        let Some(cli) = cli.as_object() else { return vec![format!("{at}.cli must be an object")] };
        if !text(cli, "path").is_some_and(valid_cli_path) {
            problems.push(format!("{at}.cli.path must be one to three lowercase words"));
        }
        if !cli.get("visible").is_some_and(Value::is_boolean) {
            problems.push(format!("{at}.cli.visible must be a boolean"));
        }
        if cli.contains_key("positional") && strings(cli.get("positional")).is_none() {
            problems.push(format!("{at}.cli.positional must be an array of strings"));
        }
        if let Some(key) =
            cli.keys().find(|key| !["path", "visible", "positional"].contains(&key.as_str()))
        {
            problems.push(format!("{at}.cli has unknown key {key:?}"));
        }
    }
    if !text(op, "risk").is_some_and(|risk| crate::op::RISKS.contains(&risk)) {
        problems.push(format!("{at}.risk must be one of {}", crate::op::RISKS.join(", ")));
    }
    if !op.get("gesture").is_some_and(Value::is_boolean) {
        problems.push(format!("{at}.gesture must be a boolean"));
    }
    for derived in ["scope_class", "server_only"] {
        if op.contains_key(derived) {
            problems.push(format!("{at}.{derived} is derived by emit-ir and may not be declared"));
        }
    }
    if op.contains_key("paths") && strings(op.get("paths")).is_none() {
        problems.push(format!("{at}.paths must be an array of strings"));
    }
    if op.contains_key("secret_output") && !op.get("secret_output").is_some_and(Value::is_boolean) {
        problems.push(format!("{at}.secret_output must be a boolean"));
    }
    problems
}

/// The IR without the fields emit-ir derives, as a fragment the merge can
/// check (emit-ir runs this over its own output).
pub fn strip_derived(ir: &Value) -> Value {
    let mut fragment = ir.clone();
    if let Some(ops) = fragment.get_mut("ops").and_then(Value::as_array_mut) {
        for op in ops.iter_mut().filter_map(Value::as_object_mut) {
            op.remove("scope_class");
            op.remove("server_only");
        }
    }
    fragment
}

/// Decision 26: an op name is `<namespace>.<family>.<verb>`, at least two
/// segments below its longest declared namespace.
fn short_name(name: &str, namespaces: &BTreeMap<String, Value>) -> Option<String> {
    let namespace = namespaces.keys().filter(|ns| within(name, ns)).max_by_key(|ns| ns.len())?;
    let rest = name.get(namespace.len() + 1..).unwrap_or_default();
    (rest.split('.').count() < 2 || rest.is_empty())
        .then(|| format!("op {name} must be <namespace>.<family>.<verb> below {namespace}"))
}

/// The top-level properties of a params schema (one `$ref` deep).
fn param_properties<'a>(
    params: &'a Value,
    types: &'a Map<String, Value>,
) -> Option<&'a Map<String, Value>> {
    let target = params
        .get("$ref")
        .and_then(Value::as_str)
        .and_then(|r| r.strip_prefix("#/types/"))
        .and_then(|name| types.get(name))
        .unwrap_or(params);
    target.get("properties").and_then(Value::as_object)
}

/// The top-level property names of a params schema (one `$ref` deep).
fn param_names<'a>(params: &'a Value, types: &'a Map<String, Value>) -> Vec<&'a str> {
    param_properties(params, types)
        .map(|p| p.keys().map(String::as_str).collect())
        .unwrap_or_default()
}

/// Decision 21 over the merged ops: fill `mcp` (never) and `secret_output`,
/// and refuse duplicate MCP tool names, duplicate CLI paths per owner, and
/// positional names that are not params.
fn normalize_ops(ops: &mut [Value], types: &Map<String, Value>, problems: &mut Vec<String>) {
    let mut tools: BTreeMap<String, String> = BTreeMap::new();
    let mut cli_paths: BTreeMap<(String, String), String> = BTreeMap::new();
    for op in ops.iter_mut() {
        let name = name_of(op);
        if op.get("mcp").is_none() {
            op["mcp"] = serde_json::json!({ "expose": "never" });
        }
        op["secret_output"] = Value::Bool(secret_output(&op["result"], types));
        // Decision 27: the scope class comes from scope-classes.json.
        match crate::scope_class::classify(op["scope"].as_str().unwrap_or_default()) {
            Ok((class, server_only)) => {
                op["scope_class"] = Value::String(class);
                match op.as_object_mut() {
                    Some(object) if server_only => {
                        object.insert("server_only".into(), Value::Bool(true));
                    }
                    Some(object) => {
                        object.remove("server_only");
                    }
                    None => {}
                }
            }
            Err(reason) => problems.push(format!("op {name}: {reason}")),
        }
        // Every op, exposed or not, reserves its tool name (decision 23).
        let tool = mcp_tool_name(&name);
        if tool.len() > MAX_MCP_TOOL_NAME {
            problems.push(format!(
                "op {name}: MCP tool name {tool} is longer than {MAX_MCP_TOOL_NAME}"
            ));
        }
        if let Some(other) = tools.insert(tool.clone(), name.clone()) {
            problems.push(format!("ops {other} and {name} share the MCP tool name {tool}"));
        }
        if op.get("paths").is_none() {
            op["paths"] = serde_json::json!([]);
        }
        let properties = param_properties(&op["params"], types);
        for path in strings(op.get("paths")).unwrap_or_default() {
            let is_string = properties.and_then(|p| p.get(path)).is_some_and(|schema| {
                let ty = &schema["type"];
                ty == "string" || ty.as_array().is_some_and(|all| all.iter().any(|t| t == "string"))
            });
            if !is_string {
                problems.push(format!(
                    "op {name}: path param {path:?} is not a top-level string param"
                ));
            }
        }
        if let Some(path) = op.get("cli").and_then(|cli| cli.get("path")).and_then(Value::as_str) {
            let key = (op["owner"].as_str().unwrap_or_default().to_owned(), path.to_owned());
            if let Some(other) = cli_paths.insert(key, name.clone()) {
                problems.push(format!("ops {other} and {name} share the CLI path {path:?}"));
            }
            let params = param_names(&op["params"], types);
            for positional in strings(op["cli"].get("positional")).unwrap_or_default() {
                if !params.contains(&positional) {
                    problems.push(format!("op {name}: positional {positional:?} is not a param"));
                }
            }
        }
    }
}

/// Checks one object of a list, appending problems.
type Check<'a> = &'a dyn Fn(&Map<String, Value>, &str, &mut Vec<String>);

fn text<'a>(object: &'a Map<String, Value>, field: &str) -> Option<&'a str> {
    object.get(field).and_then(Value::as_str).filter(|value| !value.is_empty())
}

fn valid_owner(owner: &str) -> bool {
    owner == "first-party" || owner.strip_prefix("app:").is_some_and(|app| !app.is_empty())
}

fn strings(value: Option<&Value>) -> Option<Vec<&str>> {
    value?.as_array()?.iter().map(Value::as_str).collect()
}

impl FragmentValidator for ShapeValidator {
    fn validate(&self, fragment: &Value) -> Result<(), Vec<String>> {
        let mut problems = Vec::new();
        let Some(map) = fragment.as_object() else {
            return Err(vec!["a fragment must be an object".into()]);
        };
        for key in map.keys().filter(|key| !TOP_LEVEL.contains(&key.as_str())) {
            problems.push(format!("unknown top-level key {key:?}"));
        }
        let list =
            |key: &str| map.get(key).map_or(Some(&[][..]), |v| v.as_array().map(Vec::as_slice));
        let check_list = |key: &str, problems: &mut Vec<String>, each: Check<'_>| match list(key) {
            None => problems.push(format!("{key} must be an array")),
            Some(items) => {
                for (index, item) in items.iter().enumerate() {
                    let at = format!("{key}[{index}]");
                    match item.as_object() {
                        Some(object) => each(object, &at, problems),
                        None => problems.push(format!("{at} must be an object")),
                    }
                }
            }
        };
        check_list("namespaces", &mut problems, &|ns, at, problems| {
            if text(ns, "name").is_none() {
                problems.push(format!("{at}.name must be a non-empty string"));
            }
            if !text(ns, "owner").is_some_and(valid_owner) {
                problems.push(format!("{at}.owner must be first-party or app:<id>"));
            }
        });
        check_list("ops", &mut problems, &|op, at, problems| {
            if text(op, "name").is_none_or(|name| crate::envelope::check_name(name).is_err()) {
                problems.push(format!("{at}.name must be <ns>.<family>.<verb>"));
            }
            if !text(op, "kind").is_some_and(|kind| OP_KINDS.contains(&kind)) {
                problems.push(format!("{at}.kind must be read, mutation or stream"));
            }
            if text(op, "scope").is_none() {
                problems.push(format!("{at}.scope must be a non-empty string"));
            }
            if !text(op, "owner").is_some_and(valid_owner) {
                problems.push(format!("{at}.owner must be first-party or app:<id>"));
            }
            if op.contains_key("aliases") && strings(op.get("aliases")).is_none() {
                problems.push(format!("{at}.aliases must be an array of strings"));
            }
            if op.contains_key("aliases")
                && text(op, "owner").is_some_and(|owner| owner.starts_with("app:"))
            {
                problems.push(format!("{at}.aliases: third-party ops may not declare aliases"));
            }
            problems.extend(check_mcp_and_cli(op, at));
            if strings(op.get("errors")).is_none() {
                problems.push(format!("{at}.errors must be an array of strings"));
            }
            for field in ["params", "result"] {
                match op.get(field) {
                    Some(schema) => problems
                        .extend(schema_keywords_supported(schema, &format!("{at}.{field}")).err()),
                    None => problems.push(format!("{at}.{field} is missing")),
                }
            }
        });
        check_list("events", &mut problems, &|event, at, problems| {
            if text(event, "name").is_none_or(|name| crate::envelope::check_name(name).is_err()) {
                problems.push(format!("{at}.name must be <ns>.<family>.<event>"));
            }
            if text(event, "scope").is_none() {
                problems.push(format!("{at}.scope must be a non-empty string"));
            }
            match event.get("data") {
                Some(schema) => {
                    problems.extend(schema_keywords_supported(schema, &format!("{at}.data")).err());
                }
                None => problems.push(format!("{at}.data is missing")),
            }
        });
        check_list("interfaces", &mut problems, &|interface, at, problems| {
            if !text(interface, "name").is_some_and(|name| name.contains('/')) {
                problems.push(format!("{at}.name must be <name>/<major>"));
            }
            if !interface.get("methods").is_some_and(Value::is_object) {
                problems.push(format!("{at}.methods must be an object"));
            }
            if strings(interface.get("events")).is_none() {
                problems.push(format!("{at}.events must be an array of strings"));
            }
        });
        if let Some(types) = map.get("types") {
            match types.as_object() {
                None => problems.push("types must be an object".into()),
                Some(types) => {
                    for (name, schema) in types {
                        if !is_identifier(name) {
                            problems.push(format!("type name {name:?} is not an identifier"));
                        }
                        problems.extend(
                            schema_keywords_supported(schema, &format!("types.{name}")).err(),
                        );
                    }
                }
            }
        }
        if problems.is_empty() { Ok(()) } else { Err(problems) }
    }
}

fn array<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value.get(key).and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

fn name_of(item: &Value) -> String {
    item.get("name").and_then(Value::as_str).unwrap_or_default().to_owned()
}

fn collect_refs(value: &Value, out: &mut BTreeSet<String>) {
    match value {
        Value::Object(map) => {
            if let Some(target) =
                map.get("$ref").and_then(Value::as_str).and_then(|r| r.strip_prefix("#/types/"))
            {
                out.insert(target.to_owned());
            }
            map.values().for_each(|child| collect_refs(child, out));
        }
        Value::Array(items) => items.iter().for_each(|child| collect_refs(child, out)),
        _ => {}
    }
}

/// Merge `fragment` into `base` after `validator` accepts it. Names (ops,
/// events and aliases share one space) must be new, a namespace keeps one
/// owner, every op sits in a namespace owned by the op's owner, a type or
/// interface present in both must be identical, and every ref resolves.
pub fn merge(
    base: &Value,
    fragment: &Value,
    validator: &dyn FragmentValidator,
) -> Result<Value, MergeError> {
    validator.validate(fragment).map_err(|problems| MergeError { problems })?;
    let mut problems = Vec::new();
    let mut namespaces: BTreeMap<String, Value> = BTreeMap::new();
    for ns in array(base, "namespaces").iter().chain(array(fragment, "namespaces")) {
        let name = name_of(ns);
        match namespaces.get(&name) {
            Some(existing) if existing["owner"] != ns["owner"] => {
                problems.push(format!(
                    "namespace {name} is owned by {} and {}",
                    existing["owner"], ns["owner"]
                ));
            }
            Some(_) => {}
            None => {
                namespaces.insert(name, ns.clone());
            }
        }
    }
    let owner_of = |name: &str| {
        namespaces
            .values()
            .filter(|ns| within(name, ns["name"].as_str().unwrap_or_default()))
            .max_by_key(|ns| name_of(ns).len())
            .map(|ns| ns["owner"].clone())
    };
    let mut taken: BTreeSet<String> = BTreeSet::new();
    let mut claim = |name: String, problems: &mut Vec<String>| {
        if !taken.insert(name.clone()) {
            problems.push(format!("name {name} is declared twice"));
        }
    };
    let mut ops = Vec::new();
    for op in array(base, "ops").iter().chain(array(fragment, "ops")) {
        let name = name_of(op);
        claim(name.clone(), &mut problems);
        for alias in strings(op.get("aliases")).unwrap_or_default() {
            claim(alias.to_owned(), &mut problems);
        }
        if let Some(problem) = short_name(&name, &namespaces) {
            problems.push(problem);
        }
        match owner_of(&name) {
            Some(owner) if owner == op["owner"] => {}
            Some(owner) => problems.push(format!(
                "op {name} has owner {} but its namespace is owned by {owner}",
                op["owner"]
            )),
            None => problems.push(format!("op {name} is outside every declared namespace")),
        }
        ops.push(op.clone());
    }
    let mut events = Vec::new();
    for event in array(base, "events").iter().chain(array(fragment, "events")) {
        let name = name_of(event);
        claim(name.clone(), &mut problems);
        if owner_of(&name).is_none() {
            problems.push(format!("event {name} is outside every declared namespace"));
        }
        events.push(event.clone());
    }
    let mut interfaces: BTreeMap<String, Value> = BTreeMap::new();
    for interface in array(base, "interfaces").iter().chain(array(fragment, "interfaces")) {
        let name = name_of(interface);
        match interfaces.get(&name) {
            Some(existing) if existing != interface => {
                problems.push(format!("interface {name} differs between catalogs"));
            }
            Some(_) => {}
            None => {
                interfaces.insert(name, interface.clone());
            }
        }
    }
    let mut types = base.get("types").and_then(Value::as_object).cloned().unwrap_or_default();
    for (name, schema) in fragment.get("types").and_then(Value::as_object).into_iter().flatten() {
        match types.get(name) {
            Some(existing) if existing != schema => {
                problems.push(format!("type {name} differs between catalogs"));
            }
            Some(_) => {}
            None => {
                types.insert(name.clone(), schema.clone());
            }
        }
    }
    normalize_ops(&mut ops, &types, &mut problems);
    let mut refs = BTreeSet::new();
    for item in ops.iter().chain(&events).chain(types.values()) {
        collect_refs(item, &mut refs);
    }
    problems.extend(
        refs.iter()
            .filter(|name| !types.contains_key(*name))
            .map(|name| format!("ref #/types/{name} does not resolve")),
    );
    if !problems.is_empty() {
        return Err(MergeError { problems });
    }
    let version =
        base.get("version").cloned().unwrap_or_else(|| Value::String(crate::ir::IR_VERSION.into()));
    Ok(crate::ir::canonical(&serde_json::json!({
        "version": version,
        "namespaces": namespaces.into_values().collect::<Vec<_>>(),
        "ops": ops,
        "events": events,
        "interfaces": interfaces.into_values().collect::<Vec<_>>(),
        "types": types,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fragment() -> Value {
        json!({
            "namespaces": [{ "name": "octo.diff_tools", "owner": "app:octo.diff_tools" }],
            "ops": [{
                "name": "octo.diff_tools.diff.list", "kind": "read", "scope": "diff:read", "risk": "read", "gesture": false,
                "owner": "app:octo.diff_tools",
                "params": { "$ref": "#/types/OctoListParams" }, "result": { "type": "array", "items": { "type": "string" } },
                "errors": []
            }],
            "types": { "OctoListParams": { "type": "object", "properties": {}, "additionalProperties": false } }
        })
    }

    fn first_party_alias(alias: &str) -> Value {
        json!({
            "ops": [{
                "name": "cmux.workspace.list", "kind": "read", "scope": "workspace:read", "risk": "read", "gesture": false,
                "owner": "first-party", "aliases": [alias],
                "params": { "type": "object" }, "result": { "type": "object" }, "errors": []
            }]
        })
    }

    #[test]
    fn patterns_stay_in_the_re2_and_ecma_subset() {
        assert!(portable_pattern("^[a-z][a-z0-9_]*(\\.[a-z0-9_]+)+$").is_ok());
        assert!(portable_pattern("[(?=]").is_ok());
        assert!(portable_pattern("a(?=b)").is_err());
        assert!(portable_pattern("(?<!a)b").is_err());
        assert!(portable_pattern("(a)\\1").is_err());
        assert!(portable_pattern("(?<name>a)").is_err());
        assert!(portable_pattern("(?P<name>a)").is_err());
        assert!(schema_keywords_supported(&json!({ "allOf": [{}, {}] }), "x").is_err());
        assert!(
            schema_keywords_supported(&json!({ "allOf": [{ "type": "string" }] }), "x").is_ok()
        );
    }

    #[test]
    fn merges_an_app_fragment_into_the_catalog() {
        let base = crate::catalog::catalog().ir();
        let merged = merge(&base, &fragment(), &ShapeValidator).unwrap();
        assert!(
            merged["ops"]
                .as_array()
                .unwrap()
                .iter()
                .any(|op| op["name"] == "octo.diff_tools.diff.list")
        );
        assert!(merged["types"].get("OctoListParams").is_some());
        assert!(merged["types"].get("GitStatus").is_some());
    }

    #[test]
    fn refuses_conflicts_and_unsupported_keywords() {
        let base = crate::catalog::catalog().ir();
        let mut aliased = fragment();
        aliased["ops"][0]["aliases"] = json!(["difftools.list"]);
        let problems = merge(&base, &aliased, &ShapeValidator).unwrap_err().problems;
        assert!(problems.iter().any(|p| p.contains("may not declare aliases")));
        let twice = first_party_alias("cmux.git.status");
        let problems = merge(&base, &twice, &ShapeValidator).unwrap_err().problems;
        assert!(problems.iter().any(|p| p.contains("declared twice")));
        assert!(merge(&base, &first_party_alias("workspace.list"), &ShapeValidator).is_ok());
        let mut stolen = fragment();
        stolen["ops"][0]["name"] = json!("cmux.git.steal");
        assert!(merge(&base, &stolen, &ShapeValidator).is_err());
        let mut keyword = fragment();
        keyword["types"]["OctoListParams"]["patternProperties"] = json!({});
        assert!(merge(&base, &keyword, &ShapeValidator).is_err());
        let mut dangling = fragment();
        dangling["ops"][0]["params"] = json!({ "$ref": "#/types/Missing" });
        assert!(
            merge(&base, &dangling, &ShapeValidator)
                .unwrap_err()
                .problems
                .iter()
                .any(|p| p.contains("does not resolve"))
        );
        let mut retyped = fragment();
        retyped["types"]["GitStatus"] = json!({ "type": "string" });
        assert!(merge(&base, &retyped, &ShapeValidator).is_err());
    }
}
