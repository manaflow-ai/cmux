//! The terminal view's exact raw protocol on a Native owner connection.
//! Existing handlers still validate identity fences, sizes, leases and snapshots.
use super::*;
use crate::SurfaceKind;
use crate::resource::TerminalPublicId;
use crate::sizing_policy::TerminalSizingMode;

fn pty(mux: &Mux, surface: SurfaceId) -> bool {
    mux.surface(surface).is_some_and(|surface| surface.kind() == SurfaceKind::Pty)
}

fn attached(mux: &Mux, client: u64, surface: SurfaceId) -> bool {
    pty(mux, surface)
        && mux.control_clients.state.lock().ok().is_some_and(|state| {
            state.clients.get(&client).is_some_and(|record| record.attached.contains_key(&surface))
        })
}

pub(super) fn allows(mux: &Mux, client: u64, command: &Command) -> bool {
    match command {
        Command::AttachSurface {
            surface, expected_generation, expected_terminal_id, mode, ..
        } => {
            if mode.as_deref().is_some_and(|mode| mode != "bytes") {
                return false;
            }
            // The ordinary attach handler rechecks the generation/terminal pair;
            // resolve here only to keep browser/render surfaces out of this carrier.
            let surface = surface.or_else(|| {
                if expected_generation.as_deref() != Some(mux.registry_identity().1.as_str()) {
                    return None;
                }
                let terminal = TerminalPublicId::parse(expected_terminal_id.as_deref()?).ok()?;
                mux.resource_surface_for_terminal(&terminal)
            });
            surface.is_some_and(|surface| pty(mux, surface))
        }
        Command::Send(params) => {
            params.terminal_id.is_none()
                && params.surface.is_some_and(|surface| attached(mux, client, surface))
        }
        Command::ResizeSurface { surface, .. } => attached(mux, client, *surface),
        Command::SetClientSizing { surface, client: None, enabled: true, exclusive: true } => {
            attached(mux, client, *surface)
        }
        Command::SetSizePolicy {
            surface: Some(surface),
            workspace: None,
            policy: Some(policy),
        } => {
            policy.mode == TerminalSizingMode::Latest
                && policy.priority.is_empty()
                && policy.fixed.is_none()
                && attached(mux, client, *surface)
        }
        Command::ResizeAttachedView {
            surface, lease: Some(_), view: None, identity: None, ..
        }
        | Command::ReleaseAttachedViewSize { surface, lease: Some(_), view: None }
        | Command::DetachAttachedView { surface, lease: Some(_), view: None }
        | Command::SetSizeCounts {
            surface,
            client: None,
            lease: Some(_),
            view: None,
            participant: None,
            ..
        } => {
            // Own current or retired leases only: existing handlers enforce the
            // client/terminal/lease binding and preserve idempotent detach.
            pty(mux, *surface)
        }
        Command::SnapshotRequest(params) => attached(mux, client, params.surface),
        _ => false,
    }
}

/// The GUI's takeover sends exactly {policy:{mode:"latest"}}. Check the
/// wire before deserialization, which intentionally ignores unknown policy
/// fields for other carriers, so extra client/participant controls cannot hide.
pub(super) fn latest_policy_frame(fields: &serde_json::Map<String, Value>) -> bool {
    fields.keys().all(|key| matches!(key.as_str(), "id" | "cmd" | "surface" | "policy"))
        && fields.get("policy").and_then(Value::as_object).is_some_and(|policy| {
            policy.len() == 1 && policy.get("mode").and_then(Value::as_str) == Some("latest")
        })
}
