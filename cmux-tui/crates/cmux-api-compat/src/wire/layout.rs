//! Binary layout fingerprints: what a `layout_version` stands for.

use std::collections::BTreeSet;

use serde_json::Value;

/// Keys that document a type or field node without changing its bytes.
const DOC_KEYS: [&str; 2] = ["description", "constraints"];
/// Keys whose object maps wire names (fields, variants, selectors) to nodes:
/// every key in it is a name on the wire, `description` included.
const NAME_MAPS: [&str; 4] = ["fields", "variants", "selectors", "properties"];
/// Keys whose value is data (a field's default), kept as is.
const DATA_KEYS: [&str; 1] = ["default"];

/// The named type tables of a schema file, for layout fingerprints.
pub(super) struct TypeTables<'a> {
    tables: Vec<&'a serde_json::Map<String, Value>>,
}

impl<'a> TypeTables<'a> {
    pub(super) fn new(schema: &'a Value, keys: &[&str]) -> Self {
        Self { tables: keys.iter().filter_map(|k| schema.get(*k)?.as_object()).collect() }
    }

    fn lookup(&self, name: &str) -> Option<&'a Value> {
        self.tables.iter().find_map(|table| table.get(name))
    }

    /// FNV-1a 64 of the canonical bytes of the entry's bodies plus every
    /// named type they reach, so editing a referenced type changes it too.
    pub(super) fn fingerprint(&self, entry: &Value, body_keys: &[&str]) -> String {
        let mut hash = Fnv::default();
        let mut reached = BTreeSet::new();
        let mut pending = Vec::new();
        for key in body_keys {
            hash.write(key.as_bytes());
            let body = entry.get(*key).unwrap_or(&Value::Null);
            canonical(body, Node::Type, &mut hash);
            referenced_names(body, &mut pending);
        }
        while let Some(name) = pending.pop() {
            if let Some(ty) = self.lookup(&name)
                && reached.insert(name)
            {
                referenced_names(ty, &mut pending);
            }
        }
        for name in &reached {
            hash.write(name.as_bytes());
            if let Some(ty) = self.lookup(name) {
                canonical(ty, Node::Type, &mut hash);
            }
        }
        format!("{:016x}", hash.0)
    }
}

fn referenced_names(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            let by_name = matches!(map.get("kind").and_then(Value::as_str), Some("ref" | "apply"));
            if by_name && let Some(name) = map.get("name").and_then(Value::as_str) {
                out.push(name.to_owned());
            }
            map.values().for_each(|v| referenced_names(v, out));
        }
        Value::Array(items) => items.iter().for_each(|v| referenced_names(v, out)),
        _ => {}
    }
}

/// What a JSON value is in a schema file.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Node {
    /// A type, field or body descriptor: its [`DOC_KEYS`] are annotations.
    Type,
    /// A [`NAME_MAPS`] object: every key is a wire name.
    Names,
    /// Data such as a default value: every key counts.
    Data,
}

impl Node {
    fn child(self, key: &str) -> Self {
        match self {
            Self::Data => Self::Data,
            Self::Names => Self::Type,
            Self::Type if DATA_KEYS.contains(&key) => Self::Data,
            Self::Type if NAME_MAPS.contains(&key) => Self::Names,
            Self::Type => Self::Type,
        }
    }
}

/// Sorted-key JSON without documentation members, independent of
/// serde_json's map ordering features.
fn canonical(value: &Value, node: Node, hash: &mut Fnv) {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<_> = map
                .keys()
                .filter(|k| node != Node::Type || !DOC_KEYS.contains(&k.as_str()))
                .collect();
            keys.sort();
            hash.write(b"{");
            for key in keys {
                hash.write(Value::String(key.clone()).to_string().as_bytes());
                hash.write(b":");
                canonical(&map[key], node.child(key), hash);
                hash.write(b",");
            }
            hash.write(b"}");
        }
        Value::Array(items) => {
            // An array of variants or members holds descriptors.
            let item = if node == Node::Data { Node::Data } else { Node::Type };
            hash.write(b"[");
            for value in items {
                canonical(value, item, hash);
                hash.write(b",");
            }
            hash.write(b"]");
        }
        scalar => hash.write(scalar.to_string().as_bytes()),
    }
}

struct Fnv(u64);

impl Default for Fnv {
    fn default() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }
}

impl Fnv {
    fn write(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x0100_0000_01b3);
        }
    }
}
