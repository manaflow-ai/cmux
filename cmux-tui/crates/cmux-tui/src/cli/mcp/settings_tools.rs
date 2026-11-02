//! Schema-scoped settings tools. The generic settings operations stay excluded:
//! they can read raw configuration, including credentials and MCP's own switch.
//! Writes always declare MCP origin; the daemon remains the policy and value
//! authority. Reads project only known descriptors and valid effective values.

use std::collections::BTreeMap;

use cmux_config::{
    Domains, Refusal, Schema,
    managed::ManagedSource,
    schema::{DomainKind, Kind, Row, Validation},
};
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::super::command::{RequestPlan, WireOperation};
use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};
use cmux_json::JsonSet as _;

pub(super) struct SettingTool {
    pub name: &'static str,
    operation: ResourceOperation,
    description: &'static str,
}

pub(super) const TOOLS: &[SettingTool] = &[
    SettingTool {
        name: "settings_list",
        operation: ResourceOperation::SettingsList,
        description: "List schema settings in key order with effective values and agent write policy. Raw configuration and invalid stored values are never returned. Use offset and limit for pages.",
    },
    SettingTool {
        name: "settings_get",
        operation: ResourceOperation::SettingsGet,
        description: "Read one schema setting's effective value and metadata. Raw paths, credentials, and invalid stored values are never returned.",
    },
    SettingTool {
        name: "settings_set",
        operation: ResourceOperation::SettingsSet,
        description: "Set an agent-settable schema key through the settings owner. Managed keys and user-only settings remain refused; the owner validates the value.",
    },
    SettingTool {
        name: "settings_reset",
        operation: ResourceOperation::SettingsReset,
        description: "Reset an agent-settable schema key to its default. Managed keys and user-only settings remain refused.",
    },
    SettingTool {
        name: "settings_unset",
        operation: ResourceOperation::SettingsReset,
        description: "Alias of settings_reset: remove an agent-settable schema key's override so its default applies.",
    },
];

pub(super) fn find(name: &str) -> Option<&'static SettingTool> {
    TOOLS.iter().find(|tool| tool.name == name)
}

impl SettingTool {
    fn mutation(&self) -> bool {
        matches!(self.operation, ResourceOperation::SettingsSet | ResourceOperation::SettingsReset)
    }

    pub(super) fn descriptor_json(&self) -> Value {
        let mut properties = json!({"session": {"type": "string", "minLength": 1}});
        let mut required = Vec::new();
        if self.operation == ResourceOperation::SettingsList {
            properties.set("section", json!({"type": "string", "minLength": 1}));
            properties.set("offset", json!({"type": "integer", "minimum": 0}));
            properties.set(
                "limit",
                json!({"type": "integer", "minimum": 1, "maximum": v2_tools::MAX_PAGE}),
            );
        } else {
            let keys: Vec<_> = Schema::embedded()
                .rows
                .iter()
                .filter(|row| !self.mutation() || row.agent_settable)
                .map(|row| row.key.as_str())
                .collect();
            properties.set("key", json!({"type": "string", "enum": keys}));
            required.push("key");
        }
        if self.operation == ResourceOperation::SettingsSet {
            properties.set(
                "value",
                json!({"description": "A JSON value accepted by this setting's schema."}),
            );
            required.push("value");
        }
        if self.mutation() {
            properties.set(
                "idempotency_key",
                json!({"type": "string", "minLength": 1, "maxLength": 128}),
            );
            properties.set("if_revision", json!({"type": "string", "pattern": "^[0-9]+$"}));
        }
        json!({
            "name": self.name, "description": self.description,
            "inputSchema": {"type": "object", "properties": properties,
                "required": required, "additionalProperties": false},
            "annotations": {"readOnlyHint": !self.mutation(), "destructiveHint": false,
                "idempotentHint": true, "openWorldHint": false}
        })
    }

    pub(super) fn call(&self, backend: &impl Backend, arguments: &Map<String, Value>) -> Value {
        match self.run(backend, arguments) {
            Ok(value) => value,
            Err(error) => tool_error(envelope(error, "not_run", None)),
        }
    }

    fn run(&self, backend: &impl Backend, arguments: &Map<String, Value>) -> Result<Value, Value> {
        let schema = Schema::embedded();
        let listing = self.operation == ResourceOperation::SettingsList;
        for name in arguments.keys() {
            let allowed = name == "session"
                || (listing && matches!(name.as_str(), "section" | "offset" | "limit"))
                || (!listing && name == "key")
                || (self.operation == ResourceOperation::SettingsSet && name == "value")
                || (self.mutation() && matches!(name.as_str(), "idempotency_key" | "if_revision"));
            if !allowed {
                return Err(v2_tools::invalid(format!("{} has no argument {name:?}", self.name)));
            }
        }
        let session = text(arguments, "session")?;
        let section = text(arguments, "section")?;
        if let Some(section) = section
            && schema.rows_in(Some(section)).next().is_none()
        {
            return Err(v2_tools::invalid("unknown settings section"));
        }
        let row = if listing {
            None
        } else {
            let key =
                text(arguments, "key")?.ok_or_else(|| v2_tools::invalid("key is required"))?;
            let row = schema.row(key);
            if self.mutation() && row.is_none_or(|row| !row.agent_settable) {
                let refusal = Refusal::AgentRefused {
                    key: key.to_owned(),
                    reason: row.and_then(|row| row.agent_refusal.clone()),
                };
                let mut details = refusal.data();
                if let Some(details) = details.as_object_mut() {
                    details.retain(|_, value| !value.is_null());
                }
                return Err(
                    json!({"code": "settings.agent_refused", "message": refusal.to_string(),
                    "details": details, "retryable": false}),
                );
            }
            let row = row.ok_or_else(|| v2_tools::invalid("key is not a schema setting"))?;
            Some(row)
        };
        let offset = count(arguments, "offset", 0, usize::MAX)?;
        let limit = count(arguments, "limit", v2_tools::DEFAULT_PAGE, v2_tools::MAX_PAGE)?;
        if limit == 0 {
            return Err(v2_tools::invalid("limit must be positive"));
        }
        let mut params = json!({"machine": "current", "session": "current"});
        if let Some(section) = section {
            params.set("section", json!(section));
        }
        if let Some(row) = row {
            params.set("key", json!(row.key));
        }
        if self.operation == ResourceOperation::SettingsSet {
            params.set(
                "value",
                arguments
                    .get("value")
                    .cloned()
                    .ok_or_else(|| v2_tools::invalid("value is required"))?,
            );
        }
        if self.mutation() {
            params.set("origin", json!("mcp"));
        }
        if let Some(revision) = text(arguments, "if_revision")? {
            if !revision.bytes().all(|byte| byte.is_ascii_digit())
                || revision.parse::<u64>().is_err()
            {
                return Err(v2_tools::invalid("if_revision must be a u64 decimal string"));
            }
            params.set("if_revision", json!(revision));
        }
        let idempotency_key = text(arguments, "idempotency_key")?;
        if let Some(key) = idempotency_key {
            cmux_tui_core::resource::validate_idempotency_key(key)
                .map_err(|error| v2_tools::invalid(error.message))?;
        }
        let plan = RequestPlan {
            operation: WireOperation::Typed(self.operation),
            params,
            idempotency_key: idempotency_key.map(str::to_owned),
            stream: false,
            resolve: Vec::new(),
            view: Default::default(),
        };
        let result = match backend.resource(session, plan, &[]) {
            Ok(result) => result,
            Err(failure) => return Ok(failure_result(failure)),
        };
        if self.mutation() {
            return Ok(success(result, true));
        }
        let projected = if let Some(row) = row {
            if result["key"] != row.key || result["row"]["key"] != row.key {
                return Err(v2_tools::invalid("settings owner returned no matching schema row"));
            }
            project(row, &result["row"])
        } else {
            let values = result
                .as_array()
                .ok_or_else(|| v2_tools::invalid("invalid settings list response"))?;
            let mut rows = BTreeMap::new();
            for value in values {
                let Some(row) = value["key"].as_str().and_then(|key| schema.row(key)) else {
                    continue;
                };
                if section.is_some_and(|section| row.section != section) {
                    continue;
                }
                if rows.insert(&row.key, project(row, value)).is_some() {
                    return Err(v2_tools::invalid("settings owner returned a duplicate key"));
                }
            }
            v2_tools::paginate(
                json!(rows.into_values().collect::<Vec<_>>()),
                v2_tools::Page { offset, limit },
            )
        };
        Ok(success(projected, false))
    }
}

/// Metadata comes from the embedded schema, never arbitrary response fields.
/// The raw file value may contain invalid objects or credentials even for a
/// known scalar key. Only a valid effective value crosses the MCP boundary.
fn project(row: &Row, value: &Value) -> Value {
    let mut projected = row.raw.clone();
    if let Some(object) = projected.as_object_mut() {
        object.remove("accepts");
        object.remove("refuses");
    }
    let current = &value["value"];
    let projected_value = project_value(row, current);
    let redacted = !current.is_null()
        && (cmux_config::schema::accepts(row, current, &Domains::default()).is_err()
            || sensitive_value(&projected_value, matches!(row.kind, Kind::Url)));
    projected.set("value", if redacted { Value::Null } else { projected_value });
    projected.set("value_redacted", json!(redacted));
    projected.set("customized", json!(value["customized"].as_bool().unwrap_or(false)));
    let managed = &value["managed"];
    projected.set(
        "managed",
        match managed["source"].as_str() {
            Some("mdm") => ManagedSource::Device.to_json(&row.key),
            Some("team") => {
                ManagedSource::Team(managed["team"].as_str().unwrap_or_default().to_owned())
                    .to_json(&row.key)
            }
            _ => Value::Null,
        },
    );
    projected
}

/// Schema URLs can still carry credentials. Query strings and fragments may
/// carry bearer tokens with arbitrary names, so expose no value for those
/// URLs. Likewise, map-shaped preferences must not disclose credential fields.
fn sensitive_value(value: &Value, url_setting: bool) -> bool {
    match value {
        Value::String(text) => {
            let parsed = url::Url::parse(text.trim()).or_else(|error| {
                if url_setting {
                    url::Url::parse(&format!("https://{}", text.trim()))
                } else {
                    Err(error)
                }
            });
            parsed.is_ok_and(|url| {
                !url.username().is_empty()
                    || url.password().is_some()
                    || url.query().is_some()
                    || url.fragment().is_some()
            })
        }
        Value::Array(values) => values.iter().any(|value| sensitive_value(value, false)),
        Value::Object(members) => members.iter().any(|(key, value)| {
            matches!(
                key.to_ascii_lowercase().as_str(),
                "password"
                    | "token"
                    | "access_token"
                    | "refresh_token"
                    | "api_key"
                    | "authorization"
                    | "secret"
            ) || sensitive_value(value, false)
        }),
        _ => false,
    }
}

/// These validators deliberately tolerate ignored object members for file
/// compatibility. MCP exports only the members the setting actually reads.
fn project_value(row: &Row, value: &Value) -> Value {
    let fields = |value: &Value, names: &[&str]| -> Value {
        match value.as_object() {
            Some(object) => Value::Object(
                object
                    .iter()
                    .filter(|(key, _)| names.contains(&key.as_str()))
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect(),
            ),
            None => value.clone(),
        }
    };
    if row.validation == Validation::Domain(DomainKind::CustomDensities) {
        return match value.as_array() {
            Some(values) => json!(
                values
                    .iter()
                    .map(|value| fields(
                        value,
                        &["id", "name", "level", "spacing", "fontSize", "tokens"]
                    ))
                    .collect::<Vec<_>>()
            ),
            None => value.clone(),
        };
    }
    if matches!(row.kind, Kind::TimeRange) {
        return fields(value, &["start", "end"]);
    }
    value.clone()
}

fn text<'a>(arguments: &'a Map<String, Value>, name: &str) -> Result<Option<&'a str>, Value> {
    match arguments.get(name) {
        None => Ok(None),
        Some(Value::String(text)) if !text.is_empty() => Ok(Some(text)),
        Some(_) => Err(v2_tools::invalid(format!("{name} must be a nonempty string"))),
    }
}

fn count(
    arguments: &Map<String, Value>,
    name: &str,
    default: usize,
    maximum: usize,
) -> Result<usize, Value> {
    match arguments.get(name) {
        None => Ok(default),
        Some(value) => value
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .filter(|value| *value <= maximum)
            .ok_or_else(|| {
                v2_tools::invalid(format!("{name} must be an integer at most {maximum}"))
            }),
    }
}
