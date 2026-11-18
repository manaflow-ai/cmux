//! JSON Pointer (RFC 6901) over the host-held data model, with A2UI's
//! relative paths inside templates.

use serde_json::{Map, Value};

/// Resolve `path` against `scope` (an absolute pointer, "" for the root).
/// Absolute paths start with `/`; anything else is relative to the scope.
pub fn absolute(scope: &str, path: &str) -> String {
    if path.starts_with('/') {
        return if path == "/" { String::new() } else { path.to_string() };
    }
    if path.is_empty() {
        return scope.to_string();
    }
    format!("{scope}/{path}")
}

fn tokens(pointer: &str) -> impl Iterator<Item = String> + '_ {
    pointer.split('/').skip(1).map(|t| t.replace("~1", "/").replace("~0", "~"))
}

pub fn get<'a>(root: &'a Value, pointer: &str) -> Option<&'a Value> {
    if pointer.is_empty() || pointer == "/" {
        return Some(root);
    }
    let mut cur = root;
    for t in tokens(pointer) {
        cur = match cur {
            Value::Object(m) => m.get(&t)?,
            Value::Array(a) => a.get(t.parse::<usize>().ok()?)?,
            _ => return None,
        };
    }
    Some(cur)
}

/// Write `value` at `pointer`, creating missing objects. `null` deletes the
/// key (A2UI `updateDataModel` semantics). An empty pointer replaces the root.
/// Array indexes past the end are refused (no sparse growth).
pub fn set(root: &mut Value, pointer: &str, value: Value) -> bool {
    if pointer.is_empty() || pointer == "/" {
        *root = if value.is_null() { Value::Object(Map::new()) } else { value };
        return true;
    }
    let toks: Vec<String> = tokens(pointer).collect();
    let Some((last, parents)) = toks.split_last() else {
        return false;
    };
    let mut cur = root;
    for t in parents {
        if !cur.is_object() && !cur.is_array() {
            *cur = Value::Object(Map::new());
        }
        cur = match cur {
            Value::Object(m) => m.entry(t.clone()).or_insert_with(|| Value::Object(Map::new())),
            Value::Array(a) => match t.parse::<usize>().ok().and_then(|i| a.get_mut(i)) {
                Some(v) => v,
                None => return false,
            },
            _ => return false,
        };
    }
    if !cur.is_object() && !cur.is_array() {
        *cur = Value::Object(Map::new());
    }
    match cur {
        Value::Object(m) => {
            if value.is_null() {
                m.remove(last);
            } else {
                m.insert(last.clone(), value);
            }
            true
        }
        Value::Array(a) => match last.parse::<usize>() {
            Ok(i) if i < a.len() => match a.get_mut(i) {
                Some(slot) => {
                    *slot = value;
                    true
                }
                None => false,
            },
            Ok(i) if i == a.len() && !value.is_null() => {
                a.push(value);
                true
            }
            _ => false,
        },
        _ => false,
    }
}

/// Every leaf under `root` as (pointer, value), in key order, for the
/// summary of a `sendDataModel` action.
pub fn leaves(root: &Value) -> Vec<(String, &Value)> {
    fn walk<'a>(v: &'a Value, at: String, out: &mut Vec<(String, &'a Value)>) {
        match v {
            Value::Object(m) if !m.is_empty() => {
                for (k, child) in m {
                    let esc = k.replace('~', "~0").replace('/', "~1");
                    walk(child, format!("{at}/{esc}"), out);
                }
            }
            _ => out.push((if at.is_empty() { "/".into() } else { at }, v)),
        }
    }
    let mut out = Vec::new();
    walk(root, String::new(), &mut out);
    out
}
