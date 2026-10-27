//! Resource-protocol surface attach streams: installing a resource stream's
//! outbound queue, preparing the terminal attach (snapshot, patches, scroll),
//! the browser attach (state and frames) and the sidebar render attach, their
//! cleanup, and the resource response envelope writer. The streams run as
//! drains on the sequenced pool (resource_attach_out.rs).

use super::MarkedClientAttach;
use super::MessageWriter;
use super::OutboundStream;
use super::RESOURCE_STREAMS_PER_CLIENT_CAPACITY;
use super::RESOURCE_STREAMS_SERVER_CAPACITY;
use super::RESOURCE_WAITS_PER_CLIENT_CAPACITY;
use super::RESOURCE_WAITS_SERVER_CAPACITY;
use super::RenderClientState;
use super::RenderService;
use super::ResourceStreamInstallError;
use super::ResourceWaitInstallError;
use super::ResourceWorkerPermit;
use super::browser_cells_for_pixels;
use super::browser_pixels_for_cells;
use super::mark_resource_client_attached;
use super::render_state_message;
use super::resource_browser_surface;
use super::resource_stream_end;
use super::resource_terminal_surface;
use super::rollback_failed_attach;
use super::wait_for_initial_browser_resize;
use crate::BrowserAttachState;
use crate::BrowserFrameStream;
use crate::Mux;
use crate::RenderAttachStream;
use crate::SurfaceId;
use crate::SurfaceKind;
use crate::SurfaceRenderFrame;
use crate::resource::BrowserPublicId;
use crate::resource::RequestId as ResourceRequestId;
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::ResponseEnvelope as ResourceResponseEnvelope;
use crate::resource::StreamPublicId;
use crate::resource::TerminalPublicId;
use crate::resource::WireDecimal;
use crate::sidebar_resource::SidebarRenderAttachment;
use crate::sidebar_resource::attach_sidebar_render;
use crate::sidebar_resource::resolve_sidebar_view;
use crate::sidebar_resource::sidebar_snapshot;
use crate::surface::AttachLifecycle;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

#[path = "resource_attach_out.rs"]
mod attach_out;
pub(super) use attach_out::{
    start_browser_resource_attach, start_sidebar_resource_attach, start_terminal_resource_attach,
};

pub(super) struct ResourceSurfaceAttachStart {
    pub(super) stream_id: StreamPublicId,
    pub(super) outbound: OutboundStream,
    pub(super) canceled: Arc<AtomicBool>,
    pub(super) _worker_permit: ResourceWorkerPermit,
    pub(super) surface: SurfaceId,
    pub(super) lifecycle: AttachLifecycle,
    pub(super) size_rollback: Option<crate::mux::ClientSizeRollback>,
    pub(super) client_changed: Option<(Option<String>, Option<String>)>,
}

pub(super) struct TerminalResourceAttachStart {
    pub(super) common: ResourceSurfaceAttachStart,
    pub(super) terminal_id: TerminalPublicId,
    pub(super) attach: RenderAttachStream,
}

pub(super) struct BrowserResourceAttachStart {
    pub(super) common: ResourceSurfaceAttachStart,
    pub(super) initial: BrowserAttachState,
    pub(super) frames: BrowserFrameStream,
    pub(super) snapshot: Value,
}

pub(super) struct SidebarResourceAttachStart {
    pub(super) stream_id: StreamPublicId,
    pub(super) outbound: OutboundStream,
    pub(super) canceled: Arc<AtomicBool>,
    pub(super) _worker_permit: ResourceWorkerPermit,
    pub(super) attachment: SidebarRenderAttachment,
}

pub(super) fn resource_stream_id(
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<StreamPublicId, ResourceError> {
    let field = request.fields.get("stream_id").cloned().unwrap_or(Value::Null);
    let selector = field.as_str().unwrap_or("").to_owned();
    serde_json::from_value(field).map_err(|_| {
        ResourceError::selector_invalid("stream", &selector, "expected an opaque stream id")
    })
}

fn resource_transport_error(reason: impl Into<String>) -> ResourceError {
    ResourceError::transport_closed(reason)
}

fn resource_stream_install_error(
    operation: &'static str,
    stream_id: &StreamPublicId,
    error: ResourceStreamInstallError,
) -> ResourceError {
    let (reason, reason_code, scope, limit) = match error {
        ResourceStreamInstallError::UnknownClient => {
            ("control connection is no longer registered", "connection_closed", "client", 0)
        }
        ResourceStreamInstallError::Duplicate => (
            "resource stream id is already open on this connection",
            "stream_id_in_use",
            "client",
            RESOURCE_STREAMS_PER_CLIENT_CAPACITY,
        ),
        ResourceStreamInstallError::ClientCapacity => (
            "resource stream capacity exceeded for this connection",
            "resource_stream_capacity",
            "client",
            RESOURCE_STREAMS_PER_CLIENT_CAPACITY,
        ),
        ResourceStreamInstallError::ServerCapacity => (
            "resource stream capacity exceeded for this server",
            "resource_stream_capacity",
            "server",
            RESOURCE_STREAMS_SERVER_CAPACITY,
        ),
    };
    ResourceError::operation_failed(
        operation,
        reason,
        json!({
            "reason_code":reason_code,
            "scope":scope,
            "limit":limit,
            "stream_id":stream_id,
        }),
    )
}

pub(super) fn resource_wait_install_error(
    operation: &'static str,
    error: ResourceWaitInstallError,
) -> ResourceError {
    let (reason, reason_code, scope, limit) = match error {
        ResourceWaitInstallError::UnknownClient => {
            ("control connection is no longer registered", "connection_closed", "client", 0)
        }
        ResourceWaitInstallError::Duplicate => (
            "request id already owns a detached terminal wait on this connection",
            "request_id_in_use",
            "client",
            1,
        ),
        ResourceWaitInstallError::ClientCapacity => (
            "terminal wait capacity exceeded for this connection",
            "terminal_wait_capacity",
            "client",
            RESOURCE_WAITS_PER_CLIENT_CAPACITY,
        ),
        ResourceWaitInstallError::ServerCapacity => (
            "terminal wait capacity exceeded for this server",
            "terminal_wait_capacity",
            "server",
            RESOURCE_WAITS_SERVER_CAPACITY,
        ),
    };
    ResourceError::operation_failed(
        operation,
        reason,
        json!({"reason_code":reason_code,"scope":scope,"limit":limit}),
    )
}

pub(super) fn register_resource_outbound(
    mux: &Mux,
    client: u64,
    stream_id: &StreamPublicId,
    outbound: &OutboundStream,
    operation: &'static str,
) -> Result<(Arc<AtomicBool>, ResourceWorkerPermit), ResourceError> {
    match mux.control_clients.install_resource_stream(client, stream_id, outbound.clone()) {
        Ok(installed) => Ok(installed),
        Err(error) => {
            outbound.close();
            Err(resource_stream_install_error(operation, stream_id, error))
        }
    }
}

fn install_resource_outbound(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    stream_id: &StreamPublicId,
    operation: &'static str,
) -> Result<(OutboundStream, Arc<AtomicBool>, ResourceWorkerPermit), ResourceError> {
    let overflow =
        resource_stream_end(stream_id, "gap", None, Some("open a fresh attachment stream"), None);
    let outbound = writer
        .start_stream(&overflow)
        .map_err(|error| resource_transport_error(error.to_string()))?;
    let (canceled, worker_permit) =
        register_resource_outbound(mux, client, stream_id, &outbound, operation)?;
    Ok((outbound, canceled, worker_permit))
}

fn prepare_resource_surface_attach(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    operation: &'static str,
    stream_id: StreamPublicId,
    surface: SurfaceId,
    initial_size: Option<(u16, u16)>,
) -> Result<(ResourceSurfaceAttachStart, MarkedClientAttach), ResourceError> {
    let (outbound, canceled, worker_permit) =
        install_resource_outbound(mux, client, writer, &stream_id, operation)?;
    let lifecycle = AttachLifecycle::default();
    let marked =
        match mark_resource_client_attached(mux, client, surface, outbound.clone(), initial_size) {
            Ok(marked) => marked,
            Err(error) => {
                cleanup_resource_stream(mux, client, &stream_id);
                return Err(ResourceError::operation_failed(
                    operation,
                    error.to_string(),
                    json!({}),
                ));
            }
        };
    Ok((
        ResourceSurfaceAttachStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            surface,
            lifecycle,
            size_rollback: marked.size_rollback,
            client_changed: marked.client_changed.clone(),
        },
        marked,
    ))
}

pub(super) fn cleanup_resource_stream(mux: &Mux, client: u64, stream_id: &StreamPublicId) {
    let _ = mux.control_clients.take_resource_stream(client, stream_id);
}

pub(super) fn cleanup_resource_attach(mux: &Mux, client: u64, start: &ResourceSurfaceAttachStart) {
    start.lifecycle.cancel();
    cleanup_resource_stream(mux, client, &start.stream_id);
    rollback_failed_attach(mux, client, start.surface, start.outbound.id, start.size_rollback);
}

pub(super) fn prepare_terminal_resource_attach(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, TerminalResourceAttachStart), ResourceError> {
    let operation = "terminal.attach";
    let (terminal_id, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let stream_id = resource_stream_id(request)?;
    let initial_size = super::wire_values::paired_attach_size::<u16>(request, "cols", "rows")?;
    // A read-only attach watches: its size never reaches terminal sizing.
    let read_only = request.fields.get("read_only").and_then(Value::as_bool).unwrap_or(false);
    let initial_size = if read_only { None } else { initial_size };
    let (common, marked) = prepare_resource_surface_attach(
        mux,
        client,
        writer,
        operation,
        stream_id.clone(),
        surface.id,
        initial_size,
    )?;
    if read_only {
        let marked_read_only = match marked.lease.as_deref() {
            Some(lease) => mux
                .control_clients
                .mark_view_lease_read_only(client, surface.id, lease)
                .map_err(|error| error.to_string()),
            None => Err("resource attach minted no lease".to_owned()),
        };
        if let Err(error) = marked_read_only {
            cleanup_resource_attach(mux, client, &common);
            return Err(ResourceError::operation_failed(operation, error, json!({})));
        }
    }
    let attach = match surface.attach_render_stream() {
        Ok(attach) => attach,
        Err(error) => {
            cleanup_resource_attach(mux, client, &common);
            return Err(ResourceError::operation_failed(operation, error.to_string(), json!({})));
        }
    };
    let lease = match super::wire_values::minted_lease(operation, marked.lease) {
        Ok(lease) => lease,
        Err(error) => {
            cleanup_resource_attach(mux, client, &common);
            return Err(error);
        }
    };
    Ok((
        json!({
            "stream_id":stream_id,
            "attachment_lease":lease,
        }),
        TerminalResourceAttachStart { common, terminal_id, attach },
    ))
}

fn terminal_resource_snapshot(
    render_service: &RenderService,
    terminal_id: &TerminalPublicId,
    frame: &SurfaceRenderFrame,
) -> Value {
    let mut render =
        serde_json::to_value(render_state_message(render_service, 0, frame)).unwrap_or_default();
    if let Some(fields) = render.as_object_mut() {
        fields.remove("event");
        fields.remove("surface");
    }
    json!({
        "kind":"snapshot",
        "terminal_id":terminal_id,
        "render":render,
    })
}

fn terminal_resource_patch(
    terminal_id: &TerminalPublicId,
    state: &mut RenderClientState,
    frame: &SurfaceRenderFrame,
) -> Value {
    let mut render = serde_json::to_value(state.delta_message(0, frame)).unwrap_or_default();
    if let Some(fields) = render.as_object_mut() {
        fields.remove("event");
        fields.remove("surface");
        let full_reset = fields.remove("full").unwrap_or(Value::Bool(true));
        fields.insert("full_reset".to_string(), full_reset);
    }
    json!({
        "kind":"patch",
        "terminal_id":terminal_id,
        "render":render,
    })
}

fn terminal_resource_scroll(terminal_id: &TerminalPublicId, offset: u64, at_bottom: bool) -> Value {
    json!({
        "kind":"scroll",
        "terminal_id":terminal_id,
        "scroll":{
            "offset":offset.to_string(),
            "at_bottom":at_bottom,
        },
    })
}

fn browser_snapshot_for_id(
    mux: &Mux,
    browser_id: &BrowserPublicId,
) -> Result<Value, ResourceError> {
    crate::resource_api::public_session_snapshot(mux)?
        .get("browsers")
        .and_then(Value::as_array)
        .and_then(|browsers| {
            browsers.iter().find(|browser| {
                browser.get("id").and_then(Value::as_str) == Some(browser_id.as_str())
            })
        })
        .cloned()
        .ok_or_else(|| ResourceError::not_found("browser", browser_id.as_str()))
}

pub(super) fn prepare_browser_resource_attach(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, BrowserResourceAttachStart), ResourceError> {
    let operation = "browser.attach";
    let (browser_id, surface) = resource_browser_surface(mux, &request.selectors)?;
    let stream_id = resource_stream_id(request)?;
    let initial_size =
        super::wire_values::paired_attach_size::<u32>(request, "width_px", "height_px")?
            .map(|(width, height)| browser_cells_for_pixels(mux, width, height));
    let (common, marked) = prepare_resource_surface_attach(
        mux,
        client,
        writer,
        operation,
        stream_id.clone(),
        surface.id,
        initial_size,
    )?;
    if let Some(reservation) = marked.resize_reservation
        && let Err(error) = match marked.resize_completion.as_ref() {
            Some(completion) => {
                wait_for_initial_browser_resize(completion, surface.id, reservation)
            }
            None => Err(anyhow::anyhow!("sized browser attach has no completion receiver")),
        }
    {
        cleanup_resource_attach(mux, client, &common);
        return Err(ResourceError::operation_failed(operation, error.to_string(), json!({})));
    }
    let (initial, frames) = surface.attach_frames().map_err(|error| {
        cleanup_resource_attach(mux, client, &common);
        ResourceError::operation_failed(operation, error.to_string(), json!({}))
    })?;
    let browser = match browser_snapshot_for_id(mux, &browser_id) {
        Ok(browser) => browser,
        Err(error) => {
            cleanup_resource_attach(mux, client, &common);
            return Err(error);
        }
    };
    let lease = match super::wire_values::minted_lease(operation, marked.lease) {
        Ok(lease) => lease,
        Err(error) => {
            cleanup_resource_attach(mux, client, &common);
            return Err(error);
        }
    };
    let (width_px, height_px) = browser_pixels_for_cells(mux, initial.cols, initial.rows);
    let snapshot = json!({
        "kind":"snapshot",
        "browser":browser,
        "size":{"width_px":width_px,"height_px":height_px},
    });
    Ok((
        json!({
            "stream_id":stream_id,
            "attachment_lease":lease,
        }),
        BrowserResourceAttachStart { common, initial, frames, snapshot },
    ))
}

fn browser_resource_state(state: &BrowserAttachState) -> Value {
    json!({
        "kind":"state",
        "url":state.url,
        "title":state.title,
        "loading":matches!(state.status, crate::BrowserStatus::Starting),
    })
}

pub(super) fn browser_resource_frame(
    frame: &crate::BrowserFrame,
    pointer_frame_seq: Option<u64>,
) -> Value {
    json!({
        "kind":"frame",
        "mime_type":"image/png",
        "data_base64":frame.data_b64,
        "width_px":frame.image_width.max(1),
        "height_px":frame.image_height.max(1),
        "pointer_frame_seq":pointer_frame_seq.map(WireDecimal::new),
    })
}

pub(super) fn prepare_sidebar_resource_attach(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, SidebarResourceAttachStart), ResourceError> {
    let (sidebar_id, session_id) = resolve_sidebar_view(mux, &request.selectors)?;
    let (status, last_size, configured) = mux.sidebar_plugin_resource_status();
    if !configured {
        return Err(ResourceError::not_found("sidebar_view", sidebar_id.as_str()));
    }
    let surface = status
        .surface
        .and_then(|surface| mux.surface(surface))
        .filter(|surface| surface.kind() == SurfaceKind::Pty && !surface.is_dead())
        .ok_or_else(|| ResourceError::not_found("sidebar_view", sidebar_id.as_str()))?;
    let sidebar = sidebar_snapshot(
        &sidebar_id,
        &session_id,
        last_size.unwrap_or_else(|| surface.size()),
        Some(&surface),
    );
    let attachment = attach_sidebar_render(sidebar_id, sidebar, &surface)?;
    let stream_id = resource_stream_id(request)?;
    let (outbound, canceled, worker_permit) =
        install_resource_outbound(mux, client, writer, &stream_id, "sidebar_view.attach")?;
    Ok((
        json!({"stream_id":stream_id}),
        SidebarResourceAttachStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            attachment,
        },
    ))
}

/// cx-8mla8: an `operation.failed` with reason `internal` gets a Request ID
/// in `details.extra.request_id` (the catalog's forward-compatible map, no
/// protocol change), and the daemon's log names that id with the operation
/// and the cause, so a person can quote the id and the log shows why.
fn with_internal_request_id(
    operation: ResourceOperation,
    mut error: ResourceError,
) -> ResourceError {
    if error.code != "operation.failed"
        || error.details.get("reason").and_then(Value::as_str) != Some("internal")
    {
        return error;
    }
    let mut bytes = [0_u8; 8];
    if getrandom::fill(&mut bytes).is_err() {
        return error;
    }
    let id: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let id = format!("req_{id}");
    let cause = error
        .details
        .pointer("/extra/message")
        .and_then(Value::as_str)
        .unwrap_or("no cause given")
        .to_owned();
    eprintln!("cmux-tui: internal failure in {} (Request ID {id}): {cause}", operation.wire_name());
    if let Some(details) = error.details.as_object_mut() {
        let extra = details.entry("extra").or_insert_with(|| Value::Object(Default::default()));
        if let Some(extra) = extra.as_object_mut() {
            extra.insert("request_id".into(), Value::String(id));
        }
    }
    error
}

pub(super) fn send_resource_response(
    writer: &MessageWriter,
    id: ResourceRequestId,
    operation: ResourceOperation,
    result: Result<Value, ResourceError>,
) -> bool {
    let result = crate::resource_router::validate_operation_outcome(operation, result)
        .map_err(|error| with_internal_request_id(operation, error));
    let envelope = match result {
        Ok(result) => ResourceResponseEnvelope::success(id, result),
        Err(error) => ResourceResponseEnvelope::failure(id, error),
    };
    serde_json::to_value(envelope).is_ok_and(|value| writer.send_control(&value).is_ok())
}
