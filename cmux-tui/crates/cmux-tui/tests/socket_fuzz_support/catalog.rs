//! The `cmux.protocol/2` operation catalog (spec/resource-operations-v2.json)
//! and the legacy command surface (spec/api-compat.surface.json), as the
//! fuzzer reads them: every operation, its selectors, fields and errors.

use std::collections::BTreeMap;

use serde_json::Value;

pub const OPERATIONS_JSON: &str = include_str!("../../../../spec/resource-operations-v2.json");
pub const SURFACE_JSON: &str = include_str!("../../../../spec/api-compat.surface.json");

pub struct Catalog {
    pub root: Value,
    pub operations: Vec<Operation>,
    /// Socket-less operations (`class: local`): sent anyway, they must be refused.
    pub local_operations: Vec<Operation>,
    pub error_codes: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct Operation {
    pub name: String,
    pub class: String,
    pub target: String,
    /// selector name -> required
    pub selectors: BTreeMap<String, bool>,
    /// field name -> (required, type)
    pub fields: BTreeMap<String, (bool, Value)>,
    pub extra: bool,
    pub errors: Vec<String>,
    pub one_of: Vec<Value>,
}

impl Operation {
    pub fn is_mutation(&self) -> bool {
        self.class == "mutation"
    }
}

impl Catalog {
    pub fn load() -> Self {
        let root: Value =
            serde_json::from_str(OPERATIONS_JSON).expect("resource-operations-v2.json");
        let parse = |section: &str| -> Vec<Operation> {
            root[section]
                .as_object()
                .map(|ops| ops.iter().map(|(name, op)| Operation::parse(name, op)).collect())
                .unwrap_or_default()
        };
        let operations = parse("operations");
        let local_operations = parse("local_operations");
        let error_codes =
            root["errors"].as_object().map(|e| e.keys().cloned().collect()).unwrap_or_default();
        Self { root, operations, local_operations, error_codes }
    }

    pub fn type_named(&self, name: &str) -> Option<&Value> {
        self.root["types"].get(name)
    }

    pub fn generic_named(&self, name: &str) -> Option<&Value> {
        self.root["generics"].get(name)
    }

    pub fn is_error_code(&self, code: &str) -> bool {
        self.error_codes.iter().any(|known| known == code)
    }
}

impl Operation {
    fn parse(name: &str, op: &Value) -> Self {
        let params = &op["params"];
        let selectors = params["selectors"]
            .as_object()
            .map(|s| s.iter().map(|(k, v)| (k.clone(), v.as_str() == Some("required"))).collect())
            .unwrap_or_default();
        let fields = params["fields"]
            .as_object()
            .map(|f| {
                f.iter()
                    .map(|(k, v)| {
                        (k.clone(), (v["required"].as_bool() == Some(true), v["type"].clone()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            name: name.to_string(),
            class: op["class"].as_str().unwrap_or_default().to_string(),
            target: op["target"].as_str().unwrap_or_default().to_string(),
            selectors,
            fields,
            extra: params["extra"].as_bool().unwrap_or(false),
            errors: op["errors"]
                .as_array()
                .map(|e| e.iter().filter_map(|c| c.as_str().map(str::to_string)).collect())
                .unwrap_or_default(),
            one_of: params["one_of"].as_array().cloned().unwrap_or_default(),
        }
    }
}

/// One legacy (`{"cmd": ...}`) command and its request fields, from the
/// api-compat surface snapshot: `/field` -> {ty, nullable, required}.
pub struct LegacyCommand {
    pub name: String,
    pub fields: BTreeMap<String, Value>,
}

pub fn legacy_commands() -> Vec<LegacyCommand> {
    let root: Value = serde_json::from_str(SURFACE_JSON).expect("api-compat.surface.json");
    root["surface"]
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(key, fields)| {
            let name = key.strip_prefix("request:")?;
            let fields = fields
                .as_object()?
                .iter()
                // Top-level fields only ("/name"); nested paths ride inside them.
                .filter(|(path, _)| path.matches('/').count() == 1)
                .map(|(path, spec)| (path.trim_start_matches('/').to_string(), spec.clone()))
                .collect();
            Some(LegacyCommand { name: name.to_string(), fields })
        })
        .collect()
}
