//! REQUEST frames whose body is a binary layout (p05-ipc-183;
//! spec/transports.md, "Binary payload layouts").
//!
//! A REQUEST with the BINARY flag carries its method's request layout
//! (`cmux_ipc::hot`) instead of its JSON line. Its body decodes straight into
//! the method's `Command`, member for member what the JSON gives, so the
//! request runs the handler its line runs and no JSON is parsed on its way
//! there. This is a Mojo stub's dispatch: the validated message is
//! deserialized into the method's native parameters, never into an
//! intermediate document (chromium mojo/public/cpp/bindings/lib/
//! serialization.h, `Deserialize`).
//!
//! The reply is the same JSON its line gets, on a REPLY or ERROR frame
//! without the BINARY flag: the flag of each frame selects its decoder, and
//! JSON is always allowed.

use cmux_ipc::hot::{
    HotDecodeError, RESIZE_ATTACHED_VIEW_REQUEST, ResizeAttachedViewRequest,
    SCROLL_SURFACE_REQUEST, SET_CLIENT_SIZING_REQUEST, SNAPSHOT_REQUEST_REQUEST,
    ScrollSurfaceRequest, SetClientSizingRequest, SizingIdentity, SnapshotRequestRequest,
};
use cmux_ipc::{MethodAttrs, Payload};

use super::terminal_io_wire::{ScrollSurfaceParams, SnapshotRequestParams};
use super::terminal_snapshot::SnapshotHave;
use super::{ClientIdentityWire, Command, Request};

/// Whether this daemon reads `method`'s binary request layout: every
/// `Command` with `payload: "binary"` (hot_requests_tests checks the schema
/// has no other).
pub(super) fn decodes(method: &MethodAttrs) -> bool {
    matches!(method.payload, Payload::Binary { .. }) && decoder(method.name).is_some()
}

/// The request `payload` carries for `method`: `None` when the daemon reads
/// no layout for it ([`decodes`] is false).
pub(super) fn decode(
    method: &MethodAttrs,
    payload: &[u8],
) -> Option<Result<Request, HotDecodeError>> {
    let decode = decoder(method.name)?;
    Some(decode(payload).map(|cmd| Request { id: None, cmd }))
}

type Decoder = fn(&[u8]) -> Result<Command, HotDecodeError>;

fn decoder(name: &str) -> Option<Decoder> {
    Some(match name {
        "resize-attached-view" => resize_attached_view,
        "set-client-sizing" => set_client_sizing,
        "scroll-surface" => scroll_surface,
        "snapshot-request" => snapshot_request,
        _ => return None,
    })
}

fn resize_attached_view(payload: &[u8]) -> Result<Command, HotDecodeError> {
    let ResizeAttachedViewRequest { cols, identity, lease, rows, stream, surface, view } =
        RESIZE_ATTACHED_VIEW_REQUEST.decode(payload)?;
    Ok(Command::ResizeAttachedView {
        surface,
        lease,
        view,
        identity: identity.map(client_identity),
        cols,
        rows,
        stream,
    })
}

fn client_identity(identity: SizingIdentity) -> ClientIdentityWire {
    let SizingIdentity { device_id, device_kind, device_name, display_name, user_id } = identity;
    ClientIdentityWire { user_id, display_name, device_kind, device_name, device_id }
}

fn set_client_sizing(payload: &[u8]) -> Result<Command, HotDecodeError> {
    let SetClientSizingRequest { client, enabled, exclusive, surface } =
        SET_CLIENT_SIZING_REQUEST.decode(payload)?;
    // An absent `exclusive` is its schema default, as `#[serde(default)]`.
    Ok(Command::SetClientSizing { surface, client, enabled, exclusive: exclusive.unwrap_or(false) })
}

fn scroll_surface(payload: &[u8]) -> Result<Command, HotDecodeError> {
    let ScrollSurfaceRequest { delta, surface } = SCROLL_SURFACE_REQUEST.decode(payload)?;
    Ok(Command::ScrollSurface(ScrollSurfaceParams { delta, surface }))
}

fn snapshot_request(payload: &[u8]) -> Result<Command, HotDecodeError> {
    let SnapshotRequestRequest { have, reason, request_id, stream, surface } =
        SNAPSHOT_REQUEST_REQUEST.decode(payload)?;
    let have =
        have.map(|have| SnapshotHave::new(have.generation, have.offset, have.snapshot_version));
    Ok(Command::SnapshotRequest(SnapshotRequestParams {
        have,
        reason,
        request_id,
        stream,
        surface,
    }))
}

#[cfg(all(test, unix))]
#[path = "hot_requests_tests.rs"]
mod tests;
