//! Table loops consume finite arrays. Handoff reads have a fifteen-second
//! timeout; each child has a twenty-second alarm that bounds waits.
#![cfg(target_os = "linux")]

use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

fn python() -> Option<&'static str> {
    if Command::new("python3").arg("--version").output().is_ok_and(|o| o.status.success()) {
        Some("python3")
    } else {
        eprintln!("linux_sandbox_init: skipped (python3 is absent)");
        None
    }
}

fn socketpair() -> (std::os::unix::net::UnixStream, std::os::unix::net::UnixStream) {
    let mut fds = [-1; 2];
    // SAFETY: fds points to two writable integers and the call has no Rust
    // references that outlive this function.
    assert_eq!(
        unsafe {
            libc::socketpair(
                libc::AF_UNIX,
                libc::SOCK_STREAM | libc::SOCK_CLOEXEC,
                0,
                fds.as_mut_ptr(),
            )
        },
        0
    );
    // SAFETY: each descriptor is owned exactly once by the returned streams.
    unsafe {
        (
            std::os::unix::net::UnixStream::from_raw_fd(fds[0]),
            std::os::unix::net::UnixStream::from_raw_fd(fds[1]),
        )
    }
}

/// The child alarm terminates init or its executed program after twenty seconds.
fn spawn(args: &[&str], fd: RawFd) -> Child {
    spawn_with_extra(args, fd, None)
}

fn spawn_with_extra(args: &[&str], fd: RawFd, extra_fd: Option<RawFd>) -> Child {
    let exe = env!("CARGO_BIN_EXE_acpmux");
    let mut command = Command::new(exe);
    command.args(args).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    command.env("NO_PROXY", "*").env("no_proxy", "*");
    if let Some(extra_fd) = extra_fd {
        command.env("INHERITED_FD", extra_fd.to_string());
    }
    // SAFETY: pre_exec only calls libc, allocates nothing, and runs between
    // fork and exec. The deliberate high fd leak verifies init's fd cleanup.
    // SIGALRM bounds the helper and executed program to twenty seconds.
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(fd, libc::F_SETFD, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::fcntl(fd, libc::F_DUPFD, 200) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if let Some(extra_fd) = extra_fd
                && libc::fcntl(extra_fd, libc::F_SETFD, 0) < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            libc::signal(libc::SIGALRM, libc::SIG_DFL);
            libc::alarm(20);
            Ok(())
        });
    }
    command.spawn().expect("spawn acpmux init")
}

/// Ancillary traversal ends at the control buffer's end; each fd loop has a
/// finite payload length. Reads time out after fifteen seconds.
fn recv_handoff(
    stream: &std::os::unix::net::UnixStream,
) -> (serde_json::Value, Vec<std::net::TcpListener>) {
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    let mut bytes = vec![0u8; 4096];
    let control_len =
        unsafe { libc::CMSG_SPACE((2 * std::mem::size_of::<RawFd>()) as u32) as usize };
    let mut cmsg = vec![0usize; control_len.div_ceil(std::mem::size_of::<usize>())];
    let mut iov = libc::iovec { iov_base: bytes.as_mut_ptr().cast(), iov_len: bytes.len() };
    // SAFETY: all pointers refer to writable buffers for recvmsg's duration.
    let (n, msg) = unsafe {
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsg.as_mut_ptr().cast();
        msg.msg_controllen = control_len;
        let n = libc::recvmsg(stream.as_raw_fd(), &mut msg, libc::MSG_CMSG_CLOEXEC);
        (n, msg)
    };
    assert!(n > 0, "handoff recv failed: {}", std::io::Error::last_os_error());
    assert_eq!(msg.msg_flags & libc::MSG_CTRUNC, 0, "truncated handoff fds");
    let mut fds = Vec::new();
    // SAFETY: msg was filled by recvmsg; CMSG_FIRSTHDR/NXTHDR traverse its
    // bounded control buffer and the payload is copied before this function returns.
    unsafe {
        let mut hdr = libc::CMSG_FIRSTHDR(&msg);
        while !hdr.is_null() {
            if (*hdr).cmsg_level == libc::SOL_SOCKET && (*hdr).cmsg_type == libc::SCM_RIGHTS {
                let payload = (*hdr).cmsg_len - libc::CMSG_LEN(0) as usize;
                let count = payload / std::mem::size_of::<RawFd>();
                let data = libc::CMSG_DATA(hdr).cast::<RawFd>();
                for index in 0..count {
                    fds.push(std::net::TcpListener::from_raw_fd(*data.add(index)));
                }
            }
            hdr = libc::CMSG_NXTHDR(&msg, hdr);
        }
    }
    bytes.truncate(n as usize);
    // A Unix stream may split the JSON line; stop at newline, EOF, timeout,
    // or the fixed message-size bound instead of assuming one recvmsg.
    let mut reader = stream;
    while !bytes.ends_with(b"\n") {
        assert!(bytes.len() < 4096, "oversized handoff JSON");
        let mut byte = [0];
        reader.read_exact(&mut byte).expect("complete handoff JSON line");
        bytes.push(byte[0]);
    }
    (serde_json::from_slice(&bytes).expect("handoff JSON"), fds)
}

fn ack(stream: &std::os::unix::net::UnixStream) {
    stream.try_clone().expect("clone handoff").write_all(b"1").expect("ack");
}

#[test]
fn helper_hands_off_listener_sets_env_and_closes_leaked_fds() {
    let Some(py) = python() else { return };
    let (parent, child_end) = socketpair();
    let fd = child_end.as_raw_fd();
    let mut child = spawn(
        &[
            "__remote-sandbox-init",
            "--handoff-fd",
            &fd.to_string(),
            "--proxy-port",
            "0",
            "--api-port",
            "0",
            "--",
            "/usr/bin/env",
            py,
            "-c",
            r#"import errno,json,os,socket
assert os.environ['NO_PROXY'] == '127.0.0.1,localhost,::1'
assert os.environ['no_proxy'] == '127.0.0.1,localhost,::1'
try:
    socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
    raise AssertionError('AF_UNIX allowed')
except OSError as error:
    assert error.errno == errno.EPERM, error
# listdir closes its temporary directory fd before fstat probes the names.
for fd in map(int, os.listdir('/proc/self/fd')):
    if fd <= 2:
        continue
    try:
        os.fstat(fd)
    except OSError as error:
        assert error.errno == errno.EBADF, error
    else:
        raise AssertionError('leaked fd: ' + str(fd))
# Exercise a proxy-aware request to the handed-off API listener.
import urllib.request
api = int(input())
assert urllib.request.urlopen('http://127.0.0.1:%d/' % api, timeout=5).read() == b'api'
keys = ['HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','https_proxy','http_proxy','all_proxy']
print(json.dumps({key: os.environ[key] for key in keys}))"#,
        ],
        fd,
    );
    drop(child_end);
    let (json, fds) = recv_handoff(&parent);
    let proxy = json["proxy"].as_u64().expect("proxy port") as u16;
    let api = json["api"].as_u64().expect("api port") as u16;
    assert!(proxy > 0 && api > 0);
    assert_eq!(fds.len(), 2);
    let listener = &fds[0];
    let address = listener.local_addr().unwrap();
    assert_eq!(address.port(), proxy);
    let _connection = std::net::TcpStream::connect(address).expect("proxy listener");
    let api_listener = &fds[1];
    assert_eq!(api_listener.local_addr().unwrap().port(), api);
    writeln!(child.stdin.take().unwrap(), "{api}").unwrap();
    ack(&parent);
    // Poll bounds the accept wait even if the child fails before connecting.
    let mut ready = libc::pollfd { fd: api_listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    assert_eq!(unsafe { libc::poll(&mut ready, 1, 10_000) }, 1, "API request did not arrive");
    let (mut connection, _) = api_listener.accept().unwrap();
    connection.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    connection.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut request = [0; 4096];
    assert!(connection.read(&mut request).unwrap() > 0);
    connection
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\napi")
        .unwrap();
    drop(connection);
    let status = child.wait().expect("wait helper");
    assert!(
        status.success(),
        "helper failed: {:?}",
        child.stderr.take().map(|mut e| {
            let mut s = String::new();
            let _ = e.read_to_string(&mut s);
            s
        })
    );
    let env: serde_json::Value = serde_json::from_reader(child.stdout.take().unwrap()).unwrap();
    for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"]
    {
        assert_eq!(env[key], format!("http://127.0.0.1:{proxy}"));
    }
}

#[test]
fn helper_without_ack_exits_125_without_running_program() {
    let (parent, child_end) = socketpair();
    let fd = child_end.as_raw_fd();
    let mut child = spawn(
        &[
            "__remote-sandbox-init",
            "--handoff-fd",
            &fd.to_string(),
            "--proxy-port",
            "0",
            "--",
            "/bin/sh",
            "-c",
            "exit 7",
        ],
        fd,
    );
    drop(child_end);
    let _ = recv_handoff(&parent);
    drop(parent);
    let status = child.wait().expect("wait helper");
    assert_eq!(status.code(), Some(125));
}

#[test]
fn helper_rejects_relative_program_after_ack() {
    let (parent, child_end) = socketpair();
    let fd = child_end.as_raw_fd();
    let mut child = spawn(
        &[
            "__remote-sandbox-init",
            "--handoff-fd",
            &fd.to_string(),
            "--proxy-port",
            "0",
            "--",
            "relative-program",
        ],
        fd,
    );
    drop(child_end);
    let _ = recv_handoff(&parent);
    ack(&parent);
    let status = child.wait().expect("wait helper");
    assert_eq!(status.code(), Some(125));
}

#[test]
fn helper_closes_inherited_unix_socket_before_exec() {
    let Some(py) = python() else { return };
    let (parent, child_end) = socketpair();
    let (extra_peer, extra_child) = socketpair();
    let handoff_fd = child_end.as_raw_fd();
    let inherited_fd = extra_child.as_raw_fd();
    let mut child = spawn_with_extra(
        &[
            "__remote-sandbox-init",
            "--handoff-fd",
            &handoff_fd.to_string(),
            "--proxy-port",
            "0",
            "--",
            "/usr/bin/env",
            py,
            "-c",
            "import os; assert not os.path.exists('/proc/self/fd/' + os.environ['INHERITED_FD'])",
        ],
        handoff_fd,
        Some(inherited_fd),
    );
    drop(child_end);
    drop(extra_child);
    let _ = recv_handoff(&parent);
    ack(&parent);
    drop(parent);
    drop(extra_peer);
    assert!(child.wait().expect("wait helper").success());
}

#[test]
fn helper_restores_sigpipe_before_exec() {
    let (parent, child_end) = socketpair();
    let fd = child_end.as_raw_fd();
    let mut child = spawn(
        &[
            "__remote-sandbox-init",
            "--handoff-fd",
            &fd.to_string(),
            "--proxy-port",
            "0",
            "--",
            "/bin/sh",
            "-c",
            "kill -PIPE $$; exit 42",
        ],
        fd,
    );
    drop(child_end);
    let _ = recv_handoff(&parent);
    ack(&parent);
    assert_eq!(child.wait().expect("wait helper").signal(), Some(libc::SIGPIPE));
}
