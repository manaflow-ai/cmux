//! `settings.*`: the config owner (plans/cmux-next/settings-react.md
//! section 3). Requests become `cmux_config` ops; refusals become catalog
//! errors with the owner's data in `details`.

use std::sync::Arc;

use cmux_config::{Op, Origin, Refusal, Target, TeamPolicyLayer, WriteMeta};
use serde_json::{Map, Value, json};

use super::{ParsedResourceRequest, mutation_result, validation_error};
use crate::resource::{ResourceError, ResourceOperation, WireDecimal};
use crate::{Mux, ResourceTarget};

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::SettingsSchema
            | ResourceOperation::SettingsList
            | ResourceOperation::SettingsGet
            | ResourceOperation::SettingsSnapshot
            | ResourceOperation::SettingsSet
            | ResourceOperation::SettingsReset
            | ResourceOperation::SettingsResetAll
            | ResourceOperation::SettingsDomainsPublish
            | ResourceOperation::SettingsTeamPolicySet
    )
}

pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    let operation = request.envelope.operation;
    let fields = &request.fields;
    match operation {
        ResourceOperation::SettingsSchema => Ok(schema_json()),
        ResourceOperation::SettingsList => {
            let section = fields.get("section").and_then(Value::as_str);
            Ok(mux.with_settings(|state| {
                Value::Array(state.list(section).iter().map(|row| row.to_json()).collect())
            }))
        }
        ResourceOperation::SettingsGet => {
            let target = target(fields)?;
            Ok(mux.with_settings(|state| state.get(&target).to_json()))
        }
        ResourceOperation::SettingsSnapshot => {
            Ok(mux.with_settings(|state| state.snapshot().to_json()))
        }
        _ => {
            let op = write_op(operation, fields, request.envelope.idempotency_key.clone())?;
            match mux.settings_apply(op) {
                Ok(outcome) => mutation_result(
                    mux,
                    json!({"keys": outcome.keys}),
                    outcome.revision,
                    outcome.replayed,
                ),
                Err(refusal) => Err(refusal_error(operation, &refusal)),
            }
        }
    }
}

/// The embedded schema without the conformance samples.
fn schema_json() -> Value {
    let schema = cmux_config::Schema::embedded();
    let rows = schema
        .rows
        .iter()
        .map(|row| {
            let mut raw = row.raw.clone();
            if let Some(members) = raw.as_object_mut() {
                members.remove("accepts");
                members.remove("refuses");
            }
            raw
        })
        .collect::<Vec<_>>();
    json!({
        "version": schema.version,
        "schema_hash": schema.schema_hash,
        "sections": schema.sections,
        "rows": rows,
    })
}

fn target(fields: &Map<String, Value>) -> Result<Target, ResourceError> {
    if let Some(key) = fields.get("key").and_then(Value::as_str) {
        return Ok(Target::Key(key.to_owned()));
    }
    let path = fields
        .get("path")
        .and_then(Value::as_array)
        .ok_or_else(|| validation_error("settings need key or path", json!({"field":"key"})))?;
    let path = path
        .iter()
        .map(|part| part.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| validation_error("path holds strings", json!({"field":"path"})))?;
    Ok(Target::Path(path))
}

fn meta(fields: &Map<String, Value>, key: Option<String>) -> Result<WriteMeta, ResourceError> {
    let if_revision = fields
        .get("if_revision")
        .map(|value| {
            serde_json::from_value::<WireDecimal>(value.clone()).map(WireDecimal::get).map_err(
                |_| {
                    validation_error(
                        "if_revision is a decimal string",
                        json!({"field":"if_revision"}),
                    )
                },
            )
        })
        .transpose()?;
    let origin = Origin::parse(fields.get("origin").and_then(Value::as_str));
    Ok(WriteMeta { origin, idempotency_key: key, if_revision })
}

fn strings(fields: &Map<String, Value>, name: &str) -> Vec<String> {
    fields
        .get(name)
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_owned)).collect())
        .unwrap_or_default()
}

fn write_op(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
    key: Option<String>,
) -> Result<Op, ResourceError> {
    Ok(match operation {
        ResourceOperation::SettingsSet => Op::Set {
            target: target(fields)?,
            value: fields.get("value").cloned().unwrap_or(Value::Null),
            meta: meta(fields, key)?,
        },
        ResourceOperation::SettingsReset => {
            Op::Reset { target: target(fields)?, meta: meta(fields, key)? }
        }
        ResourceOperation::SettingsResetAll => Op::ResetAll { meta: meta(fields, key)? },
        ResourceOperation::SettingsDomainsPublish => Op::DomainsPublish {
            themes: strings(fields, "themes"),
            font_families: strings(fields, "font_families"),
            sounds: strings(fields, "sounds"),
        },
        ResourceOperation::SettingsTeamPolicySet => {
            Op::TeamPolicySet { layer: team_layer(fields.get("layer").unwrap_or(&Value::Null))? }
        }
        other => unreachable!("{} is not a settings write", other.wire_name()),
    })
}

/// `{team_id, team_name, version, defaults, enforced}`; the owner keeps
/// only catalog keys.
fn team_layer(value: &Value) -> Result<TeamPolicyLayer, ResourceError> {
    let object = value
        .as_object()
        .ok_or_else(|| validation_error("layer is an object", json!({"field":"layer"})))?;
    let text = |name: &str| object.get(name).and_then(Value::as_str).unwrap_or_default().to_owned();
    let map = |name: &str| {
        object
            .get(name)
            .and_then(Value::as_object)
            .map(|members| {
                members.iter().map(|(k, v)| (k.clone(), cmux_config::value::canonical(v.clone())))
            })
            .into_iter()
            .flatten()
            .collect()
    };
    let layer = TeamPolicyLayer {
        team_name: text("team_name"),
        defaults: map("defaults"),
        enforced: map("enforced"),
        team_id: text("team_id"),
        version: object.get("version").and_then(Value::as_i64).unwrap_or(0),
    };
    Ok(layer.limited_to_catalog(cmux_config::Schema::embedded()))
}

/// The catalog error for an owner refusal.
fn refusal_error(operation: ResourceOperation, refusal: &Refusal) -> ResourceError {
    let message = refusal.to_string();
    let data = refusal.data();
    match refusal {
        Refusal::Managed { .. } => settings_error("settings.managed", &message, data),
        Refusal::InvalidValue { .. } => settings_error("settings.invalid", &message, data),
        Refusal::AgentRefused { .. } => settings_error("settings.agent_refused", &message, data),
        Refusal::Removed { .. } => settings_error("settings.removed", &message, data),
        Refusal::InvalidParams { .. } => ResourceError::validation_invalid(None, message),
        Refusal::IdempotencyConflict { .. } => {
            ResourceError::new("idempotency.conflict", message, data, false)
        }
        Refusal::RevisionConflict { expected, actual } => {
            ResourceError::revision_conflict(*expected, *actual)
        }
        Refusal::FileUnreadable { .. } | Refusal::Io { .. } => ResourceError::operation_failed(
            operation.wire_name().to_owned(),
            message,
            json!({"code": refusal.code()}),
        ),
    }
}

/// Drops null members (the catalog marks optional fields absent, not null).
fn settings_error(code: &str, message: &str, data: Value) -> ResourceError {
    let details = match data {
        Value::Object(members) => {
            Value::Object(members.into_iter().filter(|(_, value)| !value.is_null()).collect())
        }
        other => other,
    };
    ResourceError::new(code, message, details, false)
}
