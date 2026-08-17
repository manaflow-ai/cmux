//! Bounded async adaptation for Windows Unix-domain sockets.
//!
//! `uds_windows` exposes blocking streams. Keep those calls off Tokio workers
//! and exchange bounded chunks through channels instead of re-entering the
//! runtime with `Handle::block_on`. Dropping the adapter signals cancellation;
//! finite socket I/O quanta ensure both blocking workers observe it.

use std::io::{self, Read as _, Write as _};
use std::net::Shutdown;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use bytes::Bytes;
use tokio::io::{
    AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _, DuplexStream, ReadBuf,
};
use tokio::runtime::Handle;
use tokio::sync::mpsc;

const BRIDGE_CHUNK_BYTES: usize = 64 * 1024;
const BRIDGE_QUEUE_CHUNKS: usize = 4;
const BRIDGE_BUFFER_BYTES: usize = BRIDGE_CHUNK_BYTES * BRIDGE_QUEUE_CHUNKS;
const BRIDGE_IO_TIMEOUT: Duration = Duration::from_millis(250);
#[cfg(test)]
static WRITE_TIMEOUT_SIGNAL: std::sync::OnceLock<
    std::sync::Mutex<Option<std::sync::mpsc::SyncSender<()>>>,
> = std::sync::OnceLock::new();

pub(crate) struct WindowsSocketBridge {
    inner: DuplexStream,
    shutdown: uds_windows::UnixStream,
    closing: Arc<AtomicBool>,
    writer: Arc<WriterProgress>,
    accepted_bytes: u64,
}

#[derive(Default)]
struct WriterProgress {
    flushed_bytes: AtomicU64,
    done: AtomicBool,
    error: Mutex<Option<String>>,
    waker: Mutex<Option<Waker>>,
}

impl WriterProgress {
    fn poll_flushed(&self, target: u64, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Some(result) = self.flush_result(target) {
            return Poll::Ready(result);
        }
        if let Ok(mut waker) = self.waker.lock() {
            *waker = Some(context.waker().clone());
        }
        self.flush_result(target).map_or(Poll::Pending, Poll::Ready)
    }

    fn poll_done(&self, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Some(result) = self.done_result() {
            return Poll::Ready(result);
        }
        if let Ok(mut waker) = self.waker.lock() {
            *waker = Some(context.waker().clone());
        }
        self.done_result().map_or(Poll::Pending, Poll::Ready)
    }

    fn flush_result(&self, target: u64) -> Option<io::Result<()>> {
        if let Ok(error) = self.error.lock()
            && let Some(error) = error.as_ref()
        {
            return Some(Err(io::Error::other(error.clone())));
        }
        if self.flushed_bytes.load(Ordering::Acquire) >= target {
            return Some(Ok(()));
        }
        self.done
            .load(Ordering::Acquire)
            .then(|| Err(io::Error::from(io::ErrorKind::UnexpectedEof)))
    }

    fn done_result(&self) -> Option<io::Result<()>> {
        if let Ok(error) = self.error.lock()
            && let Some(error) = error.as_ref()
        {
            return Some(Err(io::Error::other(error.clone())));
        }
        self.done.load(Ordering::Acquire).then_some(Ok(()))
    }

    fn record_flush(&self, bytes: usize) {
        self.flushed_bytes.fetch_add(bytes as u64, Ordering::Release);
        self.wake();
    }

    fn finish(&self) {
        self.done.store(true, Ordering::Release);
        self.wake();
    }

    fn fail(&self, error: &io::Error) {
        if let Ok(mut recorded) = self.error.lock()
            && recorded.is_none()
        {
            *recorded = Some(error.to_string());
        }
        self.done.store(true, Ordering::Release);
        self.wake();
    }

    fn wake(&self) {
        if let Ok(mut waker) = self.waker.lock()
            && let Some(waker) = waker.take()
        {
            waker.wake();
        }
    }
}

impl AsyncRead for WindowsSocketBridge {
    fn poll_read(
        self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_read(context, buffer)
    }
}

impl AsyncWrite for WindowsSocketBridge {
    fn poll_write(
        self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        let this = self.get_mut();
        match Pin::new(&mut this.inner).poll_write(context, buffer) {
            Poll::Ready(Ok(written)) => {
                this.accepted_bytes = this.accepted_bytes.saturating_add(written as u64);
                Poll::Ready(Ok(written))
            }
            result => result,
        }
    }

    fn poll_flush(self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        let this = self.get_mut();
        match Pin::new(&mut this.inner).poll_flush(context) {
            Poll::Ready(Ok(())) => this.writer.poll_flushed(this.accepted_bytes, context),
            result => result,
        }
    }

    fn poll_shutdown(
        self: Pin<&mut Self>,
        context: &mut Context<'_>,
    ) -> Poll<Result<(), io::Error>> {
        let this = self.get_mut();
        match Pin::new(&mut this.inner).poll_flush(context) {
            Poll::Ready(Ok(())) => {}
            result => return result,
        }
        match this.writer.poll_flushed(this.accepted_bytes, context) {
            Poll::Ready(Ok(())) => {}
            result => return result,
        }
        match Pin::new(&mut this.inner).poll_shutdown(context) {
            Poll::Ready(Ok(())) => this.writer.poll_done(context),
            result => result,
        }
    }
}

impl Drop for WindowsSocketBridge {
    fn drop(&mut self) {
        self.closing.store(true, Ordering::Release);
        let _ = self.shutdown.shutdown(Shutdown::Both);
    }
}

pub(crate) fn bridge(stream: uds_windows::UnixStream) -> io::Result<WindowsSocketBridge> {
    let runtime = Handle::try_current().map_err(|error| {
        io::Error::other(format!("Windows socket bridge requires a Tokio runtime: {error}"))
    })?;
    let socket_reader = stream.try_clone()?;
    socket_reader.set_read_timeout(Some(BRIDGE_IO_TIMEOUT))?;
    stream.set_write_timeout(Some(BRIDGE_IO_TIMEOUT))?;
    let reader_shutdown = stream.try_clone()?;
    let writer_shutdown = stream.try_clone()?;
    let bridge_shutdown = stream.try_clone()?;
    let (local, bridge) = tokio::io::duplex(BRIDGE_BUFFER_BYTES);
    let (bridge_reader, bridge_writer) = tokio::io::split(bridge);
    let (upload_tx, upload_rx) = mpsc::channel(BRIDGE_QUEUE_CHUNKS);
    let (download_tx, download_rx) = mpsc::channel(BRIDGE_QUEUE_CHUNKS);
    let closing = Arc::new(AtomicBool::new(false));
    let writer = Arc::new(WriterProgress::default());

    let reader_closing = closing.clone();
    runtime.spawn_blocking(move || {
        read_socket(socket_reader, reader_shutdown, upload_tx, reader_closing)
    });
    runtime.spawn(relay_socket_upload(upload_rx, bridge_writer));
    runtime.spawn(relay_socket_download(bridge_reader, download_tx));
    let bridge_closing = closing.clone();
    let bridge_writer_progress = Arc::clone(&writer);
    runtime.spawn_blocking(move || {
        write_socket(stream, writer_shutdown, download_rx, closing, bridge_writer_progress)
    });

    Ok(WindowsSocketBridge {
        inner: local,
        shutdown: bridge_shutdown,
        closing: bridge_closing,
        writer,
        accepted_bytes: 0,
    })
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
                if socket_timeout(&error) {
                    if closing.load(Ordering::Acquire) {
                        let _ = shutdown.shutdown(Shutdown::Both);
                        return;
                    }
                    continue;
                }
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
    progress: Arc<WriterProgress>,
) {
    while let Some(chunk) = source.blocking_recv() {
        let mut offset = 0;
        while offset < chunk.len() {
            match socket.write(&chunk[offset..]) {
                Ok(0) => {
                    let error = io::Error::from(io::ErrorKind::WriteZero);
                    if !closing.swap(true, Ordering::AcqRel) {
                        report_failure("write", &error);
                    }
                    progress.fail(&error);
                    let _ = shutdown.shutdown(Shutdown::Both);
                    return;
                }
                Ok(size) => offset += size,
                Err(error) if socket_timeout(&error) => {
                    #[cfg(test)]
                    report_test_write_timeout();
                    if closing.load(Ordering::Acquire) {
                        progress.fail(&io::Error::from(io::ErrorKind::ConnectionAborted));
                        let _ = shutdown.shutdown(Shutdown::Both);
                        return;
                    }
                }
                Err(error) => {
                    if !closing.swap(true, Ordering::AcqRel) {
                        report_failure("write", &error);
                    }
                    progress.fail(&error);
                    let _ = shutdown.shutdown(Shutdown::Both);
                    return;
                }
            }
        }
        if let Err(error) = socket.flush() {
            if !closing.swap(true, Ordering::AcqRel) {
                report_failure("write", &error);
            }
            progress.fail(&error);
            let _ = shutdown.shutdown(Shutdown::Both);
            return;
        }
        progress.record_flush(chunk.len());
    }
    if let Err(error) = socket.flush() {
        progress.fail(&error);
        let _ = shutdown.shutdown(Shutdown::Both);
        return;
    }
    let _ = shutdown.shutdown(Shutdown::Write);
    progress.finish();
}

fn socket_timeout(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock)
}

fn report_failure(direction: &str, error: &io::Error) {
    eprintln!("cmux-tui: Windows local socket {direction} failed: {error}");
}

#[cfg(test)]
fn report_test_write_timeout() {
    if let Ok(signal) = WRITE_TIMEOUT_SIGNAL.get_or_init(|| std::sync::Mutex::new(None)).lock()
        && let Some(signal) = signal.as_ref()
    {
        let _ = signal.try_send(());
    }
}

#[cfg(test)]
fn install_test_write_timeout_signal(signal: std::sync::mpsc::SyncSender<()>) {
    *WRITE_TIMEOUT_SIGNAL.get_or_init(|| std::sync::Mutex::new(None)).lock().unwrap() =
        Some(signal);
}

#[cfg(test)]
mod tests {
    use std::io::Read as _;
    use std::time::Duration;

    use tokio::io::AsyncWriteExt as _;

    use super::*;

    #[test]
    fn windows_dropping_a_saturated_bridge_releases_its_blocking_workers() {
        use wait_timeout::ChildExt as _;

        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "windows_socket::tests::windows_dropping_a_saturated_bridge_fixture",
                "--nocapture",
            ])
            .env("CMUX_TEST_WINDOWS_SATURATED_BRIDGE", "1")
            .spawn()
            .unwrap();
        let status = child.wait_timeout(Duration::from_secs(10)).unwrap();
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
        let (backpressure_tx, backpressure_rx) = std::sync::mpsc::sync_channel(1);
        install_test_write_timeout_signal(backpressure_tx);
        let writer = tokio::spawn(async move {
            let chunk = vec![0_u8; BRIDGE_CHUNK_BYTES];
            loop {
                bridge.write_all(&chunk).await.unwrap();
            }
        });

        tokio::task::spawn_blocking(move || backpressure_rx.recv_timeout(Duration::from_secs(3)))
            .await
            .unwrap()
            .expect("Windows socket writer never reached backpressure");

        writer.abort();
        let _ = writer.await;
        std::mem::forget(server);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn windows_shutdown_drains_every_accepted_byte() {
        let directory = tempfile::tempdir().unwrap();
        let socket_path = directory.path().join("drain.sock");
        let listener = uds_windows::UnixListener::bind(&socket_path).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut bytes = Vec::new();
            stream.read_to_end(&mut bytes).unwrap();
            bytes
        });
        let client = uds_windows::UnixStream::connect(&socket_path).unwrap();
        let mut bridge = bridge(client).unwrap();
        let payload = vec![0x5a; BRIDGE_CHUNK_BYTES * 3 + 17];

        bridge.write_all(&payload).await.unwrap();
        bridge.shutdown().await.unwrap();

        assert_eq!(server.join().unwrap(), payload);
    }
}
