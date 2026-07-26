use std::io::Write;
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use cmux_tui_core::{Rect, SurfaceId};
use parking_lot::ReentrantMutex;

use super::graphics::{GraphicPlacement, GraphicsState};

pub type StdoutLock = ReentrantMutex<()>;

struct GraphicsSubmission {
    id: u64,
    session_generation: u64,
    placements: Vec<GraphicPlacement>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PresentedGraphic {
    pub surface: SurfaceId,
    pub rect: Rect,
    pub seq: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GraphicsPresentation {
    pub id: u64,
    pub session_generation: u64,
    pub graphics: Vec<PresentedGraphic>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GraphicsCompletion {
    Presented(GraphicsPresentation),
    Failed,
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
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        Self::spawn_with_output(stdout_lock, std::io::stdout(), on_ready)
    }

    fn spawn_with_output(
        stdout_lock: Arc<StdoutLock>,
        output: impl Write + Send + 'static,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        let (tx, rx) = sync_channel(1);
        let (done_tx, done_rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(None));
        let completion = Arc::new(Mutex::new(None));
        let handle = std::thread::Builder::new().name("mux-graphics-writer".into()).spawn({
            let slot = slot.clone();
            let completion = completion.clone();
            move || writer_loop(slot, completion, rx, stdout_lock, output, on_ready, done_tx)
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

fn writer_loop(
    slot: Arc<Mutex<Option<GraphicsSubmission>>>,
    completion: Arc<Mutex<Option<GraphicsCompletion>>>,
    rx: Receiver<()>,
    stdout_lock: Arc<StdoutLock>,
    mut output: impl Write,
    on_ready: impl Fn(),
    done: SyncSender<()>,
) {
    let _done = DoneOnDrop(done);
    let mut graphics = GraphicsState::default();
    while rx.recv().is_ok() {
        loop {
            let next = slot.lock().unwrap().take();
            let Some(submission) = next else { break };
            let presented_graphics = submission
                .placements
                .iter()
                .map(|placement| PresentedGraphic {
                    surface: placement.surface,
                    rect: placement.rect,
                    seq: placement.seq,
                })
                .collect();
            for batch in
                graphics.frame_batches(submission.session_generation, &submission.placements)
            {
                let _guard = stdout_lock.lock();
                if output.write_all(&batch).and_then(|_| output.flush()).is_err() {
                    *completion.lock().unwrap() = Some(GraphicsCompletion::Failed);
                    on_ready();
                    return;
                }
            }
            *completion.lock().unwrap() =
                Some(GraphicsCompletion::Presented(GraphicsPresentation {
                    id: submission.id,
                    session_generation: submission.session_generation,
                    graphics: presented_graphics,
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
        let mut writer = GraphicsWriter::spawn(lock, || {}).unwrap();
        writer.shutdown(Duration::from_secs(1));
        assert!(writer.handle.as_ref().is_none_or(|handle| handle.is_finished()));
    }

    #[test]
    fn presentation_is_reported_only_after_the_snapshot_is_written() {
        let lock = Arc::new(StdoutLock::new(()));
        let held = lock.lock();
        let (presented_tx, presented_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output(lock.clone(), Vec::new(), move || {
            presented_tx.send(()).unwrap();
        })
        .unwrap();

        assert!(writer.submit(
            7,
            1,
            vec![GraphicPlacement {
                surface: 11,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 13,
                data_b64: "AAAA".to_string(),
            }]
        ));
        assert!(
            presented_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "submission must not become pointer-visible while output is blocked"
        );

        drop(held);
        presented_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(
            writer.take_completion(),
            Some(GraphicsCompletion::Presented(GraphicsPresentation {
                id: 7,
                session_generation: 1,
                graphics: vec![PresentedGraphic {
                    surface: 11,
                    rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                    seq: 13,
                }],
            }))
        );
        writer.shutdown(Duration::from_secs(1));
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
