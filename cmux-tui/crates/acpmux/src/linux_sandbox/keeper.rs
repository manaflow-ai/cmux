//! Own the sandbox command and its host-side services in one process.
//!
//! Claude may be a daemon child or live in an agent host that survives daemon
//! restarts (including auto-updates). The proxy and notification supervisor
//! must live exactly as long as Claude: tying them to the daemon would lose
//! networking and could hang notified syscalls or undermine fail-closed handling.
//! A keeper owns the handoff socketpair, starts bwrap with unchanged standard
//! streams, and owns services until bwrap exits. SpawnPlan and both spawn paths
//! therefore need no additional descriptor plumbing.
//!
//! Linux remote chains require the bwrap probe and session canary to pass.
//! The supervisor enforces persistence write-opens, renames and creators.
//! Collection loops stop at finite input exhaustion.
//! Service loops stop on child exit, cancellation, or runtime teardown; the
//! supervisor thread stops on its eventfd or listener hangup.
pub(crate) use crate::hub::remote_sandbox::loader_env_key;

use super::{bwrap, proxy, rules, supervisor};
use bwrap::Paths;
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::{self, Read};
use std::net::{Ipv4Addr, SocketAddr, TcpListener};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Stdio};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use tokio::io::unix::AsyncFd;
use tokio::process::{Child, Command};
use tokio::signal::unix::{Signal, SignalKind, signal};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;
type Result<T> = std::result::Result<T, String>;

/// The supervisor stops when the sandbox child exits, the listener hangs up,
/// or keeper setup fails; dropping this guard signals its eventfd and joins it.
struct SupervisorHandle {
    stop: OwnedFd,
    join: Option<JoinHandle<io::Result<()>>>,
}
impl SupervisorHandle {
    fn start(notify: OwnedFd, policy: rules::WritePolicy) -> Result<Self> {
        let raw = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if raw < 0 {
            return Err(format!("create supervisor stop eventfd: {}", io::Error::last_os_error()));
        }
        // SAFETY: eventfd returned a new owned descriptor.
        let stop = unsafe { OwnedFd::from_raw_fd(raw) };
        let thread_stop =
            stop.try_clone().map_err(|e| format!("clone supervisor stop eventfd: {e}"))?;
        let join = thread::Builder::new()
            .name("acpmux-sandbox-supervisor".into())
            .spawn(move || supervisor::run(notify, policy, thread_stop))
            .map_err(|e| format!("start sandbox supervisor: {e}"))?;
        Ok(Self { stop, join: Some(join) })
    }

    fn signal(&self) -> Result<()> {
        let one = 1u64;
        let size = std::mem::size_of::<u64>();
        // SAFETY: stop is an eventfd and the pointer references one u64.
        let written =
            unsafe { libc::write(self.stop.as_raw_fd(), (&one as *const u64).cast(), size as _) };
        if written == size as isize
            || (written < 0 && io::Error::last_os_error().kind() == io::ErrorKind::WouldBlock)
        {
            Ok(())
        } else {
            Err(format!("stop sandbox supervisor: {}", io::Error::last_os_error()))
        }
    }

    fn stop_join(mut self) -> Result<()> {
        self.signal()?;
        let join = self.join.take().ok_or("sandbox supervisor already joined")?;
        join.join()
            .map_err(|_| "sandbox supervisor thread panicked".to_owned())?
            .map_err(|e| format!("sandbox supervisor: {e}"))
    }
}
impl Drop for SupervisorHandle {
    fn drop(&mut self) {
        let _ = self.signal();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}
/// Hidden canary helper; the parent's 20-second canary deadline bounds connect.
/// Only an explicit permission denial proves the Unix-socket boundary held.
pub(crate) fn canary_unix(args: &[OsString]) -> Result<()> {
    let [path] = args else {
        return Err("expected one Unix socket path".into());
    };
    match UnixStream::connect(path) {
        Ok(_) => println!("unix=0"),
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => println!("unix=1"),
        Err(e) => return Err(format!("Unix canary could not run: {e}")),
    }
    Ok(())
}

/// Hidden canary helper; rename(2) runs exactly once for the supplied pair.
/// It reports only the two supervisor denial errnos; all other errors refuse.
pub(crate) fn canary_rename(args: &[OsString]) -> Result<()> {
    let [source, destination] = args else {
        return Err("expected source and destination paths".into());
    };
    let source =
        std::ffi::CString::new(source.as_encoded_bytes()).map_err(|_| "source contains NUL")?;
    let destination = std::ffi::CString::new(destination.as_encoded_bytes())
        .map_err(|_| "destination contains NUL")?;
    // SAFETY: both strings are NUL-terminated and remain live for the call.
    if unsafe { libc::rename(source.as_ptr(), destination.as_ptr()) } == 0 {
        println!("rename=0");
        return Ok(());
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::EPERM | libc::EACCES) => {
            println!("rename=1");
            Ok(())
        }
        _ => Err(format!("canary rename: {error}")),
    }
}

#[derive(Debug)]
struct Options {
    paths: Paths,
    proxy_port: u16,
    api: Option<SocketAddr>,
    program: String,
    args: Vec<String>,
}
fn absolute(value: &str) -> Result<PathBuf> {
    let path = PathBuf::from(value);
    if !path.is_absolute() || path.components().any(|c| c == std::path::Component::ParentDir) {
        return Err(format!("expected absolute path without ..: {value:?}"));
    }
    Ok(path)
}
/// Argument iteration ends at --, exhausted input, or the first invalid option.
fn parse(args: Vec<OsString>) -> Result<Options> {
    let args = args
        .into_iter()
        .map(|s| s.into_string().map_err(|_| "arguments must be UTF-8"))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    if args.iter().any(|s| s.contains('\0')) {
        return Err("argument contains NUL".into());
    }
    let end = args.iter().position(|s| s == "--").ok_or("missing --")?;
    let mut values = BTreeMap::new();
    let mut input = args.get(..end).unwrap_or_default().iter();
    while let Some(flag) = input.next() {
        let value = match flag.as_str() {
            "--api-loopback-v4" | "--api-loopback-v6" => "",
            "--cwd"
            | "--tmpdir"
            | "--home"
            | "--claude-tmp-project"
            | "--claude-project"
            | "--proxy-port"
            | "--api-port" => input.next().ok_or_else(|| format!("missing value for {flag}"))?,
            _ => return Err(format!("unknown option: {flag}")),
        };
        if values.insert(flag.as_str(), value).is_some() {
            return Err(format!("duplicate {flag}"));
        }
    }
    let required = |key| values.get(key).copied().ok_or_else(|| format!("missing {key}"));
    let port = |value: &str| -> Result<u16> {
        if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
            return Err("invalid port".into());
        }
        value.parse::<u16>().ok().filter(|p| *p != 0).ok_or_else(|| "invalid port".into())
    };
    let proxy_port = port(required("--proxy-port")?)?;
    let api_port = values.get("--api-port").map(|v| port(v)).transpose()?;
    let v4 = values.contains_key("--api-loopback-v4");
    let v6 = values.contains_key("--api-loopback-v6");
    if v6 {
        return Err(
            "IPv6 API loopback is unavailable until the init handshake carries its family".into()
        );
    }
    if (v4 && v6) || api_port.is_some() != (v4 || v6) || api_port == Some(proxy_port) {
        return Err("API needs one loopback family and a port distinct from the proxy".into());
    }
    let program = args.get(end + 1).ok_or("missing program after --")?;
    absolute(program)?;
    Ok(Options {
        paths: Paths {
            cwd: absolute(required("--cwd")?)?,
            tmp: absolute(required("--tmpdir")?)?,
            home: absolute(required("--home")?)?,
            claude_tmp_project: absolute(required("--claude-tmp-project")?)?,
            claude_project: absolute(required("--claude-project")?)?,
        },
        proxy_port,
        api: api_port.map(|p| SocketAddr::new(Ipv4Addr::LOCALHOST.into(), p)),
        program: program.clone(),
        args: args.get(end + 2..).unwrap_or_default().to_vec(),
    })
}
fn validate_handoff_with_notify(
    payload: &[u8],
    mut fds: Vec<OwnedFd>,
    proxy_port: u16,
    api_port: Option<u16>,
) -> Result<(Vec<TcpListener>, OwnedFd)> {
    let expected = 1 + usize::from(api_port.is_some());
    if fds.len() != expected + 1 {
        return Err("handoff missing supervisor notification fd".into());
    }
    let notify = fds.pop().ok_or("handoff missing supervisor notification fd")?;
    let listeners = validate_handoff_inner(payload, fds, proxy_port, api_port, true)?;
    validate_notify_fd(notify.as_raw_fd())?;
    Ok((listeners, notify))
}

fn validate_notify_fd(_fd: RawFd) -> Result<()> {
    let mut id = 0u64;
    let request = libc::SECCOMP_IOCTL_NOTIF_ID_VALID as _;
    // SAFETY: the request reads the initialized notification id only.
    let result = unsafe { libc::ioctl(_fd, request, &mut id) };
    if result == 0 {
        return Err("handoff fd is not a seccomp listener (notification id accepted)".into());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() != Some(libc::ENOENT) {
        return Err(format!("handoff fd is not a seccomp listener: {error}"));
    }
    let target = std::fs::read_link(format!("/proc/self/fd/{_fd}"))
        .map_err(|e| format!("handoff fd is not a seccomp listener: {e}"))?;
    if target != Path::new("anon_inode:seccomp notify") {
        return Err("handoff fd is not a seccomp listener (wrong inode type)".into());
    }
    Ok(())
}

fn validate_handoff_inner(
    payload: &[u8],
    fds: Vec<OwnedFd>,
    proxy_port: u16,
    api_port: Option<u16>,
    prove_namespace: bool,
) -> Result<Vec<TcpListener>> {
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Ports {
        proxy: u16,
        api: serde_json::Value,
    }
    let ports: Ports = serde_json::from_slice(payload).map_err(|e| format!("handoff JSON: {e}"))?;
    if ports.proxy != proxy_port
        || ports.api != serde_json::json!(api_port)
        || fds.len() != 1 + usize::from(api_port.is_some())
        || proxy_port == 0
    {
        return Err("handoff descriptor count or JSON ports mismatch".into());
    }
    fds.into_iter()
        .zip(std::iter::once(proxy_port).chain(api_port))
        .map(|(fd, port)| {
            for (option, expected) in [
                (libc::SO_TYPE, libc::SOCK_STREAM),
                (libc::SO_ACCEPTCONN, 1),
                (libc::SO_PROTOCOL, libc::IPPROTO_TCP),
            ] {
                let mut value: libc::c_int = 0;
                let mut len = std::mem::size_of_val(&value) as libc::socklen_t;
                let raw = fd.as_raw_fd();
                let output = (&mut value as *mut libc::c_int).cast();
                // SAFETY: fd is live and the correctly sized output buffers are writable.
                if unsafe { libc::getsockopt(raw, libc::SOL_SOCKET, option, output, &mut len) } != 0
                    || value != expected
                {
                    return Err("handoff fd is not a listening TCP socket".into());
                }
            }
            if prove_namespace && listener_in_keeper_namespace(fd.as_raw_fd())? {
                return Err("handoff listener is in the keeper network namespace".into());
            }
            let listener = TcpListener::from(fd);
            if listener.local_addr().map_err(|e| e.to_string())?
                != SocketAddr::from((Ipv4Addr::LOCALHOST, port))
            {
                return Err("handoff listener address mismatch".into());
            }
            listener.set_nonblocking(true).map_err(|e| e.to_string())?;
            Ok(listener)
        })
        .collect()
}
#[cfg(test)]
fn validate_handoff_for_test(
    payload: &[u8],
    fds: Vec<OwnedFd>,
    proxy_port: u16,
    api_port: Option<u16>,
) -> Result<Vec<TcpListener>> {
    validate_handoff_inner(payload, fds, proxy_port, api_port, false)
}
const SIOCGSKNS: libc::c_ulong = 0x894c;
fn stat_fd(fd: RawFd) -> Result<(u64, u64)> {
    // SAFETY: `stat` is an initialized output buffer and fd is owned by caller.
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        return Err(io::Error::last_os_error().to_string());
    }
    Ok((stat.st_dev as u64, stat.st_ino as u64))
}
fn listener_in_keeper_namespace(fd: RawFd) -> Result<bool> {
    // SAFETY: fd is a live socket; SIOCGSKNS returns a descriptor, not an output buffer.
    let netns = unsafe { libc::ioctl(fd, SIOCGSKNS as _, 0) };
    if netns < 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EPERM) {
            return Err(
                "handoff listener is not in the sandbox network namespace (SIOCGSKNS: EPERM)"
                    .into(),
            );
        }
        return Err(error.to_string());
    }
    // SAFETY: successful SIOCGSKNS returns a new owned descriptor.
    let netns = unsafe { OwnedFd::from_raw_fd(netns) };
    let current = std::fs::File::open("/proc/self/ns/net").map_err(|e| e.to_string())?;
    Ok(stat_fd(netns.as_raw_fd())? == stat_fd(current.as_raw_fd())?)
}
/// Ancillary traversal stops at the kernel-provided buffer end. Every received
/// descriptor is owned before any truncation/error return, so rejection closes it.
fn recv_chunk(fd: RawFd, bytes: &mut [u8]) -> io::Result<(usize, Vec<OwnedFd>)> {
    let mut control = [0usize; 8];
    let mut iov = libc::iovec { iov_base: bytes.as_mut_ptr().cast(), iov_len: bytes.len() as _ };
    // SAFETY: message, iovec and aligned ancillary storage remain live throughout
    // recvmsg and traversal; SCM_RIGHTS supplies new descriptors owned only here.
    unsafe {
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1 as _;
        msg.msg_control = control.as_mut_ptr().cast();
        msg.msg_controllen = std::mem::size_of_val(&control) as _;
        let n = libc::recvmsg(fd, &mut msg, libc::MSG_CMSG_CLOEXEC | libc::MSG_DONTWAIT);
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut fds = Vec::new();
        let mut unexpected = false;
        let mut header = libc::CMSG_FIRSTHDR(&msg);
        while !header.is_null() {
            if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
                let cmsg_len = (*header).cmsg_len;
                let length: usize = cmsg_len as _;
                if length < libc::CMSG_LEN(0) as usize {
                    return Err(io::Error::other("invalid handoff control length"));
                }
                let count = (length - libc::CMSG_LEN(0) as usize) / std::mem::size_of::<RawFd>();
                for index in 0..count {
                    fds.push(OwnedFd::from_raw_fd(std::ptr::read_unaligned(
                        libc::CMSG_DATA(header).cast::<RawFd>().add(index),
                    )));
                }
            } else {
                unexpected = true;
            }
            header = libc::CMSG_NXTHDR(&msg, header);
        }
        if unexpected || msg.msg_flags & (libc::MSG_CTRUNC | libc::MSG_TRUNC) != 0 {
            return Err(io::Error::other("unexpected or truncated handoff control data"));
        }
        Ok((n as usize, fds))
    }
}
/// Stops at newline, EOF/error, 1024 bytes or excess descriptors. The caller's
/// twenty-second deadline and child/signal handling bound readiness waits.
async fn handoff(socket: &AsyncFd<UnixStream>) -> Result<(Vec<u8>, Vec<OwnedFd>)> {
    let mut bytes = Vec::new();
    let mut fds = Vec::new();
    while bytes.len() < 1024 {
        let mut chunk = [0u8; 1024];
        let mut ready = socket.readable().await.map_err(|e| e.to_string())?;
        let result = ready.try_io(|s| {
            recv_chunk(s.as_raw_fd(), chunk.get_mut(..1024 - bytes.len()).unwrap_or_default())
        });
        let (n, received) = match result {
            Err(_) => continue,
            Ok(result) => result.map_err(|e| e.to_string())?,
        };
        fds.extend(received);
        if n == 0 || fds.len() > 3 {
            return Err("handoff EOF or excess descriptors".into());
        }
        bytes.extend_from_slice(chunk.get(..n).unwrap_or_default());
        if bytes.contains(&b'\n') {
            return Ok((bytes, fds));
        }
    }
    Err("oversized handoff JSON".into())
}
fn exit_code(status: ExitStatus) -> i32 {
    status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(libc::SIGKILL))
}
fn secure_ancestors(path: &std::path::Path) -> Result<()> {
    for ancestor in path.ancestors() {
        let metadata = std::fs::symlink_metadata(ancestor).map_err(|e| e.to_string())?;
        if metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
            return Err(format!("untrusted bwrap ancestor: {}", ancestor.display()));
        }
    }
    Ok(())
}
fn open_bwrap() -> Result<OwnedFd> {
    let path = PathBuf::from("/usr/bin/bwrap");
    secure_ancestors(&path)?;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&path)
        .map_err(|e| format!("open /usr/bin/bwrap: {e}"))?;
    let fd: OwnedFd = file.into();
    let (dev, ino) = stat_fd(fd.as_raw_fd())?;
    let metadata = file_metadata(fd.as_raw_fd())?;
    if metadata.uid() != 0
        || metadata.mode() & 0o022 != 0
        || metadata.mode() & libc::S_IFMT != libc::S_IFREG
        || dev == 0
        || ino == 0
    {
        return Err("/usr/bin/bwrap is not a root-owned non-writable regular file".into());
    }
    Ok(fd)
}
fn file_metadata(fd: RawFd) -> Result<std::fs::Metadata> {
    let proc = format!("/proc/self/fd/{fd}");
    std::fs::metadata(proc).map_err(|e| e.to_string())
}
/// Open the host executable once. The fd is mounted read-only inside bwrap,
/// so replacing its pathname cannot change the init inode after this check.
fn executable(denies: &[PathBuf], writable: &[PathBuf]) -> Result<(OwnedFd, PathBuf)> {
    let exe = std::env::current_exe().and_then(std::fs::canonicalize).map_err(|e| e.to_string())?;
    if exe.to_str().is_none()
        || denies.iter().chain(writable).any(|p| exe.starts_with(p))
        || exe.starts_with("/dev")
        || exe.starts_with("/proc")
    {
        return Err("keeper executable is masked or not UTF-8".into());
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&exe)
        .map_err(|e| e.to_string())?;
    let fd: OwnedFd = file.into();
    if !file_metadata(fd.as_raw_fd())?.is_file() {
        return Err("keeper executable is not a readable regular file".into());
    }
    Ok((fd, exe))
}
// Pin before any wait/reap; the descriptor cannot target a recycled PID.
fn open_pidfd(pid: u32) -> io::Result<OwnedFd> {
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0 as libc::c_uint) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a successful pidfd_open returns a new owned descriptor.
    Ok(unsafe { OwnedFd::from_raw_fd(fd as _) })
}
fn signal_pidfd(fd: RawFd, number: libc::c_int) -> io::Result<()> {
    // SAFETY: null siginfo requests the kernel-generated signal information.
    let result = unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            fd,
            number,
            std::ptr::null::<libc::siginfo_t>(),
            0 as libc::c_uint,
        )
    };
    if result < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}
/// Stops on the child-exit cancellation token, closed signal stream, or
/// forwarding error. The owned pidfd only ever addresses the original child.
async fn forward_signals(
    pidfd: OwnedFd,
    signals: [Signal; 3],
    stop: CancellationToken,
) -> Result<i32> {
    let [mut term, mut int, mut hup] = signals;
    loop {
        let (received, number) = tokio::select! {
            biased;
            _ = stop.cancelled() => return Ok(0),
            v = term.recv() => (v, libc::SIGTERM),
            v = int.recv() => (v, libc::SIGINT),
            v = hup.recv() => (v, libc::SIGHUP),
        };
        if received.is_none() {
            return Err("signal stream closed".into());
        }
        if let Err(error) = signal_pidfd(pidfd.as_raw_fd(), number)
            && error.raw_os_error() != Some(libc::ESRCH)
        {
            return Err(error.to_string());
        }
    }
}
/// Poll through synchronous listener setup before ack. The pending service is
/// then owned by the JoinSet and stops on cancellation or runtime teardown.
async fn start_service(
    services: &mut JoinSet<io::Result<()>>,
    future: impl std::future::Future<Output = io::Result<()>> + Send + 'static,
) -> Result<()> {
    let mut future = Box::pin(future);
    let startup = std::future::poll_fn(|cx| std::task::Poll::Ready(future.as_mut().poll(cx))).await;
    match startup {
        std::task::Poll::Pending => {}
        std::task::Poll::Ready(result) => {
            return Err(format!("sandbox service failed during startup: {result:?}"));
        }
    }
    services.spawn(future);
    Ok(())
}
/// Handoff ends within 20 s or on child exit. Services stop on child exit,
/// accept failure, cancellation or future drop; JoinSet drop aborts all tunnels.
async fn session(
    child: &mut Child,
    socket: UnixStream,
    options: &Options,
    policy: rules::WritePolicy,
    relay_stop: CancellationToken,
) -> Result<i32> {
    socket.set_nonblocking(true).map_err(|e| e.to_string())?;
    let socket = AsyncFd::new(socket).map_err(|e| e.to_string())?;
    let (payload, fds) = tokio::select! {
        status = child.wait() => {
            relay_stop.cancel();
            return Err(format!("bwrap exited before handoff: {status:?}"));
        },
        result = tokio::time::timeout(Duration::from_secs(20), handoff(&socket)) => result.map_err(|_| "handoff timed out after 20 s")??,
    };
    // G1b SUPERVISOR HOOK: the init helper sends listeners followed by the
    // notify fd. The supervisor owns it before ack, so no target can exec
    // without a host receiver for every notified write-open.
    let (listeners, notify) = validate_handoff_with_notify(
        &payload,
        fds,
        options.proxy_port,
        options.api.map(|a| a.port()),
    )?;
    let mut listeners = listeners.into_iter();
    let supervisor = SupervisorHandle::start(notify, policy)?;
    let stop = CancellationToken::new();
    let mut services = JoinSet::new();
    let policy = proxy::NetPolicy { api: options.api.map(|a| (a.port(), true)) };
    start_service(
        &mut services,
        proxy::serve_proxy(listeners.next().ok_or("missing proxy listener")?, policy, stop.clone()),
    )
    .await?;
    if let Some(target) = options.api {
        start_service(
            &mut services,
            proxy::serve_forward(
                listeners.next().ok_or("missing API listener")?,
                target,
                stop.clone(),
            ),
        )
        .await?;
    }
    let fd = socket.as_raw_fd();
    let flags = libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT;
    // SAFETY: live socket and one readable byte; never block or raise SIGPIPE.
    if unsafe { libc::send(fd, b"1".as_ptr().cast(), 1, flags) } != 1 {
        return Err(format!("handoff ack: {}", io::Error::last_os_error()));
    }
    drop(socket);
    let result = tokio::select! {
        status = child.wait() => {
            relay_stop.cancel();
            status.map(exit_code).map_err(|e| e.to_string())
        },
        service = services.join_next() => Err(format!("sandbox service ended: {service:?}")),
    };
    stop.cancel();
    // Cancellation stops proxy and forward loops; shutdown awaits every task
    // before the supervisor eventfd is joined and the keeper exits.
    services.shutdown().await;
    let supervisor_result = supervisor.stop_join();
    match (result, supervisor_result) {
        (Err(error), _) => Err(error),
        (Ok(code), Ok(_)) => Ok(code),
        (Ok(_), Err(error)) => Err(error),
    }
}

fn init_prefix(
    exe: &Path,
    daemon_prefix: Vec<OsString>,
    handoff_fd: RawFd,
    proxy_port: u16,
    api: Option<SocketAddr>,
) -> Result<Vec<String>> {
    let mut prefix = vec![exe.to_str().ok_or("non-UTF-8 executable")?.to_owned()];
    prefix.extend(
        daemon_prefix
            .into_iter()
            .map(|s| s.into_string().map_err(|_| "non-UTF-8 invocation prefix"))
            .collect::<std::result::Result<Vec<_>, _>>()?,
    );
    prefix.extend([
        "__remote-sandbox-init".into(),
        "--handoff-fd".into(),
        handoff_fd.to_string(),
        "--proxy-port".into(),
        proxy_port.to_string(),
    ]);
    if let Some(api) = api {
        prefix.extend(["--api-port".into(), api.port().to_string()]);
    }
    prefix.push("--".into());
    Ok(prefix)
}

/// Setup collections are finite. Signal relay ends with session; on failure,
/// SIGKILL/reaping has a five-second deadline and kill_on_drop is a final backstop.
async fn run(options: Options) -> Result<i32> {
    let term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let int = signal(SignalKind::interrupt()).map_err(|e| e.to_string())?;
    let hup = signal(SignalKind::hangup()).map_err(|e| e.to_string())?;
    let paths = &options.paths;
    let params = [
        ("CWD", &paths.cwd),
        ("TMPDIR", &paths.tmp),
        ("HOME", &paths.home),
        ("CLAUDE_TMP_PROJECT", &paths.claude_tmp_project),
        ("CLAUDE_PROJECT", &paths.claude_project),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v.clone()))
    .collect();
    let policy = rules::WritePolicy::from_profile(crate::hub::remote_sandbox::PROFILE, &params)
        .map_err(|e| e.to_string())?;
    let mut denies = policy.read_denies();
    denies.extend(
        [
            ".local/share/keyrings",
            ".password-store",
            ".mozilla",
            ".config/google-chrome",
            ".config/chromium",
            ".config/BraveSoftware",
            ".pki",
            ".claude/.credentials.json",
        ]
        .map(|p| paths.home.join(p)),
    );
    let writable = [
        paths.cwd.clone(),
        paths.tmp.clone(),
        paths.claude_tmp_project.clone(),
        paths.claude_project.clone(),
    ];
    // std's UnixStream::pair uses SOCK_STREAM | SOCK_CLOEXEC on Linux. Create
    // it before opening pinned executable fds so fd 3 is occupied and can
    // never be overwritten by the handoff dup2.
    let (parent, child_end) = UnixStream::pair().map_err(|e| e.to_string())?;
    if parent.as_raw_fd() < 3 || child_end.as_raw_fd() < 3 {
        return Err("standard streams must be open".into());
    }
    let (exe_fd, exe) = executable(&denies, &writable)?;
    let bwrap_fd = open_bwrap()?;
    let prefix =
        init_prefix(&exe, crate::daemon::daemon_prefix(), 3, options.proxy_port, options.api)?;
    // The snapshot precedes the bwrap clone. Only unsandboxed host processes
    // can add mounts in that window, and they already have full host access.
    // After cloning, seccomp and user namespaces block sandbox mounts; the
    // only sandbox-triggered propagation path is automount. The plan refuses
    // all autofs outside /proc and /dev, which bwrap replaces. Systemd's
    // binfmt_misc automount under /proc/sys is unaffected. Mount IDs come from
    // O_PATH + /proc/self/fdinfo in this keeper, never from deepest-path guesses.
    let mut mountinfo = Vec::new();
    std::fs::File::open("/proc/self/mountinfo")
        .map_err(|e| format!("cannot read mountinfo: {e}"))?
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut mountinfo)
        .map_err(|e| format!("cannot read mountinfo: {e}"))?;
    if mountinfo.len() > 4 * 1024 * 1024 {
        return Err("mountinfo exceeds 4 MiB".into());
    }
    let mountinfo = String::from_utf8(mountinfo).map_err(|_| "mountinfo is not UTF-8")?;
    let (mut argv, bind_fds) = bwrap::plan(paths, &denies, &mountinfo, &prefix)?;
    let separator =
        argv.iter().position(|arg| arg == "--").ok_or("bwrap plan has no command separator")?;
    argv.splice(
        separator..separator,
        ["--ro-bind-fd".into(), exe_fd.as_raw_fd().to_string(), exe.to_string_lossy().into_owned()],
    );
    argv.push(options.program.clone());
    argv.extend(options.args.iter().cloned());
    let child_fd = child_end.as_raw_fd();
    let keeper_pid = std::process::id() as libc::pid_t;
    let bwrap_raw = bwrap_fd.as_raw_fd();
    let inherited: Vec<_> = bind_fds
        .iter()
        .map(AsRawFd::as_raw_fd)
        .chain(std::iter::once(exe_fd.as_raw_fd()))
        .collect();
    let bwrap_path = format!("/proc/self/fd/{}", bwrap_fd.as_raw_fd());
    let mut command = Command::new(bwrap_path);
    crate::hub::remote_sandbox::scrub_loader_env(&mut command);
    // bwrap passes inherited non-CLOEXEC fds to its command; bind fds are
    // consumed by the mount plan, and init closes the handoff before exec.
    command
        .args(argv)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .kill_on_drop(true);
    // SAFETY: pre_exec only uses async-signal-safe libc calls and finite fd
    // iteration. All referenced fds remain owned until spawn completes.
    unsafe {
        command.pre_exec(move || {
            // Cover keeper death before bwrap installs --die-with-parent itself.
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::getppid() != keeper_pid {
                return Err(io::Error::from_raw_os_error(libc::ECHILD));
            }
            if libc::dup2(child_fd, 3) < 0 || libc::fcntl(3, libc::F_SETFD, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::fcntl(bwrap_raw, libc::F_SETFD, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            for fd in &inherited {
                if libc::fcntl(*fd, libc::F_SETFD, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let mut child = command.spawn().map_err(|e| format!("start bwrap: {e}"))?;
    let pidfd =
        open_pidfd(child.id().ok_or("bwrap has no PID")?).map_err(|e| format!("pin bwrap: {e}"))?;
    drop(child_end);
    drop(bind_fds);
    drop(exe_fd);
    drop(bwrap_fd);
    let relay_stop = CancellationToken::new();
    let relay = tokio::spawn(forward_signals(pidfd, [term, int, hup], relay_stop.clone()));
    let result = session(&mut child, parent, &options, policy, relay_stop.clone()).await;
    relay_stop.cancel();
    let relay_result = relay.await.map_err(|e| format!("signal relay: {e}"))?;
    let result = match (result, relay_result) {
        (Err(error), _) => Err(error),
        (Ok(code), Ok(_)) => Ok(code),
        (Ok(_), Err(error)) => Err(error),
    };
    if result.is_err() {
        let _ = tokio::time::timeout(Duration::from_secs(5), child.kill()).await;
    }
    result
}
pub(crate) fn main(args: Vec<OsString>) -> ! {
    let result = parse(args).and_then(|options| {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        let result = runtime.block_on(run(options));
        // DNS may still occupy Tokio's blocking pool. Do not wait for it after
        // the child exits: process exit stops remaining host-side work.
        runtime.shutdown_background();
        result
    });
    let code = result.unwrap_or_else(|error| {
        eprintln!("remote sandbox keeper: {error}");
        125
    });
    std::process::exit(code) // crash-allow: keeper returns the sandbox status to its launcher
}
/// Table loops stop at finite input exhaustion. Socket connects have a two-second
/// deadline; listeners are only inspected, never accepted, and all fds are RAII-owned.
#[cfg(test)]
mod tests {
    #[test]
    fn bwrap_command_scrubs_loader_env() {
        let mut cmd = Command::new("/usr/bin/bwrap");
        cmd.env("LD_PRELOAD", "injected")
            .env("LOCPATH", "injected")
            .env("TMPDIR", "/injected")
            .env("MALLOC_CHECK_", "3")
            .env("PATH", "/usr/bin");
        crate::hub::remote_sandbox::scrub_loader_env(&mut cmd);
        let env = crate::agent::command_env(&cmd);
        assert!(!env.iter().any(|(k, _)| matches!(
            k.as_str(),
            "LD_PRELOAD" | "LOCPATH" | "TMPDIR" | "MALLOC_CHECK_"
        )));
        assert!(env.iter().any(|(k, v)| k == "PATH" && v == "/usr/bin"));
    }

    use super::*;
    use std::net::{TcpStream, UdpSocket};
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::process::ExitStatusExt;
    use std::time::Duration;
    fn required() -> Vec<&'static str> {
        "--cwd /work --tmpdir /scratch --home /home/person \
         --claude-tmp-project /claude-tmp/project \
         --claude-project /home/person/.claude/projects/project --proxy-port 3128"
            .split_whitespace()
            .collect()
    }
    fn argv(extra: &[&str]) -> Vec<OsString> {
        required()
            .into_iter()
            .chain(extra.iter().copied())
            .chain(["--", "/bin/sh", "-c", "printf '%s' \"$1\"", "sh", "a b"])
            .map(OsString::from)
            .collect()
    }
    #[test]
    fn options_canonical_round_trip() {
        let options = parse(argv(&[])).unwrap();
        assert_eq!(options.proxy_port, 3128);
        assert_eq!(options.api, None);
        let paths = [
            &options.paths.cwd,
            &options.paths.tmp,
            &options.paths.home,
            &options.paths.claude_tmp_project,
            &options.paths.claude_project,
        ];
        let mut round_trip = Vec::new();
        for (pair, path) in required().chunks_exact(2).take(5).zip(paths) {
            assert_eq!(path, &PathBuf::from(pair[1]));
            round_trip.extend([OsString::from(pair[0]), path.as_os_str().to_owned()]);
        }
        round_trip.extend([OsString::from("--proxy-port"), options.proxy_port.to_string().into()]);
        round_trip.extend([OsString::from("--"), options.program.into()]);
        round_trip.extend(options.args.into_iter().map(OsString::from));
        assert_eq!(round_trip, argv(&[]));
        assert!(parse(round_trip).is_ok());
        let options = parse(argv(&["--api-port", "31415", "--api-loopback-v4"])).unwrap();
        assert_eq!(options.api, Some("127.0.0.1:31415".parse().unwrap()));
        assert!(parse(argv(&["--api-port", "31415", "--api-loopback-v6"])).is_err());
        assert!(parse(argv(&["--bwrap", "/opt/bwrap"])).is_err());
    }
    #[test]
    fn options_refuse_missing_duplicate_and_unknown_flags() {
        for pair in required().chunks_exact(2) {
            let mut missing = argv(&[]);
            let at = missing.iter().position(|v| v == pair[0]).unwrap();
            missing.drain(at..at + 2);
            assert!(parse(missing).is_err(), "missing {}", pair[0]);
            assert!(parse(argv(pair)).is_err(), "duplicate {}", pair[0]);
        }
        for extra in [
            vec!["--wat", "1"],
            vec!["--proxy-port=3128"],
            vec!["--bwrap", "/a"],
            vec!["--api-port", "31415", "--api-port", "31415", "--api-loopback-v4"],
            vec!["--api-port", "31415", "--api-loopback-v4", "--api-loopback-v4"],
            vec!["--api-port", "31415", "--api-loopback-v6", "--api-loopback-v6"],
            vec!["--api-port", "31415", "--api-loopback-v4", "--api-loopback-v6"],
            vec!["--api-port", "31415"],
            vec!["--api-loopback-v4"],
            vec!["--api-loopback-v6"],
        ] {
            assert!(parse(argv(&extra)).is_err(), "{extra:?}");
        }
        for flag in required().chunks_exact(2).map(|p| p[0]).chain(["--api-port"]) {
            assert!(parse(vec![flag.into()]).is_err(), "{flag} at EOF");
            assert!(parse(vec![flag.into(), "--".into(), "/bin/true".into()]).is_err());
        }
        assert!(parse(Vec::new()).is_err());
        assert!(parse(required().into_iter().map(OsString::from).collect()).is_err());
        let mut missing_program = argv(&[]);
        missing_program.truncate(required().len() + 1);
        assert!(parse(missing_program).is_err());
    }
    #[test]
    fn options_refuse_invalid_values_before_spawn() {
        for index in [1, 3, 5, 7, 9, 13] {
            for bad in ["relative", "", "/a/../b", "/bad\0path"] {
                let mut values = argv(&[]);
                values[index] = bad.into();
                assert!(parse(values).is_err(), "argument {index}: {bad:?}");
            }
        }
        assert!(parse(argv(&["--bwrap", "relative"])).is_err());
        for bad in ["0", "65536", "-1", "+80", " 80", "80x", ""] {
            let mut values = argv(&[]);
            values[11] = bad.into();
            assert!(parse(values).is_err(), "proxy {bad:?}");
            assert!(parse(argv(&["--api-port", bad, "--api-loopback-v4"])).is_err());
        }
        assert!(parse(argv(&["--api-port", "3128", "--api-loopback-v4"])).is_err());
        let mut values = argv(&[]);
        values.push(OsString::from_vec(vec![0xff]));
        assert!(parse(values).is_err());
        let mut values = argv(&[]);
        values.push("arg\0tail".into());
        assert!(parse(values).is_err());
    }
    fn listener(address: &str) -> (OwnedFd, u16) {
        let listener = TcpListener::bind((address, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        (listener.into(), port)
    }
    fn payload(proxy: u16, api: Option<u16>) -> Vec<u8> {
        format!("{}\n", serde_json::json!({"proxy": proxy, "api": api})).into_bytes()
    }
    #[test]
    fn handoff_accepts_exact_proxy_and_optional_api_listeners() {
        for with_api in [false, true] {
            let (proxy, port) = listener("127.0.0.1");
            let (api, api_port) = listener("127.0.0.1");
            let expected_api = with_api.then_some(api_port);
            let fds = std::iter::once(proxy).chain(with_api.then_some(api)).collect();
            let listeners =
                validate_handoff_for_test(&payload(port, expected_api), fds, port, expected_api)
                    .unwrap();
            assert_eq!(listeners.len(), if with_api { 2 } else { 1 });
            assert_eq!(listeners[0].local_addr().unwrap().to_string(), format!("127.0.0.1:{port}"));
            if with_api {
                assert_eq!(listeners[1].local_addr().unwrap().port(), api_port);
            }
        }
    }
    #[test]
    fn handoff_refuses_wrong_counts_ports_and_order() {
        assert!(validate_handoff_for_test(&payload(3128, None), vec![], 3128, None).is_err());
        for count in [1, 2, 3] {
            let (proxy, port) = listener("127.0.0.1");
            let (api, api_port) = listener("127.0.0.1");
            let fds = vec![proxy, api, listener("127.0.0.1").0].into_iter().take(count).collect();
            let expected_api = (count != 2).then_some(api_port);
            assert!(
                validate_handoff_for_test(&payload(port, expected_api), fds, port, expected_api)
                    .is_err()
            );
        }
        let (proxy, port) = listener("127.0.0.1");
        let (api, api_port) = listener("127.0.0.1");
        assert!(
            validate_handoff_for_test(
                &payload(port, Some(api_port)),
                vec![api, proxy],
                port,
                Some(api_port)
            )
            .is_err()
        );
        let (fd, port) = listener("127.0.0.1");
        let wrong = if port == 65535 { 65534 } else { port + 1 };
        assert!(validate_handoff_for_test(&payload(wrong, None), vec![fd], wrong, None).is_err());
    }
    #[test]
    fn handoff_refuses_invalid_json_and_mismatched_json_ports() {
        for text in [
            "",
            "{",
            "{}",
            "[]",
            "null",
            "{\"proxy\":PORT}",
            "{\"proxy\":0,\"api\":null}",
            "{\"proxy\":65536,\"api\":null}",
            "{\"proxy\":\"PORT\",\"api\":null}",
            "{\"proxy\":PORT,\"api\":null,\"extra\":1}",
        ] {
            let (fd, port) = listener("127.0.0.1");
            let text = text.replace("PORT", &port.to_string());
            assert!(
                validate_handoff_for_test(text.as_bytes(), vec![fd], port, None).is_err(),
                "{text}"
            );
        }
        let (fd, port) = listener("127.0.0.1");
        let duplicate = format!("{{\"proxy\":{port},\"proxy\":{port},\"api\":null}}\n");
        assert!(validate_handoff_for_test(duplicate.as_bytes(), vec![fd], port, None).is_err());
        let (fd, port) = listener("127.0.0.1");
        assert!(
            validate_handoff_for_test(&payload(port, Some(port)), vec![fd], port, None).is_err()
        );
    }
    #[test]
    fn handoff_refuses_nonlisteners_and_other_bind_addresses() {
        let file: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
        let udp = UdpSocket::bind("127.0.0.1:0").unwrap();
        let udp_port = udp.local_addr().unwrap().port();
        let tcp = TcpListener::bind("127.0.0.1:0").unwrap();
        let stream =
            TcpStream::connect_timeout(&tcp.local_addr().unwrap(), Duration::from_secs(2)).unwrap();
        let stream_port = stream.local_addr().unwrap().port();
        for (fd, port) in [(file, 3128), (udp.into(), udp_port), (stream.into(), stream_port)] {
            assert!(validate_handoff_for_test(&payload(port, None), vec![fd], port, None).is_err());
        }
        for address in ["0.0.0.0", "127.0.0.2"] {
            let (fd, port) = listener(address);
            assert!(validate_handoff_for_test(&payload(port, None), vec![fd], port, None).is_err());
        }
    }
    #[test]
    fn handoff_refuses_a_listener_from_the_keeper_network_namespace() {
        let (fd, port) = listener("127.0.0.1");
        let notify: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
        let error =
            validate_handoff_with_notify(&payload(port, None), vec![fd, notify], port, None)
                .expect_err("a host listener must fail the namespace proof");
        assert!(error.contains("network namespace"), "{error}");
    }
    #[test]
    fn handoff_without_notify_fd_is_refused() {
        let (fd, port) = listener("127.0.0.1");
        // Missing notify is rejected before listener validation.
        assert!(validate_handoff_with_notify(&payload(port, None), vec![fd], port, None).is_err());
    }

    #[test]
    fn notify_fd_must_be_a_seccomp_listener() {
        let null: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
        assert!(validate_notify_fd(null.as_raw_fd()).is_err());
        let event = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC) };
        assert!(event >= 0);
        let event = unsafe { OwnedFd::from_raw_fd(event) };
        assert!(validate_notify_fd(event.as_raw_fd()).is_err());
        let socket: OwnedFd = TcpListener::bind("127.0.0.1:0").unwrap().into();
        assert!(validate_notify_fd(socket.as_raw_fd()).is_err());
    }

    #[tokio::test]
    async fn pidfd_signal_after_reap_is_esrch() {
        let mut child = Command::new("/bin/cat")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let pinned = open_pidfd(child.id().unwrap());
        drop(child.stdin.take());
        tokio::time::timeout(Duration::from_secs(5), child.wait()).await.unwrap().unwrap();
        let pinned = pinned.expect("relay must pin the child before any reap");
        // A queued termination delivered after reap must address only this dead child.
        assert_eq!(
            signal_pidfd(pinned.as_raw_fd(), libc::SIGTERM).unwrap_err().raw_os_error(),
            Some(libc::ESRCH)
        );
    }

    #[tokio::test]
    async fn signal_relay_stops_after_child_exit() {
        let signals = [
            signal(SignalKind::terminate()).unwrap(),
            signal(SignalKind::interrupt()).unwrap(),
            signal(SignalKind::hangup()).unwrap(),
        ];
        let stop = CancellationToken::new();
        stop.cancel();
        let result = tokio::time::timeout(
            Duration::from_millis(100),
            forward_signals(open_pidfd(std::process::id()).unwrap(), signals, stop),
        )
        .await;
        assert!(result.is_ok(), "signal relay remained alive after child exit");
    }

    #[test]
    fn keeper_to_init_api_contract_has_no_unknown_family_flag() {
        let args = init_prefix(
            Path::new("/usr/bin/acpmux"),
            Vec::new(),
            3,
            8118,
            Some("127.0.0.1:31415".parse().unwrap()),
        )
        .unwrap();
        assert!(!args.iter().any(|arg| arg == "--api-loopback-v4"));
    }

    #[test]
    fn child_exit_status_mapping() {
        for code in [0, 1, 7, 125, 127, 255] {
            assert_eq!(exit_code(ExitStatus::from_raw(code << 8)), code);
        }
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP, libc::SIGKILL] {
            assert_eq!(exit_code(ExitStatus::from_raw(signal)), 128 + signal);
        }
        assert_eq!(exit_code(ExitStatus::from_raw(libc::SIGSEGV | 0x80)), 128 + libc::SIGSEGV);
    }
}
