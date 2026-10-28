//! The byte, render and browser views as drains on the sequenced pool, on a
//! client-minted attach stream or a legacy one:
//! the work of the former `mux-attach-out`,
//! `mux-render-attach-out` and `mux-attach-notifications` threads, without
//! the threads. The snapshot view's drain is in snapshot_attach_out.rs.

use std::sync::Arc;
use std::sync::mpsc::TryRecvError;

use serde_json::json;

use crate::BrowserFrameStream;
use crate::Mux;
use crate::RenderAttachFrame;
use crate::RenderAttachStream;
use crate::SurfaceId;
use crate::input_stages::InputStageRing;
use crate::panic_free::RecoverPoison;
use crate::server::AttachWireShape;
use crate::server::MessageWriter;
use crate::server::OutboundStream;
use crate::server::RenderClientState;
use crate::server::WatchKind;
use crate::server::attach_lifecycle::attach_pump::{
    AttachPump, PumpTimer, Step, ViewDrain, ViewOut, ViewSource,
};
use crate::server::attach_lifecycle::{AttachCommit, commit_client_attach_and_start_pump};
use crate::server::browser_state_message;
use crate::server::render_messages::browser_frame_json;
use crate::server::stream_priority::follow_visibility;
use crate::surface::AttachStream;

/// Where a view's drain runs and what it starts with.
pub(crate) struct StreamView<'a> {
    pub(crate) mux: &'a Arc<Mux>,
    pub(crate) client: u64,
    pub(crate) surface: SurfaceId,
    pub(crate) writer: &'a MessageWriter,
    pub(crate) stream: &'a OutboundStream,
    pub(crate) commit: AttachCommit,
}

impl StreamView<'_> {
    /// Binds `source`'s drain to a pump at its connection's view priority
    /// (`ConnectionClass::view_priority`: the person's views on the input
    /// workers, automation's below them), commits the attach and starts the
    /// drain. `on_ready` sets the source's ready hook.
    fn start<S: ViewSource>(
        self,
        notifications: bool,
        on_ready: impl FnOnce(&S, Box<dyn Fn() + Send + Sync>),
        source: S,
    ) -> anyhow::Result<()> {
        let priority = self.mux.control_clients.connection_class(self.client).get().view_priority();
        let pump = AttachPump::new(&self.mux.sequenced_pool, priority);
        let out = ViewOut::bind(
            &pump,
            self.mux,
            self.client,
            self.surface,
            self.writer,
            self.stream,
            &self.commit.lifecycle,
            notifications,
        );
        on_ready(&source, Box::new(pump.hook()));
        follow_visibility(self.stream, &pump, None);
        pump.install(Box::new(ViewDrain::new(out, source)));
        commit_client_attach_and_start_pump(
            self.mux,
            self.client,
            self.surface,
            self.stream.id,
            self.commit,
            pump,
        )
    }

    /// A replay byte view: the terminal's output is the echo path.
    /// Each echo goes out with its press's stages from `key_stages`.
    pub(crate) fn start_bytes(
        self,
        attach: AttachStream,
        shape: AttachWireShape,
        key_stages: Option<Arc<InputStageRing>>,
    ) -> anyhow::Result<()> {
        self.start(
            true,
            |source: &BytesSource, hook| {
                source.attach.stream.on_ready(hook);
            },
            BytesSource { attach, shape, key_stages },
        )
    }

    /// A render view (protocol-v7 frames of a terminal), like the byte view.
    pub(crate) fn start_render(self, attach: RenderAttachStream) -> anyhow::Result<()> {
        let state = RenderClientState::new(self.writer.render_service.clone(), &attach.initial);
        self.start(
            false,
            |source: &RenderSource, hook| {
                source.attach.stream.on_ready(hook);
            },
            RenderSource { attach, state },
        )
    }

    /// A browser view: the page the person sees, like the echo thread that
    /// served it before.
    pub(crate) fn start_browser(self, frames: BrowserFrameStream) -> anyhow::Result<()> {
        self.start(
            true,
            |source: &BrowserSource, hook| {
                source.frames.notify.on_ready(hook);
            },
            BrowserSource { frames },
        )
    }
}

struct BytesSource {
    attach: AttachStream,
    shape: AttachWireShape,
    /// The terminal's key presses' stages, read as each echo goes out.
    key_stages: Option<Arc<InputStageRing>>,
}

impl ViewSource for BytesSource {
    const WATCH: WatchKind = WatchKind::AttachOut;

    fn next(&mut self, out: &mut ViewOut, _timer: &PumpTimer<'_>) -> Step {
        match self.attach.stream.try_recv() {
            Ok(frame) => {
                let stages = self.key_stages.as_ref().and_then(|ring| ring.stages(frame.flow()));
                let sent = out.writer.send_attach_frame(
                    out.surface,
                    &frame,
                    self.shape,
                    stages,
                    &out.stream,
                );
                if out.sent(sent) { Step::Sent } else { Step::End }
            }
            Err(TryRecvError::Empty) => Step::Empty,
            Err(TryRecvError::Disconnected) => {
                self.attach.lifecycle.cancel();
                out.send_detached();
                Step::End
            }
        }
    }
}

struct RenderSource {
    attach: RenderAttachStream,
    state: RenderClientState,
}

impl ViewSource for RenderSource {
    const WATCH: WatchKind = WatchKind::RenderAttachOut;

    fn next(&mut self, out: &mut ViewOut, _timer: &PumpTimer<'_>) -> Step {
        let sent = match self.attach.stream.try_recv() {
            Ok(RenderAttachFrame::Frame(frame)) => {
                out.send(&self.state.delta_message(out.surface, &frame))
            }
            Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => out.send(&json!({
                "event": "scroll-changed",
                "surface": out.surface,
                "offset": offset,
                "at_bottom": at_bottom,
            })),
            Err(TryRecvError::Empty) => return Step::Empty,
            Err(TryRecvError::Disconnected) => return Step::End,
        };
        if sent { Step::Sent } else { Step::End }
    }

    /// Every end but an overflow tells the viewer it is detached.
    fn end(self, out: &ViewOut) {
        if !out.lifecycle.overflowed() {
            out.send_detached();
        }
    }
}

struct BrowserSource {
    frames: BrowserFrameStream,
}

impl ViewSource for BrowserSource {
    const WATCH: WatchKind = WatchKind::AttachOut;

    fn next(&mut self, out: &mut ViewOut, _timer: &PumpTimer<'_>) -> Step {
        match self.frames.notify.try_recv() {
            Ok(()) => {}
            Err(TryRecvError::Empty) => return Step::Empty,
            Err(TryRecvError::Disconnected) => {
                out.lifecycle.cancel();
                out.send_detached();
                return Step::End;
            }
        }
        let update = std::mem::take(&mut *self.frames.slot.lock().recover_poison());
        // A frame applies its bitmap and authority atomically: it goes
        // before a paired state that can expose the same positive token.
        if let Some(frame) = update.frame
            && !out.send(&browser_frame_json(out.surface, &frame))
        {
            return Step::End;
        }
        if let Some(state) = update.state
            && !out.send(&browser_state_message(out.surface, &state, false))
        {
            return Step::End;
        }
        Step::Sent
    }

    /// The frame claim goes before the detach, which can resize the page:
    /// a natively hosted page is not restarted for nobody.
    fn end(self, _out: &ViewOut) {
        drop(self.frames);
    }
}

#[cfg(test)]
#[path = "stream_attach_out_tests.rs"]
mod tests;
