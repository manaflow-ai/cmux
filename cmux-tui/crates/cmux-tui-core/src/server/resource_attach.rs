//! Resource-protocol surface attach streams: installing a resource stream's
//! outbound queue, the terminal attach (snapshot, patches, scroll), the browser
//! attach (state and frames) and the sidebar render attach, their interrupts
//! and cleanup, and the resource response envelope writer.

use super::AttachWorkerCommit;
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
use super::commit_client_attach_and_start_worker;
use super::detach_committed_attach;
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
use crate::RenderAttachFrame;
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
use crate::sidebar_resource::SidebarRenderClientState;
use crate::sidebar_resource::attach_sidebar_render;
use crate::sidebar_resource::resolve_sidebar_view;
use crate::sidebar_resource::sidebar_attach_snapshot;
use crate::sidebar_resource::sidebar_snapshot;
use crate::stream_interrupt::StreamInterrupt;
use crate::surface::AttachLifecycle;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;

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
    serde_json::from_value(request.fields["stream_id"].clone()).map_err(|_| {
        ResourceError::selector_invalid(
            "stream",
            request.fields["stream_id"].as_str().unwrap_or(""),
            "expected an opaque stream id",
        )
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
    let initial_size = match (request.fields.get("cols"), request.fields.get("rows")) {
        (Some(cols), Some(rows)) => Some((
            u16::try_from(cols.as_u64().expect("catalog validates terminal attach cols"))
                .expect("catalog validates uint16"),
            u16::try_from(rows.as_u64().expect("catalog validates terminal attach rows"))
                .expect("catalog validates uint16"),
        )),
        (None, None) => None,
        _ => unreachable!("catalog validates paired terminal attach size"),
    };
    let (common, marked) = prepare_resource_surface_attach(
        mux,
        client,
        writer,
        operation,
        stream_id.clone(),
        surface.id,
        initial_size,
    )?;
    let attach = match surface.attach_render_stream() {
        Ok(attach) => attach,
        Err(error) => {
            cleanup_resource_attach(mux, client, &common);
            return Err(ResourceError::operation_failed(operation, error.to_string(), json!({})));
        }
    };
    Ok((
        json!({
            "stream_id":stream_id,
            "attachment_lease":marked.lease.expect("resource attach always mints a lease"),
        }),
        TerminalResourceAttachStart { common, terminal_id, attach },
    ))
}

fn terminal_resource_snapshot(
    render_service: &RenderService,
    terminal_id: &TerminalPublicId,
    frame: &SurfaceRenderFrame,
) -> Value {
    let mut render = serde_json::to_value(render_state_message(render_service, 0, frame))
        .expect("render snapshot serializes");
    let render = render.as_object_mut().expect("render snapshot is an object");
    render.remove("event");
    render.remove("surface");
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
    let mut render =
        serde_json::to_value(state.delta_message(0, frame)).expect("render patch serializes");
    let render = render.as_object_mut().expect("render patch is an object");
    render.remove("event");
    render.remove("surface");
    let full_reset = render.remove("full").expect("render patch contains full");
    render.insert("full_reset".to_string(), full_reset);
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

fn send_resource_uncursored_stream_item(
    writer: &MessageWriter,
    outbound: &OutboundStream,
    stream_id: &StreamPublicId,
    sequence: u64,
    item: Value,
) -> bool {
    writer
        .send_stream_backpressured(
            &json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":stream_id,
                "sequence":sequence.to_string(),
                "item":item,
            }),
            outbound,
        )
        .is_ok()
}

/// One interrupt for a resource attach loop: its connection writer, its
/// outbound stream (closed with `canceled`) and its attach lifecycle.
fn resource_attach_interrupt(
    writer: &MessageWriter,
    start: &ResourceSurfaceAttachStart,
) -> Arc<StreamInterrupt> {
    let interrupt = StreamInterrupt::new();
    writer.register_interrupt(&interrupt);
    start.outbound.register_interrupt(&interrupt);
    start.lifecycle.register_interrupt(&interrupt);
    interrupt
}

fn finish_resource_surface_attach(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    start: &ResourceSurfaceAttachStart,
    reason: &str,
) {
    if writer.is_open() && start.outbound.is_open() && !start.canceled.load(Ordering::Acquire) {
        let end = resource_stream_end(&start.stream_id, reason, None, None, None);
        let _ = writer.send_terminal(&end, &start.outbound);
    }
    mux.control_clients.finish_resource_stream(client, &start.stream_id, start.outbound.id);
    detach_committed_attach(mux, client, start.surface, start.outbound.id);
}

pub(super) fn start_terminal_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: TerminalResourceAttachStart,
) {
    let stream_id = start.common.stream_id.clone();
    let outbound = start.common.outbound.clone();
    let surface = start.common.surface;
    let lifecycle = start.common.lifecycle.clone();
    let client_changed = start.common.client_changed.clone();
    let size_rollback = start.common.size_rollback;
    let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn =
        std::thread::Builder::new().name("mux-resource-terminal-attach".into()).spawn(move || {
            if worker_committed.recv().is_err() {
                return;
            }
            let mut sequence = 0u64;
            if !send_resource_uncursored_stream_item(
                &worker_writer,
                &start.common.outbound,
                &start.common.stream_id,
                sequence,
                terminal_resource_snapshot(
                    &worker_writer.render_service,
                    &start.terminal_id,
                    &start.attach.initial,
                ),
            ) {
                finish_resource_surface_attach(
                    &worker_mux,
                    client,
                    &worker_writer,
                    &start.common,
                    "gap",
                );
                return;
            }
            sequence = sequence.saturating_add(1);
            let mut render_state =
                RenderClientState::new(worker_writer.render_service.clone(), &start.attach.initial);
            let interrupt = resource_attach_interrupt(&worker_writer, &start.common);
            start.attach.stream.wake_on(&interrupt);
            while worker_writer.is_open()
                && start.common.outbound.is_open()
                && !start.common.canceled.load(Ordering::Acquire)
                && !start.common.lifecycle.is_canceled()
            {
                let item = match start.attach.stream.recv_until_interrupted(&interrupt) {
                    Ok(RenderAttachFrame::Frame(frame)) => {
                        terminal_resource_patch(&start.terminal_id, &mut render_state, &frame)
                    }
                    Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                        terminal_resource_scroll(&start.terminal_id, offset, at_bottom)
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
                if !send_resource_uncursored_stream_item(
                    &worker_writer,
                    &start.common.outbound,
                    &start.common.stream_id,
                    sequence,
                    item,
                ) {
                    break;
                }
                sequence = sequence.saturating_add(1);
            }
            finish_resource_surface_attach(
                &worker_mux,
                client,
                &worker_writer,
                &start.common,
                "closed",
            );
        });
    if let Err(error) = spawn {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh terminal attachment"),
            Some((
                ResourceOperation::TerminalAttach,
                ResourceError::operation_failed("terminal.attach", error.to_string(), json!({})),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        lifecycle.cancel();
        cleanup_resource_stream(&mux, client, &stream_id);
        rollback_failed_attach(&mux, client, surface, outbound.id, size_rollback);
        return;
    }
    if let Err(error) = commit_client_attach_and_start_worker(
        &mux,
        client,
        surface,
        outbound.id,
        AttachWorkerCommit {
            start: worker_start,
            lifecycle,
            changed: client_changed,
            size_rollback,
        },
    ) {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh terminal attachment"),
            Some((
                ResourceOperation::TerminalAttach,
                ResourceError::operation_failed("terminal.attach", error.to_string(), json!({})),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        cleanup_resource_stream(&mux, client, &stream_id);
    }
}

fn browser_snapshot_for_id(
    mux: &Mux,
    browser_id: &BrowserPublicId,
) -> Result<Value, ResourceError> {
    crate::resource_api::public_session_snapshot(mux)?["browsers"]
        .as_array()
        .and_then(|browsers| browsers.iter().find(|browser| browser["id"] == browser_id.as_str()))
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
    let initial_size = match (request.fields.get("width_px"), request.fields.get("height_px")) {
        (Some(width), Some(height)) => Some(browser_cells_for_pixels(
            mux,
            u32::try_from(width.as_u64().expect("catalog validates browser attach width"))
                .expect("catalog validates uint32"),
            u32::try_from(height.as_u64().expect("catalog validates browser attach height"))
                .expect("catalog validates uint32"),
        )),
        (None, None) => None,
        _ => unreachable!("catalog validates paired browser attach size"),
    };
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
        && let Err(error) = wait_for_initial_browser_resize(
            marked
                .resize_completion
                .as_ref()
                .expect("sized browser attach has a completion receiver"),
            surface.id,
            reservation,
        )
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
    let (width_px, height_px) = browser_pixels_for_cells(mux, initial.cols, initial.rows);
    let snapshot = json!({
        "kind":"snapshot",
        "browser":browser,
        "size":{"width_px":width_px,"height_px":height_px},
    });
    Ok((
        json!({
            "stream_id":stream_id,
            "attachment_lease":marked.lease.expect("resource attach always mints a lease"),
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

pub(super) fn start_browser_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: BrowserResourceAttachStart,
) {
    let stream_id = start.common.stream_id.clone();
    let outbound = start.common.outbound.clone();
    let surface = start.common.surface;
    let lifecycle = start.common.lifecycle.clone();
    let client_changed = start.common.client_changed.clone();
    let size_rollback = start.common.size_rollback;
    let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn =
        std::thread::Builder::new().name("mux-resource-browser-attach".into()).spawn(move || {
            if worker_committed.recv().is_err() {
                return;
            }
            let mut sequence = 0u64;
            if !send_resource_uncursored_stream_item(
                &worker_writer,
                &start.common.outbound,
                &start.common.stream_id,
                sequence,
                start.snapshot,
            ) {
                finish_resource_surface_attach(
                    &worker_mux,
                    client,
                    &worker_writer,
                    &start.common,
                    "gap",
                );
                return;
            }
            sequence = sequence.saturating_add(1);
            if let Some(frame) = start.initial.frame.as_ref() {
                if !send_resource_uncursored_stream_item(
                    &worker_writer,
                    &start.common.outbound,
                    &start.common.stream_id,
                    sequence,
                    browser_resource_frame(frame, start.initial.pointer_frame_seq),
                ) {
                    finish_resource_surface_attach(
                        &worker_mux,
                        client,
                        &worker_writer,
                        &start.common,
                        "gap",
                    );
                    return;
                }
                sequence = sequence.saturating_add(1);
            }
            let interrupt = resource_attach_interrupt(&worker_writer, &start.common);
            start.frames.notify.wake_on(&interrupt);
            while worker_writer.is_open()
                && start.common.outbound.is_open()
                && !start.common.canceled.load(Ordering::Acquire)
                && !start.common.lifecycle.is_canceled()
            {
                match start.frames.notify.recv_until_interrupted(&interrupt) {
                    Ok(()) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
                let update = std::mem::take(&mut *start.frames.slot.lock().unwrap());
                let mut items = Vec::with_capacity(2);
                if let Some(state) = update.state.as_ref() {
                    items.push(browser_resource_state(state));
                }
                if let Some(frame) = update.frame.as_ref() {
                    items.push(browser_resource_frame(&frame.frame, frame.pointer_frame_seq));
                }
                for item in items {
                    if !send_resource_uncursored_stream_item(
                        &worker_writer,
                        &start.common.outbound,
                        &start.common.stream_id,
                        sequence,
                        item,
                    ) {
                        finish_resource_surface_attach(
                            &worker_mux,
                            client,
                            &worker_writer,
                            &start.common,
                            "gap",
                        );
                        return;
                    }
                    sequence = sequence.saturating_add(1);
                }
            }
            finish_resource_surface_attach(
                &worker_mux,
                client,
                &worker_writer,
                &start.common,
                "closed",
            );
        });
    if let Err(error) = spawn {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh browser attachment"),
            Some((
                ResourceOperation::BrowserAttach,
                ResourceError::operation_failed("browser.attach", error.to_string(), json!({})),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        lifecycle.cancel();
        cleanup_resource_stream(&mux, client, &stream_id);
        rollback_failed_attach(&mux, client, surface, outbound.id, size_rollback);
        return;
    }
    if let Err(error) = commit_client_attach_and_start_worker(
        &mux,
        client,
        surface,
        outbound.id,
        AttachWorkerCommit {
            start: worker_start,
            lifecycle,
            changed: client_changed,
            size_rollback,
        },
    ) {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh browser attachment"),
            Some((
                ResourceOperation::BrowserAttach,
                ResourceError::operation_failed("browser.attach", error.to_string(), json!({})),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        cleanup_resource_stream(&mux, client, &stream_id);
    }
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

pub(super) fn start_sidebar_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: SidebarResourceAttachStart,
) {
    let stream_id = start.stream_id.clone();
    let outbound = start.outbound.clone();
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn =
        std::thread::Builder::new().name("mux-resource-sidebar-attach".into()).spawn(move || {
            let mut sequence = 0u64;
            if !send_resource_uncursored_stream_item(
                &worker_writer,
                &start.outbound,
                &start.stream_id,
                sequence,
                sidebar_attach_snapshot(&start.attachment),
            ) {
                worker_mux.control_clients.finish_resource_stream(
                    client,
                    &start.stream_id,
                    start.outbound.id,
                );
                return;
            }
            sequence = sequence.saturating_add(1);
            let mut render_state = SidebarRenderClientState::new(&start.attachment.initial);
            // `canceled` is only set together with closing `outbound`.
            let interrupt = StreamInterrupt::new();
            worker_writer.register_interrupt(&interrupt);
            start.outbound.register_interrupt(&interrupt);
            start.attachment.stream.wake_on(&interrupt);
            while worker_writer.is_open()
                && start.outbound.is_open()
                && !start.canceled.load(Ordering::Acquire)
            {
                let item = match start.attachment.stream.recv_until_interrupted(&interrupt) {
                    Ok(RenderAttachFrame::Frame(frame)) => {
                        render_state.patch(&start.attachment.sidebar_view_id, &frame)
                    }
                    Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                        SidebarRenderClientState::scroll(
                            &start.attachment.sidebar_view_id,
                            offset,
                            at_bottom,
                        )
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
                if !send_resource_uncursored_stream_item(
                    &worker_writer,
                    &start.outbound,
                    &start.stream_id,
                    sequence,
                    item,
                ) {
                    break;
                }
                sequence = sequence.saturating_add(1);
            }
            if worker_writer.is_open()
                && start.outbound.is_open()
                && !start.canceled.load(Ordering::Acquire)
            {
                let end = resource_stream_end(&start.stream_id, "closed", None, None, None);
                let _ = worker_writer.send_terminal(&end, &start.outbound);
            }
            worker_mux.control_clients.finish_resource_stream(
                client,
                &start.stream_id,
                start.outbound.id,
            );
        });
    if let Err(error) = spawn {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh sidebar attachment"),
            Some((
                ResourceOperation::SidebarViewAttach,
                ResourceError::operation_failed(
                    "sidebar_view.attach",
                    error.to_string(),
                    json!({}),
                ),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        cleanup_resource_stream(&mux, client, &stream_id);
    }
}

pub(super) fn send_resource_response(
    writer: &MessageWriter,
    id: ResourceRequestId,
    operation: ResourceOperation,
    result: Result<Value, ResourceError>,
) -> bool {
    let result = crate::resource_router::validate_operation_outcome(operation, result);
    let envelope = match result {
        Ok(result) => ResourceResponseEnvelope::success(id, result),
        Err(error) => ResourceResponseEnvelope::failure(id, error),
    };
    serde_json::to_value(envelope).is_ok_and(|value| writer.send_control(&value).is_ok())
}
