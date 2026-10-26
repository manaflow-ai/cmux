//! The byte stream under an RFB session: a TCP socket, or a proxy
//! command's stdin and stdout (as `ssh -W` or a Cloud port forward).

use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
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
pub struct Closer(Arc<dyn Fn() + Send + Sync>);

impl Closer {
    pub fn new(close: impl Fn() + Send + Sync + 'static) -> Self {
        Self(Arc::new(close))
    }

    pub fn close(&self) {
        (self.0)();
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
                    tail.push(&buf[..read]);
                }
            })?;
        }
        let child = Arc::new(Mutex::new(child));
        let closer = Closer::new(move || {
            if let Ok(mut child) = child.lock() {
                kill(&mut child);
            }
        });
        Ok((Self { reader: Box::new(stdout), writer: Box::new(stdin), closer }, tail))
    }

    /// The closer, for ending the session from another thread.
    pub fn closer(&self) -> Closer {
        self.closer.clone()
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
