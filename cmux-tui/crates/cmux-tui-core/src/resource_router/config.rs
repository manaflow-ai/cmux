//! `settings.*` and `keybindings.*`: the config owners (plans/cmux-next/settings-react.md
//! section 3). Requests become `cmux_config` ops; refusals become catalog
//! errors with the owner's data in `details`.

use std::sync::Arc;

use cmux_config::keybindings::edit::Target as KeybindingTarget;
use cmux_config::{KeybindingsOp, KeybindingsRefusal, Op, Origin, Refusal, Target, WriteMeta};
use serde_json::{Map, Value, json};

use super::{ParsedResourceRequest, mutation_result, validation_error};
use crate::resource::{ResourceError, ResourceOperation, WireDecimal};
use crate::workspace_registry::Actor;
use crate::{Mux, ResourceTarget};

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
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
        ResourceOperation::SettingsSet
        | ResourceOperation::SettingsReset
        | ResourceOperation::SettingsResetAll => {
            let op = write_op(
                operation,
                fields,
                request.envelope.idempotency_key.clone(),
                &request.actor,
            )?;
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
        ResourceOperation::KeybindingsGet => Ok(mux.with_keybindings(|store| {
            let parsed = store.parsed();
            json!({
                "path": store.path().to_string_lossy(),
                "revision": WireDecimal::new(store.revision()),
                "entries": parsed.entries,
                "diagnostics": parsed.diagnostics,
            })
        })),
        ResourceOperation::KeybindingsSet
        | ResourceOperation::KeybindingsRemove
        | ResourceOperation::KeybindingsReset => {
            let op = keybindings_op(operation, fields)?;
            let origin = meta(fields, None, &request.actor)?.origin;
            match mux.keybindings_apply(op, origin, request.envelope.idempotency_key.clone()) {
                Ok(outcome) => mutation_result(mux, json!({}), outcome.revision, outcome.replayed),
                Err(refusal) => Err(keybindings_error(operation, &refusal)),
            }
        }
        other => Err(ResourceError::operation_failed(
            other.wire_name().to_owned(),
            "not a settings operation",
            json!({}),
        )),
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

fn meta(
    fields: &Map<String, Value>,
    key: Option<String>,
    actor: &Actor,
) -> Result<WriteMeta, ResourceError> {
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
    // A sandboxed app or a peer on another machine is an agent, whatever it
    // declares.
    let origin = match actor {
        Actor::App { .. } | Actor::Peer { .. } => Origin::Mcp,
        _ => Origin::parse(fields.get("origin").and_then(Value::as_str)),
    };
    Ok(WriteMeta { origin, idempotency_key: key, if_revision })
}

fn write_op(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
    key: Option<String>,
    actor: &Actor,
) -> Result<Op, ResourceError> {
    Ok(match operation {
        ResourceOperation::SettingsSet => Op::Set {
            target: target(fields)?,
            value: fields.get("value").cloned().unwrap_or(Value::Null),
            meta: meta(fields, key, actor)?,
        },
        ResourceOperation::SettingsReset => {
            Op::Reset { target: target(fields)?, meta: meta(fields, key, actor)? }
        }
        _ => Op::ResetAll { meta: meta(fields, key, actor)? },
    })
}

/// `{command, key, when?}`; `default_command` fills a `replaces` that names
/// only keys (the binding's own command).
fn binding(
    fields: &Map<String, Value>,
    default_command: Option<&str>,
) -> Result<KeybindingTarget, ResourceError> {
    let text = |name: &str| fields.get(name).and_then(Value::as_str).map(str::to_owned);
    let command = text("command")
        .or_else(|| default_command.map(str::to_owned))
        .ok_or_else(|| validation_error("a binding needs command", json!({"field":"command"})))?;
    let key = text("key")
        .ok_or_else(|| validation_error("a binding needs key", json!({"field":"key"})))?;
    Ok(KeybindingTarget { command, key, when: text("when") })
}

fn keybindings_op(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
) -> Result<KeybindingsOp, ResourceError> {
    Ok(match operation {
        ResourceOperation::KeybindingsSet => {
            let target = binding(fields, None)?;
            let replaces = match fields.get("replaces") {
                None | Some(Value::Null) => None,
                Some(Value::Object(old)) => Some(binding(old, Some(&target.command))?),
                Some(_) => {
                    return Err(validation_error(
                        "replaces is {key, when?, command?}",
                        json!({"field":"replaces"}),
                    ));
                }
            };
            let args = match fields.get("args") {
                None | Some(Value::Null) => None,
                Some(args @ Value::Object(members)) if !members.is_empty() => Some(args.clone()),
                Some(Value::Object(_)) => None,
                Some(_) => {
                    return Err(validation_error("args is an object", json!({"field":"args"})));
                }
            };
            KeybindingsOp::Set { binding: target, args, replaces }
        }
        ResourceOperation::KeybindingsRemove => {
            KeybindingsOp::Remove { target: binding(fields, None)? }
        }
        _ => KeybindingsOp::Reset {
            command: fields.get("command").and_then(Value::as_str).map(str::to_owned).ok_or_else(
                || validation_error("reset needs command", json!({"field":"command"})),
            )?,
        },
    })
}

fn keybindings_error(operation: ResourceOperation, refusal: &KeybindingsRefusal) -> ResourceError {
    match refusal {
        KeybindingsRefusal::Invalid(message) | KeybindingsRefusal::Unreadable(message) => {
            ResourceError::new(refusal.code(), message, json!({}), false)
        }
        KeybindingsRefusal::IdempotencyConflict { key, committed } => {
            ResourceError::idempotency_conflict(key, committed)
        }
        KeybindingsRefusal::Io(message) => ResourceError::operation_failed(
            operation.wire_name().to_owned(),
            message,
            json!({"code": refusal.code()}),
        ),
    }
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

#[cfg(test)]
mod tests {
    use super::schema_json;

    /// `settings.schema` carries each row's one-line `summary` (the only
    /// text a Settings row draws under its title) apart from the long
    /// `help`, and the typed schema row reads the same line.
    #[test]
    fn settings_schema_rows_carry_the_summary_line() {
        let wire = schema_json();
        let rows = wire["rows"].as_array().expect("settings.schema lists rows");
        let row = rows
            .iter()
            .find(|row| row["key"] == "appearance.backdropArt")
            .expect("appearance.backdropArt is a schema row");
        assert_eq!(row["summary"]["text"], "Painting behind the window", "{row}");
        assert_eq!(row["summary"]["key"], "settings.appearance.backdropArt.summary", "{row}");
        assert_ne!(row["summary"], row["help"], "the summary is not the help text");

        let schema = cmux_config::Schema::embedded();
        let typed = schema.row("appearance.backdropArt").and_then(|row| row.summary.as_ref());
        assert_eq!(typed.map(|text| text.text.as_str()), Some("Painting behind the window"));
        assert_eq!(
            typed.and_then(|text| text.key.as_deref()),
            Some("settings.appearance.backdropArt.summary")
        );
        for row in &schema.rows {
            if let Some(summary) = &row.summary {
                assert!(
                    summary.text.chars().count() <= 60,
                    "{}: a summary is one line of at most 60 characters",
                    row.key
                );
            }
        }
    }
}
