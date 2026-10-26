#![cfg(target_os = "linux")]

use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};

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
        unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, fds.as_mut_ptr()) },
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

fn spawn(args: &[&str], fd: RawFd) -> Child {
    let exe = env!("CARGO_BIN_EXE_acpmux");
    let mut command = Command::new(exe);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    // SAFETY: this pre_exec only clears CLOEXEC on the already-open handoff
    // descriptor; it allocates nothing and runs between fork and exec.
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(fd, libc::F_SETFD, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn().expect("spawn acpmux init")
}

fn recv_handoff(stream: &std::os::unix::net::UnixStream) -> (serde_json::Value, Vec<RawFd>) {
    let mut bytes = vec![0u8; 4096];
    let mut cmsg =
        vec![0u8; unsafe { libc::CMSG_SPACE((2 * std::mem::size_of::<RawFd>()) as u32) as usize }];
    let mut iov = libc::iovec { iov_base: bytes.as_mut_ptr().cast(), iov_len: bytes.len() };
    // SAFETY: all pointers refer to writable buffers for recvmsg's duration.
    let (n, mut msg) = unsafe {
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsg.as_mut_ptr().cast();
        msg.msg_controllen = cmsg.len();
        let n = libc::recvmsg(stream.as_raw_fd(), &mut msg, 0);
        (n, msg)
    };
    assert!(n > 0, "handoff recv failed: {}", std::io::Error::last_os_error());
    let text = String::from_utf8_lossy(&bytes[..n as usize]);
    let line = text.lines().next().expect("handoff JSON line");
    let mut fds = Vec::new();
    // SAFETY: msg was filled by recvmsg; CMSG_FIRSTHDR/NXTHDR traverse its
    // bounded control buffer and the payload is copied before this function returns.
    unsafe {
        let mut hdr = libc::CMSG_FIRSTHDR(&msg);
        while !hdr.is_null() {
            if (*hdr).cmsg_level == libc::SOL_SOCKET && (*hdr).cmsg_type == libc::SCM_RIGHTS {
                let payload = (*hdr).cmsg_len as usize - libc::CMSG_LEN(0) as usize;
                let count = payload / std::mem::size_of::<RawFd>();
                let data = libc::CMSG_DATA(hdr).cast::<RawFd>();
                for index in 0..count {
                    fds.push(*data.add(index));
                }
            }
            hdr = libc::CMSG_NXTHDR(&msg, hdr);
        }
    }
    (serde_json::from_str(line).expect("handoff JSON"), fds)
}

fn ack(stream: &std::os::unix::net::UnixStream) {
    stream.try_clone().expect("clone handoff").write_all(&[b'1']).expect("ack");
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
            "import os,socket; assert os.environ['HTTP_PROXY'].endswith(':'+os.environ['HTTP_PROXY'].rsplit(':',1)[1]); assert 'NO_PROXY' not in os.environ and 'no_proxy' not in os.environ;
try: socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); raise SystemExit(4)
except PermissionError: pass
d=os.open('/proc/self/fd',os.O_RDONLY|os.O_DIRECTORY); f=[int(x) for x in os.listdir(d)]; os.close(d); assert all(x <= 2 or x == d for x in f)",
        ],
        fd,
    );
    drop(child_end);
    let (json, fds) = recv_handoff(&parent);
    let proxy = json["proxy"].as_u64().expect("proxy port") as u16;
    let api = json["api"].as_u64().expect("api port") as u16;
    assert!(proxy > 0 && api > 0);
    assert_eq!(fds.len(), 2);
    // SAFETY: recvmsg transferred ownership of this listener fd to the test.
    let listener = unsafe { std::net::TcpListener::from_raw_fd(fds[0]) };
    let address = listener.local_addr().unwrap();
    assert_eq!(address.port(), proxy);
    let _connection = std::net::TcpStream::connect(address).expect("proxy listener");
    // SAFETY: recvmsg transferred the second listener fd to this test.
    let api_listener = unsafe { std::net::TcpListener::from_raw_fd(fds[1]) };
    let _api_connection =
        std::net::TcpStream::connect(api_listener.local_addr().unwrap()).expect("api listener");
    assert_eq!(api_listener.local_addr().unwrap().port(), api);
    ack(&parent);
    let status = child.wait().expect("wait helper");
    assert!(
        status.success(),
        "helper failed: {:?}",
        child.stderr.take().and_then(|mut e| {
            let mut s = String::new();
            let _ = e.read_to_string(&mut s);
            Some(s)
        })
    );
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
