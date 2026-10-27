//! The output of a snapshot viewer (`terminal-snapshot-v1`): READY
//! snapshots, live output, history and images chunks and the idle digest.
//!
//! A legacy viewer runs it on its own `mux-snapshot-attach-out` thread,
//! blocked on the viewer's queue. A viewer on a client-minted attach stream
//! runs it as a drain on the daemon-wide sequenced pool and holds no thread
//! (p05-ipc-079); its idle digest is a delayed task of its sequence, aligned
//! to the daemon's wake grid so the digests of many idle viewers share one
//! wake (Chrome's `kAlignWakeUps`, base/message_pump.cc).

use std::sync::Arc;
use std::sync::mpsc::{RecvTimeoutError, TryRecvError};
use std::time::Instant;

use cmux_threads::checked::sync as waits;
use serde_json::{Value, json};

use super::{
    PendingTail, digest_json, frame_json, frame_output_len, local_ready_event, log_skipped_images,
    ready_event,
};
use crate::server::attach_lifecycle::attach_pump::{
    AttachPump, PumpTimer, Step, ViewDrain, ViewOut, ViewSource,
};
use crate::server::attach_lifecycle::{
    AttachCommit, AttachWorkerCommit, commit_client_attach_and_start_pump,
    commit_client_attach_and_start_worker,
};
use crate::server::attach_streams::StreamEndReason;
use crate::server::sequenced_pool::SequencePriority;
use crate::server::{
    MessageWriter, OutboundStream, detach_committed_attach, handle_attach_send_error,
    report_attach_overflow,
};
use crate::stream_interrupt::StreamInterrupt;
use crate::surface::snapshot_attach::{
    LocalReadySnapshot, SNAPSHOT_DIGEST_IDLE, SnapshotRequestGate,
};
use crate::surface::{AttachFrameReceiver, AttachLifecycle, ViewerEvent};
use crate::wake::{Policy, Ticks};
use crate::{Mux, Surface, SurfaceId};

/// Everything the attach worker needs.
pub(super) struct SnapshotWorker {
    pub(super) mux: Arc<Mux>,
    pub(super) client: u64,
    pub(super) surface_id: SurfaceId,
    pub(super) surface: Arc<Surface>,
    pub(super) writer: MessageWriter,
    pub(super) outbound_stream: OutboundStream,
    pub(super) receiver: AttachFrameReceiver,
    pub(super) lifecycle: AttachLifecycle,
    pub(super) gate: SnapshotRequestGate,
    pub(super) generation: u64,
    pub(super) offset: u64,
    /// History and images of the last READY not yet sent; a newer READY
    /// replaces them.
    pub(super) tail: Option<PendingTail>,
    /// The images cap when the viewer opted into images.
    pub(super) images_cap: Option<u64>,
    /// When the idle digest is due: set by output, cleared by a READY.
    pub(super) digest_at: Option<Instant>,
    /// The viewer is an attach stream: a drain on the sequenced pool, not
    /// a thread of its own.
    pub(super) on_pool: bool,
}

/// What the viewer's queue held.
enum Polled {
    Event(ViewerEvent),
    /// Nothing queued: a tail chunk or the due digest goes now.
    Nothing,
    /// The terminal is gone.
    Disconnected,
}

impl SnapshotWorker {
    /// Queues `value`. The legacy thread waits for room; a drain runs only
    /// while its stream has room, so it never waits.
    fn queue(&self, value: &Value) -> std::io::Result<()> {
        if self.on_pool {
            self.writer.send_stream(value, &self.outbound_stream)
        } else {
            self.writer.send_stream_backpressured(value, &self.outbound_stream)
        }
    }

    fn send(&self, value: &Value) -> bool {
        match self.queue(value) {
            Ok(()) => true,
            Err(error) => {
                handle_attach_send_error(&self.lifecycle, &error);
                false
            }
        }
    }

    fn send_snapshot(&mut self) -> bool {
        match self.surface.take_viewer_snapshot(&self.receiver, self.images_cap) {
            Ok(mut frame) => {
                self.gate.sent(Instant::now());
                self.generation = frame.generation;
                self.offset = frame.offset;
                log_skipped_images(self.surface_id, &frame);
                // The older READY's history and images no longer apply.
                self.tail = Some(PendingTail::of(&mut frame));
                self.send(&ready_event(self.surface_id, &frame).into_json())
            }
            Err(_) => {
                // The unfinished escape sequence is longer than the snapshot
                // continuation budget: retry at the next output; the viewer
                // stays attached.
                self.receiver.defer_snapshot();
                self.gate.sent(Instant::now());
                true
            }
        }
    }

    /// A local-history READY at a resize cut. It continues the viewer's
    /// stream only when the viewer holds a complete history to reflow and
    /// every byte before the cut; otherwise the viewer gets a READY with
    /// history at a new cut.
    fn send_local_ready(&mut self, ready: &LocalReadySnapshot) -> bool {
        // A viewer still owed the images of an older READY has none to keep.
        if self.tail.is_some() || self.offset != ready.frame.offset {
            return self.send_snapshot();
        }
        self.generation = ready.frame.generation;
        self.send(&local_ready_event(self.surface_id, ready).into_json())
    }

    /// One history or images chunk; the last one ends the pending tail. A
    /// history chunk that cannot be compressed ends this READY's tail (its
    /// images too: they need the history rows); the viewer stays attached
    /// and its next READY brings a complete history.
    fn send_tail_chunk(&mut self) -> bool {
        let Some(tail) = self.tail.as_mut() else { return true };
        match tail.next_chunk(self.surface_id) {
            Ok(Some((event, done))) => {
                let value = event.into_json();
                if done {
                    self.tail = None;
                }
                self.send(&value)
            }
            Ok(None) => {
                self.tail = None;
                true
            }
            Err(error) => {
                eprintln!(
                    "cmux-tui: surface {} snapshot history not sent (generation {}): {error}",
                    self.surface_id, tail.generation
                );
                self.tail = None;
                true
            }
        }
    }

    fn digest_due(&self) -> bool {
        self.digest_at.is_some_and(|deadline| Instant::now() >= deadline)
    }

    /// Sends the idle digest, if it is due.
    fn send_due_digest(&mut self) -> bool {
        if !self.digest_due() {
            return true;
        }
        self.digest_at = None;
        match self.surface.snapshot_digest() {
            // Output that arrived after the queue emptied reaches this viewer
            // next; a digest at an offset it has not reached would be a false
            // mismatch.
            Ok(digest) if (digest.generation, digest.offset) == (self.generation, self.offset) => {
                self.send(&digest_json(self.surface_id, &digest))
            }
            Ok(_) | Err(_) => true,
        }
    }

    /// Handles what the queue held. False ends the view.
    fn handle(&mut self, polled: Polled) -> bool {
        match polled {
            Polled::Event(ViewerEvent::Snapshot) => {
                self.digest_at = None;
                self.send_snapshot()
            }
            Polled::Event(ViewerEvent::LocalReady(ready)) => {
                self.digest_at = None;
                self.send_local_ready(&ready)
            }
            Polled::Event(ViewerEvent::Frame(frame)) => {
                self.offset += frame_output_len(&frame) as u64;
                if frame_output_len(&frame) > 0 {
                    self.digest_at = Some(Instant::now() + SNAPSHOT_DIGEST_IDLE);
                }
                match frame_json(self.surface_id, &frame, self.generation, self.offset) {
                    Some(value) => self.send(&value),
                    None => true,
                }
            }
            Polled::Nothing if self.tail.is_some() => self.send_tail_chunk(),
            Polled::Nothing => self.send_due_digest(),
            Polled::Disconnected => {
                self.lifecycle.cancel();
                if self.writer.is_open() {
                    let _ = self.queue(&json!({"event": "detached", "surface": self.surface_id}));
                }
                false
            }
        }
    }

    fn unregister(&self) {
        self.mux.control_clients.snapshot_viewers.unregister(
            self.client,
            self.surface_id,
            self.outbound_stream.id,
        );
    }

    /// The legacy thread: blocks on the viewer's queue; the only timed wait
    /// is the one-shot idle digest deadline set by the last output. While
    /// history is pending the queue is only polled: a queued event goes
    /// first, else one chunk. Images chunks follow the history chunks at the
    /// same priority.
    fn run(mut self) {
        let interrupt = StreamInterrupt::new();
        self.writer.register_interrupt(&interrupt);
        self.outbound_stream.register_interrupt(&interrupt);
        self.lifecycle.register_interrupt(&interrupt);
        self.receiver.wake_on(&interrupt);
        while self.writer.is_open()
            && self.outbound_stream.is_open()
            && !self.lifecycle.is_canceled()
        {
            let deadline = if self.tail.is_some() { Some(Instant::now()) } else { self.digest_at };
            let polled = match self.receiver.recv_viewer_event(&interrupt, deadline) {
                Ok(event) => Polled::Event(event),
                Err(RecvTimeoutError::Timeout) => Polled::Nothing,
                Err(RecvTimeoutError::Disconnected) => Polled::Disconnected,
            };
            if !self.handle(polled) {
                break;
            }
        }
        report_attach_overflow(
            &self.writer,
            self.surface_id,
            &self.lifecycle,
            &self.outbound_stream,
        );
        self.unregister();
        detach_committed_attach(&self.mux, self.client, self.surface_id, self.outbound_stream.id);
        self.writer.end_client_stream(&self.outbound_stream, StreamEndReason::Detached);
    }
}

/// Starts `worker` and commits its attach: on its own thread for a legacy
/// viewer, as a drain on the sequenced pool for an attach stream.
pub(super) fn start(worker: SnapshotWorker, commit: AttachCommit) -> anyhow::Result<()> {
    let (mux, client, surface, stream) =
        (worker.mux.clone(), worker.client, worker.surface_id, worker.outbound_stream.clone());
    if worker.on_pool {
        let pump = AttachPump::new(&mux.sequenced_pool, SequencePriority::Input);
        let out = ViewOut::bind(
            &pump,
            &mux,
            client,
            surface,
            &worker.writer,
            &stream,
            &commit.lifecycle,
            true,
        );
        worker.receiver.on_ready(pump.hook());
        pump.install(Box::new(ViewDrain { out, source: SnapshotSource { worker, wake_at: None } }));
        return commit_client_attach_and_start_pump(&mux, client, surface, stream.id, commit, pump);
    }
    let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
    let spawned =
        std::thread::Builder::new().name("mux-snapshot-attach-out".into()).spawn(move || {
            if waits::recv(&worker_committed).is_ok() {
                worker.run();
            } else {
                worker.unregister();
            }
        });
    let AttachCommit { lifecycle, changed, size_rollback } = commit;
    if let Err(error) = spawned {
        lifecycle.cancel();
        mux.control_clients.snapshot_viewers.unregister(client, surface, stream.id);
        crate::server::rollback_failed_attach(&mux, client, surface, stream.id, size_rollback);
        return Err(error.into());
    }
    commit_client_attach_and_start_worker(
        &mux,
        client,
        surface,
        stream.id,
        AttachWorkerCommit { start: worker_start, lifecycle, changed, size_rollback },
    )
}

/// A snapshot viewer of an attach stream.
struct SnapshotSource {
    worker: SnapshotWorker,
    /// When the delayed turn armed for the digest runs.
    wake_at: Option<Instant>,
}

impl SnapshotSource {
    /// A turn when the idle digest is due, unless one is armed already: the
    /// digest deadline only moves later, and an early turn arms the next.
    fn arm_digest(&mut self, timer: &PumpTimer<'_>) {
        let Some(due) = self.worker.digest_at else { return };
        let now = Instant::now();
        if self.wake_at.is_some_and(|wake| wake <= now) {
            self.wake_at = None;
        }
        if self.wake_at.is_some() {
            return;
        }
        let ticks = Ticks::now();
        let delay = crate::wake::deadline(
            ticks,
            due.saturating_duration_since(now),
            Policy::FlexibleNoSooner,
        )
        .wait_from(ticks);
        timer.wake_after(delay);
        self.wake_at = Some(now + delay);
    }
}

impl ViewSource for SnapshotSource {
    fn next(&mut self, _out: &mut ViewOut, timer: &PumpTimer<'_>) -> Step {
        let polled = match self.worker.receiver.try_viewer_event() {
            Ok(event) => Polled::Event(event),
            Err(TryRecvError::Empty) if self.worker.tail.is_some() || self.worker.digest_due() => {
                Polled::Nothing
            }
            Err(TryRecvError::Empty) => {
                self.arm_digest(timer);
                return Step::Empty;
            }
            Err(TryRecvError::Disconnected) => Polled::Disconnected,
        };
        if self.worker.handle(polled) { Step::Sent } else { Step::End }
    }

    fn end(self, _out: &ViewOut) {
        self.worker.unregister();
    }

    fn abandon(self, _out: &ViewOut) {
        self.worker.unregister();
    }
}
