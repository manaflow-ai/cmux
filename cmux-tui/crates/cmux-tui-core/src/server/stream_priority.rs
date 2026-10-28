//! Stream visibility priority (p05-ipc.md 3.4 "Stream
//! visibility"): `set-stream-priority {stream, focused|visible|hidden}` ranks
//! one client-minted attach stream against the others of its connection.
//!
//! Chrome ranks a renderer's work by what the person sees: the focused
//! widget's input and frames come first, a hidden widget gets `WasHidden()`
//! and produces no frames while its renderer keeps running
//! (content/browser/renderer_host/render_widget_host_impl.cc), and its task
//! runners move to a lower priority with
//! `UpdateableSequencedTaskRunner::UpdatePriority`
//! (base/task/updateable_sequenced_task_runner.h). Here:
//!
//! - focused: the stream's items ride the input lane (before replies) and its
//!   view drains on the input workers: the echo the person waits for.
//! - visible: the bulk lane and the utility workers, so a flooding visible
//!   terminal never delays a focused echo.
//! - hidden: the background lane and workers; a snapshot viewer queues no
//!   output at all and is not woken (`TapVisibility`): the terminal still
//!   parses its bytes, and the viewer gets one READY when it shows if any
//!   arrived meanwhile, else it continues at its offset.
//!
//! A stream never set keeps what it opened with (the bulk lane, its
//! connection's view priority), so a client that never sends the command
//! sees no change.

use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, Ordering};

use cmux_ipc::StreamLane;
use serde_json::{Value, json};

use super::MessageWriter;
use super::OutboundStream;
use super::attach_lifecycle::attach_pump::AttachPump;
use super::attach_streams::{ClientStreamId, require_grant};
use super::sequenced_pool::SequencePriority;
use crate::Mux;
use crate::surface::TapVisibility;

/// One stream's priority as the client set it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StreamPriority {
    Focused,
    Visible,
    Hidden,
}

impl StreamPriority {
    /// The wire value.
    pub(crate) fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "focused" => Ok(Self::Focused),
            "visible" => Ok(Self::Visible),
            "hidden" => Ok(Self::Hidden),
            other => anyhow::bail!(
                "bad request: set-stream-priority priority must be focused, visible or hidden, not {other:?}"
            ),
        }
    }

    /// The outbound lane its items ride.
    pub(crate) const fn lane(self) -> StreamLane {
        match self {
            Self::Focused => StreamLane::Input,
            Self::Visible => StreamLane::Bulk,
            Self::Hidden => StreamLane::Background,
        }
    }

    /// The workers its view drains on.
    pub(crate) const fn sequence(self) -> SequencePriority {
        match self {
            Self::Focused => SequencePriority::Input,
            Self::Visible => SequencePriority::Utility,
            Self::Hidden => SequencePriority::Background,
        }
    }

    const fn encode(self) -> u8 {
        match self {
            Self::Focused => 1,
            Self::Visible => 2,
            Self::Hidden => 3,
        }
    }

    const fn decode(value: u8) -> Option<Self> {
        match value {
            1 => Some(Self::Focused),
            2 => Some(Self::Visible),
            3 => Some(Self::Hidden),
            _ => None,
        }
    }
}

type ChangeHook = Box<dyn Fn(StreamPriority) + Send + Sync>;

/// A stream's priority, shared by every clone of its `OutboundStream`, and
/// what follows it: its view's drain and snapshot viewer.
#[derive(Default)]
pub(crate) struct StreamVisibility {
    /// 0 while never set.
    priority: AtomicU8,
    on_change: OnceLock<ChangeHook>,
}

impl StreamVisibility {
    pub(crate) fn get(&self) -> Option<StreamPriority> {
        StreamPriority::decode(self.priority.load(Ordering::SeqCst))
    }

    pub(crate) fn is_hidden(&self) -> bool {
        self.get() == Some(StreamPriority::Hidden)
    }

    /// Sets `priority`; when it changed, the view follows it. The hook reads
    /// the value at its call, so racing sets end at the last one stored.
    fn set(&self, priority: StreamPriority) {
        if self.priority.swap(priority.encode(), Ordering::SeqCst) == priority.encode() {
            return;
        }
        self.notify();
    }

    fn notify(&self) {
        if let (Some(hook), Some(priority)) = (self.on_change.get(), self.get()) {
            hook(priority);
        }
    }

    /// Installs what follows the priority and applies one set before it was
    /// installed (a `set-stream-priority` that raced the attach).
    fn follow(&self, hook: ChangeHook) {
        if self.on_change.set(hook).is_err() {
            return;
        }
        // Pairs with `set`'s SeqCst swap: either that set sees the hook, or
        // this read sees its value.
        std::sync::atomic::fence(Ordering::SeqCst);
        self.notify();
    }
}

/// Makes `pump`'s drain, and the snapshot viewer `tap` when there is one,
/// follow `stream`'s priority. Before the pump starts.
pub(crate) fn follow_visibility(
    stream: &OutboundStream,
    pump: &AttachPump,
    tap: Option<TapVisibility>,
) {
    let move_drain = pump.priority_hook();
    stream.visibility.follow(Box::new(move |priority| {
        if let Some(tap) = &tap {
            tap.set_hidden(priority == StreamPriority::Hidden);
        }
        move_drain(priority.sequence());
    }));
}

/// `set-stream-priority`: moves the stream's lane, then its view. An id with
/// no open stream answers `ended`.
pub(super) fn set_stream_priority(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    stream: u16,
    priority: &str,
) -> anyhow::Result<Value> {
    require_grant(mux, client)?;
    let priority = StreamPriority::parse(priority)?;
    let Some(outbound) = writer.client_stream(ClientStreamId(stream)) else {
        return Ok(json!({"stream": stream, "outcome": "ended"}));
    };
    writer.sink.set_stream_lane(&outbound, priority.lane());
    outbound.visibility.set(priority);
    Ok(json!({"stream": stream, "outcome": "applied"}))
}

#[cfg(test)]
#[path = "stream_priority_tests.rs"]
mod tests;
