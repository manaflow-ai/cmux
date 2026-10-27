//! Resource-protocol attach streams (`terminal.attach`, `browser.attach`,
//! `sidebar_view.attach`) as drains on the daemon-wide sequenced pool
//! (p05-ipc-147). Each held a thread blocked on its source
//! (`mux-resource-terminal-attach`, `-browser-attach`, `-sidebar-attach`);
//! now each is an [`AttachPump`] at control priority, as the legacy and
//! attach-stream views are (attach_pump.rs, p05-ipc-079): its source's
//! ready hook, room on its stream and a close of the connection, the stream
//! or the attachment wake it, and a turn sends what is ready and returns.
//! Chrome runs each Mojo receiver's messages as tasks on its sequence
//! (mojo/public/cpp/bindings/lib/connector.cc); no receiver holds a thread.

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::TryRecvError;

use serde_json::{Value, json};

use super::{
    ResourceSurfaceAttachStart, SidebarResourceAttachStart, browser_resource_frame,
    browser_resource_state, terminal_resource_patch, terminal_resource_scroll,
    terminal_resource_snapshot,
};
use crate::BrowserAttachState;
use crate::BrowserFrameStream;
use crate::Mux;
use crate::RenderAttachFrame;
use crate::RenderAttachStream;
use crate::SurfaceId;
use crate::panic_free::RecoverPoison;
use crate::resource::StreamPublicId;
use crate::resource::TerminalPublicId;
use crate::server::MessageWriter;
use crate::server::OutboundStream;
use crate::server::RenderClientState;
use crate::server::ResourceWorkerPermit;
use crate::server::attach_lifecycle::attach_pump::{AttachDrain, AttachPump, PumpTimer, Turn};
use crate::server::attach_lifecycle::{AttachCommit, commit_client_attach_and_start_pump};
use crate::server::detach_committed_attach;
use crate::server::resource_stream_end;
use crate::server::sequenced_pool::{PostError, SequencePriority};
use crate::sidebar_resource::{
    SidebarRenderAttachment, SidebarRenderClientState, sidebar_attach_snapshot,
};
use crate::surface::AttachLifecycle;

/// Items one turn sends before it yields its worker.
const TURN_BUDGET: usize = 64;

/// What a source had for its drain.
pub(super) enum Next {
    /// Items to send, in order.
    Items(Vec<Value>),
    /// Nothing until its ready hook runs.
    Empty,
    /// The source ended.
    End,
}

/// One resource attach's source: what its first turn sends, then what each
/// later turn takes without waiting.
pub(super) trait ResourceSource: Send + 'static {
    fn first(&mut self, writer: &MessageWriter) -> Vec<Value>;
    fn next(&mut self) -> Next;
}

/// The committed surface attachment a stream ends by detaching.
struct Attached {
    surface: SurfaceId,
    lifecycle: AttachLifecycle,
}

/// A resource attach's drain. Its first item has sequence 0.
pub(super) struct ResourceAttachDrain<S> {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    stream_id: StreamPublicId,
    outbound: OutboundStream,
    canceled: Arc<AtomicBool>,
    _worker_permit: ResourceWorkerPermit,
    attached: Option<Attached>,
    /// `None` once it ended: its frame claim goes before the detach.
    source: Option<S>,
    pending: VecDeque<Value>,
    sequence: u64,
    started: bool,
}

impl<S: ResourceSource> AttachDrain for ResourceAttachDrain<S> {
    fn turn(&mut self, _timer: &PumpTimer<'_>) -> Turn {
        if !self.started {
            self.started = true;
            if let Some(source) = self.source.as_mut() {
                self.pending.extend(source.first(&self.writer));
            }
        }
        for _ in 0..TURN_BUDGET {
            if !self.is_live() {
                return self.finish("closed");
            }
            if !self.writer.sink.stream_has_room(&self.outbound) {
                return Turn::Idle;
            }
            let item = match self.pending.pop_front() {
                Some(item) => item,
                None => match self.source.as_mut().map_or(Next::End, ResourceSource::next) {
                    Next::Items(items) => {
                        self.pending.extend(items);
                        continue;
                    }
                    Next::Empty => return Turn::Idle,
                    Next::End => return self.finish("closed"),
                },
            };
            if !self.send(item) {
                return self.finish("gap");
            }
        }
        Turn::Yield
    }
}

impl<S> ResourceAttachDrain<S> {
    fn is_live(&self) -> bool {
        self.writer.is_open()
            && self.outbound.is_open()
            && !self.canceled.load(Ordering::Acquire)
            && self.attached.as_ref().is_none_or(|attached| !attached.lifecycle.is_canceled())
    }

    fn send(&mut self, item: Value) -> bool {
        let sent = self.writer.send_stream(
            &json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":self.stream_id,
                "sequence":self.sequence.to_string(),
                "item":item,
            }),
            &self.outbound,
        );
        self.sequence = self.sequence.saturating_add(1);
        sent.is_ok()
    }

    /// Ends the stream: its source (and its frame claim) first, then its
    /// `stream_end` while it can still be read, its registration and its
    /// attachment.
    fn finish(&mut self, reason: &str) -> Turn {
        drop(self.source.take());
        if self.writer.is_open()
            && self.outbound.is_open()
            && !self.canceled.load(Ordering::Acquire)
        {
            let end = resource_stream_end(&self.stream_id, reason, None, None, None);
            let _ = self.writer.send_terminal(&end, &self.outbound);
        }
        self.mux.control_clients.finish_resource_stream(
            self.client,
            &self.stream_id,
            self.outbound.id,
        );
        if let Some(attached) = self.attached.take() {
            detach_committed_attach(&self.mux, self.client, attached.surface, self.outbound.id);
        }
        Turn::Done
    }
}

/// A pump for `source` whose stop fires on a close of `writer` or
/// `outbound` (and `lifecycle`, for a surface attach).
fn bind(
    mux: &Arc<Mux>,
    writer: &MessageWriter,
    outbound: &OutboundStream,
    lifecycle: Option<&AttachLifecycle>,
) -> AttachPump {
    let pump = AttachPump::new(&mux.sequenced_pool, SequencePriority::Control);
    writer.register_interrupt(pump.stop());
    outbound.register_interrupt(pump.stop());
    if let Some(lifecycle) = lifecycle {
        lifecycle.register_interrupt(pump.stop());
    }
    outbound.on_space(pump.hook());
    pump
}

/// Binds a surface attach's drain to a pump, commits the attach and starts
/// the drain; `on_ready` sets the source's ready hook.
pub(super) fn start_surface_attach<S: ResourceSource>(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    common: ResourceSurfaceAttachStart,
    source: S,
    on_ready: impl FnOnce(&S, Box<dyn Fn() + Send + Sync>),
) -> anyhow::Result<()> {
    let pump = bind(mux, writer, &common.outbound, Some(&common.lifecycle));
    on_ready(&source, Box::new(pump.hook()));
    let ResourceSurfaceAttachStart {
        stream_id,
        outbound,
        canceled,
        _worker_permit,
        surface,
        lifecycle,
        size_rollback,
        client_changed,
    } = common;
    let stream = outbound.id;
    pump.install(Box::new(ResourceAttachDrain {
        mux: mux.clone(),
        client,
        writer: writer.clone(),
        stream_id,
        outbound,
        canceled,
        _worker_permit,
        attached: Some(Attached { surface, lifecycle: lifecycle.clone() }),
        source: Some(source),
        pending: VecDeque::new(),
        sequence: 0,
        started: false,
    }));
    let commit = AttachCommit { lifecycle, changed: client_changed, size_rollback };
    commit_client_attach_and_start_pump(mux, client, surface, stream, commit, pump)
}

/// Starts a sidebar attach's drain: it has no surface attachment to commit.
pub(super) fn start_sidebar_attach(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    start: SidebarResourceAttachStart,
) -> Result<(), PostError> {
    let pump = bind(mux, writer, &start.outbound, None);
    start.attachment.stream.on_ready(pump.hook());
    let SidebarResourceAttachStart { stream_id, outbound, canceled, _worker_permit, attachment } =
        start;
    let state = SidebarRenderClientState::new(&attachment.initial);
    pump.install(Box::new(ResourceAttachDrain {
        mux: mux.clone(),
        client,
        writer: writer.clone(),
        stream_id,
        outbound,
        canceled,
        _worker_permit,
        attached: None,
        source: Some(SidebarSource { attachment, state }),
        pending: VecDeque::new(),
        sequence: 0,
        started: false,
    }));
    pump.start()
}

pub(super) struct TerminalSource {
    pub(super) terminal_id: TerminalPublicId,
    pub(super) attach: RenderAttachStream,
    pub(super) state: Option<RenderClientState>,
}

impl ResourceSource for TerminalSource {
    fn first(&mut self, writer: &MessageWriter) -> Vec<Value> {
        self.state =
            Some(RenderClientState::new(writer.render_service.clone(), &self.attach.initial));
        vec![terminal_resource_snapshot(
            &writer.render_service,
            &self.terminal_id,
            &self.attach.initial,
        )]
    }

    fn next(&mut self) -> Next {
        let Some(state) = self.state.as_mut() else { return Next::End };
        match self.attach.stream.try_recv() {
            Ok(RenderAttachFrame::Frame(frame)) => {
                Next::Items(vec![terminal_resource_patch(&self.terminal_id, state, &frame)])
            }
            Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                Next::Items(vec![terminal_resource_scroll(&self.terminal_id, offset, at_bottom)])
            }
            Err(TryRecvError::Empty) => Next::Empty,
            Err(TryRecvError::Disconnected) => Next::End,
        }
    }
}

pub(super) struct BrowserSource {
    pub(super) initial: BrowserAttachState,
    pub(super) frames: BrowserFrameStream,
    pub(super) snapshot: Value,
}

impl ResourceSource for BrowserSource {
    fn first(&mut self, _writer: &MessageWriter) -> Vec<Value> {
        let mut items = vec![std::mem::take(&mut self.snapshot)];
        if let Some(frame) = self.initial.frame.as_ref() {
            items.push(browser_resource_frame(frame, self.initial.pointer_frame_seq));
        }
        items
    }

    fn next(&mut self) -> Next {
        match self.frames.notify.try_recv() {
            Ok(()) => {}
            Err(TryRecvError::Empty) => return Next::Empty,
            Err(TryRecvError::Disconnected) => return Next::End,
        }
        let update = std::mem::take(&mut *self.frames.slot.lock().recover_poison());
        let mut items = Vec::with_capacity(2);
        if let Some(state) = update.state.as_ref() {
            items.push(browser_resource_state(state));
        }
        if let Some(frame) = update.frame.as_ref() {
            items.push(browser_resource_frame(&frame.frame, frame.pointer_frame_seq));
        }
        Next::Items(items)
    }
}

struct SidebarSource {
    attachment: SidebarRenderAttachment,
    state: SidebarRenderClientState,
}

impl ResourceSource for SidebarSource {
    fn first(&mut self, _writer: &MessageWriter) -> Vec<Value> {
        vec![sidebar_attach_snapshot(&self.attachment)]
    }

    fn next(&mut self) -> Next {
        match self.attachment.stream.try_recv() {
            Ok(RenderAttachFrame::Frame(frame)) => {
                Next::Items(vec![self.state.patch(&self.attachment.sidebar_view_id, &frame)])
            }
            Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                Next::Items(vec![SidebarRenderClientState::scroll(
                    &self.attachment.sidebar_view_id,
                    offset,
                    at_bottom,
                )])
            }
            Err(TryRecvError::Empty) => Next::Empty,
            Err(TryRecvError::Disconnected) => Next::End,
        }
    }
}
