//! Resource effect field parsing and operation classification: required and optional fields, terminal options, effect targets, and which operations are effectful or create paths.

use super::*;

pub(super) fn resource_effect_indeterminate(
    idempotency_key: &str,
    operation: &str,
) -> ResourceError {
    ResourceError::new(
        "mutation.indeterminate",
        "the external effect may have run before its outcome was recorded",
        json!({
            "idempotency_key":idempotency_key,
            "operation":operation,
            "recovery":"inspect_state_then_retry_with_new_key",
        }),
        false,
    )
}

pub(super) fn is_resource_close_operation(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::WorkspaceClose
            | ResourceOperation::ScreenClose
            | ResourceOperation::PaneClose
            | ResourceOperation::TabClose
    )
}

pub(super) fn topology_effect_may_create_workspace(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::WorkspaceCreate
            | ResourceOperation::ScreenCreate
            | ResourceOperation::PaneCreate
            | ResourceOperation::TabCreateTerminal
            | ResourceOperation::TabCreateBrowser
    )
}

pub(super) fn effect_target(
    operation: ResourceOperation,
    selectors: &ResourceSelectors,
) -> ResourceTarget {
    match operation {
        ResourceOperation::WorkspaceCreate => ResourceTarget::Session,
        ResourceOperation::WorkspaceClose
        | ResourceOperation::WorkspaceRun
        | ResourceOperation::WorkspaceLayoutApply => ResourceTarget::Workspace,
        ResourceOperation::ScreenClose | ResourceOperation::ScreenLayoutUndo => {
            ResourceTarget::Screen
        }
        ResourceOperation::PaneSplit
        | ResourceOperation::PaneClose
        | ResourceOperation::PaneRun => ResourceTarget::Pane,
        ResourceOperation::TabClose => ResourceTarget::Tab,
        ResourceOperation::ScreenCreate => {
            if selectors.workspace.is_some() {
                ResourceTarget::Workspace
            } else {
                ResourceTarget::Session
            }
        }
        ResourceOperation::PaneCreate => {
            // The public operation creates a pane within a selected screen.
            // Ordinary mux callers additionally carry the exact existing pane
            // whose auto-layout column should receive the new pane.
            if selectors.pane.is_some() {
                ResourceTarget::Pane
            } else if selectors.screen.is_some() {
                ResourceTarget::Screen
            } else if selectors.workspace.is_some() {
                ResourceTarget::Workspace
            } else {
                ResourceTarget::Session
            }
        }
        ResourceOperation::TabCreateTerminal | ResourceOperation::TabCreateBrowser => {
            if selectors.pane.is_some() {
                ResourceTarget::Pane
            } else if selectors.screen.is_some() {
                ResourceTarget::Screen
            } else if selectors.workspace.is_some() {
                ResourceTarget::Workspace
            } else {
                ResourceTarget::Session
            }
        }
        _ => ResourceTarget::Session,
    }
}

/// A caller-chosen terminal id is a lowercase UUIDv4 in 32 hex digits, the
/// same shape as a daemon-generated one.
pub(super) fn validate_requested_terminal_id(value: &str) -> anyhow::Result<()> {
    let bytes = value.as_bytes();
    anyhow::ensure!(
        bytes.len() == 32
            && bytes.iter().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
            && bytes[12] == b'4'
            && matches!(bytes[16], b'8'..=b'b'),
        "bad request: terminal_id must be a 32-character lowercase UUIDv4 hex value"
    );
    Ok(())
}

pub(super) fn validate_effect_fields(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
) -> anyhow::Result<()> {
    match operation {
        ResourceOperation::WorkspaceCreate => {
            anyhow::ensure!(
                required_str(fields, "initial_content")? == "terminal",
                "effectful workspace creation requires terminal initial content"
            );
            if fields.contains_key("argv") || fields.contains_key("shell") {
                let _ = effect_command(fields)?;
            }
        }
        ResourceOperation::WorkspaceRun | ResourceOperation::PaneRun => {
            let _ = effect_command(fields)?;
            let _ = effect_cell_size(fields)?;
        }
        ResourceOperation::WorkspaceLayoutApply => {
            anyhow::ensure!(fields["layout"].is_object(), "layout must be an object");
        }
        ResourceOperation::PaneCreate
        | ResourceOperation::TabCreateTerminal
        | ResourceOperation::ScreenCreate => {
            let _ = effect_cell_size(fields)?;
            let _ = optional_effect_command(fields)?;
        }
        ResourceOperation::PaneSplit => {
            let direction = required_str(fields, "direction")?;
            anyhow::ensure!(
                matches!(direction, "left" | "right" | "up" | "down"),
                "invalid pane split direction"
            );
            if let Some(ratio) = fields.get("ratio").and_then(Value::as_f64) {
                anyhow::ensure!(
                    ratio.is_finite() && 0.0 < ratio && ratio < 1.0,
                    "invalid pane split ratio"
                );
                let ratio = ratio as f32;
                anyhow::ensure!(
                    ratio.is_finite() && 0.0 < ratio && ratio < 1.0,
                    "pane split ratio cannot be represented"
                );
            }
            if let Some(width) = fields.get("viewport_width").and_then(Value::as_f64) {
                anyhow::ensure!(
                    direction == "right"
                        && width.is_finite()
                        && (f64::from(MIN_VIEWPORT_PANE_WIDTH)
                            ..=f64::from(MAX_VIEWPORT_PANE_WIDTH))
                            .contains(&width),
                    "invalid viewport pane width"
                );
            }
            rows::validate_row_height_field(fields, direction)?;
            pane_browser::validate_pane_browser_fields(fields)?;
            let _ = effect_cell_size(fields)?;
            let _ = optional_effect_command(fields)?;
        }
        ResourceOperation::TabCreateBrowser => {
            anyhow::ensure!(!required_str(fields, "url")?.is_empty(), "browser URL is empty");
            let dimensions = (
                fields.get("width_px").and_then(Value::as_u64),
                fields.get("height_px").and_then(Value::as_u64),
            );
            anyhow::ensure!(
                matches!(dimensions, (None, None) | (Some(_), Some(_))),
                "browser pixel dimensions must be paired"
            );
        }
        _ => {}
    }
    Ok(())
}

pub(super) fn optional_owned_string(
    fields: &Map<String, Value>,
    name: &str,
) -> anyhow::Result<Option<String>> {
    fields
        .get(name)
        .map(|value| {
            value
                .as_str()
                .map(str::to_string)
                .with_context(|| format!("field {name:?} must be a string"))
        })
        .transpose()
}

pub(super) fn effect_on_exit(
    fields: &Map<String, Value>,
) -> anyhow::Result<Option<TerminalOnExit>> {
    fields
        .get("on_exit")
        .map(|value| {
            let value = value.as_str().context("field \"on_exit\" must be a string")?;
            TerminalOnExit::parse(value)
        })
        .transpose()
}

/// `argv` or `shell` when the creation names one, else none (the default
/// shell). Placement verbs store `argv` for `shell_args`.
pub(super) fn optional_effect_command(
    fields: &Map<String, Value>,
) -> anyhow::Result<Option<Vec<String>>> {
    if fields.contains_key("argv") || fields.contains_key("shell") {
        effect_command(fields).map(Some)
    } else {
        Ok(None)
    }
}

pub(super) fn effect_command(fields: &Map<String, Value>) -> anyhow::Result<Vec<String>> {
    match (fields.get("argv"), fields.get("shell")) {
        (Some(Value::Array(argv)), None) => {
            let argv = argv
                .iter()
                .map(|argument| {
                    argument.as_str().map(str::to_string).context("argv entries must be strings")
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            anyhow::ensure!(
                argv.first().is_some_and(|program| !program.is_empty()),
                "argv must contain a non-empty executable"
            );
            Ok(argv)
        }
        (None, Some(Value::String(shell))) if !shell.is_empty() => {
            Ok(vec![crate::platform::default_shell(), "-lc".to_string(), shell.clone()])
        }
        _ => anyhow::bail!("exactly one of argv or shell must be present"),
    }
}

pub(super) fn effect_cell_size(fields: &Map<String, Value>) -> anyhow::Result<Option<(u16, u16)>> {
    match (fields.get("cols").and_then(Value::as_u64), fields.get("rows").and_then(Value::as_u64)) {
        (None, None) => Ok(None),
        (Some(cols), Some(rows)) => Ok(Some((
            u16::try_from(cols).context("cols exceed uint16")?,
            u16::try_from(rows).context("rows exceed uint16")?,
        ))),
        _ => anyhow::bail!("cols and rows must be paired"),
    }
}

pub(super) fn parse_direction(value: &str) -> anyhow::Result<Direction> {
    Ok(match value {
        "left" => Direction::Left,
        "right" => Direction::Right,
        "up" => Direction::Up,
        "down" => Direction::Down,
        _ => anyhow::bail!("invalid pane direction {value:?}"),
    })
}

pub(super) fn operation_name(operation: ResourceOperation) -> String {
    operation.wire_name().to_owned()
}

pub(super) fn required_str<'a>(
    fields: &'a Map<String, Value>,
    name: &str,
) -> anyhow::Result<&'a str> {
    fields[name].as_str().with_context(|| format!("field {name:?} is missing"))
}

pub(super) fn required_u64(fields: &Map<String, Value>, name: &str) -> anyhow::Result<u64> {
    fields[name].as_u64().with_context(|| format!("field {name:?} is missing"))
}

pub(super) fn required_f64(fields: &Map<String, Value>, name: &str) -> anyhow::Result<f64> {
    fields[name].as_f64().with_context(|| format!("field {name:?} is missing"))
}

pub(super) fn layout_resize_coalesce(
    fields: &Map<String, Value>,
) -> anyhow::Result<Option<LayoutMutationKey>> {
    let Some(kind) = fields.get("resize_owner_kind") else {
        anyhow::ensure!(
            !fields.contains_key("resize_owner") && !fields.contains_key("resize_transaction"),
            "resize transaction fields must be supplied together"
        );
        return Ok(None);
    };
    let owner = required_u64(fields, "resize_owner")?;
    let transaction = required_u64(fields, "resize_transaction")?;
    let owner = match kind.as_str().context("resize_owner_kind must be a string")? {
        "control-client" => LayoutResizeOwner::ControlClient(owner),
        "in-process" => LayoutResizeOwner::InProcess(owner),
        value => anyhow::bail!("invalid resize owner kind {value:?}"),
    };
    Ok(Some(LayoutMutationKey::Resize { owner, transaction }))
}

pub(super) fn nullable_name(fields: &Map<String, Value>) -> anyhow::Result<Option<String>> {
    match fields.get("name") {
        Some(Value::Null) => Ok(None),
        Some(Value::String(name)) => Ok(Some(name.clone())),
        _ => anyhow::bail!("field \"name\" must be a string or null"),
    }
}

pub(super) fn is_effectful(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::WorkspaceCreate
            | ResourceOperation::WorkspaceClose
            | ResourceOperation::WorkspaceRun
            | ResourceOperation::WorkspaceLayoutApply
            | ResourceOperation::ScreenCreate
            | ResourceOperation::ScreenClose
            | ResourceOperation::ScreenLayoutUndo
            | ResourceOperation::PaneCreate
            | ResourceOperation::PaneSplit
            | ResourceOperation::PaneClose
            | ResourceOperation::PaneRun
            | ResourceOperation::TabCreateTerminal
            | ResourceOperation::TabCreateBrowser
            | ResourceOperation::TabClose
    )
}

pub(super) fn is_created_path_operation(operation: ResourceOperation) -> bool {
    created_identity_kind(operation).is_some()
}

pub(super) fn created_identity_kind(operation: ResourceOperation) -> Option<CreatedIdentityKind> {
    match operation {
        ResourceOperation::WorkspaceCreate
        | ResourceOperation::WorkspaceRun
        | ResourceOperation::ScreenCreate
        | ResourceOperation::PaneCreate
        | ResourceOperation::PaneSplit
        | ResourceOperation::PaneRun
        | ResourceOperation::TabCreateTerminal => Some(CreatedIdentityKind::Terminal),
        ResourceOperation::TabCreateBrowser => Some(CreatedIdentityKind::Browser),
        _ => None,
    }
}

pub(super) fn semantic_creation_fields(fields: &Map<String, Value>) -> Map<String, Value> {
    let mut fields = fields.clone();
    fields.remove("expected_revision");
    fields.remove("correlation_key");
    fields.remove("idempotency_key");
    fields
}
