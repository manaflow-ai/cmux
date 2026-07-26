use std::collections::VecDeque;
use std::io::Write;
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_tui_core::{Rect, SurfaceId};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use parking_lot::ReentrantMutex;

use super::graphics::{
    GraphicPlacement, GraphicsState, PROCESSING_FENCE_ID_BASE, processing_fence,
    processing_fence_id,
};

pub type StdoutLock = ReentrantMutex<()>;
const PROCESSING_FENCE_TIMEOUT: Duration = Duration::from_secs(1);
const LATE_FENCE_RESPONSE_GRACE: Duration = Duration::from_secs(4);
const MAX_RETIRED_FENCES: usize = 4;
const MAX_GRAPHICS_RESPONSE_EVENTS: usize = 128;

struct GraphicsSubmission {
    id: u64,
    session_generation: u64,
    placements: Vec<GraphicPlacement>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessedGraphic {
    pub surface: SurfaceId,
    pub rect: Rect,
    pub seq: u64,
    pub pointer_frame_seq: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GraphicsProcessing {
    pub id: u64,
    pub session_generation: u64,
    pub graphics: Vec<ProcessedGraphic>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GraphicsCompletion {
    Processed(GraphicsProcessing),
    TimedOut { id: u64, session_generation: u64 },
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct GraphicsFenceResponse {
    id: u32,
    ok: bool,
}

pub struct GraphicsFenceWaiter {
    responses: Receiver<GraphicsFenceResponse>,
    state: Arc<Mutex<GraphicsFenceState>>,
}

#[derive(Clone)]
pub struct GraphicsFenceNotifier {
    responses: SyncSender<GraphicsFenceResponse>,
    state: Arc<Mutex<GraphicsFenceState>>,
}

#[derive(Default)]
struct GraphicsFenceState {
    expected: u32,
    retired: VecDeque<RetiredGraphicsFence>,
}

struct RetiredGraphicsFence {
    id: u32,
    expires_at: Instant,
}

impl GraphicsFenceState {
    fn prune(&mut self, now: Instant) {
        self.retired.retain(|fence| fence.expires_at > now);
    }

    fn retire(&mut self, id: u32, now: Instant) {
        if id == 0 {
            return;
        }
        self.prune(now);
        self.retired.retain(|fence| fence.id != id);
        self.retired
            .push_back(RetiredGraphicsFence { id, expires_at: now + LATE_FENCE_RESPONSE_GRACE });
        while self.retired.len() > MAX_RETIRED_FENCES {
            self.retired.pop_front();
        }
    }

    fn candidates(&mut self, now: Instant) -> Vec<u32> {
        self.prune(now);
        let mut candidates =
            Vec::with_capacity(self.retired.len() + usize::from(self.expected != 0));
        if self.expected != 0 {
            candidates.push(self.expected);
        }
        for fence in &self.retired {
            if !candidates.contains(&fence.id) {
                candidates.push(fence.id);
            }
        }
        candidates
    }
}

pub fn graphics_fence_channel() -> (GraphicsFenceWaiter, GraphicsFenceNotifier) {
    let (responses, pending) = sync_channel(4);
    let state = Arc::new(Mutex::new(GraphicsFenceState::default()));
    (
        GraphicsFenceWaiter { responses: pending, state: state.clone() },
        GraphicsFenceNotifier { responses, state },
    )
}

impl GraphicsFenceWaiter {
    fn prepare(&self, expected: u32) {
        while self.responses.try_recv().is_ok() {}
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        if state.expected != 0 && state.expected != expected {
            let previous = state.expected;
            state.retire(previous, now);
        }
        state.expected = expected;
    }

    fn cancel(&self, expected: u32) {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        if state.expected == expected {
            state.expected = 0;
            state.retire(expected, now);
        }
    }

    fn wait_for(&self, expected: u32) -> std::io::Result<()> {
        let result = self.responses.recv_timeout(PROCESSING_FENCE_TIMEOUT).map_err(|error| {
            std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!("graphics processing fence timed out: {error}"),
            )
        });
        self.cancel(expected);
        let response = result?;
        if response.id != expected {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "graphics processing fence replied out of order: expected {expected}, got {}",
                    response.id
                ),
            ));
        }
        if !response.ok {
            return Err(std::io::Error::other(format!(
                "host rejected graphics processing fence {expected}"
            )));
        }
        Ok(())
    }
}

impl GraphicsFenceNotifier {
    fn candidate_ids(&self) -> Vec<u32> {
        self.state.lock().unwrap().candidates(Instant::now())
    }

    fn has_active_candidate(&self, candidates: &[u32]) -> bool {
        let state = self.state.lock().unwrap();
        state.expected != 0 && candidates.contains(&state.expected)
    }

    fn notify(&self, response: GraphicsFenceResponse) {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        state.prune(now);
        let active = state.expected == response.id;
        if active {
            state.expected = 0;
            state.retire(response.id, now);
        }
        drop(state);
        if active {
            let _ = self.responses.try_send(response);
        }
    }
}

struct BufferedGraphicsResponse {
    candidates: Vec<u32>,
    events: Vec<Event>,
    payload: String,
}

/// Crossterm exposes an APC reply as Alt+_ followed by ordinary key events and
/// Alt+\. Reassemble only complete Kitty graphics responses and leave every
/// other host input unchanged.
pub struct GraphicsResponseFilter {
    notifier: GraphicsFenceNotifier,
    buffered: Option<BufferedGraphicsResponse>,
}

impl GraphicsResponseFilter {
    pub fn new(notifier: GraphicsFenceNotifier) -> Self {
        Self { notifier, buffered: None }
    }

    pub fn filter(&mut self, event: Event) -> Vec<Event> {
        if self.buffered.as_ref().is_some_and(|buffered| {
            !self.notifier.has_active_candidate(&buffered.candidates)
                && !buffered.payload.is_empty()
                && !buffered.payload.starts_with('G')
        }) {
            let mut replay = self.buffered.take().unwrap().events;
            replay.extend(self.filter(event));
            return replay;
        }
        if self.buffered.is_none() {
            let candidates = self.notifier.candidate_ids();
            if !candidates.is_empty() && is_apc_boundary(&event, '_') {
                self.buffered = Some(BufferedGraphicsResponse {
                    candidates,
                    events: vec![event],
                    payload: String::new(),
                });
                return Vec::new();
            }
            return vec![event];
        }

        if is_apc_boundary(&event, '_') {
            let mut replay = self.buffered.take().unwrap().events;
            let candidates = self.notifier.candidate_ids();
            if candidates.is_empty() {
                replay.push(event);
            } else {
                self.buffered = Some(BufferedGraphicsResponse {
                    candidates,
                    events: vec![event],
                    payload: String::new(),
                });
            }
            return replay;
        }

        if is_apc_boundary(&event, '\\') {
            let mut buffered = self.buffered.take().unwrap();
            buffered.events.push(event);
            if let Some(response) = parse_graphics_response(&buffered.payload)
                && response.id >= PROCESSING_FENCE_ID_BASE
                && buffered.candidates.contains(&response.id)
            {
                self.notifier.notify(response);
                return Vec::new();
            }
            return buffered.events;
        }

        let Some(ch) = graphics_response_char(&event) else {
            let mut replay = self.buffered.take().unwrap().events;
            replay.push(event);
            return replay;
        };
        let buffered = self.buffered.as_mut().unwrap();
        buffered.events.push(event);
        if buffered.events.len() > MAX_GRAPHICS_RESPONSE_EVENTS {
            return self.buffered.take().unwrap().events;
        }
        buffered.payload.push(ch);
        Vec::new()
    }
}

fn is_apc_boundary(event: &Event, boundary: char) -> bool {
    matches!(
        event,
        Event::Key(KeyEvent {
            code: KeyCode::Char(ch),
            modifiers,
            kind: KeyEventKind::Press,
            ..
        }) if *ch == boundary && *modifiers == KeyModifiers::ALT
    )
}

fn graphics_response_char(event: &Event) -> Option<char> {
    let Event::Key(KeyEvent {
        code: KeyCode::Char(ch), modifiers, kind: KeyEventKind::Press, ..
    }) = event
    else {
        return None;
    };
    (*ch)
        .is_ascii()
        .then_some(*ch)
        .filter(|_| modifiers.is_empty() || *modifiers == KeyModifiers::SHIFT)
}

fn parse_graphics_response(payload: &str) -> Option<GraphicsFenceResponse> {
    let (control, message) = payload.strip_prefix('G')?.split_once(';')?;
    let id = control.split(',').find_map(|field| field.strip_prefix("i="))?.parse::<u32>().ok()?;
    Some(GraphicsFenceResponse { id, ok: message == "OK" })
}

trait ProcessingFence: Send + 'static {
    fn prepare(&mut self, _id: u32) {}
    fn cancel(&mut self, _id: u32) {}
    fn wait(&mut self, id: u32) -> std::io::Result<()>;
}

impl ProcessingFence for GraphicsFenceWaiter {
    fn prepare(&mut self, id: u32) {
        GraphicsFenceWaiter::prepare(self, id);
    }

    fn cancel(&mut self, id: u32) {
        GraphicsFenceWaiter::cancel(self, id);
    }

    fn wait(&mut self, id: u32) -> std::io::Result<()> {
        self.wait_for(id)
    }
}

#[cfg(test)]
struct ClosureProcessingFence<F>(F);

#[cfg(test)]
impl<F> ProcessingFence for ClosureProcessingFence<F>
where
    F: FnMut() -> std::io::Result<()> + Send + 'static,
{
    fn wait(&mut self, _id: u32) -> std::io::Result<()> {
        (self.0)()
    }
}

pub struct GraphicsWriter {
    slot: Arc<Mutex<Option<GraphicsSubmission>>>,
    completion: Arc<Mutex<Option<GraphicsCompletion>>>,
    notify: Option<SyncSender<()>>,
    done: Option<Receiver<()>>,
    handle: Option<JoinHandle<()>>,
}

impl GraphicsWriter {
    pub fn spawn(
        stdout_lock: Arc<StdoutLock>,
        processing_fence: GraphicsFenceWaiter,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        Self::spawn_with_fence(stdout_lock, std::io::stdout(), processing_fence, on_ready)
    }

    #[cfg(test)]
    fn spawn_with_output(
        stdout_lock: Arc<StdoutLock>,
        output: impl Write + Send + 'static,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        Self::spawn_with_output_and_fence(stdout_lock, output, || Ok(()), on_ready)
    }

    #[cfg(test)]
    fn spawn_with_output_and_fence(
        stdout_lock: Arc<StdoutLock>,
        output: impl Write + Send + 'static,
        processing_fence: impl FnMut() -> std::io::Result<()> + Send + 'static,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        Self::spawn_with_fence(
            stdout_lock,
            output,
            ClosureProcessingFence(processing_fence),
            on_ready,
        )
    }

    fn spawn_with_fence(
        stdout_lock: Arc<StdoutLock>,
        output: impl Write + Send + 'static,
        processing_fence: impl ProcessingFence,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        let (tx, rx) = sync_channel(1);
        let (done_tx, done_rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(None));
        let completion = Arc::new(Mutex::new(None));
        let handle = std::thread::Builder::new().name("mux-graphics-writer".into()).spawn({
            let slot = slot.clone();
            let completion = completion.clone();
            move || {
                writer_loop(WriterLoop {
                    slot,
                    completion,
                    rx,
                    stdout_lock,
                    output,
                    processing_fence_waiter: processing_fence,
                    on_ready,
                    done_tx,
                });
            }
        })?;
        Ok(Self { slot, completion, notify: Some(tx), done: Some(done_rx), handle: Some(handle) })
    }

    pub fn submit(
        &self,
        id: u64,
        session_generation: u64,
        placements: Vec<GraphicPlacement>,
    ) -> bool {
        let Some(tx) = &self.notify else { return false };
        submit_snapshot(&self.slot, tx, GraphicsSubmission { id, session_generation, placements })
    }

    pub fn take_completion(&self) -> Option<GraphicsCompletion> {
        self.completion.lock().unwrap().take()
    }

    pub fn shutdown(&mut self, timeout: Duration) {
        self.notify.take();
        let Some(handle) = self.handle.take() else { return };
        let Some(done) = self.done.take() else {
            let _ = handle.join();
            return;
        };
        match done.recv_timeout(timeout) {
            Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let _ = handle.join();
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                self.done = Some(done);
                self.handle = Some(handle);
            }
        }
    }
}

impl Drop for GraphicsWriter {
    fn drop(&mut self) {
        self.shutdown(Duration::from_millis(200));
    }
}

fn submit_snapshot(
    slot: &Arc<Mutex<Option<GraphicsSubmission>>>,
    tx: &SyncSender<()>,
    submission: GraphicsSubmission,
) -> bool {
    *slot.lock().unwrap() = Some(submission);
    match tx.try_send(()) {
        Ok(()) | Err(TrySendError::Full(())) => true,
        Err(TrySendError::Disconnected(())) => false,
    }
}

struct WriterLoop<W, P, F> {
    slot: Arc<Mutex<Option<GraphicsSubmission>>>,
    completion: Arc<Mutex<Option<GraphicsCompletion>>>,
    rx: Receiver<()>,
    stdout_lock: Arc<StdoutLock>,
    output: W,
    processing_fence_waiter: P,
    on_ready: F,
    done_tx: SyncSender<()>,
}

fn writer_loop<W, P, F>(worker: WriterLoop<W, P, F>)
where
    W: Write,
    P: ProcessingFence,
    F: Fn(),
{
    let WriterLoop {
        slot,
        completion,
        rx,
        stdout_lock,
        mut output,
        mut processing_fence_waiter,
        on_ready,
        done_tx,
    } = worker;
    let _done = DoneOnDrop(done_tx);
    let mut graphics = GraphicsState::default();
    while rx.recv().is_ok() {
        loop {
            let next = slot.lock().unwrap().take();
            let Some(submission) = next else { break };
            let processed_graphics = submission
                .placements
                .iter()
                .map(|placement| ProcessedGraphic {
                    surface: placement.surface,
                    rect: placement.rect,
                    seq: placement.seq,
                    pointer_frame_seq: placement.pointer_frame_seq,
                })
                .collect();
            let batches =
                graphics.frame_batches(submission.session_generation, &submission.placements);
            let fence_id = processing_fence_id(submission.id);
            processing_fence_waiter.prepare(fence_id);
            let output_result = {
                let _guard = stdout_lock.lock();
                let mut result = Ok(());
                for batch in batches {
                    if result.is_ok() {
                        result = output.write_all(&batch);
                    }
                }
                if result.is_ok() {
                    result = output.write_all(&processing_fence(fence_id));
                }
                if result.is_ok() {
                    result = output.flush();
                }
                result
            };
            if output_result.is_err() {
                processing_fence_waiter.cancel(fence_id);
                *completion.lock().unwrap() = Some(GraphicsCompletion::Failed);
                on_ready();
                return;
            }
            let mut processed = processing_fence_waiter.wait(fence_id);
            if processed.as_ref().is_err_and(|error| error.kind() == std::io::ErrorKind::TimedOut) {
                // The graphics bytes were written successfully. A second
                // ordered query distinguishes a delayed response from a
                // failed output stream without retransmitting image data.
                processing_fence_waiter.prepare(fence_id);
                let retry_output = {
                    let _guard = stdout_lock.lock();
                    output.write_all(&processing_fence(fence_id)).and_then(|()| output.flush())
                };
                if retry_output.is_err() {
                    processing_fence_waiter.cancel(fence_id);
                    *completion.lock().unwrap() = Some(GraphicsCompletion::Failed);
                    on_ready();
                    return;
                }
                processed = processing_fence_waiter.wait(fence_id);
            }
            if let Err(error) = processed {
                processing_fence_waiter.cancel(fence_id);
                if error.kind() == std::io::ErrorKind::TimedOut {
                    // Keep graphics enabled, but discard all unconfirmed
                    // processing state so the app can redraw and retransmit.
                    graphics = GraphicsState::default();
                    *completion.lock().unwrap() = Some(GraphicsCompletion::TimedOut {
                        id: submission.id,
                        session_generation: submission.session_generation,
                    });
                    on_ready();
                    continue;
                }
                *completion.lock().unwrap() = Some(GraphicsCompletion::Failed);
                on_ready();
                return;
            }
            *completion.lock().unwrap() = Some(GraphicsCompletion::Processed(GraphicsProcessing {
                id: submission.id,
                session_generation: submission.session_generation,
                graphics: processed_graphics,
            }));
            on_ready();
        }
    }
}

struct DoneOnDrop(SyncSender<()>);

impl Drop for DoneOnDrop {
    fn drop(&mut self) {
        let _ = self.0.try_send(());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tui_core::Rect;

    struct FailingOutput;

    impl Write for FailingOutput {
        fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
            Err(std::io::Error::other("injected graphics output failure"))
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn key(ch: char, modifiers: KeyModifiers) -> Event {
        Event::Key(KeyEvent::new(KeyCode::Char(ch), modifiers))
    }

    #[test]
    fn kitty_graphics_response_completes_matching_processing_fence() {
        let (waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let id = processing_fence_id(11);
        waiter.prepare(id);
        let response = format!("Gi={id};OK");
        let wire_events = std::iter::once(key('_', KeyModifiers::ALT))
            .chain(response.chars().map(|ch| {
                key(ch, if ch.is_uppercase() { KeyModifiers::SHIFT } else { KeyModifiers::NONE })
            }))
            .chain(std::iter::once(key('\\', KeyModifiers::ALT)));

        assert!(wire_events.flat_map(|event| filter.filter(event)).next().is_none());
        waiter.wait_for(id).unwrap();
    }

    #[test]
    fn non_graphics_apc_input_is_replayed_losslessly() {
        let (_waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let events = vec![
            key('_', KeyModifiers::ALT),
            key('x', KeyModifiers::NONE),
            key('\\', KeyModifiers::ALT),
        ];

        let replayed =
            events.clone().into_iter().flat_map(|event| filter.filter(event)).collect::<Vec<_>>();

        assert_eq!(replayed, events);
    }

    #[test]
    fn canceled_processing_fence_replays_buffered_apc_input() {
        let (waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let id = processing_fence_id(12);
        waiter.prepare(id);
        let boundary = key('_', KeyModifiers::ALT);
        let buffered = key('x', KeyModifiers::NONE);
        assert!(filter.filter(boundary.clone()).is_empty());
        assert!(filter.filter(buffered.clone()).is_empty());

        waiter.cancel(id);
        let following = key('z', KeyModifiers::NONE);

        assert_eq!(
            filter.filter(following.clone()),
            vec![boundary, buffered, following],
            "canceling a fence must stop its partial APC from consuming later input"
        );
    }

    #[test]
    fn late_canceled_processing_fence_reply_is_consumed() {
        let (waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let id = processing_fence_id(13);
        waiter.prepare(id);
        waiter.cancel(id);
        let response = format!("Gi={id};OK");
        let replayed = std::iter::once(key('_', KeyModifiers::ALT))
            .chain(response.chars().map(|ch| {
                key(ch, if ch.is_uppercase() { KeyModifiers::SHIFT } else { KeyModifiers::NONE })
            }))
            .chain(std::iter::once(key('\\', KeyModifiers::ALT)))
            .flat_map(|event| filter.filter(event))
            .collect::<Vec<_>>();

        assert!(
            replayed.is_empty(),
            "a late terminal response for a canceled fence must not become user input"
        );
    }

    #[test]
    fn kitty_query_acknowledges_processing_not_presentation() {
        let production = |source: &'static str| {
            source.split("\n#[cfg(test)]\nmod tests {").next().expect("production graphics source")
        };
        let graphics_source = production(include_str!("graphics.rs"));
        let writer_source = production(include_str!("graphics_writer.rs"));
        assert!(
            !graphics_source.contains("presentation_fence")
                && !writer_source.contains("GraphicsPresentation")
                && !writer_source.contains("Presented("),
            "a Kitty query reply proves command processing, not compositor presentation"
        );
    }

    #[test]
    fn snapshot_slot_is_latest_wins_and_shutdown_is_clean() {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(None));
        submit_snapshot(
            &slot,
            &tx,
            GraphicsSubmission {
                id: 1,
                session_generation: 1,
                placements: vec![GraphicPlacement {
                    surface: 1,
                    rect: Rect { x: 0, y: 0, width: 10, height: 5 },
                    seq: 1,
                    pointer_frame_seq: Some(1),
                    data_b64: "AAAA".to_string(),
                }],
            },
        );
        submit_snapshot(
            &slot,
            &tx,
            GraphicsSubmission {
                id: 2,
                session_generation: 1,
                placements: vec![GraphicPlacement {
                    surface: 1,
                    rect: Rect { x: 1, y: 1, width: 11, height: 6 },
                    seq: 2,
                    pointer_frame_seq: Some(1),
                    data_b64: "BBBB".to_string(),
                }],
            },
        );

        let latest = slot.lock().unwrap().take().expect("latest snapshot");
        assert_eq!(latest.id, 2);
        assert_eq!(latest.placements.len(), 1);
        assert_eq!(latest.placements[0].seq, 2);
        assert_eq!(latest.placements[0].rect.x, 1);
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(rx.try_recv().is_err());

        let lock = Arc::new(StdoutLock::new(()));
        let (fence, _notifier) = graphics_fence_channel();
        let mut writer = GraphicsWriter::spawn(lock, fence, || {}).unwrap();
        writer.shutdown(Duration::from_secs(1));
        assert!(writer.handle.as_ref().is_none_or(|handle| handle.is_finished()));
    }

    #[test]
    fn processing_completion_waits_for_host_fence_after_stdout_flush() {
        let lock = Arc::new(StdoutLock::new(()));
        let held = lock.lock();
        let (processed_tx, processed_rx) = std::sync::mpsc::channel();
        let (fence_entered_tx, fence_entered_rx) = std::sync::mpsc::channel();
        let (fence_release_tx, fence_release_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock.clone(),
            Vec::new(),
            move || {
                fence_entered_tx.send(()).unwrap();
                fence_release_rx.recv().unwrap();
                Ok(())
            },
            move || {
                processed_tx.send(()).unwrap();
            },
        )
        .unwrap();

        assert!(writer.submit(
            7,
            1,
            vec![GraphicPlacement {
                surface: 11,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 13,
                pointer_frame_seq: Some(8),
                data_b64: "AAAA".to_string(),
            }]
        ));
        assert!(
            processed_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "submission must not complete while output is blocked"
        );

        drop(held);
        fence_entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            lock.try_lock().is_some(),
            "waiting for a graphics response must not monopolize terminal output"
        );
        assert_eq!(
            writer.take_completion(),
            None,
            "stdout flush alone must not complete the ordered submission"
        );
        assert!(
            processed_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "the app must wait until the host acknowledges command processing"
        );

        fence_release_tx.send(()).unwrap();
        processed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(
            writer.take_completion(),
            Some(GraphicsCompletion::Processed(GraphicsProcessing {
                id: 7,
                session_generation: 1,
                graphics: vec![ProcessedGraphic {
                    surface: 11,
                    rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                    seq: 13,
                    pointer_frame_seq: Some(8),
                }],
            }))
        );
        writer.shutdown(Duration::from_secs(1));
    }

    #[test]
    fn transient_processing_timeout_retries_without_stopping_writer() {
        let lock = Arc::new(StdoutLock::new(()));
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock,
            Vec::new(),
            move || {
                if attempts.fetch_add(1, std::sync::atomic::Ordering::AcqRel) == 0 {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "injected transient fence timeout",
                    ))
                } else {
                    Ok(())
                }
            },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let placement = |seq| GraphicPlacement {
            surface: 11,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq,
            pointer_frame_seq: Some(seq),
            data_b64: "AAAA".to_string(),
        };

        assert!(writer.submit(9, 1, vec![placement(15)]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let first_processed = matches!(
            writer.take_completion(),
            Some(GraphicsCompletion::Processed(GraphicsProcessing { id: 9, .. }))
        );
        let second_accepted = writer.submit(10, 1, vec![placement(16)]);
        let second_processed = if second_accepted {
            ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            matches!(
                writer.take_completion(),
                Some(GraphicsCompletion::Processed(GraphicsProcessing { id: 10, .. }))
            )
        } else {
            false
        };
        writer.shutdown(Duration::from_secs(1));

        assert!(first_processed, "one fence timeout must retry the accepted submission");
        assert!(second_accepted, "a transient timeout must not stop the graphics writer");
        assert!(second_processed, "the writer must process later graphics after recovery");
    }

    #[test]
    fn exhausted_processing_timeout_remains_recoverable() {
        let lock = Arc::new(StdoutLock::new(()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock,
            Vec::new(),
            || {
                Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "injected persistent fence timeout",
                ))
            },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let placement = |seq| GraphicPlacement {
            surface: 11,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq,
            pointer_frame_seq: Some(seq),
            data_b64: "AAAA".to_string(),
        };

        assert!(writer.submit(11, 1, vec![placement(17)]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let completion = writer.take_completion();
        let later_accepted = writer.submit(12, 1, vec![placement(18)]);
        if later_accepted {
            ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        writer.shutdown(Duration::from_secs(1));

        assert!(
            completion.is_some() && !matches!(completion, Some(GraphicsCompletion::Failed)),
            "an exhausted fence timeout must request recovery without disabling graphics"
        );
        assert!(later_accepted, "the writer must remain available for a later re-probe");
    }

    #[test]
    fn output_failure_notifies_the_app_to_settle_the_submission() {
        let lock = Arc::new(StdoutLock::new(()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output(lock, FailingOutput, move || {
            ready_tx.send(()).unwrap();
        })
        .unwrap();

        assert!(writer.submit(
            9,
            1,
            vec![GraphicPlacement {
                surface: 11,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 15,
                pointer_frame_seq: Some(9),
                data_b64: "AAAA".to_string(),
            }]
        ));
        ready_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("a failed accepted submission must wake the app");
        assert_eq!(writer.take_completion(), Some(GraphicsCompletion::Failed));
        writer.shutdown(Duration::from_secs(1));
    }
}
