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
