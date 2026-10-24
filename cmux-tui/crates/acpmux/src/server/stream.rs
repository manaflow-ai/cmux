//! One daemon socket connection (Unix and Windows): newline-delimited
//! JSON-RPC both ways over a `local_stream::Stream`.

use super::{ConnAuth, Hub, Origin, WorkAdmission, serve_connection_from};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

/// One daemon socket connection: newline-delimited JSON-RPC both ways.
pub(super) async fn serve_stream(
    hub: Arc<Hub>,
    stream: crate::local_stream::Stream,
    peer: Option<cmux_link::app_caller::PeerToken>,
) {
    serve_stream_with_admission(hub, stream, peer, WorkAdmission::default()).await;
}

async fn serve_stream_with_admission(
    hub: Arc<Hub>,
    stream: crate::local_stream::Stream,
    peer: Option<cmux_link::app_caller::PeerToken>,
    admission: WorkAdmission,
) {
    let (rd, mut wr) = crate::local_stream::split(stream);
    let (in_tx, in_rx) = mpsc::channel::<String>(256);
    let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
    let (reader_done_tx, reader_done_rx) = oneshot::channel();
    tokio::spawn(async move {
        let _reader_done = reader_done_tx;
        let mut lines = BufReader::new(rd).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if in_tx.send(line).await.is_err() {
                break;
            }
        }
    });
    let (writer_stop_tx, writer_stop_rx) = oneshot::channel::<()>();
    tokio::spawn(async move {
        let write = async {
            while let Some(line) = out_rx.recv().await {
                if wr.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
            }
        };
        tokio::select! {
            _ = write => {},
            _ = writer_stop_rx => {},
        }
    });
    serve_connection_from(
        hub,
        in_rx,
        out_tx,
        Origin::Local,
        ConnAuth::LocalSocket,
        peer,
        Some(reader_done_rx),
        admission,
    )
    .await;
    let _ = writer_stop_tx.send(());
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::config::{Config, ProfileSources, StoreMode};
    use crate::rpc::Message;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixStream;
    use tokio::sync::Semaphore;

    struct Fixture(std::path::PathBuf);

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn full_input_queue_still_closes_after_notification_admission_stalls() {
        use std::os::unix::fs::PermissionsExt;

        let root = Fixture(
            std::env::temp_dir().join(format!("acpmux-work-limit-{}", uuid::Uuid::new_v4())),
        );
        std::fs::create_dir_all(&root.0).unwrap();
        std::fs::set_permissions(&root.0, std::fs::Permissions::from_mode(0o700)).unwrap();
        let config = root.0.join("config.json");
        std::fs::write(&config, "{}").unwrap();
        std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mut cfg = Config::load_from_with(&config, &ProfileSources::none()).unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        let hub = Hub::new(cfg, store);

        let slots = Arc::new(Semaphore::new(super::super::NOTIFICATION_WORK_LIMIT));
        let _held: Vec<_> = (0..super::super::NOTIFICATION_WORK_LIMIT)
            .map(|_| slots.clone().try_acquire_owned().unwrap())
            .collect();
        let admission =
            WorkAdmission { notification_slots: slots, max_wait: Duration::from_millis(500) };
        let (server_socket, mut client_socket) = UnixStream::pair().unwrap();
        let server = tokio::spawn(serve_stream_with_admission(hub, server_socket, None, admission));
        // The server consumes one notification and waits for a slot. Its reader
        // fills the 256-frame forwarding channel before it can observe EOF.
        let line =
            Message::notification("session/cancel", serde_json::json!({"sessionId": "missing"}))
                .to_line();
        client_socket.write_all(line.repeat(300).as_bytes()).await.unwrap();
        client_socket.shutdown().await.unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(!server.is_finished(), "the notification limit should be engaged");
        tokio::time::timeout(Duration::from_secs(2), server).await.unwrap().unwrap();
        let mut byte = [0];
        let n = tokio::time::timeout(Duration::from_secs(2), client_socket.read(&mut byte))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(n, 0, "the server must close its writer after overload cleanup");
    }
}
