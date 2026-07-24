use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread::{JoinHandle, ThreadId};
use std::time::Duration;

use super::graphics::{GraphicPlacement, GraphicsState};

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
    /// possible. This is safe to call from the process panic hook. The wait
    /// is deliberately unbounded because returning while a `Write` is still
    /// blocked would allow Kitty bytes to arrive after terminal restoration.
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
    pub fn spawn(stdout_lock: Arc<Mutex<()>>) -> std::io::Result<Self> {
        Self::spawn_with_output(stdout_lock, std::io::stdout())
    }

    fn spawn_with_output<W>(stdout_lock: Arc<Mutex<()>>, output: W) -> std::io::Result<Self>
    where
        W: Write + Send + 'static,
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

fn writer_loop<W>(
    slot: Arc<Mutex<PendingGraphics>>,
    rx: Receiver<()>,
    stdout_lock: Arc<Mutex<()>>,
    mut output: W,
    control: Arc<WriterControl>,
) where
    W: Write,
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

fn write_batch<W: Write>(
    output: &mut W,
    stdout_lock: &Arc<Mutex<()>>,
    slot: &Arc<Mutex<PendingGraphics>>,
    host_scene_epoch: u64,
    control: &WriterControl,
    batch: &[u8],
) -> bool {
    if control.is_cancelled() {
        return false;
    }
    #[cfg(test)]
    control.report_write_attempt();
    let _guard = stdout_lock.lock().unwrap();
    if control.is_cancelled() {
        return false;
    }
    if slot.lock().unwrap().host_scene_epoch != host_scene_epoch {
        return true;
    }
    output.write_all(batch).and_then(|_| output.flush()).is_ok()
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
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            let _ = self.entered.try_send(());
            self.release.recv().unwrap();
            self.writes_after_restore.lock().unwrap().push(self.restored.load(Ordering::Acquire));
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    struct ObservedOutput {
        bytes: Arc<Mutex<Vec<u8>>>,
        flushed: SyncSender<()>,
    }

    impl Write for ObservedOutput {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.bytes.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
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
        let mut writer = GraphicsWriter::spawn(lock).unwrap();
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
