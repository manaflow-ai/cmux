//! Native pasteboard handoff to the authenticated remote terminal owner.
//! Transfer, file validation and PTY commit stay in Rust. Never paste a local
//! source path, retry an uncertain commit, or claim the terminal's geometry.

#![cfg(unix)]

use base64::Engine as _;
use cmux_process::{Child, Command, Stdio};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

type Result<T> = std::result::Result<T, &'static str>;
pub(crate) const MODE: &str = "__terminal-paste";
const CHUNK_BYTES: usize = 48 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_LINE_BYTES: usize = 64 * 1024 * 1024;

#[derive(Deserialize)]
struct Request {
    socket_path: String,
    bridge: Option<Bridge>,
    terminal_id: String,
    image: Option<Image>,
    #[serde(default)]
    files: Vec<String>,
}

#[derive(Deserialize)]
struct Bridge {
    executable: String,
    #[serde(default)]
    arguments: Vec<String>,
    #[serde(default)]
    environment: HashMap<String, String>,
    #[serde(default = "default_timeout_ms")]
    reply_timeout_ms: u64,
}

#[derive(Deserialize)]
struct Image {
    mime: String,
    data: String,
}

fn default_timeout_ms() -> u64 {
    10_000
}

/// Owns exactly the child started by this request, including failed handshakes.
struct BridgeChild(Child);
impl Drop for BridgeChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct Endpoint {
    socket: UnixStream,
    pending: Vec<u8>,
    _child: Option<BridgeChild>,
}

/// A poll timeout of at least 1 ms, saturating at `i32::MAX`.
fn poll_millis(remaining: Duration) -> i32 {
    i32::try_from(remaining.as_millis()).unwrap_or(i32::MAX).max(1)
}

/// `now + timeout`, or the furthest representable instant.
fn deadline_after(timeout: Duration) -> Result<Instant> {
    Instant::now().checked_add(timeout).ok_or("terminal-paste-timeout")
}

fn wait_fd(fd: RawFd, events: i16, deadline: Instant) -> Result<()> {
    loop {
        let remaining =
            deadline.checked_duration_since(Instant::now()).ok_or("terminal-paste-timeout")?;
        let mut descriptor = libc::pollfd { fd, events, revents: 0 };
        let millis = poll_millis(remaining);
        let result = unsafe { libc::poll(&mut descriptor, 1, millis) };
        if result > 0 {
            if descriptor.revents & libc::POLLNVAL != 0 {
                return Err("terminal-paste-daemon-unavailable");
            }
            return Ok(()); // HUP/ERR are consumed by the following read/write.
        }
        if result == 0 {
            return Err("terminal-paste-timeout");
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return Err("terminal-paste-daemon-unavailable");
        }
    }
}

/// Nonblocking connect also bounds a daemon whose listen backlog is full.
fn connect_socket(path: &Path) -> Result<UnixStream> {
    cmux_unix_socket::check_path(path).map_err(|_| "terminal-paste-daemon-unavailable")?;
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err("terminal-paste-daemon-unavailable");
    }
    // socket returned a fresh descriptor, owned here from this point on.
    let socket = unsafe { UnixStream::from_raw_fd(fd) };
    socket.set_nonblocking(true).map_err(|_| "terminal-paste-daemon-unavailable")?;
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_family = libc::sa_family_t::try_from(libc::AF_UNIX)
        .map_err(|_| "terminal-paste-daemon-unavailable")?;
    let bytes = path.as_os_str().as_bytes();
    if bytes.contains(&0) || bytes.len() >= address.sun_path.len() {
        return Err("terminal-paste-daemon-unavailable");
    }
    for (destination, byte) in address.sun_path.iter_mut().zip(bytes) {
        *destination = *byte as libc::c_char;
    }
    let length = std::mem::offset_of!(libc::sockaddr_un, sun_path)
        .checked_add(bytes.len())
        .and_then(|length| length.checked_add(1))
        .and_then(|length| libc::socklen_t::try_from(length).ok())
        .ok_or("terminal-paste-daemon-unavailable")?;
    #[cfg(target_vendor = "apple")]
    {
        address.sun_len = u8::try_from(length).map_err(|_| "terminal-paste-daemon-unavailable")?;
    }
    let result =
        unsafe { libc::connect(fd, (&address as *const libc::sockaddr_un).cast(), length) };
    if result < 0 {
        if io::Error::last_os_error().raw_os_error() != Some(libc::EINPROGRESS) {
            return Err("terminal-paste-daemon-unavailable");
        }
        wait_fd(fd, libc::POLLOUT, deadline_after(REQUEST_TIMEOUT)?)?;
        if socket.take_error().map_err(|_| "terminal-paste-daemon-unavailable")?.is_some() {
            return Err("terminal-paste-daemon-unavailable");
        }
    }
    Ok(socket)
}

impl Endpoint {
    fn open(request: &Request) -> Result<Self> {
        let (socket, child) = if let Some(bridge) = &request.bridge {
            if !Path::new(&bridge.executable).is_absolute() {
                return Err("terminal-paste-bridge-unavailable");
            }
            let (ours, theirs) =
                UnixStream::pair().map_err(|_| "terminal-paste-bridge-unavailable")?;
            let output = theirs.try_clone().map_err(|_| "terminal-paste-bridge-unavailable")?;
            let child = Command::new(&bridge.executable)
                .args(&bridge.arguments)
                .envs(&bridge.environment)
                .stdin(Stdio::from(OwnedFd::from(theirs)))
                .stdout(Stdio::from(OwnedFd::from(output)))
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|_| "terminal-paste-bridge-unavailable")?;
            let mut child = BridgeChild(child);
            let mut stderr = child.0.stderr.take().ok_or("terminal-paste-bridge-unavailable")?;
            let deadline =
                deadline_after(Duration::from_millis(bridge.reply_timeout_ms.clamp(1, 300_000)))?;
            let mut line = Vec::new();
            loop {
                wait_fd(stderr.as_raw_fd(), libc::POLLIN, deadline)?;
                let mut byte = [0];
                if stderr.read(&mut byte).map_err(|_| "terminal-paste-bridge-unavailable")? != 1 {
                    return Err("terminal-paste-bridge-unavailable");
                }
                if byte[0] == b'\n' {
                    break;
                }
                if line.len() == 1024 {
                    return Err("terminal-paste-bridge-unavailable");
                }
                line.push(byte[0]);
            }
            let announced: Value =
                serde_json::from_slice(&line).map_err(|_| "terminal-paste-bridge-unavailable")?;
            if announced.get("ok") != Some(&Value::Bool(true)) {
                return Err("terminal-paste-bridge-unavailable");
            }
            child.0.stderr = Some(stderr);
            (ours, Some(child))
        } else {
            (connect_socket(Path::new(&request.socket_path))?, None)
        };
        socket.set_nonblocking(true).map_err(|_| "terminal-paste-daemon-unavailable")?;
        Ok(Self { socket, pending: Vec::new(), _child: child })
    }

    /// Keep draining bridge diagnostics for its whole lifetime. Closing stderr
    /// after the handshake can crash the bridge; leaving it full can stall it.
    /// This shares the request deadline, so log output cannot prolong a paste.
    fn wait_io(&mut self, events: i16, deadline: Instant) -> Result<()> {
        loop {
            let remaining =
                deadline.checked_duration_since(Instant::now()).ok_or("terminal-paste-timeout")?;
            let stderr = self._child.as_mut().and_then(|child| child.0.stderr.as_mut());
            let mut descriptors = [
                libc::pollfd { fd: self.socket.as_raw_fd(), events, revents: 0 },
                libc::pollfd {
                    fd: stderr.as_ref().map_or(-1, |pipe| pipe.as_raw_fd()),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            let millis = poll_millis(remaining);
            let result = unsafe { libc::poll(descriptors.as_mut_ptr(), 2, millis) };
            if result < 0 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err("terminal-paste-daemon-unavailable");
            }
            if result == 0 {
                return Err("terminal-paste-timeout");
            }
            if descriptors[1].revents != 0 {
                let mut discarded = [0; 8192];
                if let Some(stderr) = stderr {
                    match stderr.read(&mut discarded) {
                        Ok(0) | Err(_) => {
                            if let Some(child) = self._child.as_mut() {
                                child.0.stderr = None;
                            }
                        }
                        Ok(_) => {}
                    }
                }
            }
            if descriptors[0].revents & libc::POLLNVAL != 0 {
                return Err("terminal-paste-daemon-unavailable");
            }
            if descriptors[0].revents != 0 {
                return Ok(());
            }
        }
    }

    fn send(&mut self, message: &Value, deadline: Instant) -> Result<()> {
        let mut bytes =
            serde_json::to_vec(message).map_err(|_| "terminal-paste-invalid-request")?;
        bytes.push(b'\n');
        let mut rest = bytes.as_slice();
        while !rest.is_empty() {
            self.wait_io(libc::POLLOUT, deadline)?;
            match self.socket.write(rest) {
                Ok(0) => return Err("terminal-paste-daemon-unavailable"),
                Ok(n) => rest = rest.get(n..).ok_or("terminal-paste-daemon-unavailable")?,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(_) => return Err("terminal-paste-daemon-unavailable"),
            }
        }
        Ok(())
    }

    fn read_line(&mut self, deadline: Instant) -> Result<Value> {
        let mut scanned = 0;
        loop {
            if Instant::now() >= deadline {
                return Err("terminal-paste-timeout");
            }
            let newline = self
                .pending
                .get(scanned..)
                .and_then(|unscanned| unscanned.iter().position(|byte| *byte == b'\n'))
                .and_then(|relative| scanned.checked_add(relative));
            if let Some(end) = newline {
                let line: Vec<_> = self.pending.drain(..=end).collect();
                return serde_json::from_slice(&line)
                    .map_err(|_| "terminal-paste-daemon-unavailable");
            }
            if self.pending.len() >= MAX_LINE_BYTES {
                return Err("terminal-paste-daemon-unavailable");
            }
            scanned = self.pending.len();
            self.wait_io(libc::POLLIN, deadline)?;
            let mut buffer = [0; 8192];
            match self.socket.read(&mut buffer) {
                Ok(0) => return Err("terminal-paste-daemon-unavailable"),
                Ok(n) => self
                    .pending
                    .extend_from_slice(buffer.get(..n).ok_or("terminal-paste-daemon-unavailable")?),
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(_) => return Err("terminal-paste-daemon-unavailable"),
            }
        }
    }
}

struct Session {
    endpoint: Endpoint,
    next_id: u64,
    surface: Option<u64>,
    lease: String,
    terminal_id: String,
}

impl Session {
    fn open(request: &Request) -> Result<Self> {
        let mut session = Self {
            endpoint: Endpoint::open(request)?,
            next_id: 1,
            surface: None,
            lease: String::new(),
            terminal_id: request.terminal_id.clone(),
        };
        let identify = session.request("identify", json!({}))?;
        let data = identify.get("data").ok_or("terminal-paste-daemon-incompatible")?;
        if data.get("protocol").and_then(Value::as_u64) != Some(12) {
            return Err("terminal-paste-daemon-incompatible");
        }
        let capabilities = data
            .get("capabilities")
            .and_then(Value::as_array)
            .ok_or("terminal-paste-unsupported")?;
        let required = if request.image.is_some() {
            "terminal-image-paste-v1"
        } else {
            "terminal-file-paste-v1"
        };
        for capability in [required, "attach-identity-v1", "view-attachment-lease-v1"] {
            if !capabilities.iter().any(|value| value.as_str() == Some(capability)) {
                return Err("terminal-paste-unsupported");
            }
        }
        let generation =
            data.get("generation").and_then(Value::as_str).ok_or("terminal-paste-attach-failed")?;
        session.request(
            "set-client-info",
            json!({
                "name": "cmux-next-terminal-paste", "kind": "frontend",
                "capabilities": ["view-attachment-lease-v1"]
            }),
        )?;
        // No size and no geometry claim: pasting must never resize the program.
        let attached = session.request(
            "attach-surface",
            json!({
                "mode": "bytes", "replay_history_rows": 0,
                "expected_terminal_id": session.terminal_id, "expected_generation": generation
            }),
        )?;
        session.lease = attached
            .pointer("/data/lease")
            .and_then(Value::as_str)
            .ok_or("terminal-paste-attach-failed")?
            .to_owned();
        session.surface.ok_or("terminal-paste-attach-failed")?;
        Ok(session)
    }

    fn request(&mut self, command: &str, mut fields: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1);
        let object = fields.as_object_mut().ok_or("terminal-paste-invalid-request")?;
        object.insert("id".into(), json!(id));
        object.insert("cmd".into(), json!(command));
        let deadline = deadline_after(REQUEST_TIMEOUT)?;
        self.endpoint.send(&fields, deadline)?;
        loop {
            let response = self.endpoint.read_line(deadline)?;
            if let Some(event) = response.get("event") {
                if command == "attach-surface"
                    && self.surface.is_none()
                    && event.as_str() == Some("vt-state")
                {
                    self.surface = response.get("surface").and_then(Value::as_u64);
                }
                continue;
            }
            if response.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if response.get("ok") != Some(&Value::Bool(true)) {
                return Err("terminal-paste-daemon-rejected");
            }
            return Ok(response);
        }
    }

    fn upload(
        &mut self,
        mime: Option<&str>,
        filename: Option<&str>,
        size: u64,
        mut source: impl Read,
    ) -> Result<()> {
        let surface = self.surface.ok_or("terminal-paste-attach-failed")?;
        let upload_id = format!("{:032x}", self.next_id);
        let mut begin = json!({"surface": surface, "terminal_id": self.terminal_id,
            "lease": self.lease, "upload_id": upload_id, "op": "begin", "size": size});
        let fields = begin.as_object_mut().ok_or("terminal-paste-invalid-request")?;
        if let Some(mime) = mime {
            fields.insert("mime".into(), json!(mime));
        }
        if let Some(filename) = filename {
            fields.insert("filename".into(), json!(filename));
        }
        self.request("paste-image", begin)?;
        let mut offset = 0_u64;
        let mut buffer = [0; CHUNK_BYTES];
        while offset < size {
            let count = usize::try_from(size.saturating_sub(offset))
                .unwrap_or(CHUNK_BYTES)
                .min(CHUNK_BYTES);
            let chunk = buffer.get_mut(..count).ok_or("terminal-paste-invalid-request")?;
            source.read_exact(chunk).map_err(|_| "terminal-paste-file-changed")?;
            self.request(
                "paste-image",
                json!({
                    "surface": surface, "terminal_id": self.terminal_id, "lease": self.lease,
                    "upload_id": upload_id, "op": "chunk", "offset": offset,
                    "data": base64::engine::general_purpose::STANDARD.encode(&*chunk)
                }),
            )?;
            offset = offset.saturating_add(count as u64);
        }
        let mut extra = [0];
        if source.read(&mut extra).map_err(|_| "terminal-paste-file-unavailable")? != 0 {
            return Err("terminal-paste-file-changed");
        }
        self.request(
            "paste-image",
            json!({
                "surface": surface, "terminal_id": self.terminal_id, "lease": self.lease,
                "upload_id": upload_id, "op": "commit"
            }),
        )?;
        Ok(())
    }

    fn separator(&mut self) -> Result<()> {
        self.request("send", json!({"surface": self.surface, "text": " ", "paste": true}))?;
        Ok(())
    }
}

fn open_file(path: &str) -> Result<(File, String, u64)> {
    let name = Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or("terminal-paste-file-type-rejected")?;
    if name.len() > 255
        || name.contains(['/', '\\'])
        || name.chars().any(char::is_control)
        || [".", "..", ".receipt", ".receipt-next", ".cleanup-image"].contains(&name)
    {
        return Err("terminal-paste-file-type-rejected");
    }
    // O_NONBLOCK prevents a FIFO from hanging open before metadata can reject it.
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| "terminal-paste-file-unavailable")?;
    let metadata = file.metadata().map_err(|_| "terminal-paste-file-unavailable")?;
    if !metadata.is_file() {
        return Err("terminal-paste-file-type-rejected");
    }
    Ok((file, name.to_owned(), metadata.len()))
}

fn transfer(request: Request) -> Result<()> {
    if request.image.is_some() != request.files.is_empty() {
        return Err("terminal-paste-invalid-request");
    }
    let mut session = Session::open(&request)?;
    if let Some(image) = request.image {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(image.data)
            .map_err(|_| "terminal-paste-invalid-request")?;
        session.upload(Some(&image.mime), None, bytes.len() as u64, bytes.as_slice())?;
    } else {
        // Validate the full selection before the first path reaches the PTY.
        let files = request.files.iter().map(|path| open_file(path)).collect::<Result<Vec<_>>>()?;
        for (index, (file, name, size)) in files.into_iter().enumerate() {
            if index > 0 {
                session.separator()?;
            }
            session.upload(None, Some(&name), size, file)?;
        }
    }
    Ok(())
}

pub(crate) fn run() -> i32 {
    let result = serde_json::from_reader(io::stdin().lock())
        .map_err(|_| "terminal-paste-invalid-request")
        .and_then(transfer);
    match result {
        Ok(()) => {
            println!("{{\"accepted\":true}}");
            0
        }
        Err(error) => {
            eprintln!("{error}");
            1
        }
    }
}
