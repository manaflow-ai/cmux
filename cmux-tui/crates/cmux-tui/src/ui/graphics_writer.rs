use std::io;
#[cfg(any(test, not(unix)))]
use std::io::Write;
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread::{JoinHandle, ThreadId};
use std::time::Duration;

use super::graphics::{GraphicPlacement, GraphicsState};

/// Bound one stdout-lock hold while preserving complete Kitty APC commands.
/// This lets ordinary terminal draws make progress during multi-megabyte
/// image uploads without ever interleaving bytes inside one protocol command.
const MAX_LOCKED_GRAPHICS_WRITE_BYTES: usize = 64 * 1024;
#[cfg(unix)]
const OUTPUT_POLL_INTERVAL_MS: i32 = 20;

trait GraphicsOutput: Send + 'static {
    /// Write one complete group of Kitty APC commands. `Ok(false)` means
    /// cancellation won before the complete group was emitted.
    fn write_segment(&mut self, bytes: &[u8], control: &WriterControl) -> io::Result<bool>;
}

#[cfg(unix)]
struct InterruptibleStdout {
    fd: OwnedFd,
}

#[cfg(unix)]
impl InterruptibleStdout {
    fn open() -> io::Result<Self> {
        // `dup` would share file-status flags with stdout, so setting
        // O_NONBLOCK on the duplicate would also make ratatui's stdout
        // writes nonblocking. Opening the controlling terminal creates an
        // independent open-file description for the same terminal.
        let raw = unsafe {
            libc::open(c"/dev/tty".as_ptr(), libc::O_WRONLY | libc::O_NONBLOCK | libc::O_CLOEXEC)
        };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        Ok(Self { fd })
    }
}

#[cfg(unix)]
impl GraphicsOutput for InterruptibleStdout {
    fn write_segment(&mut self, bytes: &[u8], control: &WriterControl) -> io::Result<bool> {
        let mut offset = 0;
        while offset < bytes.len() {
            if control.is_cancelled() {
                return Ok(false);
            }
            let written = unsafe {
                libc::write(
                    self.fd.as_raw_fd(),
                    bytes[offset..].as_ptr().cast(),
                    bytes.len() - offset,
                )
            };
            if written > 0 {
                offset += written as usize;
                continue;
            }
            if written == 0 {
                return Err(io::Error::new(io::ErrorKind::WriteZero, "stdout accepted zero bytes"));
            }
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::EAGAIN) => {
                    let mut poll_fd =
                        libc::pollfd { fd: self.fd.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
                    let ready = unsafe { libc::poll(&mut poll_fd, 1, OUTPUT_POLL_INTERVAL_MS) };
                    if ready < 0 && io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                        return Err(io::Error::last_os_error());
                    }
                }
                _ => return Err(error),
            }
        }
        Ok(true)
    }
}

#[cfg(not(unix))]
struct InterruptibleStdout(std::io::Stdout);

#[cfg(not(unix))]
impl InterruptibleStdout {
    fn open() -> io::Result<Self> {
        Ok(Self(std::io::stdout()))
    }
}

#[cfg(not(unix))]
impl GraphicsOutput for InterruptibleStdout {
    fn write_segment(&mut self, bytes: &[u8], control: &WriterControl) -> io::Result<bool> {
        if control.is_cancelled() {
            return Ok(false);
        }
        self.0.write_all(bytes)?;
        self.0.flush()?;
        Ok(!control.is_cancelled())
    }
}

#[cfg(test)]
struct TestOutput<W>(W);

#[cfg(test)]
impl<W> GraphicsOutput for TestOutput<W>
where
    W: Write + Send + 'static,
{
    fn write_segment(&mut self, bytes: &[u8], control: &WriterControl) -> io::Result<bool> {
        if control.is_cancelled() {
            return Ok(false);
        }
        self.0.write_all(bytes)?;
        self.0.flush()?;
        Ok(!control.is_cancelled())
    }
}

#[derive(Default)]
struct PendingGraphics {
    placements: Option<Vec<GraphicPlacement>>,
    host_scene_epoch: u64,
}

struct PendingUpdate {
    placements: Option<Vec<GraphicPlacement>>,
    host_scene_epoch: u64,
}

#[derive(Default)]
struct WriterControlState {
    done: bool,
}

#[derive(Default)]
struct WriterControl {
    stop_requested: AtomicBool,
    cancelled: AtomicBool,
    worker_thread: OnceLock<ThreadId>,
    state: Mutex<WriterControlState>,
    changed: Condvar,
    #[cfg(test)]
    write_attempt_observer: Mutex<Option<SyncSender<()>>>,
}

impl WriterControl {
    fn request_stop(&self, notify: &SyncSender<()>) {
        self.stop_requested.store(true, Ordering::Release);
        notify_writer(notify);
    }

    fn request_cancel(&self, notify: &SyncSender<()>) {
        self.cancelled.store(true, Ordering::Release);
        self.changed.notify_all();
        notify_writer(notify);
    }

    fn is_stopping(&self) -> bool {
        self.stop_requested.load(Ordering::Acquire) || self.is_cancelled()
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    fn mark_done(&self) {
        self.state.lock().unwrap().done = true;
        self.changed.notify_all();
    }

    fn wait_done(&self) {
        let state = self.state.lock().unwrap();
        drop(self.changed.wait_while(state, |state| !state.done).unwrap());
    }

    fn wait_done_timeout(&self, timeout: Duration) -> bool {
        let state = self.state.lock().unwrap();
        if state.done {
            return true;
        }
        let (state, _) =
            self.changed.wait_timeout_while(state, timeout, |state| !state.done).unwrap();
        state.done
    }

    #[cfg(test)]
    fn wait_until_cancelled(&self) {
        let state = self.state.lock().unwrap();
        drop(self.changed.wait_while(state, |_| !self.cancelled.load(Ordering::Acquire)).unwrap());
    }

    #[cfg(test)]
    fn observe_write_attempts(&self, observer: SyncSender<()>) {
        *self.write_attempt_observer.lock().unwrap() = Some(observer);
    }

    #[cfg(test)]
    fn report_write_attempt(&self) {
        if let Some(observer) = self.write_attempt_observer.lock().unwrap().as_ref() {
            let _ = observer.try_send(());
        }
    }
}

#[derive(Clone)]
pub(crate) struct GraphicsWriterShutdown {
    control: Arc<WriterControl>,
    notify: SyncSender<()>,
}

impl GraphicsWriterShutdown {
    /// Stop the writer and wait until no future host-terminal writes are
    /// possible. This is safe to call from the process panic hook because the
    /// production writer uses a nonblocking descriptor and bounded poll loop.
    pub(crate) fn cancel_and_wait(&self) {
        self.control.request_cancel(&self.notify);
        if self
            .control
            .worker_thread
            .get()
            .is_none_or(|worker| *worker != std::thread::current().id())
        {
            self.control.wait_done();
        }
    }

    #[cfg(test)]
    fn wait_until_cancelled(&self) {
        self.control.wait_until_cancelled();
    }
}

pub struct GraphicsWriter {
    slot: Arc<Mutex<PendingGraphics>>,
    notify: Option<SyncSender<()>>,
    control: Arc<WriterControl>,
    handle: Option<JoinHandle<()>>,
}

impl GraphicsWriter {
    pub fn spawn(stdout_lock: Arc<Mutex<()>>) -> io::Result<Self> {
        Self::spawn_with_graphics_output(stdout_lock, InterruptibleStdout::open()?)
    }

    #[cfg(test)]
    fn spawn_with_output<W>(stdout_lock: Arc<Mutex<()>>, output: W) -> io::Result<Self>
    where
        W: Write + Send + 'static,
    {
        Self::spawn_with_graphics_output(stdout_lock, TestOutput(output))
    }

    fn spawn_with_graphics_output<O>(stdout_lock: Arc<Mutex<()>>, output: O) -> io::Result<Self>
    where
        O: GraphicsOutput,
    {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(PendingGraphics::default()));
        let control = Arc::new(WriterControl::default());
        let handle = std::thread::Builder::new().name("mux-graphics-writer".into()).spawn({
            let slot = slot.clone();
            let control = control.clone();
            move || writer_loop(slot, rx, stdout_lock, output, control)
        })?;
        Ok(Self { slot, notify: Some(tx), control, handle: Some(handle) })
    }

    pub(crate) fn shutdown_control(&self) -> GraphicsWriterShutdown {
        GraphicsWriterShutdown {
            control: self.control.clone(),
            notify: self.notify.as_ref().expect("active graphics writer").clone(),
        }
    }

    pub fn submit(&self, placements: Vec<GraphicPlacement>) {
        if self.control.is_stopping() {
            return;
        }
        let Some(tx) = &self.notify else { return };
        submit_snapshot(&self.slot, tx, placements);
    }

    /// Mark the host terminal's Kitty scene as cleared.
    ///
    /// The epoch remains in the latest-wins slot until the writer observes
    /// it, so later snapshot replacement cannot discard the invalidation.
    pub fn invalidate_host_scene(&self) {
        if self.control.is_stopping() {
            return;
        }
        let Some(tx) = &self.notify else { return };
        let mut pending = self.slot.lock().unwrap();
        pending.host_scene_epoch = pending.host_scene_epoch.wrapping_add(1);
        if pending.host_scene_epoch == 0 {
            pending.host_scene_epoch = 1;
        }
        drop(pending);
        notify_writer(tx);
    }

    pub fn shutdown(&mut self, timeout: Duration) {
        let Some(handle) = self.handle.take() else { return };
        let Some(notify) = self.notify.as_ref() else {
            let _ = handle.join();
            return;
        };
        self.control.request_stop(notify);
        if !self.control.wait_done_timeout(timeout) {
            self.control.request_cancel(notify);
            // The production stdout descriptor is nonblocking and polls
            // cancellation at most every OUTPUT_POLL_INTERVAL_MS.
            self.control.wait_done();
        }
        let _ = handle.join();
        self.notify.take();
    }
}

impl Drop for GraphicsWriter {
    fn drop(&mut self) {
        self.shutdown(Duration::from_millis(200));
    }
}

fn submit_snapshot(
    slot: &Arc<Mutex<PendingGraphics>>,
    tx: &SyncSender<()>,
    placements: Vec<GraphicPlacement>,
) {
    slot.lock().unwrap().placements = Some(placements);
    notify_writer(tx);
}

fn notify_writer(tx: &SyncSender<()>) {
    match tx.try_send(()) {
        Ok(()) | Err(TrySendError::Full(())) => {}
        Err(TrySendError::Disconnected(())) => {}
    }
}

fn take_pending_update(
    slot: &Arc<Mutex<PendingGraphics>>,
    applied_host_scene_epoch: u64,
) -> Option<PendingUpdate> {
    let mut pending = slot.lock().unwrap();
    if pending.placements.is_none() && pending.host_scene_epoch == applied_host_scene_epoch {
        return None;
    }
    Some(PendingUpdate {
        placements: pending.placements.take(),
        host_scene_epoch: pending.host_scene_epoch,
    })
}

fn writer_loop<O>(
    slot: Arc<Mutex<PendingGraphics>>,
    rx: Receiver<()>,
    stdout_lock: Arc<Mutex<()>>,
    mut output: O,
    control: Arc<WriterControl>,
) where
    O: GraphicsOutput,
{
    let _ = control.worker_thread.set(std::thread::current().id());
    let _done = DoneOnDrop(control.clone());
    let mut graphics = GraphicsState::default();
    let mut applied_host_scene_epoch = 0;
    'writer: loop {
        if control.is_cancelled() {
            break;
        }
        while let Some(update) = take_pending_update(&slot, applied_host_scene_epoch) {
            if update.host_scene_epoch != applied_host_scene_epoch {
                graphics.invalidate_host_scene();
                applied_host_scene_epoch = update.host_scene_epoch;
            }
            let Some(placements) = update.placements else {
                continue;
            };
            for batch in graphics.frame_batches(&placements) {
                if !write_batch(
                    &mut output,
                    &stdout_lock,
                    &slot,
                    update.host_scene_epoch,
                    &control,
                    &batch,
                ) {
                    break 'writer;
                }
            }
        }
        if control.stop_requested.load(Ordering::Acquire) {
            break;
        }
        if rx.recv().is_err() {
            break;
        }
    }
    if !control.is_cancelled() {
        for batch in graphics.frame_batches(&[]) {
            if !write_batch(
                &mut output,
                &stdout_lock,
                &slot,
                applied_host_scene_epoch,
                &control,
                &batch,
            ) {
                break;
            }
        }
    }
}

fn write_batch<O: GraphicsOutput>(
    output: &mut O,
    stdout_lock: &Arc<Mutex<()>>,
    slot: &Arc<Mutex<PendingGraphics>>,
    host_scene_epoch: u64,
    control: &WriterControl,
    batch: &[u8],
) -> bool {
    let mut offset = 0;
    while offset < batch.len() {
        if control.is_cancelled() {
            return false;
        }
        let Some(end) = next_graphics_write_end(batch, offset) else {
            return false;
        };
        #[cfg(test)]
        control.report_write_attempt();
        {
            let _guard = stdout_lock.lock().unwrap();
            if control.is_cancelled() {
                return false;
            }
            if slot.lock().unwrap().host_scene_epoch != host_scene_epoch {
                return true;
            }
            match output.write_segment(&batch[offset..end], control) {
                Ok(true) => {}
                Ok(false) | Err(_) => return false,
            }
        }
        offset = end;
    }
    true
}

fn next_graphics_write_end(batch: &[u8], start: usize) -> Option<usize> {
    let mut end = start;
    while end < batch.len() {
        let Some(terminator) = batch[end..]
            .windows(2)
            .position(|bytes| bytes == b"\x1b\\")
            .map(|offset| end + offset + 2)
        else {
            if end > start && !batch[end..].windows(3).any(|bytes| bytes == b"\x1b_G") {
                return Some(batch.len());
            }
            return (end > start).then_some(end);
        };
        if end > start && terminator - start > MAX_LOCKED_GRAPHICS_WRITE_BYTES {
            break;
        }
        end = terminator;
        if end - start >= MAX_LOCKED_GRAPHICS_WRITE_BYTES {
            break;
        }
    }
    (end > start).then_some(end)
}

struct DoneOnDrop(Arc<WriterControl>);

impl Drop for DoneOnDrop {
    fn drop(&mut self) {
        self.0.mark_done();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::graphics::{
        GraphicData, GraphicFormat, GraphicImage, GraphicImageKey, GraphicPlacementKey,
    };
    use cmux_tui_core::Rect;
    use ghostty_vt::{Callbacks, Terminal};
    use std::sync::atomic::{AtomicBool, Ordering};

    struct BlockingOutput {
        entered: SyncSender<()>,
        release: Receiver<()>,
        restored: Arc<AtomicBool>,
        writes_after_restore: Arc<Mutex<Vec<bool>>>,
    }

    impl Write for BlockingOutput {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let _ = self.entered.try_send(());
            self.release.recv().unwrap();
            self.writes_after_restore.lock().unwrap().push(self.restored.load(Ordering::Acquire));
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct ObservedOutput {
        bytes: Arc<Mutex<Vec<u8>>>,
        flushed: SyncSender<()>,
    }

    impl Write for ObservedOutput {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.bytes.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            let _ = self.flushed.try_send(());
            Ok(())
        }
    }

    fn rgba_placement(image_id: u32, generation: u64, x: u16, rgba: [u8; 4]) -> GraphicPlacement {
        let image_key = GraphicImageKey { namespace: 91, surface: 7, image_id };
        GraphicPlacement {
            key: GraphicPlacementKey { image: image_key, placement_id: 1, ordinal: 0 },
            image: Arc::new(GraphicImage {
                key: image_key,
                generation,
                width: 1,
                height: 1,
                format: GraphicFormat::Rgba,
                data: GraphicData::Bytes(Arc::from(rgba)),
            }),
            rect: Rect { x, y: 0, width: 1, height: 1 },
            columns: Some(1),
            rows: Some(1),
            source: None,
            x_offset: 0,
            y_offset: 0,
            z: 0,
        }
    }

    fn wait_for_output(
        flushed: &Receiver<()>,
        bytes: &Arc<Mutex<Vec<u8>>>,
        predicate: impl Fn(&[u8]) -> bool,
    ) {
        loop {
            flushed.recv_timeout(Duration::from_secs(2)).expect("graphics writer flush");
            if predicate(&bytes.lock().unwrap()) {
                return;
            }
        }
    }

    #[test]
    fn large_batches_split_only_between_complete_kitty_commands() {
        let command = |payload: u8| {
            let mut command = b"\x1b_Gq=2,m=1;".to_vec();
            command.extend(std::iter::repeat_n(payload, 4_096));
            command.extend_from_slice(b"\x1b\\");
            command
        };
        let commands = (0..40).map(command).collect::<Vec<_>>();
        let batch = commands.concat();

        let mut offset = 0;
        let mut segments = Vec::new();
        while offset < batch.len() {
            let end = next_graphics_write_end(&batch, offset).expect("complete Kitty segment");
            let segment = &batch[offset..end];
            assert!(segment.ends_with(b"\x1b\\"));
            assert!(
                segment.len() <= MAX_LOCKED_GRAPHICS_WRITE_BYTES,
                "bounded command grouping held stdout for {} bytes",
                segment.len()
            );
            segments.extend_from_slice(segment);
            offset = end;
        }
        assert_eq!(segments, batch);
        assert!(next_graphics_write_end(b"\x1b_Gunterminated", 0).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn shutdown_cancels_a_writer_blocked_by_terminal_backpressure() {
        let mut raw_fds = [-1; 2];
        assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
        let read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
        let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
        let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
        assert!(flags >= 0);
        assert_eq!(
            unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
            0
        );
        let fill = [0_u8; 4_096];
        loop {
            let written =
                unsafe { libc::write(write_fd.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
            if written >= 0 {
                continue;
            }
            assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
            break;
        }

        let mut writer = GraphicsWriter::spawn_with_graphics_output(
            Arc::new(Mutex::new(())),
            InterruptibleStdout { fd: write_fd },
        )
        .unwrap();
        let (attempt_tx, attempt_rx) = sync_channel(1);
        writer.control.observe_write_attempts(attempt_tx);
        writer.submit(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        attempt_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let started = std::time::Instant::now();
        writer.shutdown(Duration::ZERO);
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "cancelable stdout did not stop within its bounded poll interval"
        );
        drop(read_fd);
    }

    #[test]
    fn snapshot_slot_is_latest_wins_and_shutdown_is_clean() {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(PendingGraphics::default()));
        submit_snapshot(
            &slot,
            &tx,
            vec![GraphicPlacement::browser(
                0,
                1,
                Rect { x: 0, y: 0, width: 10, height: 5 },
                1,
                10,
                5,
                "AAAA".to_string(),
            )],
        );
        submit_snapshot(
            &slot,
            &tx,
            vec![GraphicPlacement::browser(
                0,
                1,
                Rect { x: 1, y: 1, width: 11, height: 6 },
                2,
                11,
                6,
                "BBBB".to_string(),
            )],
        );

        let latest = take_pending_update(&slot, 0)
            .and_then(|update| update.placements)
            .expect("latest snapshot");
        assert_eq!(latest.len(), 1);
        assert_eq!(latest[0].image.generation, 2);
        assert_eq!(latest[0].rect.x, 1);
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(rx.try_recv().is_err());

        let lock = Arc::new(Mutex::new(()));
        let mut writer = GraphicsWriter::spawn_with_output(lock, io::sink()).unwrap();
        writer.shutdown(Duration::from_secs(1));
        assert!(writer.handle.as_ref().is_none_or(|handle| handle.is_finished()));
    }

    #[test]
    fn host_scene_invalidation_survives_latest_wins_coalescing() {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(PendingGraphics::default()));
        let writer = GraphicsWriter {
            slot: slot.clone(),
            notify: Some(tx),
            control: Arc::new(WriterControl::default()),
            handle: None,
        };

        writer.invalidate_host_scene();
        writer.submit(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        writer.submit(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 1, y: 1, width: 11, height: 6 },
            2,
            11,
            6,
            "BBBB".to_string(),
        )]);

        let update = take_pending_update(&slot, 0).expect("pending scene update");
        assert_ne!(update.host_scene_epoch, 0);
        let latest = update.placements.expect("latest snapshot");
        assert_eq!(latest.len(), 1);
        assert_eq!(latest[0].image.generation, 2);
        assert_eq!(latest[0].rect.x, 1);
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn host_scene_invalidation_discards_a_pre_clear_write_waiting_on_stdout() {
        let stdout_lock = Arc::new(Mutex::new(()));
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (flushed_tx, flushed_rx) = sync_channel(8);
        let output = ObservedOutput { bytes: bytes.clone(), flushed: flushed_tx };
        let mut writer = GraphicsWriter::spawn_with_output(stdout_lock.clone(), output).unwrap();
        let first = rgba_placement(41, 1, 0, [255, 0, 0, 255]);
        let second = rgba_placement(42, 1, 1, [0, 255, 0, 255]);

        writer.submit(vec![first.clone(), second]);
        wait_for_output(&flushed_rx, &bytes, |bytes| {
            String::from_utf8_lossy(bytes).matches("a=p").count() == 2
        });
        bytes.lock().unwrap().clear();

        let draw_guard = stdout_lock.lock().unwrap();
        let (attempt_tx, attempt_rx) = sync_channel(1);
        writer.control.observe_write_attempts(attempt_tx);
        let changed_second = rgba_placement(42, 2, 1, [0, 0, 255, 255]);
        writer.submit(vec![first, changed_second.clone()]);
        attempt_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("pre-clear graphics batch must be waiting on stdout");

        writer.invalidate_host_scene();
        writer.submit(vec![changed_second]);
        drop(draw_guard);

        wait_for_output(&flushed_rx, &bytes, |bytes| {
            String::from_utf8_lossy(bytes).contains("a=p,i=1")
        });
        let raced_output = bytes.lock().unwrap().clone();
        let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
        host.resize(8, 4, 1, 1).unwrap();
        host.vt_write(&raced_output);
        let snapshot = host.kitty_graphics_snapshot().unwrap();
        assert_eq!(
            snapshot.images.len(),
            1,
            "stale pre-clear transmission left a duplicate host image: {snapshot:?}"
        );
        assert_eq!(
            snapshot.placements.len(),
            1,
            "stale pre-clear placement survived host-scene invalidation: {snapshot:?}"
        );

        writer.shutdown(Duration::from_secs(1));
    }

    #[test]
    fn shutdown_quiesces_a_blocked_writer_before_terminal_restore() {
        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let restored = Arc::new(AtomicBool::new(false));
        let writes_after_restore = Arc::new(Mutex::new(Vec::new()));
        let output = BlockingOutput {
            entered: entered_tx,
            release: release_rx,
            restored: restored.clone(),
            writes_after_restore: writes_after_restore.clone(),
        };
        let mut writer =
            GraphicsWriter::spawn_with_output(Arc::new(Mutex::new(())), output).unwrap();
        let shutdown = writer.shutdown_control();
        writer.submit(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        entered_rx.recv().unwrap();

        let (shutdown_done_tx, shutdown_done_rx) = sync_channel(1);
        let restored_for_shutdown = restored.clone();
        std::thread::spawn(move || {
            writer.shutdown(Duration::ZERO);
            restored_for_shutdown.store(true, Ordering::Release);
            shutdown_done_tx.send(()).unwrap();
        });

        shutdown.wait_until_cancelled();
        release_tx.send(()).unwrap();
        shutdown_done_rx.recv().unwrap();

        assert!(restored.load(Ordering::Acquire));
        assert!(
            writes_after_restore.lock().unwrap().iter().all(|after_restore| !after_restore),
            "graphics bytes were written after terminal restoration"
        );
    }

    #[test]
    fn panic_shutdown_control_quiesces_before_terminal_restore() {
        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let restored = Arc::new(AtomicBool::new(false));
        let writes_after_restore = Arc::new(Mutex::new(Vec::new()));
        let output = BlockingOutput {
            entered: entered_tx,
            release: release_rx,
            restored: restored.clone(),
            writes_after_restore: writes_after_restore.clone(),
        };
        let writer = GraphicsWriter::spawn_with_output(Arc::new(Mutex::new(())), output).unwrap();
        let shutdown = writer.shutdown_control();
        writer.submit(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        entered_rx.recv().unwrap();

        let (panic_hook_done_tx, panic_hook_done_rx) = sync_channel(1);
        let panic_shutdown = shutdown.clone();
        let restored_for_hook = restored.clone();
        std::thread::spawn(move || {
            panic_shutdown.cancel_and_wait();
            restored_for_hook.store(true, Ordering::Release);
            panic_hook_done_tx.send(()).unwrap();
        });

        shutdown.wait_until_cancelled();
        release_tx.send(()).unwrap();
        panic_hook_done_rx.recv().unwrap();

        assert!(restored.load(Ordering::Acquire));
        assert!(
            writes_after_restore.lock().unwrap().iter().all(|after_restore| !after_restore),
            "panic restoration raced a graphics write"
        );
    }
}
