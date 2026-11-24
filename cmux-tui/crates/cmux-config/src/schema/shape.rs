//! The `json` kind's shape: a JSON Schema (draft 2020-12) a row carries for a
//! nested value (arrays of arrays, maps of lists), checked here so the owner,
//! `cmux settings schema` and an editor all hold one definition.
//!
//! Only the keywords below are read. A shape with any other keyword is refused
//! when the schema is parsed (`check`): a keyword this validator skipped would
//! accept a value an editor's full validator refuses, which silently weakens
//! validation. Annotations (`title`, `description`, `$comment`, `examples`)
//! carry no rule and are allowed.
//!
//! Checking is bounded by the value: each member and item is visited once per
//! schema node that applies to it.

use std::collections::HashSet;

use serde_json::{Map, Value};

/// The keywords the validator applies.
const RULES: &[&str] = &[
    "type",
    "enum",
    "const",
    "items",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minLength",
    "maxLength",
    "properties",
    "required",
    "additionalProperties",
    "propertyNames",
    "minProperties",
    "maxProperties",
];

/// Keywords that hold no rule.
const ANNOTATIONS: &[&str] = &["title", "description", "$comment", "examples"];

const TYPES: &[&str] = &["null", "boolean", "object", "array", "number", "integer", "string"];

/// `Ok` when `shape` uses only keywords this validator applies, each with a
/// well-formed value; else what is wrong and where.
pub fn check(shape: &Value) -> Result<(), String> {
    check_at(shape, "")
}

fn check_at(shape: &Value, at: &str) -> Result<(), String> {
    let Some(members) = shape.as_object() else {
        // `true` and `false` are schemas too.
        return if shape.is_boolean() { Ok(()) } else { Err(format!("{at}: not a schema")) };
    };
    for (keyword, value) in members {
        let here = format!("{at}/{keyword}");
        if ANNOTATIONS.contains(&keyword.as_str()) {
            continue;
        }
        if !RULES.contains(&keyword.as_str()) {
            return Err(format!("{here}: unsupported keyword"));
        }
        let well_formed = match keyword.as_str() {
            "type" => match value {
                Value::String(name) => TYPES.contains(&name.as_str()),
                Value::Array(names) => {
                    names.iter().all(|name| name.as_str().is_some_and(|name| TYPES.contains(&name)))
                }
                _ => false,
            },
            "enum" => value.is_array(),
            "const" => true,
            "minItems" | "maxItems" | "minLength" | "maxLength" | "minProperties"
            | "maxProperties" => value.as_u64().is_some(),
            "uniqueItems" => value.is_boolean(),
            "required" => value.as_array().is_some_and(|names| names.iter().all(Value::is_string)),
            "properties" => {
                let Some(properties) = value.as_object() else {
                    return Err(format!("{here}: not an object"));
                };
                for (name, schema) in properties {
                    check_at(schema, &format!("{here}/{name}"))?;
                }
                true
            }
            "items" | "additionalProperties" | "propertyNames" => {
                check_at(value, &here)?;
                true
            }
            _ => false,
        };
        if !well_formed {
            return Err(format!("{here}: malformed"));
        }
    }
    Ok(())
}

/// `Ok` when `value` matches `shape`; else the first mismatch, as the path
/// inside the value (`[1][0]`, `.agent`) and why.
pub fn matches(shape: &Value, value: &Value) -> Result<(), String> {
    matches_at(shape, value, &mut String::new())
}

fn fail(at: &str, why: &str) -> Result<(), String> {
    Err(if at.is_empty() { why.to_owned() } else { format!("{at}: {why}") })
}

fn matches_at(shape: &Value, value: &Value, at: &mut String) -> Result<(), String> {
    let members: &Map<String, Value> = match shape {
        Value::Bool(true) => return Ok(()),
        Value::Bool(false) => return fail(at, "not allowed"),
        Value::Object(members) => members,
        _ => return fail(at, "the row's shape is not a schema"),
    };
    if let Some(types) = members.get("type") {
        let ok = match types {
            Value::String(name) => has_type(value, name),
            Value::Array(names) => {
                names.iter().filter_map(Value::as_str).any(|n| has_type(value, n))
            }
            _ => false,
        };
        if !ok {
            return fail(at, &format!("expected {}", type_words(types)));
        }
    }
    if let Some(allowed) = members.get("enum").and_then(Value::as_array)
        && !allowed.iter().any(|item| same(item, value))
    {
        return fail(at, "not one of the allowed values");
    }
    if let Some(expected) = members.get("const")
        && !same(expected, value)
    {
        return fail(at, "not the allowed value");
    }
    if let Value::String(text) = value {
        let count = text.chars().count() as u64;
        if members.get("minLength").and_then(Value::as_u64).is_some_and(|min| count < min) {
            return fail(at, "too short");
        }
        if members.get("maxLength").and_then(Value::as_u64).is_some_and(|max| count > max) {
            return fail(at, "too long");
        }
    }
    if let Value::Array(items) = value {
        let count = items.len() as u64;
        if members.get("minItems").and_then(Value::as_u64).is_some_and(|min| count < min) {
            return fail(at, "too few items");
        }
        if let Some(max) = members.get("maxItems").and_then(Value::as_u64)
            && count > max
        {
            return fail(at, &format!("more than {max} items"));
        }
        if members.get("uniqueItems").and_then(Value::as_bool) == Some(true) {
            let mut seen = HashSet::with_capacity(items.len());
            for (index, item) in items.iter().enumerate() {
                if !seen.insert(crate::render::compact(&crate::value::canonical(item.clone()))) {
                    let len = at.len();
                    at.push_str(&format!("[{index}]"));
                    let result = fail(at, "repeated");
                    at.truncate(len);
                    return result;
                }
            }
        }
        if let Some(item_shape) = members.get("items") {
            for (index, item) in items.iter().enumerate() {
                let len = at.len();
                at.push_str(&format!("[{index}]"));
                let result = matches_at(item_shape, item, at);
                at.truncate(len);
                result?;
            }
        }
    }
    if let Value::Object(object) = value {
        let count = object.len() as u64;
        if members.get("minProperties").and_then(Value::as_u64).is_some_and(|min| count < min) {
            return fail(at, "too few members");
        }
        if let Some(max) = members.get("maxProperties").and_then(Value::as_u64)
            && count > max
        {
            return fail(at, &format!("more than {max} members"));
        }
        if let Some(required) = members.get("required").and_then(Value::as_array) {
            for name in required.iter().filter_map(Value::as_str) {
                if !object.contains_key(name) {
                    return fail(at, &format!("{name} is required"));
                }
            }
        }
        let properties = members.get("properties").and_then(Value::as_object);
        for (name, member) in object {
            let len = at.len();
            at.push('.');
            at.push_str(name);
            let result = (|| {
                if let Some(names) = members.get("propertyNames") {
                    matches_at(names, &Value::String(name.clone()), &mut String::new())
                        .or_else(|_| fail(at, "not an allowed name"))?;
                }
                match properties.and_then(|properties| properties.get(name)) {
                    Some(member_shape) => matches_at(member_shape, member, at),
                    None => match members.get("additionalProperties") {
                        Some(member_shape) => matches_at(member_shape, member, at),
                        None => Ok(()),
                    },
                }
            })();
            at.truncate(len);
            result?;
        }
    }
    Ok(())
}

fn has_type(value: &Value, name: &str) -> bool {
    match name {
        "null" => value.is_null(),
        "boolean" => value.is_boolean(),
        "object" => value.is_object(),
        "array" => value.is_array(),
        "string" => value.is_string(),
        "number" => value.is_number(),
        // JSON Schema: a number with a zero fractional part is an integer.
        "integer" => value.as_f64().is_some_and(|x| x.is_finite() && x.fract() == 0.0),
        _ => false,
    }
}

fn type_words(types: &Value) -> String {
    match types {
        Value::String(name) => article(name),
        Value::Array(names) => {
            names.iter().filter_map(Value::as_str).map(article).collect::<Vec<_>>().join(" or ")
        }
        _ => "a value".to_owned(),
    }
}

fn article(name: &str) -> String {
    match name {
        "array" | "object" | "integer" => format!("an {name}"),
        "null" => "null".to_owned(),
        _ => format!("a {name}"),
    }
}

/// JSON equality, numbers by value (`1` equals `1.0`).
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(key, x)| y.get(key).is_some_and(|y| same(x, y)))
        }
        _ => a == b,
    }
}

#[cfg(test)]
#[path = "shape_tests.rs"]
mod tests;
