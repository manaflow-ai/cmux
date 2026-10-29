//! The output of a snapshot viewer (`terminal-snapshot-v1`): READY
//! snapshots, live output, history and images chunks and the idle digest.
//!
//! Every viewer, legacy or on a client-minted attach stream, runs it as a
//! drain on the daemon-wide sequenced pool and holds no thread,
//! at its connection's view priority
//! (`ConnectionClass::view_priority`: the person's viewers on the input
//! workers, automation's on the utility workers). Its idle digest is a
//! delayed task of its sequence, aligned to the daemon's wake grid so the
//! digests of many idle viewers share one wake (Chrome's `kAlignWakeUps`,
//! base/message_pump.cc).
//!
//! The drain only hands items over. A viewer's bulk work (the READY's
//! COMPLETE encode under the terminal lock, each history or images chunk
//! with its DEFLATE and base64) runs on a utility sequence of the viewer's
//! own and posts its encoded text back to the drain, which sends it in
//! order. A resync of many viewers (a window resize, a workspace of deep
//! scrollbacks) then never takes the input workers that carry the focused
//! terminal's echo, as Chrome posts bulk work to the pool at a lower
//! priority and replies to the owning sequence
//! (base/task/post_task_and_reply_with_result.h). One bulk job runs at a
//! time: a READY holds the viewer's frames until it is sent; live frames
//! overtake a history chunk.

use std::sync::Arc;
use std::sync::mpsc::{self, TryRecvError};
use std::time::Instant;

use serde_json::{Value, json};

use super::{
    PendingTail, digest_json, frame_json, frame_output_len, local_ready_event, log_skipped_images,
    ready_event,
};
use crate::server::BudgetedText;
use crate::server::WatchKind;
use crate::server::attach_lifecycle::attach_pump::{
    AttachPump, PumpTimer, Step, ViewDrain, ViewOut, ViewSource,
};
use crate::server::attach_lifecycle::{AttachCommit, commit_client_attach_and_start_pump};
use crate::server::sequenced_pool::{PostError, Sequence, SequencePriority};
use crate::server::stream_priority::follow_visibility;
use crate::server::{MessageWriter, OutboundStream, handle_attach_send_error};
use crate::surface::snapshot_attach::{
    LocalReadySnapshot, SNAPSHOT_DIGEST_IDLE, SnapshotRequestGate,
};
use crate::surface::{AttachFrame, AttachFrameReceiver, AttachLifecycle, ViewerEvent};
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
    /// Shared with the viewer's bulk jobs, which take its snapshots.
    pub(super) receiver: Arc<AttachFrameReceiver>,
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
}

impl SnapshotWorker {
    /// Queues `value`. The drain runs only while its stream has room, so it
    /// never waits.
    fn send(&self, value: &Value) -> bool {
        self.sent(self.writer.send_stream(value, &self.outbound_stream))
    }

    /// Queues text a bulk job encoded.
    fn send_encoded(&self, encoded: std::io::Result<Arc<BudgetedText>>) -> bool {
        self.sent(self.writer.send_encoded_stream(encoded, &self.outbound_stream))
    }

    fn sent(&self, result: std::io::Result<()>) -> bool {
        match result {
            Ok(()) => true,
            Err(error) => {
                handle_attach_send_error(&self.lifecycle, &error);
                false
            }
        }
    }

    /// What a bulk job of this viewer reads.
    fn bulk_context(&self) -> BulkContext {
        BulkContext {
            surface_id: self.surface_id,
            surface: self.surface.clone(),
            receiver: self.receiver.clone(),
            gate: self.gate.clone(),
            images_cap: self.images_cap,
            writer: self.writer.clone(),
            stream: self.outbound_stream.clone(),
        }
    }

    /// Takes in what a bulk job did and sends its text. False ends the view.
    fn apply(&mut self, done: BulkDone) -> bool {
        match done {
            BulkDone::Ready { generation, offset, tail, text } => {
                self.generation = generation;
                self.offset = offset;
                // The older READY's history and images no longer apply.
                self.tail = Some(tail);
                self.send_encoded(text)
            }
            // The unfinished escape sequence is longer than the snapshot
            // continuation budget: the receiver retries at the next output;
            // the viewer stays attached.
            BulkDone::Deferred => true,
            BulkDone::LocalReady { generation, text } => {
                self.generation = generation;
                self.send_encoded(text)
            }
            BulkDone::Chunk { tail, text } => {
                self.tail = tail;
                text.is_none_or(|text| self.send_encoded(text))
            }
        }
    }

    /// Live output, at the viewer's position after it.
    fn send_frame(&mut self, frame: &AttachFrame) -> bool {
        self.offset += frame_output_len(frame) as u64;
        if frame_output_len(frame) > 0 {
            self.digest_at = Some(Instant::now() + SNAPSHOT_DIGEST_IDLE);
        }
        match frame_json(self.surface_id, frame, self.generation, self.offset) {
            Some(value) => self.send(&value),
            None => true,
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

    /// The terminal is gone: the view says so before it ends.
    fn disconnected(&self) {
        self.lifecycle.cancel();
        if self.writer.is_open() {
            let _ = self.writer.send_stream(
                &json!({"event": "detached", "surface": self.surface_id}),
                &self.outbound_stream,
            );
        }
    }

    fn unregister(&self) {
        self.mux.control_clients.snapshot_viewers.unregister(
            self.client,
            self.surface_id,
            self.outbound_stream.id,
        );
    }
}

/// A viewer's bulk work.
enum BulkJob {
    /// The READY the viewer owes, with its history and images to follow.
    Ready,
    /// A local-history READY at a resize cut.
    LocalReady(Arc<LocalReadySnapshot>),
    /// The next history or images chunk of the pending READY.
    Chunk(PendingTail),
}

/// What a bulk job hands back to the viewer's drain.
enum BulkDone {
    Ready {
        generation: u64,
        offset: u64,
        tail: PendingTail,
        text: std::io::Result<Arc<BudgetedText>>,
    },
    /// The snapshot could not be encoded now.
    Deferred,
    LocalReady {
        generation: u64,
        text: std::io::Result<Arc<BudgetedText>>,
    },
    /// `tail` is what is left of it (`None` once it is done or failed);
    /// `text` the chunk, if there was one.
    Chunk {
        tail: Option<PendingTail>,
        text: Option<std::io::Result<Arc<BudgetedText>>>,
    },
}

/// What a bulk job reads: the viewer's terminal and queue, and the stream
/// it encodes for.
struct BulkContext {
    surface_id: SurfaceId,
    surface: Arc<Surface>,
    receiver: Arc<AttachFrameReceiver>,
    gate: SnapshotRequestGate,
    images_cap: Option<u64>,
    writer: MessageWriter,
    stream: OutboundStream,
}

impl BulkContext {
    fn run(&self, job: BulkJob) -> BulkDone {
        match job {
            BulkJob::Ready => self.ready(),
            BulkJob::LocalReady(ready) => BulkDone::LocalReady {
                generation: ready.frame.generation,
                text: self.encode(&local_ready_event(self.surface_id, &ready).into_json()),
            },
            BulkJob::Chunk(tail) => self.chunk(tail),
        }
    }

    fn encode(&self, value: &Value) -> std::io::Result<Arc<BudgetedText>> {
        self.writer.encode(value, &self.stream)
    }

    /// One COMPLETE encode at one cut (`Surface::take_viewer_snapshot`):
    /// the READY, and the history and images that follow it.
    fn ready(&self) -> BulkDone {
        match self.surface.take_viewer_snapshot(&self.receiver, self.images_cap) {
            Ok(mut frame) => {
                self.gate.sent(Instant::now());
                log_skipped_images(self.surface_id, &frame);
                let tail = PendingTail::of(&mut frame);
                let text = self.encode(&ready_event(self.surface_id, &frame).into_json());
                BulkDone::Ready { generation: frame.generation, offset: frame.offset, tail, text }
            }
            Err(_) => {
                self.receiver.defer_snapshot();
                self.gate.sent(Instant::now());
                BulkDone::Deferred
            }
        }
    }

    /// One history or images chunk; the last one ends the pending tail. A
    /// history chunk that cannot be compressed ends this READY's tail (its
    /// images too: they need the history rows); the viewer stays attached
    /// and its next READY brings a complete history.
    fn chunk(&self, mut tail: PendingTail) -> BulkDone {
        let (text, done) = match tail.next_chunk(self.surface_id) {
            Ok(Some((event, done))) => (Some(self.encode(&event.into_json())), done),
            Ok(None) => (None, true),
            Err(error) => {
                eprintln!(
                    "cmux-tui: surface {} snapshot history not sent (generation {}): {error}",
                    self.surface_id, tail.generation
                );
                (None, true)
            }
        };
        BulkDone::Chunk { tail: (!done).then_some(tail), text }
    }
}

/// Which bulk job is out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum InFlight {
    /// A READY: the viewer's frames follow it, so they wait.
    Ready,
    /// A history or images chunk: live frames overtake it.
    Chunk,
}

/// The viewer's utility sequence and the way back to its drain.
struct BulkLane {
    sequence: Sequence,
    done: mpsc::Sender<BulkDone>,
    results: mpsc::Receiver<BulkDone>,
    /// The pump's hook: a finished job wakes the drain.
    wake: Arc<dyn Fn() + Send + Sync>,
    in_flight: Option<InFlight>,
}

impl BulkLane {
    fn new(sequence: Sequence, wake: Arc<dyn Fn() + Send + Sync>) -> Self {
        let (done, results) = mpsc::channel();
        Self { sequence, done, results, wake, in_flight: None }
    }

    fn post(&mut self, context: BulkContext, job: BulkJob) -> Result<(), PostError> {
        let kind = match job {
            BulkJob::Chunk(_) => InFlight::Chunk,
            BulkJob::Ready | BulkJob::LocalReady(_) => InFlight::Ready,
        };
        let (done, wake) = (self.done.clone(), self.wake.clone());
        self.sequence.post(move || {
            // A view that ended takes nothing more.
            if !context.stream.is_open() {
                return;
            }
            if done.send(context.run(job)).is_ok() {
                wake();
            }
        })?;
        self.in_flight = Some(kind);
        Ok(())
    }

    /// The finished job's result, once it is back.
    fn take_done(&mut self) -> Option<BulkDone> {
        let done = self.results.try_recv().ok()?;
        self.in_flight = None;
        Some(done)
    }
}

/// Starts `worker` as a drain on the sequenced pool, at its connection's
/// view priority with its bulk work at utility, and commits its attach.
pub(super) fn start(worker: SnapshotWorker, commit: AttachCommit) -> anyhow::Result<()> {
    let (mux, client, surface, stream) =
        (worker.mux.clone(), worker.client, worker.surface_id, worker.outbound_stream.clone());
    let priority = mux.control_clients.connection_class(client).get().view_priority();
    let pump = AttachPump::new(&mux.sequenced_pool, priority);
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
    follow_visibility(&stream, &pump, Some(worker.receiver.visibility_handle()));
    let wake: Arc<dyn Fn() + Send + Sync> = Arc::new(pump.hook());
    let bulk = BulkLane::new(mux.sequenced_pool.sequence(SequencePriority::Utility), wake);
    let source = SnapshotSource { worker, wake_at: None, bulk, held: None };
    pump.install(Box::new(ViewDrain::new(out, source)));
    commit_client_attach_and_start_pump(&mux, client, surface, stream.id, commit, pump)
}

/// A snapshot viewer's source.
struct SnapshotSource {
    worker: SnapshotWorker,
    /// When the delayed turn armed for the digest runs.
    wake_at: Option<Instant>,
    bulk: BulkLane,
    /// A local-history READY that waits for the chunk in flight: whether it
    /// can be sent depends on what is left of the history.
    held: Option<Arc<LocalReadySnapshot>>,
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

    /// Posts `job` to the viewer's utility sequence. A pool that cannot run
    /// it (shut down, no worker) ends the view.
    fn dispatch(&mut self, job: BulkJob) -> Step {
        match self.bulk.post(self.worker.bulk_context(), job) {
            Ok(()) => Step::Sent,
            Err(error) => {
                eprintln!(
                    "cmux-tui: surface {} snapshot viewer ends: {error}",
                    self.worker.surface_id
                );
                Step::End
            }
        }
    }

    /// A local-history READY continues the viewer's stream only when the
    /// viewer holds a complete history to reflow and every byte before the
    /// cut; otherwise the viewer gets a READY with history at a new cut. A
    /// viewer still owed the images of an older READY has none to keep.
    fn local_ready(&mut self, ready: Arc<LocalReadySnapshot>) -> Step {
        if self.worker.tail.is_some() || self.worker.offset != ready.frame.offset {
            return self.dispatch(BulkJob::Ready);
        }
        self.dispatch(BulkJob::LocalReady(ready))
    }
}

fn step(live: bool) -> Step {
    if live { Step::Sent } else { Step::End }
}

impl ViewSource for SnapshotSource {
    const WATCH: WatchKind = WatchKind::SnapshotAttachOut;

    /// Each item is a hand-off: a frame, a digest, or the text a bulk job
    /// encoded. A queued event goes before the next chunk.
    fn next(&mut self, out: &mut ViewOut, timer: &PumpTimer<'_>) -> Step {
        // Hidden (`set-stream-priority`): no output, chunk or digest until
        // it shows; its viewer queue holds nothing meanwhile, and a bulk job
        // that comes back waits for it. Its surface closing still ends it
        // (`detached`, then `stream-end`): the tap's drop wakes every
        // viewer, hidden or not.
        if out.stream.visibility.is_hidden() {
            if !self.worker.receiver.is_disconnected() {
                return Step::Empty;
            }
            self.worker.disconnected();
            return Step::End;
        }
        if let Some(done) = self.bulk.take_done() {
            return step(self.worker.apply(done));
        }
        match self.bulk.in_flight {
            Some(InFlight::Ready) => return Step::Empty,
            Some(InFlight::Chunk) if self.held.is_some() => return Step::Empty,
            Some(InFlight::Chunk) => {}
            None => {
                if let Some(ready) = self.held.take() {
                    return self.local_ready(ready);
                }
            }
        }
        let busy = self.bulk.in_flight.is_some();
        match self.worker.receiver.try_viewer_event() {
            Ok(ViewerEvent::Frame(frame)) => step(self.worker.send_frame(&frame)),
            Ok(ViewerEvent::Snapshot) => {
                self.worker.digest_at = None;
                // The chunk in flight comes back first; the READY then
                // replaces what is left of its history.
                if busy { Step::Empty } else { self.dispatch(BulkJob::Ready) }
            }
            Ok(ViewerEvent::LocalReady(ready)) => {
                self.worker.digest_at = None;
                if busy {
                    self.held = Some(ready);
                    return Step::Empty;
                }
                self.local_ready(ready)
            }
            Err(TryRecvError::Empty) if busy => Step::Empty,
            Err(TryRecvError::Empty) => {
                if let Some(tail) = self.worker.tail.take() {
                    return self.dispatch(BulkJob::Chunk(tail));
                }
                if self.worker.digest_due() {
                    return step(self.worker.send_due_digest());
                }
                self.arm_digest(timer);
                Step::Empty
            }
            Err(TryRecvError::Disconnected) => {
                self.worker.disconnected();
                Step::End
            }
        }
    }

    fn end(self, _out: &ViewOut) {
        self.worker.unregister();
    }

    fn abandon(self, _out: &ViewOut) {
        self.worker.unregister();
    }
}

#[cfg(all(test, unix))]
#[path = "snapshot_attach_out_tests.rs"]
mod tests;
