//! An order-preserving JSON value for editing agent config files.
//!
//! The workspace builds `serde_json` without `preserve_order`, so a
//! `serde_json::Value` round trip sorts every object's keys. Claude Code's
//! settings.json and Codex's hooks.json are hand-edited files whose key order
//! is the user's, so edits go through [`OJson`], which keeps each object's
//! members in file order and leaves every member it is not asked to change
//! exactly as parsed.

use std::fmt;

use indexmap::IndexMap;
use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde::ser::{Serialize, SerializeMap, SerializeSeq, Serializer};

/// One JSON value whose objects keep their members in file order.
#[derive(Clone, Debug, PartialEq)]
pub enum OJson {
    Null,
    Bool(bool),
    Number(serde_json::Number),
    String(String),
    Array(Vec<OJson>),
    Object(IndexMap<String, OJson>),
}

impl OJson {
    pub fn object() -> Self {
        Self::Object(IndexMap::new())
    }

    pub fn as_object(&self) -> Option<&IndexMap<String, OJson>> {
        match self {
            Self::Object(map) => Some(map),
            _ => None,
        }
    }

    pub fn as_object_mut(&mut self) -> Option<&mut IndexMap<String, OJson>> {
        match self {
            Self::Object(map) => Some(map),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&Vec<OJson>> {
        match self {
            Self::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_array_mut(&mut self) -> Option<&mut Vec<OJson>> {
        match self {
            Self::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(value) => Some(*value),
            _ => None,
        }
    }

    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Self::Number(number) => number.as_u64(),
            _ => None,
        }
    }

    pub fn get(&self, key: &str) -> Option<&OJson> {
        self.as_object().and_then(|map| map.get(key))
    }

    pub fn get_mut(&mut self, key: &str) -> Option<&mut OJson> {
        self.as_object_mut().and_then(|map| map.get_mut(key))
    }

    /// Parses `text`; an empty or whitespace-only file is an empty object.
    pub fn parse(text: &str) -> serde_json::Result<Self> {
        if text.trim().is_empty() {
            return Ok(Self::object());
        }
        serde_json::from_str(text)
    }

    /// Two-space pretty JSON with a trailing newline, the shape Claude Code
    /// and Codex write themselves.
    pub fn to_pretty(&self) -> String {
        let mut text = serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".into());
        text.push('\n');
        text
    }
}

impl From<&str> for OJson {
    fn from(value: &str) -> Self {
        Self::String(value.to_owned())
    }
}

impl From<u64> for OJson {
    fn from(value: u64) -> Self {
        Self::Number(value.into())
    }
}

impl Serialize for OJson {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Null => serializer.serialize_unit(),
            Self::Bool(value) => serializer.serialize_bool(*value),
            Self::Number(number) => number.serialize(serializer),
            Self::String(text) => serializer.serialize_str(text),
            Self::Array(items) => {
                let mut seq = serializer.serialize_seq(Some(items.len()))?;
                for item in items {
                    seq.serialize_element(item)?;
                }
                seq.end()
            }
            Self::Object(members) => {
                let mut map = serializer.serialize_map(Some(members.len()))?;
                for (key, value) in members {
                    map.serialize_entry(key, value)?;
                }
                map.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for OJson {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(OJsonVisitor)
    }
}

struct OJsonVisitor;

impl<'de> Visitor<'de> for OJsonVisitor {
    type Value = OJson;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("any JSON value")
    }

    fn visit_bool<E>(self, value: bool) -> Result<OJson, E> {
        Ok(OJson::Bool(value))
    }

    fn visit_i64<E>(self, value: i64) -> Result<OJson, E> {
        Ok(OJson::Number(value.into()))
    }

    fn visit_u64<E>(self, value: u64) -> Result<OJson, E> {
        Ok(OJson::Number(value.into()))
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<OJson, E> {
        serde_json::Number::from_f64(value)
            .map(OJson::Number)
            .ok_or_else(|| E::custom("a non-finite number"))
    }

    fn visit_str<E>(self, value: &str) -> Result<OJson, E> {
        Ok(OJson::String(value.to_owned()))
    }

    fn visit_string<E>(self, value: String) -> Result<OJson, E> {
        Ok(OJson::String(value))
    }

    fn visit_unit<E>(self) -> Result<OJson, E> {
        Ok(OJson::Null)
    }

    fn visit_none<E>(self) -> Result<OJson, E> {
        Ok(OJson::Null)
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<OJson, D::Error> {
        Deserialize::deserialize(deserializer)
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut access: A) -> Result<OJson, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = access.next_element()? {
            items.push(item);
        }
        Ok(OJson::Array(items))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut access: A) -> Result<OJson, A::Error> {
        let mut members = IndexMap::new();
        while let Some((key, value)) = access.next_entry::<String, OJson>()? {
            members.insert(key, value);
        }
        Ok(OJson::Object(members))
    }
}

#[cfg(test)]
#[path = "hooks_ojson_tests.rs"]
mod tests;
