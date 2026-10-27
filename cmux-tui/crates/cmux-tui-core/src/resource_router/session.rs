use std::sync::Arc;

use ghostty_vt::CursorShape;
use serde_json::{Value, json};

use super::effects::{self, EffectPreparation};
use super::{
    ParsedResourceRequest, expected_revision, mutation_result, required_string,
    resource_operation_error, validation_error,
};
use crate::resource::{ResourceError, ResourceOperation};
use crate::{ConfigReloadError, DefaultColors, Mux, MuxEvent, ResourceTarget, Rgb};

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
    let effect = match request.envelope.operation {
        ResourceOperation::SessionCreationResolve => {
            mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
            return mux
                .resource_creation_resolution(required_string(&request.fields, "correlation_key")?)
                .map_err(resource_operation_error);
        }
        ResourceOperation::SessionTerminalDefaultsUpdate => {
            return update_terminal_defaults(mux, request);
        }
        ResourceOperation::SessionReloadConfig => SessionEffect::ReloadConfig,
        ResourceOperation::SessionWindowTitleSet => SessionEffect::SetWindowTitle,
        ResourceOperation::SessionWindowTitleClear => SessionEffect::ClearWindowTitle,
        other => {
            return Err(ResourceError::operation_failed(
                super::operation_name(other),
                "operation is not a session operation",
                json!({}),
            ));
        }
    };
    let prepared = effects::prepare(mux, &request, || {
        mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
        Ok(json!({"fields":request.fields}))
    })?;
    let prepared = match prepared {
        EffectPreparation::Complete(result) => return result,
        EffectPreparation::Execute(prepared) => prepared,
    };

    let value = match effect {
        SessionEffect::ReloadConfig => {
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
        SessionEffect::SetWindowTitle => {
            let Some(title) = prepared.intent.pointer("/fields/title").and_then(Value::as_str)
            else {
                return Err(effects::mark_indeterminate(mux, prepared));
            };
            mux.emit(MuxEvent::WindowTitleRequested(title.to_string()));
            json!({})
        }
        SessionEffect::ClearWindowTitle => {
            mux.emit(MuxEvent::WindowTitleRequested(String::new()));
            json!({})
        }
    };
    effects::commit_success(mux, prepared, value, json!([]))
}

/// The session operations that run through a durable effect.
enum SessionEffect {
    ReloadConfig,
    SetWindowTitle,
    ClearWindowTitle,
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
    // The catalog fills the documented default (false) for an omitted `complete`.
    let complete = request.fields.get("complete").and_then(Value::as_bool).unwrap_or(false);
    let base = if complete { DefaultColors::default() } else { mux.default_colors() };
    let colors = DefaultColors {
        fg: nullable_color(&request.fields, "foreground", base.fg)?,
        bg: nullable_color(&request.fields, "background", base.bg)?,
        cursor: nullable_color(&request.fields, "cursor", base.cursor)?,
        selection_bg: nullable_color(&request.fields, "selection_background", base.selection_bg)?,
        selection_fg: nullable_color(&request.fields, "selection_foreground", base.selection_fg)?,
        cursor_style: nullable_cursor_style(&request.fields, base.cursor_style)?,
        cursor_blink: match request.fields.get("cursor_blink") {
            None => base.cursor_blink,
            Some(Value::Null) => None,
            Some(Value::Bool(value)) => Some(*value),
            Some(_) => {
                return Err(validation_error(
                    "cursor_blink must be a boolean or null",
                    json!({"field":"cursor_blink"}),
                ));
            }
        },
        palette: nullable_palette(&request.fields, base.palette)?,
    };
    let value = terminal_defaults_snapshot(colors);
    let mutation = request.mutation().map_err(resource_operation_error)?;
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
        Some(_) => {
            Err(validation_error("terminal colors must be strings or null", json!({"field":name})))
        }
    }
}

fn nullable_cursor_style(
    fields: &serde_json::Map<String, Value>,
    inherited: Option<CursorShape>,
) -> Result<Option<CursorShape>, ResourceError> {
    let Some(value) = fields.get("cursor_style") else {
        return Ok(inherited);
    };
    match value {
        Value::Null => Ok(None),
        Value::String(style) if style == "block" => Ok(Some(CursorShape::Block)),
        Value::String(style) if style == "bar" => Ok(Some(CursorShape::Bar)),
        Value::String(style) if style == "underline" => Ok(Some(CursorShape::Underline)),
        _ => Err(validation_error(
            "cursor_style must be block, bar, underline or null",
            json!({"field":"cursor_style"}),
        )),
    }
}

fn nullable_palette(
    fields: &serde_json::Map<String, Value>,
    inherited: [Option<Rgb>; 256],
) -> Result<[Option<Rgb>; 256], ResourceError> {
    let entries = match fields.get("palette") {
        None => return Ok(inherited),
        Some(Value::Null) => return Ok([None; 256]),
        Some(Value::Object(entries)) => entries,
        Some(_) => {
            return Err(validation_error(
                "palette must be an object or null",
                json!({"field":"palette"}),
            ));
        }
    };
    let mut palette = [None; 256];
    for (index, value) in entries {
        let invalid_index = || {
            validation_error(
                "palette index must be a decimal value from 0 through 255",
                json!({"index":index}),
            )
        };
        let position = index.parse::<u8>().map_err(|_| invalid_index())?;
        let color = value.as_str().ok_or_else(|| {
            validation_error("palette colors must be strings", json!({"index":index}))
        })?;
        let Some(slot) = palette.get_mut(usize::from(position)) else {
            return Err(invalid_index());
        };
        *slot = Some(parse_hex_color(color)?);
    }
    Ok(palette)
}

fn parse_hex_color(value: &str) -> Result<Rgb, ResourceError> {
    let invalid = || validation_error("terminal colors must use #rrggbb", json!({"color":value}));
    // Six ASCII hex digits, so every two-byte range below is a char boundary.
    let hex = value
        .strip_prefix('#')
        .filter(|hex| hex.len() == 6 && hex.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(invalid)?;
    let parse = |range: std::ops::Range<usize>| {
        hex.get(range).and_then(|digits| u8::from_str_radix(digits, 16).ok()).ok_or_else(invalid)
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
            CursorShape::Bar => "bar",
            CursorShape::Underline => "underline",
            CursorShape::Block | CursorShape::BlockHollow => "block",
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
                origin: None,
                priority: None,
                credential: None,
            },
            selectors: crate::ResourceSelectors {
                machine: Some("current".to_string()),
                session: Some("current".to_string()),
                ..Default::default()
            },
            fields: fields.as_object().unwrap().clone(),
            actor: crate::Actor::local_user(),
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

    #[test]
    fn hex_colors_with_multibyte_or_signed_digits_are_validation_errors() {
        // Six bytes, but the first two-byte range ends inside 'é': slicing panicked.
        for color in ["#aééb", "#+f+f+f", "#12345", "#1234567", "123456"] {
            let error = parse_hex_color(color).unwrap_err();
            assert_eq!(error.code, "validation.invalid", "{color}");
        }
        let color = parse_hex_color("#0A1b2C").unwrap();
        assert_eq!((color.r, color.g, color.b), (0x0a, 0x1b, 0x2c));
    }

    #[test]
    fn terminal_defaults_reject_uncatalogued_shapes_without_panicking() {
        let mux = Mux::new_for_test("session-defaults-shapes", SurfaceOptions::default());
        for (key, fields) in [
            ("defaults-style", json!({"cursor_style":7})),
            ("defaults-style-name", json!({"cursor_style":"beam"})),
            ("defaults-blink", json!({"cursor_blink":"yes"})),
            ("defaults-color", json!({"foreground":1})),
            ("defaults-palette", json!({"palette":[]})),
            ("defaults-palette-index", json!({"palette":{"256":"#000000"}})),
            ("defaults-palette-value", json!({"palette":{"1":1}})),
            ("defaults-palette-color", json!({"palette":{"1":"#aééb"}})),
        ] {
            let error = dispatch(
                &mux,
                request(ResourceOperation::SessionTerminalDefaultsUpdate, key, fields.clone()),
            )
            .unwrap_err();
            assert_eq!(error.code, "validation.invalid", "{fields}");
        }
    }
}
