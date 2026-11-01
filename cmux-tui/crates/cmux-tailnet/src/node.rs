//! One tsnet node per process (the host binary, later the cmux daemon).

use std::ffi::{CStr, CString};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::raw::c_char;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

use crate::localapi::LocalApi;
use crate::{Error, Result, Status, Watch, WhoIs, ffi};

/// How the node joins the tailnet. Set before [`Node::start`]; tsnet reads
/// these once.
#[derive(Debug, Clone)]
pub struct NodeConfig {
    /// Where the node keeps its keys and login (made 0700). One node per folder.
    pub state_dir: PathBuf,
    /// The device name on the tailnet, and the first label of its MagicDNS name.
    pub hostname: String,
    /// A one-time auth key for headless sign-in. None: sign in with the
    /// browser link from [`Node::watch`] or [`Status::auth_url`].
    pub auth_key: Option<String>,
    /// A coordination server other than Tailscale's (Headscale).
    pub control_url: Option<String>,
    /// Remove the device from the tailnet when it goes offline.
    pub ephemeral: bool,
    /// Where tsnet writes its log. None: discarded (tsnet logs are verbose
    /// and can carry the sign-in link; the link is read from the API instead).
    pub log_fd: Option<RawFd>,
}

impl NodeConfig {
    pub fn new(state_dir: impl Into<PathBuf>, hostname: impl Into<String>) -> Self {
        Self {
            state_dir: state_dir.into(),
            hostname: hostname.into(),
            auth_key: None,
            control_url: None,
            ephemeral: false,
            log_fd: None,
        }
    }
}

pub struct Node {
    sd: ffi::Tailscale,
    local: OnceLock<std::result::Result<LocalApi, String>>,
    /// libtailscale keeps one unguarded "last error" per handle: every call
    /// that can set it runs with its errmsg read under this lock.
    calls: Mutex<()>,
    closed: AtomicBool,
}

unsafe impl Send for Node {}
unsafe impl Sync for Node {}

impl Node {
    pub fn new(config: &NodeConfig) -> Result<Self> {
        create_private_dir(&config.state_dir)?;
        let sd = unsafe { ffi::tailscale_new() };
        let node = Self {
            sd,
            local: OnceLock::new(),
            calls: Mutex::new(()),
            closed: AtomicBool::new(false),
        };
        let dir = cstring(config.state_dir.to_string_lossy().as_ref())?;
        node.call(|| unsafe { ffi::tailscale_set_dir(sd, dir.as_ptr()) })?;
        let hostname = cstring(&config.hostname)?;
        node.call(|| unsafe { ffi::tailscale_set_hostname(sd, hostname.as_ptr()) })?;
        if let Some(key) = &config.auth_key {
            let key = cstring(key.trim())?;
            node.call(|| unsafe { ffi::tailscale_set_authkey(sd, key.as_ptr()) })?;
        }
        if let Some(url) = &config.control_url {
            let url = cstring(url)?;
            node.call(|| unsafe { ffi::tailscale_set_control_url(sd, url.as_ptr()) })?;
        }
        node.call(|| unsafe { ffi::tailscale_set_ephemeral(sd, config.ephemeral as i32) })?;
        node.call(|| unsafe { ffi::tailscale_set_logfd(sd, config.log_fd.unwrap_or(-1)) })?;
        Ok(node)
    }

    /// Connects to the tailnet without waiting for sign-in. A node with no
    /// saved login and no auth key goes to NeedsLogin and offers a sign-in
    /// link ([`Node::watch`]).
    pub fn start(&self) -> Result<()> {
        self.call(|| unsafe { ffi::tailscale_start(self.sd) })
    }

    /// The node's current status (ipnstate.Status), read in memory.
    pub fn status(&self) -> Result<Status> {
        let mut json: *mut c_char = std::ptr::null_mut();
        self.call(|| unsafe { ffi::tailscale_status_json(self.sd, &mut json) })?;
        if json.is_null() {
            return Err(Error("status: no data".into()));
        }
        let text = unsafe { CStr::from_ptr(json) }.to_string_lossy().into_owned();
        unsafe { libc::free(json.cast()) };
        serde_json::from_str(&text).map_err(|error| Error(format!("status: {error}")))
    }

    /// State changes as they happen: sign-in link, Running, errors. Blocking
    /// iterator; run it on its own thread.
    pub fn watch(&self) -> Result<Watch> {
        self.local_api()?.watch()
    }

    /// Signs out and removes the saved login, without deleting unrelated state.
    pub fn logout(&self) -> Result<()> {
        self.local_api()?.logout()
    }

    /// Requests a new sign-in URL, delivered on the IPN state stream.
    pub fn login_interactive(&self) -> Result<()> {
        self.local_api()?.login_interactive()
    }

    /// Closes the node once, waking its state stream and network listeners.
    /// Like other Node operations, run this on a background thread.
    pub fn close(&self) -> Result<()> {
        let _guard = self.calls.lock().unwrap_or_else(|e| e.into_inner());
        if self.closed.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        if unsafe { ffi::tailscale_close(self.sd) } == 0 {
            Ok(())
        } else {
            Err(Error("could not close tailnet node".into()))
        }
    }

    /// Who is at a tailnet IP (or IP:port), from the node's control plane.
    /// Takes the bracketed IPv6 form libtailscale reports (`[fd7a::1]`) too.
    pub fn whois(&self, addr: &str) -> Result<WhoIs> {
        let addr = addr.strip_prefix('[').and_then(|ip| ip.strip_suffix(']')).unwrap_or(addr);
        self.local_api()?.whois(addr)
    }

    /// Fetches a Tailscale-issued certificate/key PEM pair for `domain` from
    /// the node's LocalAPI. The result is intentionally opaque to this crate;
    /// callers parse it for their TLS stack and keep it in memory.
    pub fn certificate_pair(&self, domain: &str) -> Result<Vec<u8>> {
        self.local_api()?.certificate_pair(domain)
    }

    /// This node's tailnet addresses.
    pub fn ips(&self) -> Result<Vec<String>> {
        let mut buf = vec![0 as c_char; 256];
        self.call(|| unsafe { ffi::tailscale_getips(self.sd, buf.as_mut_ptr(), buf.len()) })?;
        let text = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned();
        Ok(text.split(',').filter(|ip| !ip.is_empty()).map(str::to_owned).collect())
    }

    /// Listens for TCP on this node's tailnet addresses only (never on a
    /// LAN or public interface).
    pub fn listen_tcp(&self, port: u16) -> Result<Listener> {
        let network = cstring("tcp")?;
        let addr = cstring(&format!(":{port}"))?;
        let mut fd = -1;
        self.call(|| unsafe {
            ffi::tailscale_listen(self.sd, network.as_ptr(), addr.as_ptr(), &mut fd)
        })?;
        close_on_exec(fd);
        Ok(Listener { fd })
    }

    /// A TCP connection to `addr` (`host:port`, a MagicDNS name or tailnet IP) over the tailnet.
    /// Holds the call lock while it connects.
    pub fn dial_tcp(&self, addr: &str) -> Result<UnixStream> {
        let network = cstring("tcp")?;
        let addr = cstring(addr)?;
        let mut fd = -1;
        self.call(|| unsafe {
            ffi::tailscale_dial(self.sd, network.as_ptr(), addr.as_ptr(), &mut fd)
        })?;
        close_on_exec(fd);
        Ok(unsafe { UnixStream::from_raw_fd(fd) })
    }

    fn local_api(&self) -> Result<&LocalApi> {
        if self.closed.load(Ordering::Acquire) {
            return Err(Error("node closed".into()));
        }
        self.local
            .get_or_init(|| {
                let mut addr = vec![0 as c_char; 128];
                let mut proxy = vec![0 as c_char; 33];
                let mut local = vec![0 as c_char; 33];
                self.call(|| unsafe {
                    ffi::tailscale_loopback(
                        self.sd,
                        addr.as_mut_ptr(),
                        addr.len(),
                        proxy.as_mut_ptr(),
                        local.as_mut_ptr(),
                    )
                })
                .map_err(|error| error.0)?;
                let addr = unsafe { CStr::from_ptr(addr.as_ptr()) }.to_string_lossy().into_owned();
                let local =
                    unsafe { CStr::from_ptr(local.as_ptr()) }.to_string_lossy().into_owned();
                LocalApi::new(&addr, &local).map_err(|e| e.0)
            })
            .as_ref()
            .map_err(|message| Error(message.clone()))
    }

    /// Runs one libtailscale call and reads its error under the call lock.
    fn call(&self, f: impl FnOnce() -> i32) -> Result<()> {
        let _serialized = self.calls.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.closed.load(Ordering::Acquire) {
            return Err(Error("node closed".into()));
        }
        let code = f();
        match code {
            0 => Ok(()),
            libc::EBADF => Err(Error("libtailscale: bad handle".into())),
            libc::ERANGE => Err(Error("libtailscale: buffer too small".into())),
            _ => Err(Error(self.message())),
        }
    }

    fn message(&self) -> String {
        let mut buf = vec![0 as c_char; 1024];
        if unsafe { ffi::tailscale_errmsg(self.sd, buf.as_mut_ptr(), buf.len()) } != 0 {
            return "libtailscale: unknown error".into();
        }
        unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

const LISTENER_CLOSED: &str = "listener closed";

/// A TCP listener on the tailnet. Each accepted connection carries the
/// peer's tailnet IP, which is what [`Node::whois`] takes.
pub struct Listener {
    fd: ffi::TailscaleListener,
}

impl Listener {
    /// Blocks until a peer connects.
    pub fn accept(&self) -> Result<(UnixStream, String)> {
        let mut conn = -1;
        match unsafe { ffi::tailscale_accept(self.fd, &mut conn) } {
            0 => {}
            libc::EBADF => return Err(Error(LISTENER_CLOSED.into())),
            _ => return Err(Error("accept failed".into())),
        }
        close_on_exec(conn);
        let stream = unsafe { UnixStream::from_raw_fd(conn) };
        let mut buf = vec![0 as c_char; 64];
        if unsafe { ffi::tailscale_getremoteaddr(self.fd, conn, buf.as_mut_ptr(), buf.len()) } != 0
        {
            return Err(Error("accept: no remote address".into()));
        }
        let remote = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned();
        Ok((stream, remote))
    }
}

impl AsRawFd for Listener {
    fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

impl Listener {
    /// Nonblocking readiness check for libtailscale's fixed-size accept record.
    /// A single owner must consume the listener; incomplete records stay queued.
    pub fn try_accept(&mut self) -> std::io::Result<Option<(UnixStream, String)>> {
        let mut record = [0_u8; 64];
        let n = unsafe {
            libc::recv(
                self.fd,
                record.as_mut_ptr().cast(),
                record.len(),
                libc::MSG_PEEK | libc::MSG_DONTWAIT,
            )
        };
        if n < 0 {
            let error = std::io::Error::last_os_error();
            return if error.kind() == std::io::ErrorKind::WouldBlock {
                Ok(None)
            } else {
                Err(error)
            };
        }
        if n == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "tailnet listener closed",
            ));
        }
        if n < record.len() as isize {
            let mut poll = libc::pollfd { fd: self.fd, events: libc::POLLIN, revents: 0 };
            if unsafe { libc::poll(&mut poll, 1, 0) } > 0 && poll.revents & libc::POLLHUP != 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "incomplete tailnet accept record",
                ));
            }
            return Ok(None);
        }
        // EBADF keeps its errno, so a caller can tell a closed listener (stop) from one record
        // that failed (accept again).
        self.accept().map(Some).map_err(|e| {
            if e.0 == LISTENER_CLOSED {
                std::io::Error::from_raw_os_error(libc::EBADF)
            } else {
                std::io::Error::other(e.0)
            }
        })
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        // libtailscale stops listening once a read on its end of this socketpair sees EOF. A
        // process forked meanwhile can hold a copy of our end (until its exec, or past it with a
        // libtailscale that does not set close-on-exec), and close alone sends no EOF while a
        // copy is open, so tsnet would keep accepting. Shutdown acts on the socket, whatever
        // copies remain.
        unsafe {
            libc::shutdown(self.fd, libc::SHUT_RDWR);
            libc::close(self.fd);
        }
    }
}

/// Marks an fd from libtailscale close-on-exec. Our libtailscale patch already creates and
/// receives them that way (`patches/0002-fds-close-on-exec.patch`); this keeps them from
/// leaking into every process the host spawns if a libtailscale without it is linked
/// (`LIBTAILSCALE_A`). An inherited copy outlives our close: the socket stays open, so
/// libtailscale sees no EOF and keeps the listener or connection alive.
fn close_on_exec(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 && flags & libc::FD_CLOEXEC == 0 {
            libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
    }
}

fn cstring(value: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error("NUL byte in node configuration".into()))
}

fn create_private_dir(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .and_then(|()| std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)))
        .map_err(|error| Error(format!("state dir {}: {error}", path.display())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::fd::IntoRawFd;

    #[test]
    fn invalid_configuration_never_reports_secret_values() {
        let error = cstring("private-auth-key\0suffix").unwrap_err().to_string();
        assert_eq!(error, "NUL byte in node configuration");
        assert!(!error.contains("private-auth-key"));
    }

    /// libtailscale tears its listener down when a read on its end of the socketpair returns
    /// EOF. A process spawned while the listener is open holds a copy of our end; dropping the
    /// listener must still end libtailscale's side.
    #[test]
    fn dropping_a_listener_ends_libtailscales_side_while_a_child_holds_a_copy() {
        use std::io::Read;
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let listener = Listener { fd: ours.into_raw_fd() };
        let inherited = unsafe { libc::dup(listener.fd) };
        assert!(inherited >= 0, "dup: {}", std::io::Error::last_os_error());
        drop(listener);
        theirs.set_nonblocking(true).unwrap();
        let mut byte = [0_u8; 1];
        assert_eq!(theirs.read(&mut byte).unwrap(), 0, "libtailscale's side must read EOF");
        unsafe { libc::close(inherited) };
    }

    #[test]
    fn accept_readiness_does_not_block_and_detects_truncated_close() {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        let mut listener = Listener { fd: reader.into_raw_fd() };
        assert!(listener.try_accept().unwrap().is_none());
        writer.write_all(b"partial").unwrap();
        assert!(listener.try_accept().unwrap().is_none());
        drop(writer);
        assert_eq!(listener.try_accept().unwrap_err().kind(), std::io::ErrorKind::UnexpectedEof);
    }
}
