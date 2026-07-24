use std::io::Write;
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
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

pub struct GraphicsWriter {
    slot: Arc<Mutex<PendingGraphics>>,
    notify: Option<SyncSender<()>>,
    done: Option<Receiver<()>>,
    handle: Option<JoinHandle<()>>,
}

impl GraphicsWriter {
    pub fn spawn(stdout_lock: Arc<Mutex<()>>) -> std::io::Result<Self> {
        let (tx, rx) = sync_channel(1);
        let (done_tx, done_rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(PendingGraphics::default()));
        let handle = std::thread::Builder::new().name("mux-graphics-writer".into()).spawn({
            let slot = slot.clone();
            move || writer_loop(slot, rx, stdout_lock, done_tx)
        })?;
        Ok(Self { slot, notify: Some(tx), done: Some(done_rx), handle: Some(handle) })
    }

    pub fn submit(&self, placements: Vec<GraphicPlacement>) {
        let Some(tx) = &self.notify else { return };
        submit_snapshot(&self.slot, tx, placements);
    }

    /// Mark the host terminal's Kitty scene as cleared.
    ///
    /// The epoch remains in the latest-wins slot until the writer observes
    /// it, so later snapshot replacement cannot discard the invalidation.
    pub fn invalidate_host_scene(&self) {
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

fn writer_loop(
    slot: Arc<Mutex<PendingGraphics>>,
    rx: Receiver<()>,
    stdout_lock: Arc<Mutex<()>>,
    done: SyncSender<()>,
) {
    let _done = DoneOnDrop(done);
    let mut graphics = GraphicsState::default();
    let mut applied_host_scene_epoch = 0;
    while rx.recv().is_ok() {
        loop {
            let Some(update) = take_pending_update(&slot, applied_host_scene_epoch) else {
                break;
            };
            if update.host_scene_epoch != applied_host_scene_epoch {
                graphics.invalidate_host_scene();
                applied_host_scene_epoch = update.host_scene_epoch;
            }
            let Some(placements) = update.placements else {
                continue;
            };
            for batch in graphics.frame_batches(&placements) {
                let _guard = stdout_lock.lock().unwrap();
                let mut stdout = std::io::stdout();
                if stdout.write_all(&batch).and_then(|_| stdout.flush()).is_err() {
                    return;
                }
            }
        }
    }
    for batch in graphics.frame_batches(&[]) {
        let _guard = stdout_lock.lock().unwrap();
        let mut stdout = std::io::stdout();
        if stdout.write_all(&batch).and_then(|_| stdout.flush()).is_err() {
            return;
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
        let writer =
            GraphicsWriter { slot: slot.clone(), notify: Some(tx), done: None, handle: None };

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
}
