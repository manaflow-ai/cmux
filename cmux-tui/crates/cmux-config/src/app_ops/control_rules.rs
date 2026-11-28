//! The control socket's `action.run` request rules: Swift
//! `ControlRouter.validatedRequest` (CmuxNextControl/Routing). The app resolves
//! the action in its catalog and checks `origin` (it knows the connection);
//! this op checks everything else against the action's schema, so only a
//! validated request reaches the main actor.
//!
//! - `control.validate` `{action, params, known_kinds}` answers `{request}` or
//!   `{error}`.
//!   - `action`: `{id, targets, arguments}`; each argument is `{name, kind,
//!     required, choices?, min?, max?, target_kind?, supplied_by_target?}`
//!     (`kind`: `string`, `int`, `bool`, `enum` or `target`; `choices`: the
//!     values).
//!   - `params`: the request's params as sent.
//!   - `request`: `{focus?, background?, beside_chat, target?, arguments}`;
//!     `target` is `{kind, id}`; `arguments` maps each argument's schema name
//!     to `{string}`, `{int}`, `{bool}` or `{target: {kind, id}}`.
//!   - `error`: `{id, args, data?}`, an `invalid_params` the app words in its
//!     own strings: `id` names the message (`focus_shape`, `background_shape`,
//!     `args_shape`, `no_such_argument`, `argument_given_twice`,
//!     `missing_arguments`, `argument_expects`, `target_shape`,
//!     `target_id_empty`, `no_target`, `wrong_target_kind`) and `args` are its
//!     format arguments, in order.
//! - `control.normalized_kind` `{kind}` answers `{kind}`: case, `-` and `_`
//!   dropped, so `workspaceGroup` and `workspace-group` are one kind.

use serde_json::{Map, Value, json};

use super::OpError;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "control.validate" => validate(request),
        "control.normalized_kind" => {
            super::string(request, "kind").map(|kind| json!({ "kind": normalized_kind(kind) }))
        }
        _ => return None,
    })
}

/// Old argument names and the ones that replaced them (data-model.md 3.4):
/// rooms became Spaces, machines became hosts.
const RENAMED_ARGUMENTS: &[(&str, &str)] = &[("room", "space"), ("machine", "host")];

/// A kind or argument name with case, `-` and `_` folded away.
pub fn normalized_kind(kind: &str) -> String {
    kind.chars().filter(|c| *c != '-' && *c != '_').flat_map(char::to_lowercase).collect()
}

/// An `invalid_params` refusal: the message's id, its format arguments and data.
#[derive(Debug, Clone, PartialEq)]
pub struct Refusal {
    pub id: &'static str,
    pub args: Vec<String>,
    pub data: Option<Value>,
}

impl Refusal {
    fn new(id: &'static str, args: &[&str]) -> Self {
        Self { id, args: args.iter().map(|arg| (*arg).to_owned()).collect(), data: None }
    }

    fn with(mut self, data: Value) -> Self {
        self.data = Some(data);
        self
    }

    fn json(&self) -> Value {
        let mut error = Map::new();
        error.insert("id".into(), json!(self.id));
        error.insert("args".into(), json!(self.args));
        if let Some(data) = &self.data {
            error.insert("data".into(), data.clone());
        }
        Value::Object(error)
    }
}

#[derive(Debug, Clone)]
struct Argument {
    name: String,
    kind: String,
    required: bool,
    choices: Vec<String>,
    range: Option<(i64, i64)>,
    target_kind: Option<String>,
    supplied_by_target: bool,
}

impl Argument {
    fn from_json(value: &Value) -> Result<Self, OpError> {
        let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
        let name =
            text("name").ok_or_else(|| OpError::Invalid("expected an argument `name`".into()))?;
        let kind =
            text("kind").ok_or_else(|| OpError::Invalid("expected an argument `kind`".into()))?;
        let choices = value
            .get("choices")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        item.as_str().or_else(|| item.get("value")?.as_str()).map(str::to_owned)
                    })
                    .collect()
            })
            .unwrap_or_default();
        let range = match (
            value.get("min").and_then(Value::as_i64),
            value.get("max").and_then(Value::as_i64),
        ) {
            (Some(low), Some(high)) => Some((low, high)),
            _ => None,
        };
        Ok(Self {
            name,
            kind,
            required: value.get("required").and_then(Value::as_bool).unwrap_or(false),
            choices,
            range,
            target_kind: text("target_kind"),
            supplied_by_target: value
                .get("supplied_by_target")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        })
    }

    /// Whether `target` gives this argument its value, so a run that names
    /// only the target misses nothing (`cmux space switch Work` sends
    /// `--target room:Work`).
    fn is_supplied_by(&self, target: Option<&Target>) -> bool {
        match (self.supplied_by_target, target, &self.target_kind) {
            (true, Some(target), Some(kind)) => {
                normalized_kind(&target.kind) == normalized_kind(kind)
            }
            _ => false,
        }
    }
}

/// A parsed `kind:id`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub kind: String,
    pub id: String,
}

impl Target {
    fn json(&self) -> Value {
        json!({ "kind": self.kind, "id": self.id })
    }
}

fn validate(request: &Value) -> Result<Value, OpError> {
    let action =
        request.get("action").ok_or_else(|| OpError::Invalid("expected an `action`".into()))?;
    let id = action
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| OpError::Invalid("expected an action `id`".into()))?;
    let targets = strings(action.get("targets"));
    let arguments = action
        .get("arguments")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(Argument::from_json).collect::<Result<Vec<_>, _>>())
        .transpose()?
        .unwrap_or_default();
    let known_kinds = strings(request.get("known_kinds"));
    let empty = Map::new();
    let params = request.get("params").and_then(Value::as_object).unwrap_or(&empty);
    Ok(match validated(id, &targets, &arguments, params, &known_kinds) {
        Ok(answer) => json!({ "request": answer }),
        Err(refusal) => json!({ "error": refusal.json() }),
    })
}

fn strings(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn present(value: Option<&Value>) -> Option<&Value> {
    value.filter(|value| !value.is_null())
}

fn validated(
    action: &str,
    targets: &[String],
    schema: &[Argument],
    params: &Map<String, Value>,
    known_kinds: &[String],
) -> Result<Value, Refusal> {
    let mut answer = Map::new();
    if let Some(focus) = present(params.get("focus")) {
        let focus = focus.as_bool().ok_or_else(|| Refusal::new("focus_shape", &[]))?;
        answer.insert("focus".into(), focus.into());
    }
    if let Some(background) = present(params.get("background")) {
        let background =
            background.as_bool().ok_or_else(|| Refusal::new("background_shape", &[]))?;
        answer.insert("background".into(), background.into());
    }
    answer.insert(
        "beside_chat".into(),
        params.get("beside_chat").and_then(Value::as_bool).unwrap_or(false).into(),
    );
    let target = match present(params.get("target")) {
        Some(raw) => Some(target_from(raw, targets, known_kinds, action)?),
        None => None,
    };
    let empty = Map::new();
    let given = match params.get("args").or_else(|| params.get("arguments")) {
        Some(Value::Object(members)) => members,
        None | Some(Value::Null) => &empty,
        Some(_) => return Err(Refusal::new("args_shape", &[])),
    };
    let by_name = |name: &str| schema.iter().find(|argument| argument.name == name);
    let by_folded = |name: &str| {
        let folded = normalized_kind(name);
        schema.iter().find(|argument| normalized_kind(&argument.name) == folded)
    };
    let mut values = Map::new();
    // The spelling that named each argument: two spellings of one argument
    // (`promptId` and `prompt-id`) are refused, never one silently
    // overwriting the other.
    let mut given_as: Vec<(String, String)> = Vec::new();
    let mut sorted: Vec<(&String, &Value)> = given.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    for (spelled, raw) in sorted {
        // `--room` still names `space`; a spelling the schema does not use
        // (`prompt-id`, `prompt_id`, `promptId`) names the argument it folds to.
        let renamed = RENAMED_ARGUMENTS
            .iter()
            .find(|(old, _)| old == spelled)
            .and_then(|(_, new)| by_name(new));
        let Some(argument) = by_name(spelled).or(renamed).or_else(|| by_folded(spelled)) else {
            let valid: Vec<&str> = schema.iter().map(|argument| argument.name.as_str()).collect();
            return Err(Refusal::new("no_such_argument", &[action, spelled])
                .with(json!({ "valid": valid })));
        };
        if let Some((_, earlier)) = given_as.iter().find(|(name, _)| *name == argument.name) {
            return Err(Refusal::new(
                "argument_given_twice",
                &[action, &argument.name, earlier, spelled],
            )
            .with(json!({ "argument": argument.name, "given": [earlier, spelled] })));
        }
        given_as.push((argument.name.clone(), spelled.clone()));
        values.insert(argument.name.clone(), value(raw, argument, action, known_kinds)?);
    }
    let interactive = params.get("interactive").and_then(Value::as_bool).unwrap_or(false);
    let missing: Vec<&str> = schema
        .iter()
        .filter(|argument| {
            argument.required
                && !values.contains_key(&argument.name)
                && !argument.is_supplied_by(target.as_ref())
        })
        .map(|argument| argument.name.as_str())
        .collect();
    if !missing.is_empty() && !interactive {
        let flags: Vec<String> = missing.iter().map(|name| format!("--{name}")).collect();
        return Err(Refusal::new("missing_arguments", &[action, &flags.join(", ")])
            .with(json!({ "missing": missing })));
    }
    if let Some(target) = target {
        answer.insert("target".into(), target.json());
    }
    answer.insert("arguments".into(), Value::Object(values));
    Ok(Value::Object(answer))
}

/// Swift's `.whitespaces`: spaces and tabs, not line breaks.
fn trim(text: &str) -> &str {
    text.trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    })
}

/// An exact integer below 1e15, as `JSONValue.intValue` reads one.
fn exact_int(raw: &Value) -> Option<i64> {
    if let Some(number) = raw.as_i64() {
        return (number.unsigned_abs() < 1_000_000_000_000_000).then_some(number);
    }
    let number = raw.as_f64()?;
    if number.round() != number || number.abs() >= 1e15 {
        return None;
    }
    format!("{number:.0}").parse().ok()
}

/// A number or flag as `JSONValue.compactText` writes it.
fn compact_text(raw: &Value) -> String {
    match exact_int(raw) {
        Some(number) => number.to_string(),
        None => raw.to_string(),
    }
}

fn value(
    raw: &Value,
    argument: &Argument,
    action: &str,
    known_kinds: &[String],
) -> Result<Value, Refusal> {
    let fail = |expected: &str| {
        Refusal::new("argument_expects", &[action, &argument.name, expected])
            .with(json!({ "argument": argument.name }))
    };
    match argument.kind.as_str() {
        "string" => match raw {
            Value::String(text) => Ok(json!({ "string": text })),
            Value::Number(_) | Value::Bool(_) => Ok(json!({ "string": compact_text(raw) })),
            _ => Err(fail("a string")),
        },
        "int" => {
            let number = exact_int(raw)
                .or_else(|| raw.as_str().and_then(|text| trim(text).parse::<i64>().ok()));
            let number = number.ok_or_else(|| fail("an integer"))?;
            if let Some((low, high)) = argument.range
                && !(low..=high).contains(&number)
            {
                return Err(fail(&format!("an integer in {low}...{high}")));
            }
            Ok(json!({ "int": number }))
        }
        "bool" => {
            if let Some(flag) = raw.as_bool() {
                return Ok(json!({ "bool": flag }));
            }
            let text = raw
                .as_str()
                .map(str::to_lowercase)
                .or_else(|| exact_int(raw).map(|number| number.to_string()));
            match text.as_deref() {
                Some("true" | "yes" | "on" | "1") => Ok(json!({ "bool": true })),
                Some("false" | "no" | "off" | "0") => Ok(json!({ "bool": false })),
                _ => Err(fail("true or false")),
            }
        }
        "enum" => {
            let chosen = raw.as_str().map(trim).and_then(|text| {
                let text = text.to_lowercase();
                argument.choices.iter().find(|choice| choice.to_lowercase() == text)
            });
            match chosen {
                Some(choice) => Ok(json!({ "string": choice })),
                None => Err(fail(&format!("one of {}", argument.choices.join(", ")))),
            }
        }
        "target" => {
            let kinds: Vec<String> = argument.target_kind.iter().cloned().collect();
            Ok(json!({ "target": target_from(raw, &kinds, known_kinds, action)?.json() }))
        }
        _ => Err(fail("a value")),
    }
}

/// Parses `kind:id`, `{kind, id}`, or a bare id (the kind its public-id
/// prefix names, else the first allowed kind). Kinds match after dropping
/// case, `-` and `_`.
pub fn target_from(
    raw: &Value,
    allowed: &[String],
    known: &[String],
    action: &str,
) -> Result<Target, Refusal> {
    let same = |a: &str, b: &str| normalized_kind(a) == normalized_kind(b);
    let (kind_text, id): (Option<String>, String) = match raw {
        Value::String(text) => {
            let trimmed = trim(text);
            match trimmed.split_once(':') {
                Some((prefix, rest))
                    if known.iter().any(|kind| same(kind, prefix))
                        || allowed.iter().any(|kind| same(kind, prefix)) =>
                {
                    (Some(prefix.to_owned()), rest.to_owned())
                }
                _ => (None, trimmed.to_owned()),
            }
        }
        Value::Object(members) => (
            members.get("kind").and_then(Value::as_str).map(str::to_owned),
            members.get("id").and_then(Value::as_str).unwrap_or_default().to_owned(),
        ),
        _ => return Err(Refusal::new("target_shape", &[])),
    };
    if id.is_empty() {
        return Err(Refusal::new("target_id_empty", &[]));
    }
    let Some(first) = allowed.first() else {
        return Err(Refusal::new("no_target", &[action]));
    };
    let Some(kind_text) = kind_text else {
        // A bare public id names its kind by its prefix (`tab_…`, `pane_…`,
        // `ws_…`): an action that takes a pane or a tab resolves it as that
        // kind, not as its first.
        let named = allowed.iter().find(|kind| {
            let normal = normalized_kind(kind);
            let prefix =
                if normal == "workspace" { "ws_".to_owned() } else { format!("{normal}_") };
            id.starts_with(&prefix)
        });
        return Ok(Target { kind: named.unwrap_or(first).clone(), id });
    };
    match allowed.iter().find(|kind| same(kind, &kind_text)) {
        Some(kind) => Ok(Target { kind: kind.clone(), id }),
        None => Err(Refusal::new("wrong_target_kind", &[action, &allowed.join("|"), &kind_text])
            .with(json!({ "targets": allowed }))),
    }
}

#[cfg(test)]
#[path = "control_rules_tests.rs"]
mod tests;
