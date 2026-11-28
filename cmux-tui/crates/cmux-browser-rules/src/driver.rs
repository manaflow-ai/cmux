//! A driver call's params, its deadline and where its new tab opens (`DriverParams`,
//! `CallDeadline`, `AutomationTabPlace`).
//!
//! The reads follow `DriverParams`: an explicit null reads as absent; a missing required
//! field or a field of the wrong type is an error that names the method and the field.

use serde::Serialize;
use serde_json::{Map, Value};

/// The deadline a call takes when it names none (`timeout(default:)`): 30 s.
pub const DEFAULT_TIMEOUT_MS: f64 = 30_000.0;

/// The longest deadline a call takes: a year, which no browser call outlives.
pub const LONGEST_DEADLINE_MS: f64 = 31_622_400_000.0;

/// A driver call's params, read by field.
#[derive(Debug, Clone, PartialEq)]
pub struct DriverParams {
    /// The call's method, which the error texts name.
    pub method: String,
    fields: Map<String, Value>,
}

impl DriverParams {
    /// The params of a call to `method`: an object, or null for none. Anything else is an
    /// error.
    pub fn new(method: &str, json: &Value) -> Result<Self, String> {
        let fields = match json {
            Value::Object(fields) => fields.clone(),
            Value::Null => Map::new(),
            _ => return Err(format!("{method}: params must be an object")),
        };
        Ok(Self { method: method.to_owned(), fields })
    }

    /// The field `key`, or None when it is absent or null.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.fields.get(key).filter(|value| !value.is_null())
    }

    /// True when the field is present and not null.
    pub fn has(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    /// A required string.
    pub fn string(&self, key: &str) -> Result<String, String> {
        self.optional_string(key)?.ok_or_else(|| self.missing(key, "a string"))
    }

    /// A string, or None when absent.
    pub fn optional_string(&self, key: &str) -> Result<Option<String>, String> {
        match self.get(key) {
            None => Ok(None),
            Some(Value::String(string)) => Ok(Some(string.clone())),
            Some(_) => Err(self.wrong(key, "a string")),
        }
    }

    /// A required finite number.
    pub fn number(&self, key: &str) -> Result<f64, String> {
        self.optional_number(key)?.ok_or_else(|| self.missing(key, "a number"))
    }

    /// A finite number, or None when absent.
    pub fn optional_number(&self, key: &str) -> Result<Option<f64>, String> {
        match self.get(key) {
            None => Ok(None),
            Some(Value::Number(number)) => match number.as_f64() {
                Some(value) if value.is_finite() => Ok(Some(value)),
                _ => Err(self.wrong(key, "a finite number")),
            },
            Some(_) => Err(self.wrong(key, "a finite number")),
        }
    }

    /// A boolean, `fallback` when absent.
    pub fn bool(&self, key: &str, fallback: bool) -> Result<bool, String> {
        match self.get(key) {
            None => Ok(fallback),
            Some(Value::Bool(flag)) => Ok(*flag),
            Some(_) => Err(self.wrong(key, "a boolean")),
        }
    }

    /// An array of strings, empty when absent.
    pub fn strings(&self, key: &str) -> Result<Vec<String>, String> {
        let items = match self.get(key) {
            None => return Ok(Vec::new()),
            Some(Value::Array(items)) => items,
            Some(_) => return Err(self.wrong(key, "an array of strings")),
        };
        items
            .iter()
            .map(|item| match item {
                Value::String(string) => Ok(string.clone()),
                _ => Err(self.wrong(key, "an array of strings")),
            })
            .collect()
    }

    /// An array, empty when absent.
    pub fn array(&self, key: &str) -> Result<Vec<Value>, String> {
        match self.get(key) {
            None => Ok(Vec::new()),
            Some(Value::Array(items)) => Ok(items.clone()),
            Some(_) => Err(self.wrong(key, "an array")),
        }
    }

    /// The call's deadline in milliseconds (`timeoutMs`): `fallback_ms` when absent, None (no
    /// deadline) for 0 or less, as Playwright's `timeout: 0`; capped at [`LONGEST_DEADLINE_MS`].
    pub fn timeout_ms(&self, fallback_ms: f64) -> Result<Option<i64>, String> {
        match self.optional_number("timeoutMs")? {
            None => Ok(Some(deadline_ms(fallback_ms))),
            Some(ms) if ms > 0.0 => Ok(Some(deadline_ms(ms))),
            Some(_) => Ok(None),
        }
    }

    fn missing(&self, key: &str, kind: &str) -> String {
        format!("{}: {key}: expected {kind}", self.method)
    }

    fn wrong(&self, key: &str, kind: &str) -> String {
        let got = describe(self.fields.get(key).unwrap_or(&Value::Null));
        format!("{}: {key}: expected {kind}, got {got}", self.method)
    }
}

/// The JSON kind of `value`, as the error texts name it.
pub fn describe(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

/// `ms` as a whole-millisecond deadline, rounded half away from zero and capped at
/// [`LONGEST_DEADLINE_MS`] (`DriverParams.duration(milliseconds:)`).
pub fn deadline_ms(ms: f64) -> i64 {
    ms.round().min(LONGEST_DEADLINE_MS) as i64
}

/// A deadline as Swift's `Duration` prints it: seconds as a `Double`, `"1.5 seconds"`.
pub fn duration_text(ms: i64) -> String {
    format!("{:?} seconds", ms as f64 / 1000.0)
}

/// The error a call answers when its deadline passes first (`CallDeadline.run`):
/// `"<what>: Timeout 30.0 seconds exceeded"`.
pub fn timeout_message(what: &str, ms: i64) -> String {
    format!("{what}: Timeout {} exceeded", duration_text(ms))
}

/// Where a browser session's new tab opens: beside the session's caller
/// (`AutomationTabPlace`). With neither field the app falls back to the focused pane.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct TabPlace {
    /// The caller's workspace key (`callerWorkspace`).
    pub workspace: Option<String>,
    /// The caller's terminal id, `term_…` (`callerTerminal`).
    pub terminal: Option<String>,
}

impl TabPlace {
    /// The place a `tabs.open` call's params name; a field that is not a non-empty string is
    /// ignored.
    pub fn from_params(params: &Value) -> Self {
        let field = |key: &str| {
            params
                .get(key)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        Self { workspace: field("callerWorkspace"), terminal: field("callerTerminal") }
    }
}
