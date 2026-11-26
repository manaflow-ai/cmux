//! JSON that keeps its key order, for editing files another program owns (`~/.claude.json`,
//! `.mcp.json`) without reordering them. The workspace's serde_json is built without
//! `preserve_order` (turning it on would change every map in the binary), so this is its own
//! small value: objects are ordered pairs, numbers keep serde_json's [`Number`].
//!
//! [`Json::pretty`] writes what JavaScript's `JSON.stringify(value, null, 2)` writes, which is how
//! Claude Code writes `~/.claude.json`: a file it wrote reads and writes back byte for byte.

use std::fmt;

use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::Number;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(Number),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    pub fn parse(text: &str) -> Result<Json, String> {
        serde_json::from_str(text).map_err(|error| error.to_string())
    }

    pub fn object() -> Json {
        Json::Object(Vec::new())
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(pairs) => pairs.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn get_mut(&mut self, key: &str) -> Option<&mut Json> {
        match self {
            Json::Object(pairs) => pairs.iter_mut().rev().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(value) => Some(*value),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&[(String, Json)]> {
        match self {
            Json::Object(pairs) => Some(pairs),
            _ => None,
        }
    }

    /// The strings of an array member (`args`, `disabledMcpServers`); non-strings are skipped.
    pub fn strings(&self) -> Vec<String> {
        self.as_array()
            .unwrap_or_default()
            .iter()
            .filter_map(|item| item.as_str().map(str::to_owned))
            .collect()
    }

    /// Sets `key` in place when it is there (keeping its position), else appends it. A non-object
    /// is left unchanged and false returned.
    pub fn set(&mut self, key: &str, value: Json) -> bool {
        let Json::Object(pairs) = self else { return false };
        if let Some(slot) = pairs.iter_mut().rev().find(|(k, _)| k == key) {
            slot.1 = value;
        } else {
            pairs.push((key.to_owned(), value));
        }
        true
    }

    /// Removes every `key`; the removed value (the last one) when there was one.
    pub fn remove(&mut self, key: &str) -> Option<Json> {
        let Json::Object(pairs) = self else { return None };
        let mut removed = None;
        pairs.retain_mut(|(k, v)| {
            if k == key {
                removed = Some(std::mem::replace(v, Json::Null));
                false
            } else {
                true
            }
        });
        removed
    }

    /// The object at `key`, made (appended) when absent or null. None when `self` or that member
    /// is some other kind of value: nothing is replaced.
    pub fn object_at(&mut self, key: &str) -> Option<&mut Json> {
        if !matches!(self, Json::Object(_)) {
            return None;
        }
        match self.get(key) {
            None | Some(Json::Null) => {
                self.set(key, Json::object());
            }
            Some(Json::Object(_)) => {}
            Some(_) => return None,
        }
        self.get_mut(key)
    }

    /// Converts from serde_json (whose maps are sorted); for values cmux makes itself.
    pub fn from_value(value: &serde_json::Value) -> Json {
        match value {
            serde_json::Value::Null => Json::Null,
            serde_json::Value::Bool(b) => Json::Bool(*b),
            serde_json::Value::Number(n) => Json::Number(n.clone()),
            serde_json::Value::String(s) => Json::String(s.clone()),
            serde_json::Value::Array(items) => {
                Json::Array(items.iter().map(Json::from_value).collect())
            }
            serde_json::Value::Object(map) => {
                Json::Object(map.iter().map(|(k, v)| (k.clone(), Json::from_value(v))).collect())
            }
        }
    }

    /// `JSON.stringify(self, null, 2)`.
    pub fn pretty(&self) -> String {
        let mut out = String::new();
        self.write(&mut out, 0);
        out
    }

    fn write(&self, out: &mut String, depth: usize) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Number(n) => out.push_str(&number_text(n)),
            Json::String(s) => out.push_str(&quote(s)),
            Json::Array(items) if items.is_empty() => out.push_str("[]"),
            Json::Object(pairs) if pairs.is_empty() => out.push_str("{}"),
            Json::Array(items) => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    out.push_str(if index == 0 { "\n" } else { ",\n" });
                    indent(out, depth + 1);
                    item.write(out, depth + 1);
                }
                out.push('\n');
                indent(out, depth);
                out.push(']');
            }
            Json::Object(pairs) => {
                out.push('{');
                for (index, (key, value)) in pairs.iter().enumerate() {
                    out.push_str(if index == 0 { "\n" } else { ",\n" });
                    indent(out, depth + 1);
                    out.push_str(&quote(key));
                    out.push_str(": ");
                    value.write(out, depth + 1);
                }
                out.push('\n');
                indent(out, depth);
                out.push('}');
            }
        }
    }
}

fn indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn quote(text: &str) -> String {
    // serde_json escapes as JSON.stringify does: `"`, `\`, and control characters (\b \f \n \r \t,
    // others as \u00XX); everything else, non-ASCII included, as itself.
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_owned())
}

/// A number as JavaScript prints it: integers plainly, an integral float without `.0`, and
/// exponents with a sign (`1e+21`).
fn number_text(number: &Number) -> String {
    if number.is_i64() || number.is_u64() {
        return number.to_string();
    }
    let Some(float) = number.as_f64() else { return number.to_string() };
    if float.fract() == 0.0 && float.abs() < 1e21 {
        return format!("{float:.0}");
    }
    let text = number.to_string();
    match text.split_once('e') {
        Some((mantissa, exponent)) if !exponent.starts_with('-') && !exponent.starts_with('+') => {
            format!("{mantissa}e+{exponent}")
        }
        _ => text,
    }
}

impl<'de> Deserialize<'de> for Json {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(JsonVisitor)
    }
}

struct JsonVisitor;

impl<'de> Visitor<'de> for JsonVisitor {
    type Value = Json;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("any JSON value")
    }

    fn visit_bool<E>(self, value: bool) -> Result<Json, E> {
        Ok(Json::Bool(value))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Json, E> {
        Ok(Json::Number(value.into()))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Json, E> {
        Ok(Json::Number(value.into()))
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<Json, E> {
        Number::from_f64(value)
            .map(Json::Number)
            .ok_or_else(|| E::custom("a number JSON cannot hold"))
    }

    fn visit_str<E>(self, value: &str) -> Result<Json, E> {
        Ok(Json::String(value.to_owned()))
    }

    fn visit_string<E>(self, value: String) -> Result<Json, E> {
        Ok(Json::String(value))
    }

    fn visit_unit<E>(self) -> Result<Json, E> {
        Ok(Json::Null)
    }

    fn visit_none<E>(self) -> Result<Json, E> {
        Ok(Json::Null)
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<Json, D::Error> {
        Json::deserialize(deserializer)
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Json, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = seq.next_element()? {
            items.push(item);
        }
        Ok(Json::Array(items))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Json, A::Error> {
        let mut pairs = Vec::new();
        while let Some((key, value)) = map.next_entry::<String, Json>()? {
            pairs.push((key, value));
        }
        Ok(Json::Object(pairs))
    }
}

#[cfg(test)]
#[path = "ojson_tests.rs"]
mod tests;
