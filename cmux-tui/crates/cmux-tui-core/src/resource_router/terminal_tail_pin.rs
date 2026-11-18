//! `terminal.tail_pin.set` (mutation, `terminal-tail-pin-set-v1`): pin or
//! unpin a terminal's tail, the typed form of `set-terminal-tail-pin`
//! (`terminal-tail-pin-v1`, `mux/terminal_tail_pins.rs`).
//!
//! The terminal is named by its `term_` id (`terminal`, what `cmux terminal
//! <term_id> pin-tail` sends) or by a pane (`pane`, the terminal in that
//! pane's selected tab, what a command palette row sends for the focused
//! pane): exactly one of the two. Both pin through the same `Mux` path as the
//! raw command. A pin is naturally idempotent (pinning again changes
//! nothing more), so a retried key does it again harmlessly, as `chat.pin`.

use std::sync::Arc;

use serde_json::{Value, json};

use super::{ParsedResourceRequest, ensure_session_route, mutation_result};
use crate::resource::{PanePublicId, ResourceError, TerminalPublicId};
use crate::{Mux, SurfaceKind};

/// Advertised in identify: the daemon answers `terminal.tail_pin.set`.
pub(crate) const CAPABILITY: &str = "terminal-tail-pin-set-v1";

const OPERATION: &str = "terminal.tail_pin.set";

pub(super) fn set(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    let fields = &request.fields;
    let pinned = fields.get("pinned").and_then(Value::as_bool).ok_or_else(|| {
        ResourceError::validation_invalid(Some("pinned"), "pinned must be true or false")
    })?;
    let terminal = match (
        fields.get("terminal").and_then(Value::as_str),
        fields.get("pane").and_then(Value::as_str),
    ) {
        (Some(terminal), None) => {
            // The catalog checked the form; parse keeps the id typed.
            let terminal = TerminalPublicId::parse(terminal)?;
            mux.set_terminal_tail_pin_of(terminal.as_str(), pinned)
                .map_err(|error| pin_error(error, "terminal", terminal.as_str()))?
        }
        (None, Some(pane)) => {
            let pane = PanePublicId::parse(pane)?;
            let selected = mux
                .with_state(|state| {
                    state.pane_by_public_id(&pane).map(|pane| {
                        pane.active_surface().and_then(|surface| {
                            state.surfaces.get(&surface).map(|tab| (surface, tab.kind()))
                        })
                    })
                })
                .ok_or_else(|| ResourceError::not_found("pane", pane.as_str()))?;
            let surface = match selected {
                Some((surface, SurfaceKind::Pty)) => surface,
                _ => {
                    return Err(ResourceError::operation_failed(
                        OPERATION,
                        "not_a_terminal",
                        json!({"message": format!(
                            "the selected tab of pane {} is not a terminal",
                            pane.as_str()
                        )}),
                    ));
                }
            };
            mux.set_terminal_tail_pin(surface, pinned)
                .map_err(|error| pin_error(error, "pane", pane.as_str()))?
                .into_string()
        }
        _ => {
            return Err(ResourceError::validation_invalid(
                None,
                "terminal.tail_pin.set takes exactly one of terminal or pane",
            ));
        }
    };
    let revision = crate::resource_api::public_session_revision(mux)?;
    mutation_result(mux, json!({"terminal": terminal, "pinned": pinned}), revision, false)
}

/// The resource error of a refused pin. `Mux::set_terminal_tail_pin` and
/// `set_terminal_tail_pin_of` name their refusal first (`not_a_terminal`,
/// `terminal_private: ...`, `terminal_not_found`), as the raw command answers it.
fn pin_error(error: anyhow::Error, scope: &str, selector: &str) -> ResourceError {
    let message = error.to_string();
    let reason = message.split(':').next().unwrap_or_default().trim();
    match reason {
        "terminal_not_found" | "surface_not_found" => ResourceError::not_found(scope, selector),
        "not_a_terminal" | "terminal_not_hosted" | "terminal_private" => {
            ResourceError::operation_failed(OPERATION, reason, json!({"message": message}))
        }
        _ => super::resource_operation_error(error),
    }
}
