//! Bounded async adaptation for Windows Unix-domain sockets.
//!
//! `uds_windows` exposes blocking streams. Keep those calls off Tokio workers
//! and exchange bounded chunks through channels instead of re-entering the
//! runtime with `Handle::block_on`. Dropping the adapter shuts down the socket,
//! which releases both blocking workers.

use std::io::{self, Read as _, Write as _};
use std::net::Shutdown;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use bytes::Bytes;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _, DuplexStream};
use tokio::runtime::Handle;
use tokio::sync::mpsc;

const BRIDGE_CHUNK_BYTES: usize = 64 * 1024;
const BRIDGE_QUEUE_CHUNKS: usize = 4;
const BRIDGE_BUFFER_BYTES: usize = BRIDGE_CHUNK_BYTES * BRIDGE_QUEUE_CHUNKS;

pub(crate) fn bridge(stream: uds_windows::UnixStream) -> io::Result<DuplexStream> {
    let runtime = Handle::try_current().map_err(|error| {
        io::Error::other(format!("Windows socket bridge requires a Tokio runtime: {error}"))
    })?;
    let socket_reader = stream.try_clone()?;
    let reader_shutdown = stream.try_clone()?;
    let writer_shutdown = stream.try_clone()?;
    let (local, bridge) = tokio::io::duplex(BRIDGE_BUFFER_BYTES);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge);
    let (upload_tx, upload_rx) = mpsc::channel(BRIDGE_QUEUE_CHUNKS);
    let (download_tx, download_rx) = mpsc::channel(BRIDGE_QUEUE_CHUNKS);
    let closing = Arc::new(AtomicBool::new(false));

    let reader_closing = closing.clone();
    runtime.spawn_blocking(move || {
        read_socket(socket_reader, reader_shutdown, upload_tx, reader_closing)
    });
    runtime.spawn(relay_socket_upload(upload_rx, bridge_writer));
    runtime.spawn(relay_socket_download(bridge_reader, download_tx));
    runtime.spawn_blocking(move || write_socket(stream, writer_shutdown, download_rx, closing));

    Ok(local)
}

fn read_socket(
    mut socket: uds_windows::UnixStream,
    shutdown: uds_windows::UnixStream,
    destination: mpsc::Sender<Bytes>,
    closing: Arc<AtomicBool>,
) {
    let mut buffer = vec![0_u8; BRIDGE_CHUNK_BYTES];
    loop {
        match socket.read(&mut buffer) {
            Ok(0) => {
                let _ = shutdown.shutdown(Shutdown::Read);
                return;
            }
            Ok(size) => {
                if destination.blocking_send(Bytes::copy_from_slice(&buffer[..size])).is_err() {
                    closing.store(true, Ordering::Release);
                    let _ = shutdown.shutdown(Shutdown::Both);
                    return;
                }
            }
            Err(error) => {
                if !closing.swap(true, Ordering::AcqRel) {
                    report_failure("read", &error);
                }
                let _ = shutdown.shutdown(Shutdown::Both);
                return;
            }
        }
    }
}

async fn relay_socket_upload(
    mut source: mpsc::Receiver<Bytes>,
    mut destination: tokio::io::WriteHalf<DuplexStream>,
) {
    while let Some(chunk) = source.recv().await {
        if destination.write_all(&chunk).await.is_err() {
            return;
        }
    }
    let _ = destination.shutdown().await;
}

async fn relay_socket_download(
    mut source: tokio::io::ReadHalf<DuplexStream>,
    destination: mpsc::Sender<Bytes>,
) {
    let mut buffer = vec![0_u8; BRIDGE_CHUNK_BYTES];
    loop {
        match source.read(&mut buffer).await {
            Ok(0) | Err(_) => return,
            Ok(size) => {
                if destination.send(Bytes::copy_from_slice(&buffer[..size])).await.is_err() {
                    return;
                }
            }
        }
    }
}

fn write_socket(
    mut socket: uds_windows::UnixStream,
    shutdown: uds_windows::UnixStream,
    mut source: mpsc::Receiver<Bytes>,
    closing: Arc<AtomicBool>,
) {
    while let Some(chunk) = source.blocking_recv() {
        if let Err(error) = socket.write_all(&chunk).and_then(|()| socket.flush()) {
            if !closing.swap(true, Ordering::AcqRel) {
                report_failure("write", &error);
            }
            let _ = shutdown.shutdown(Shutdown::Both);
            return;
        }
    }
    closing.store(true, Ordering::Release);
    let _ = shutdown.shutdown(Shutdown::Both);
}

fn report_failure(direction: &str, error: &io::Error) {
    eprintln!("cmux-tui: Windows local socket {direction} failed: {error}");
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    use tokio::io::AsyncWriteExt as _;

    use super::*;

    #[test]
    fn windows_dropping_a_saturated_bridge_releases_its_blocking_workers() {
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "windows_socket::tests::windows_dropping_a_saturated_bridge_fixture",
                "--nocapture",
            ])
            .env("CMUX_TEST_WINDOWS_SATURATED_BRIDGE", "1")
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break Some(status);
            }
            if Instant::now() >= deadline {
                break None;
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let Some(status) = status else {
            let _ = child.kill();
            let _ = child.wait();
            panic!("dropping a saturated Windows socket bridge stranded a blocking worker");
        };

        assert!(status.success(), "saturated Windows bridge fixture failed: {status}");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn windows_dropping_a_saturated_bridge_fixture() {
        if std::env::var_os("CMUX_TEST_WINDOWS_SATURATED_BRIDGE").is_none() {
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        let socket_path = directory.path().join("bridge.sock");
        let listener = uds_windows::UnixListener::bind(&socket_path).unwrap();
        let accept = std::thread::spawn(move || listener.accept().unwrap().0);
        let client = uds_windows::UnixStream::connect(&socket_path).unwrap();
        let server = accept.join().unwrap();
        let mut bridge = bridge(client).unwrap();
        let completed_writes = Arc::new(AtomicUsize::new(0));
        let writer_progress = completed_writes.clone();
        let writer = tokio::spawn(async move {
            let chunk = vec![0_u8; BRIDGE_CHUNK_BYTES];
            loop {
                bridge.write_all(&chunk).await.unwrap();
                writer_progress.fetch_add(1, Ordering::Release);
            }
        });

        let deadline = Instant::now() + Duration::from_secs(3);
        let mut previous = 0;
        let mut unchanged_samples = 0;
        while unchanged_samples < 4 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let current = completed_writes.load(Ordering::Acquire);
            unchanged_samples =
                if current > 0 && current == previous { unchanged_samples + 1 } else { 0 };
            previous = current;
            assert!(Instant::now() < deadline, "Windows socket writer never reached backpressure");
        }

        writer.abort();
        let _ = writer.await;
        std::mem::forget(server);
    }
}
