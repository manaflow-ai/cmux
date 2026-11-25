//! The byte stream under an RFB session: a TCP socket, or a proxy
//! command's stdin and stdout (as `ssh -W` or a Cloud port forward).

use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

/// Bytes of a proxy command's stderr kept for the error message.
const STDERR_TAIL_BYTES: usize = 2048;

/// A connected stream split into its reading and writing halves, plus a
/// way to end it from another thread (which unblocks the reader).
pub struct Transport {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    pub(crate) closer: Closer,
}

/// Ends a transport; cloneable and callable from any thread, any number of times.
#[derive(Clone)]
pub struct Closer {
    close: Arc<dyn Fn() + Send + Sync>,
    /// Waits (at most the limit) for the far end to take what was written
    /// after the writer was dropped; `None` when closing loses nothing (TCP:
    /// a shutdown sends its FIN behind the data).
    drain: Option<Arc<dyn Fn(Duration) + Send + Sync>>,
}

impl Closer {
    pub fn new(close: impl Fn() + Send + Sync + 'static) -> Self {
        Self { close: Arc::new(close), drain: None }
    }

    /// Ends the transport now.
    pub fn close(&self) {
        (self.close)();
    }

    /// Ends the transport after its writing half was dropped, letting the
    /// far end take the bytes already written (a proxy command forwards
    /// them and exits on stdin's end), waiting at most `limit`.
    pub fn finish(&self, limit: Duration) {
        if let Some(drain) = &self.drain {
            drain(limit);
        }
        self.close();
    }
}

impl Transport {
    pub fn from_parts(
        reader: Box<dyn Read + Send>,
        writer: Box<dyn Write + Send>,
        closer: Closer,
    ) -> Self {
        Self { reader, writer, closer }
    }

    /// Connects to `host:port`, trying each resolved address in turn.
    pub fn tcp(host: &str, port: u16, timeout: Duration) -> io::Result<Self> {
        let mut last = io::Error::new(io::ErrorKind::NotFound, format!("{host} did not resolve"));
        for address in (host, port).to_socket_addrs()? {
            match TcpStream::connect_timeout(&address, timeout) {
                Ok(stream) => return Self::from_tcp(stream),
                Err(error) => last = error,
            }
        }
        Err(last)
    }

    pub fn from_tcp(stream: TcpStream) -> io::Result<Self> {
        stream.set_nodelay(true)?;
        let writer = stream.try_clone()?;
        let closer = stream.try_clone()?;
        Ok(Self {
            reader: Box::new(stream),
            writer: Box::new(writer),
            closer: Closer::new(move || {
                let _ = closer.shutdown(std::net::Shutdown::Both);
            }),
        })
    }

    /// Runs `command_line` through the shell and speaks RFB over its stdin
    /// and stdout. Its stderr is kept (the last 2 KiB) for [`ProxyStderr`].
    pub fn command(command_line: &str) -> io::Result<(Self, ProxyStderr)> {
        let mut command = shell(command_line);
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = command.spawn()?;
        let stdin = child.stdin.take().ok_or_else(|| io::Error::other("no proxy stdin"))?;
        let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no proxy stdout"))?;
        let stderr = child.stderr.take();
        let tail = ProxyStderr::default();
        if let Some(mut stderr) = stderr {
            let tail = tail.clone();
            std::thread::Builder::new().name("vnc-proxy-stderr".into()).spawn(move || {
                let mut buf = [0u8; 512];
                while let Ok(read @ 1..) = stderr.read(&mut buf) {
                    if let Some(bytes) = buf.get(..read) {
                        tail.push(bytes);
                    }
                }
            })?;
        }
        let child = Arc::new(Mutex::new(child));
        let (ended_tx, ended) = mpsc::channel();
        let ended = Mutex::new(ended);
        let mut closer = Closer::new(move || {
            if let Ok(mut child) = child.lock() {
                kill(&mut child);
            }
        });
        // The proxy has forwarded everything once its stdout ends (the
        // session's reader sees that end).
        closer.drain = Some(Arc::new(move |limit| {
            let ended = ended.lock().unwrap_or_else(PoisonError::into_inner);
            let _ = ended.recv_timeout(limit);
        }));
        let reader = EndSignal { inner: stdout, ended: Some(ended_tx) };
        Ok((Self { reader: Box::new(reader), writer: Box::new(stdin), closer }, tail))
    }

    /// The closer, for ending the session from another thread.
    pub fn closer(&self) -> Closer {
        self.closer.clone()
    }
}

/// A reader that reports its end (EOF or an error) once.
struct EndSignal<R> {
    inner: R,
    ended: Option<Sender<()>>,
}

impl<R: Read> Read for EndSignal<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let result = self.inner.read(buf);
        if matches!(result, Ok(0) | Err(_))
            && !buf.is_empty()
            && let Some(ended) = self.ended.take()
        {
            let _ = ended.send(());
        }
        result
    }
}

fn kill(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(unix)]
fn shell(command_line: &str) -> Command {
    let mut command = Command::new("/bin/sh");
    command.arg("-c").arg(command_line);
    command
}

#[cfg(not(unix))]
fn shell(command_line: &str) -> Command {
    let mut command = Command::new("cmd");
    command.arg("/C").arg(command_line);
    command
}

/// The end of a proxy command's stderr, to explain why it closed.
#[derive(Clone, Default)]
pub struct ProxyStderr(Arc<Mutex<Vec<u8>>>);

impl ProxyStderr {
    fn push(&self, bytes: &[u8]) {
        if let Ok(mut tail) = self.0.lock() {
            tail.extend_from_slice(bytes);
            let excess = tail.len().saturating_sub(STDERR_TAIL_BYTES);
            tail.drain(..excess);
        }
    }

    /// The kept stderr as text, trimmed.
    pub fn text(&self) -> String {
        self.0
            .lock()
            .map(|tail| String::from_utf8_lossy(&tail).trim().to_owned())
            .unwrap_or_default()
    }
}
