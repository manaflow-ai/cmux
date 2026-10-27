//! The terminal, browser and sidebar resource attaches as drains on the
//! sequenced pool (resource_pump.rs, p01-process-204): the work of the
//! `mux-resource-terminal-attach`, `mux-resource-browser-attach` and
//! `mux-resource-sidebar-attach` threads, without the threads. They run at
//! input priority, as the attach streams' views do: they are what the person
//! sees.

use std::sync::Arc;
use std::sync::mpsc::TryRecvError;

use serde_json::json;

use super::{
    BrowserResourceAttachStart, ResourceSurfaceAttachStart, SidebarResourceAttachStart,
    TerminalResourceAttachStart, browser_resource_frame, browser_resource_state,
    cleanup_resource_stream, terminal_resource_patch, terminal_resource_scroll,
    terminal_resource_snapshot,
};
use crate::BrowserFrameStream;
use crate::Mux;
use crate::RenderAttachFrame;
use crate::panic_free::RecoverPoison;
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::StreamPublicId;
use crate::server::MessageWriter;
use crate::server::OutboundStream;
use crate::server::RenderClientState;
use crate::server::attach_lifecycle::attach_pump::{AttachPump, PumpTimer, Step};
use crate::server::attach_lifecycle::{AttachCommit, commit_client_attach_and_start_pump};
use crate::server::detach_committed_attach;
use crate::server::resource_pump::{ResourceOut, ResourceSource, ResourceStart, StreamItem};
use crate::server::resource_stream_end;
use crate::server::sequenced_pool::SequencePriority;
use crate::sidebar_resource::SidebarRenderClientState;
use crate::sidebar_resource::sidebar_attach_snapshot;

/// The stream of a surface attach: its view's attachment ends it too.
fn surface_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    common: &ResourceSurfaceAttachStart,
    initial: Vec<StreamItem>,
) -> ResourceStart {
    ResourceStart {
        mux: mux.clone(),
        client,
        writer: writer.clone(),
        outbound: common.outbound.clone(),
        stream_id: common.stream_id.clone(),
        canceled: common.canceled.clone(),
        lifecycle: Some(common.lifecycle.clone()),
        first_sequence: 0,
        initial,
    }
}

/// Ends a surface attach's stream with `closed` unless it was canceled or
/// closed, releases it and detaches its view.
fn finish_surface_attach(out: &ResourceOut, common: &ResourceSurfaceAttachStart) {
    if out.is_live() {
        out.send_end(&resource_stream_end(&common.stream_id, "closed", None, None, None));
    }
    out.finish();
    detach_committed_attach(&out.mux, out.client, common.surface, common.outbound.id);
}

/// What committing a surface attach needs once its start moved into the
/// drain.
struct SurfaceCommit {
    stream_id: StreamPublicId,
    outbound: OutboundStream,
    commit: AttachCommit,
    surface: crate::SurfaceId,
}

impl SurfaceCommit {
    fn of(common: &ResourceSurfaceAttachStart) -> Self {
        Self {
            stream_id: common.stream_id.clone(),
            outbound: common.outbound.clone(),
            commit: AttachCommit {
                lifecycle: common.lifecycle.clone(),
                changed: common.client_changed.clone(),
                size_rollback: common.size_rollback,
            },
            surface: common.surface,
        }
    }

    /// Commits the attach and starts its drain; a failure ends the stream
    /// with `error` and releases it.
    fn start(
        self,
        mux: &Arc<Mux>,
        client: u64,
        writer: &MessageWriter,
        pump: AttachPump,
        (operation, recovery): (ResourceOperation, &str),
    ) {
        let Self { stream_id, outbound, commit, surface } = self;
        if let Err(error) =
            commit_client_attach_and_start_pump(mux, client, surface, outbound.id, commit, pump)
        {
            let end = resource_stream_end(
                &stream_id,
                "error",
                None,
                Some(recovery),
                Some((
                    operation,
                    ResourceError::operation_failed(
                        operation.wire_name(),
                        error.to_string(),
                        json!({}),
                    ),
                )),
            );
            let _ = writer.send_terminal(&end, &outbound);
            cleanup_resource_stream(mux, client, &stream_id);
        }
    }
}

pub(in crate::server) fn start_terminal_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: TerminalResourceAttachStart,
) {
    let snapshot = terminal_resource_snapshot(
        &writer.render_service,
        &start.terminal_id,
        &start.attach.initial,
    );
    let render_state = RenderClientState::new(writer.render_service.clone(), &start.attach.initial);
    let commit = SurfaceCommit::of(&start.common);
    let stream = surface_stream(
        &mux,
        client,
        &writer,
        &start.common,
        vec![StreamItem::uncursored(snapshot)],
    );
    let source = TerminalAttachSource { start, render_state };
    let pump = stream.bind(SequencePriority::Input, source, |source, wake| {
        source.start.attach.stream.on_ready(move || wake());
    });
    commit.start(
        &mux,
        client,
        &writer,
        pump,
        (ResourceOperation::TerminalAttach, "open a fresh terminal attachment"),
    );
}

/// A terminal's render frames and scroll changes as patches.
struct TerminalAttachSource {
    start: TerminalResourceAttachStart,
    render_state: RenderClientState,
}

impl ResourceSource for TerminalAttachSource {
    fn next(&mut self, out: &mut ResourceOut, _timer: &PumpTimer<'_>) -> Step {
        let terminal_id = &self.start.terminal_id;
        let item = match self.start.attach.stream.try_recv() {
            Ok(RenderAttachFrame::Frame(frame)) => {
                terminal_resource_patch(terminal_id, &mut self.render_state, &frame)
            }
            Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                terminal_resource_scroll(terminal_id, offset, at_bottom)
            }
            Err(TryRecvError::Empty) => return Step::Empty,
            Err(TryRecvError::Disconnected) => return Step::End,
        };
        if out.send(StreamItem::uncursored(item)) { Step::Sent } else { Step::End }
    }

    fn finish(&mut self, out: &ResourceOut, _timer: &PumpTimer<'_>) -> bool {
        finish_surface_attach(out, &self.start.common);
        true
    }
}

pub(in crate::server) fn start_browser_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: BrowserResourceAttachStart,
) {
    let BrowserResourceAttachStart { common, initial, frames, snapshot } = start;
    let mut items = vec![StreamItem::uncursored(snapshot)];
    if let Some(frame) = initial.frame.as_ref() {
        items
            .push(StreamItem::uncursored(browser_resource_frame(frame, initial.pointer_frame_seq)));
    }
    let commit = SurfaceCommit::of(&common);
    let stream = surface_stream(&mux, client, &writer, &common, items);
    let source = BrowserAttachSource { common, frames: Some(frames) };
    let pump = stream.bind(SequencePriority::Input, source, |source, wake| {
        if let Some(frames) = source.frames.as_ref() {
            frames.notify.on_ready(move || wake());
        }
    });
    commit.start(
        &mux,
        client,
        &writer,
        pump,
        (ResourceOperation::BrowserAttach, "open a fresh browser attachment"),
    );
}

/// A browser's state and frame updates.
struct BrowserAttachSource {
    common: ResourceSurfaceAttachStart,
    /// The frame claim: dropped before the view detaches.
    frames: Option<BrowserFrameStream>,
}

impl ResourceSource for BrowserAttachSource {
    fn next(&mut self, out: &mut ResourceOut, _timer: &PumpTimer<'_>) -> Step {
        let Some(frames) = self.frames.as_ref() else { return Step::End };
        match frames.notify.try_recv() {
            Ok(()) => {}
            Err(TryRecvError::Empty) => return Step::Empty,
            Err(TryRecvError::Disconnected) => return Step::End,
        }
        let update = std::mem::take(&mut *frames.slot.lock().recover_poison());
        let state = update.state.as_ref().map(browser_resource_state);
        let frame = update
            .frame
            .as_ref()
            .map(|frame| browser_resource_frame(&frame.frame, frame.pointer_frame_seq));
        for item in state.into_iter().chain(frame) {
            if !out.send(StreamItem::uncursored(item)) {
                return Step::End;
            }
        }
        Step::Sent
    }

    /// The frame claim goes before the detach, which can resize the page.
    fn finish(&mut self, out: &ResourceOut, _timer: &PumpTimer<'_>) -> bool {
        drop(self.frames.take());
        finish_surface_attach(out, &self.common);
        true
    }
}

pub(in crate::server) fn start_sidebar_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: SidebarResourceAttachStart,
) {
    let stream = ResourceStart {
        mux: mux.clone(),
        client,
        writer: writer.clone(),
        outbound: start.outbound.clone(),
        stream_id: start.stream_id.clone(),
        canceled: start.canceled.clone(),
        lifecycle: None,
        first_sequence: 0,
        initial: vec![StreamItem::uncursored(sidebar_attach_snapshot(&start.attachment))],
    };
    let (stream_id, outbound) = (start.stream_id.clone(), start.outbound.clone());
    let render_state = SidebarRenderClientState::new(&start.attachment.initial);
    let source = SidebarAttachSource { start, render_state };
    let pump = stream.bind(SequencePriority::Input, source, |source, wake| {
        source.start.attachment.stream.on_ready(move || wake());
    });
    if let Err(error) = pump.start() {
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

/// The sidebar view's render frames and scroll changes as patches.
struct SidebarAttachSource {
    start: SidebarResourceAttachStart,
    render_state: SidebarRenderClientState,
}

impl ResourceSource for SidebarAttachSource {
    fn next(&mut self, out: &mut ResourceOut, _timer: &PumpTimer<'_>) -> Step {
        let attachment = &self.start.attachment;
        let item = match attachment.stream.try_recv() {
            Ok(RenderAttachFrame::Frame(frame)) => {
                self.render_state.patch(&attachment.sidebar_view_id, &frame)
            }
            Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                SidebarRenderClientState::scroll(&attachment.sidebar_view_id, offset, at_bottom)
            }
            Err(TryRecvError::Empty) => return Step::Empty,
            Err(TryRecvError::Disconnected) => return Step::End,
        };
        if out.send(StreamItem::uncursored(item)) { Step::Sent } else { Step::End }
    }

    fn finish(&mut self, out: &ResourceOut, _timer: &PumpTimer<'_>) -> bool {
        if out.is_live() {
            out.send_end(&resource_stream_end(&self.start.stream_id, "closed", None, None, None));
        }
        out.finish();
        true
    }
}
