use std::io::Write;
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use super::graphics::{GraphicPlacement, GraphicsState};

pub struct GraphicsWriter {
    slot: Arc<Mutex<Option<Vec<GraphicPlacement>>>>,
    notify: Option<SyncSender<()>>,
    done: Option<Receiver<()>>,
    handle: Option<JoinHandle<()>>,
}

impl GraphicsWriter {
    pub fn spawn(stdout_lock: Arc<Mutex<()>>) -> std::io::Result<Self> {
        let (tx, rx) = sync_channel(1);
        let (done_tx, done_rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(None));
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
    slot: &Arc<Mutex<Option<Vec<GraphicPlacement>>>>,
    tx: &SyncSender<()>,
    placements: Vec<GraphicPlacement>,
) {
    *slot.lock().unwrap() = Some(placements);
    match tx.try_send(()) {
        Ok(()) | Err(TrySendError::Full(())) => {}
        Err(TrySendError::Disconnected(())) => {}
    }
}

fn writer_loop(
    slot: Arc<Mutex<Option<Vec<GraphicPlacement>>>>,
    rx: Receiver<()>,
    stdout_lock: Arc<Mutex<()>>,
    done: SyncSender<()>,
) {
    let _done = DoneOnDrop(done);
    let mut graphics = GraphicsState::default();
    while rx.recv().is_ok() {
        loop {
            let next = slot.lock().unwrap().take();
            let Some(placements) = next else { break };
            for batch in graphics.frame_batches(&placements) {
                let _guard = stdout_lock.lock().unwrap();
                let mut stdout = std::io::stdout();
                if stdout.write_all(&batch).and_then(|_| stdout.flush()).is_err() {
                    return;
                }
            }
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
        let slot = Arc::new(Mutex::new(None));
        submit_snapshot(
            &slot,
            &tx,
            vec![GraphicPlacement {
                surface: 1,
                rect: Rect { x: 0, y: 0, width: 10, height: 5 },
                seq: 1,
                data_b64: "AAAA".to_string(),
            }],
        );
        submit_snapshot(
            &slot,
            &tx,
            vec![GraphicPlacement {
                surface: 1,
                rect: Rect { x: 1, y: 1, width: 11, height: 6 },
                seq: 2,
                data_b64: "BBBB".to_string(),
            }],
        );

        let latest = slot.lock().unwrap().take().expect("latest snapshot");
        assert_eq!(latest.len(), 1);
        assert_eq!(latest[0].seq, 2);
        assert_eq!(latest[0].rect.x, 1);
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(rx.try_recv().is_err());

        let lock = Arc::new(Mutex::new(()));
        let mut writer = GraphicsWriter::spawn(lock).unwrap();
        writer.shutdown(Duration::from_secs(1));
        assert!(writer.handle.as_ref().is_none_or(|handle| handle.is_finished()));
    }
}
