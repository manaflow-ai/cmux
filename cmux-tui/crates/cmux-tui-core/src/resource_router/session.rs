use std::sync::Arc;

use serde_json::{Value, json};

use super::effects::{self, EffectPreparation};
use super::{
    ParsedResourceRequest, expected_revision, mutation_result, required_string,
    resource_operation_error, validation_error,
};
use crate::resource::{ResourceError, ResourceOperation};
use crate::{
    ConfigReloadError, DefaultColors, Mux, MuxEvent, ResourceTarget, Rgb, WorkspaceMutation,
};

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::SessionCreationResolve
            | ResourceOperation::SessionReloadConfig
            | ResourceOperation::SessionTerminalDefaultsUpdate
            | ResourceOperation::SessionWindowTitleSet
            | ResourceOperation::SessionWindowTitleClear
    )
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    if request.envelope.operation == ResourceOperation::SessionCreationResolve {
        mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
        return mux
            .resource_creation_resolution(required_string(&request.fields, "correlation_key")?)
            .map_err(resource_operation_error);
    }
    if request.envelope.operation == ResourceOperation::SessionTerminalDefaultsUpdate {
        return update_terminal_defaults(mux, request);
    }
    let prepared = effects::prepare(mux, &request, || {
        mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
        Ok(json!({"fields":request.fields}))
    })?;
    let prepared = match prepared {
        EffectPreparation::Complete(result) => return result,
        EffectPreparation::Execute(prepared) => prepared,
    };

    let value = match request.envelope.operation {
        ResourceOperation::SessionReloadConfig => {
            match mux.request_config_reload() {
                Ok(()) => {}
                Err(ConfigReloadError::TimedOut) => {
                    return Err(effects::mark_indeterminate(mux, prepared));
                }
                Err(ConfigReloadError::OwnerStopped) => {
                    return effects::commit_known_failure(
                        mux,
                        prepared,
                        ResourceError::operation_failed(
                            "session.reload_config",
                            "owner_stopped",
                            json!({}),
                        ),
                    );
                }
            }
            json!({"reloaded":true,"warnings":[]})
        }
        ResourceOperation::SessionWindowTitleSet => {
            let Some(title) = prepared.intent["fields"]["title"].as_str() else {
                return Err(effects::mark_indeterminate(mux, prepared));
            };
            mux.emit(MuxEvent::WindowTitleRequested(title.to_string()));
            json!({})
        }
        ResourceOperation::SessionWindowTitleClear => {
            mux.emit(MuxEvent::WindowTitleRequested(String::new()));
            json!({})
        }
        ResourceOperation::SessionTerminalDefaultsUpdate => {
            unreachable!("terminal defaults use the exact pure mutation path")
        }
        _ => unreachable!("handles guards every session operation"),
    };
    effects::commit_success(mux, prepared, value, json!([]))
}

pub(super) fn commit_shutdown(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert_eq!(request.envelope.operation, ResourceOperation::SessionShutdown);
    let prepared = effects::prepare(mux, &request, || {
        mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
        Ok(json!({"fields":request.fields}))
    })?;
    let prepared = match prepared {
        EffectPreparation::Complete(result) => return result,
        EffectPreparation::Execute(prepared) => prepared,
    };
    // The connection owner requests process shutdown only after this durable
    // result commits and its response has been queued.
    effects::commit_success(mux, prepared, json!({"accepted":true}), json!([]))
}

fn update_terminal_defaults(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let complete = request.fields["complete"].as_bool().unwrap_or(false);
    let base = if complete { DefaultColors::default() } else { mux.default_colors() };
    let colors = DefaultColors {
        fg: nullable_color(&request.fields, "foreground", base.fg)?,
        bg: nullable_color(&request.fields, "background", base.bg)?,
        cursor: nullable_color(&request.fields, "cursor", base.cursor)?,
        selection_bg: nullable_color(&request.fields, "selection_background", base.selection_bg)?,
        selection_fg: nullable_color(&request.fields, "selection_foreground", base.selection_fg)?,
        cursor_style: match request.fields.get("cursor_style") {
            None => base.cursor_style,
            Some(Value::Null) => None,
            Some(Value::String(value)) => Some(match value.as_str() {
                "block" => ghostty_vt::CursorShape::Block,
                "bar" => ghostty_vt::CursorShape::Bar,
                "underline" => ghostty_vt::CursorShape::Underline,
                _ => unreachable!("catalog validates cursor style"),
            }),
            Some(_) => unreachable!("catalog validates cursor style"),
        },
        cursor_blink: match request.fields.get("cursor_blink") {
            None => base.cursor_blink,
            Some(Value::Null) => None,
            Some(Value::Bool(value)) => Some(*value),
            Some(_) => unreachable!("catalog validates cursor blink"),
        },
        palette: match request.fields.get("palette") {
            None => base.palette,
            Some(Value::Null) => [None; 256],
            Some(Value::Object(entries)) => {
                let mut palette = [None; 256];
                for (index, value) in entries {
                    let index = index.parse::<u8>().map_err(|_| {
                        validation_error(
                            "palette index must be a decimal value from 0 through 255",
                            json!({"index":index}),
                        )
                    })?;
                    let color = value.as_str().expect("catalog validates terminal palette values");
                    palette[usize::from(index)] = Some(parse_hex_color(color)?);
                }
                palette
            }
            Some(_) => unreachable!("catalog validates terminal palette"),
        },
    };
    let value = terminal_defaults_snapshot(colors);
    let mutation = WorkspaceMutation::new(
        request
            .envelope
            .idempotency_key
            .clone()
            .expect("validated mutations have an idempotency key"),
        "resource-api",
    )
    .map_err(resource_operation_error)?;
    let fields = Value::Object(request.fields.clone());
    let commit = mux
        .resource_update_terminal_defaults_selected(
            request.selectors,
            &fields,
            colors,
            &value,
            expected_revision(&request.fields)?,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

fn nullable_color(
    fields: &serde_json::Map<String, Value>,
    name: &str,
    inherited: Option<Rgb>,
) -> Result<Option<Rgb>, ResourceError> {
    match fields.get(name) {
        None => Ok(inherited),
        Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => parse_hex_color(value).map(Some),
        Some(_) => unreachable!("catalog validates terminal colors"),
    }
}

fn parse_hex_color(value: &str) -> Result<Rgb, ResourceError> {
    let Some(hex) = value.strip_prefix('#').filter(|hex| hex.len() == 6) else {
        return Err(validation_error("terminal colors must use #rrggbb", json!({"color":value})));
    };
    let parse = |range| {
        u8::from_str_radix(&hex[range], 16).map_err(|_| {
            validation_error("terminal colors must use #rrggbb", json!({"color":value}))
        })
    };
    Ok(Rgb { r: parse(0..2)?, g: parse(2..4)?, b: parse(4..6)? })
}

fn terminal_defaults_snapshot(colors: DefaultColors) -> Value {
    let palette = colors
        .palette
        .iter()
        .enumerate()
        .filter_map(|(index, color)| {
            color.map(|color| (index.to_string(), Value::String(rgb_hex(color))))
        })
        .collect::<serde_json::Map<_, _>>();
    json!({
        "foreground":colors.fg.map(rgb_hex),
        "background":colors.bg.map(rgb_hex),
        "cursor":colors.cursor.map(rgb_hex),
        "selection_background":colors.selection_bg.map(rgb_hex),
        "selection_foreground":colors.selection_fg.map(rgb_hex),
        "cursor_style":colors.cursor_style.map(|style| match style {
            ghostty_vt::CursorShape::Bar => "bar",
            ghostty_vt::CursorShape::Underline => "underline",
            ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
        }),
        "cursor_blink":colors.cursor_blink,
        "palette":palette,
    })
}

fn rgb_hex(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SurfaceOptions;

    fn request(
        operation: ResourceOperation,
        idempotency_key: &str,
        fields: Value,
    ) -> ParsedResourceRequest {
        ParsedResourceRequest {
            envelope: crate::resource::RequestEnvelope {
                protocol: crate::resource::PROTOCOL.to_string(),
                envelope_type: crate::resource::EnvelopeType::Request,
                id: crate::resource::RequestId::parse("session-effect").unwrap(),
                operation,
                params: json!({}),
                idempotency_key: Some(idempotency_key.to_string()),
            },
            selectors: crate::ResourceSelectors {
                machine: Some("current".to_string()),
                session: Some("current".to_string()),
                ..Default::default()
            },
            fields: fields.as_object().unwrap().clone(),
        }
    }

    #[test]
    fn window_title_effect_replays_without_reemitting() {
        let mux = Mux::new_for_test("session-effects", SurfaceOptions::default());
        let events = mux.subscribe();
        let first = dispatch(
            &mux,
            request(
                ResourceOperation::SessionWindowTitleSet,
                "window-title-once",
                json!({"title":"one"}),
            ),
        )
        .unwrap();
        assert_eq!(first["replayed"], false);
        assert!(matches!(
            events.recv_timeout(std::time::Duration::from_millis(50)),
            Ok(MuxEvent::WindowTitleRequested(title)) if title == "one"
        ));
        let replay = dispatch(
            &mux,
            request(
                ResourceOperation::SessionWindowTitleSet,
                "window-title-once",
                json!({"title":"one"}),
            ),
        )
        .unwrap();
        assert_eq!(replay["replayed"], true);
        assert!(events.recv_timeout(std::time::Duration::from_millis(10)).is_err());
    }

    #[test]
    fn shutdown_receipt_commits_without_starting_process_shutdown() {
        let mux = Mux::new_for_test("session-shutdown", SurfaceOptions::default());
        let first = commit_shutdown(
            &mux,
            request(ResourceOperation::SessionShutdown, "shutdown-once", json!({"force":true})),
        )
        .unwrap();
        assert_eq!(first["value"]["accepted"], true);
        assert_eq!(first["replayed"], false);
        assert!(!mux.daemon_shutdown_requested());

        let replay = commit_shutdown(
            &mux,
            request(ResourceOperation::SessionShutdown, "shutdown-once", json!({"force":true})),
        )
        .unwrap();
        assert_eq!(replay["value"]["accepted"], true);
        assert_eq!(replay["replayed"], true);
        assert!(!mux.daemon_shutdown_requested());
    }

    #[test]
    fn stopped_owner_reload_replays_its_known_failure_receipt() {
        let mux = Mux::new_for_test("session-reload-failure", SurfaceOptions::default());
        mux.shutdown();
        let reload = || {
            dispatch(
                &mux,
                request(ResourceOperation::SessionReloadConfig, "reload-failure", json!({})),
            )
            .unwrap_err()
        };

        let first = reload();
        let replay = reload();
        assert_eq!(first.code, "operation.failed");
        assert_eq!(first.message, "owner_stopped");
        assert_eq!(first.details["operation"], "session.reload_config");
        assert_eq!(first.details["reason"], "owner_stopped");
        assert_eq!(replay, first);
    }

    #[test]
    fn timed_out_reload_remains_indeterminate_after_late_owner_completion() {
        let mux = Mux::new_for_test("session-reload-timeout", SurfaceOptions::default());
        let events = mux.subscribe_config_reload();
        let worker_mux = mux.clone();
        let worker = std::thread::spawn(move || {
            dispatch(
                &worker_mux,
                request(ResourceOperation::SessionReloadConfig, "reload-timeout", json!({})),
            )
            .unwrap_err()
        });

        assert!(matches!(
            events.recv_timeout(std::time::Duration::from_secs(1)),
            Ok(MuxEvent::ConfigReloadRequested)
        ));
        let first = worker.join().unwrap();
        let target = mux.begin_config_reload_application();
        mux.complete_config_reload_application(target);
        let replay = dispatch(
            &mux,
            request(ResourceOperation::SessionReloadConfig, "reload-timeout", json!({})),
        )
        .unwrap_err();

        assert_eq!(first.code, "mutation.indeterminate");
        assert_eq!(replay, first);
        assert!(events.recv_timeout(std::time::Duration::from_millis(50)).is_err());
    }

    #[test]
    fn creation_resolve_returns_unknown_and_typed_validation_states() {
        let mux = Mux::new_for_test("creation-resolve", SurfaceOptions::default());
        let unknown = dispatch(
            &mux,
            request(
                ResourceOperation::SessionCreationResolve,
                "unused",
                json!({"correlation_key":"unknown-correlation"}),
            ),
        )
        .unwrap();
        assert_eq!(
            unknown,
            json!({
                "correlation_key":"unknown-correlation",
                "state":"not_applied",
                "recovery":"retry_new_idempotency_key",
            })
        );
        let error = dispatch(
            &mux,
            request(
                ResourceOperation::SessionCreationResolve,
                "unused",
                json!({"correlation_key":""}),
            ),
        )
        .unwrap_err();
        assert_eq!(error.code, "validation.invalid");
        assert_eq!(error.details["field"], "correlation_key");
    }
}
