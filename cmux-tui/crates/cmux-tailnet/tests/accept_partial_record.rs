//! `tailscale_accept` reads a fixed-size record (the remote IP, NUL-padded) that carries the
//! connection's fd over `SCM_RIGHTS`. A read can come back short, and the fd then arrives with
//! the first part: accept must keep it across the reads that complete the record, and close any
//! fd it received when it fails (`patches/0003-accept-keeps-fd-across-partial-reads.patch`).
//!
//! libtailscale always sends a record in one `sendmsg`, so the test writes records itself into
//! libtailscale's end of the listener's socketpair, split in two sends with the fd on the first.
//! Linux ends a stream read at a send that carried fds, even with `MSG_WAITALL`, so accept's
//! first read returns only the first part, every time.
//!
//! Linux only: it finds libtailscale's end of the socketpair in `/proc/self/fd`.

#![cfg(target_os = "linux")]

use std::collections::HashSet;
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::process::Command;

use cmux_tailnet::{Node, NodeConfig};

const NAME: &str = "accept_keeps_the_fd_of_a_record_read_in_parts";
const RECORD: usize = 64;

/// The sockets this process holds: (fd, `socket:[inode]`).
fn sockets() -> Vec<(RawFd, String)> {
    std::fs::read_dir("/proc/self/fd")
        .unwrap()
        .filter_map(|entry| {
            let entry = entry.ok()?;
            let fd = entry.file_name().to_str()?.parse().ok()?;
            let target = std::fs::read_link(entry.path()).ok()?.to_string_lossy().into_owned();
            target.starts_with("socket:").then_some((fd, target))
        })
        .collect()
}

fn sockopt(fd: RawFd, option: libc::c_int) -> libc::c_int {
    let mut value: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    let status = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            option,
            (&mut value as *mut libc::c_int).cast(),
            &mut len,
        )
    };
    if status == 0 { value } else { -1 }
}

/// Sends `bytes` on `socket`, with `fd` attached over `SCM_RIGHTS` when given.
fn send(socket: RawFd, bytes: &[u8], fd: Option<RawFd>) {
    let mut iov = libc::iovec { iov_base: bytes.as_ptr() as *mut _, iov_len: bytes.len() };
    let space = unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) } as usize;
    let mut control = vec![0_u64; space.div_ceil(8)];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    if let Some(fd) = fd {
        msg.msg_control = control.as_mut_ptr().cast();
        msg.msg_controllen = space as _;
        unsafe {
            let cmsg = libc::CMSG_FIRSTHDR(&msg);
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = libc::SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as _;
            libc::CMSG_DATA(cmsg).cast::<RawFd>().write_unaligned(fd);
        }
    }
    let sent = unsafe { libc::sendmsg(socket, &msg, 0) };
    assert_eq!(sent, bytes.len() as isize, "sendmsg: {}", std::io::Error::last_os_error());
}

fn record(ip: &str) -> [u8; RECORD] {
    let mut record = [0_u8; RECORD];
    record[..ip.len()].copy_from_slice(ip.as_bytes());
    record
}

/// Whether the other end of `near` was closed everywhere (it reads EOF).
fn peer_closed(near: &mut UnixStream) -> bool {
    near.set_nonblocking(true).unwrap();
    let mut byte = [0_u8; 1];
    match near.read(&mut byte) {
        Ok(0) => true,
        Err(error) if error.kind() == ErrorKind::WouldBlock => false,
        other => panic!("unexpected read: {other:?}"),
    }
}

#[test]
fn accept_keeps_the_fd_of_a_record_read_in_parts() {
    // tsnet reads its environment when the process starts, so this test reruns alone in a
    // process where tsnet uploads no logs.
    if std::env::var_os("TS_NO_LOGS_NO_SUPPORT").is_none() {
        let status = Command::new(std::env::current_exe().unwrap())
            .args([NAME, "--exact", "--test-threads=1", "--nocapture"])
            .env("TS_NO_LOGS_NO_SUPPORT", "true")
            .status()
            .unwrap();
        assert!(status.success(), "{NAME} failed in its own process: {status}");
        return;
    }

    let dir = std::env::temp_dir().join(format!("cmux-tailnet-accept-{}", std::process::id()));
    let mut config = NodeConfig::new(&dir, "accept-test");
    // An unreachable control server: the node starts but never joins a tailnet, so
    // libtailscale itself never writes a record to the listener.
    config.control_url = Some("http://127.0.0.1:1".into());
    config.ephemeral = true;
    let node = Node::new(&config).unwrap();
    node.start().unwrap();

    let before: HashSet<String> = sockets().into_iter().map(|(_, socket)| socket).collect();
    let listener = node.listen_tcp(7443).unwrap();
    let ours = listener.as_raw_fd();
    // libtailscale's end of the listener's socketpair: the other new Unix stream socket.
    let theirs: Vec<RawFd> = sockets()
        .into_iter()
        .filter(|(fd, socket)| *fd != ours && !before.contains(socket))
        .map(|(fd, _)| fd)
        .filter(|&fd| {
            sockopt(fd, libc::SO_DOMAIN) == libc::AF_UNIX
                && sockopt(fd, libc::SO_TYPE) == libc::SOCK_STREAM
        })
        .collect();
    assert_eq!(theirs.len(), 1, "libtailscale's end of the listener: {theirs:?}");
    let theirs = theirs[0];

    // The fd rides with the first 10 bytes; the rest of the record follows on its own.
    let (mut near, far) = UnixStream::pair().unwrap();
    let ip = record("100.64.0.7");
    send(theirs, &ip[..10], Some(far.as_raw_fd()));
    send(theirs, &ip[10..], None);
    drop(far);
    let accepted = listener.accept();

    // A record whose second part brings another fd: accept fails, and closes both fds.
    let (mut near_first, far_first) = UnixStream::pair().unwrap();
    let (mut near_second, far_second) = UnixStream::pair().unwrap();
    let bad = record("100.64.0.8");
    send(theirs, &bad[..10], Some(far_first.as_raw_fd()));
    send(theirs, &bad[10..], Some(far_second.as_raw_fd()));
    drop((far_first, far_second));
    let failed = listener.accept();
    let leaked_first = !peer_closed(&mut near_first);
    let leaked_second = !peer_closed(&mut near_second);

    let (mut stream, remote) = accepted.expect("accept of a record read in two parts");
    assert_eq!(remote, "100.64.0.7");
    stream.write_all(b"ping").unwrap();
    let mut got = [0_u8; 4];
    near.read_exact(&mut got).unwrap();
    assert_eq!(&got, b"ping", "accept returned an fd that is not the one sent");
    drop(stream);

    assert!(failed.is_err(), "a record with two fds must fail");
    assert!(
        !leaked_first && !leaked_second,
        "a failed accept leaked a received fd (first {leaked_first}, second {leaked_second})"
    );

    drop(listener);
    node.close().unwrap();
    drop(node);
    let _ = std::fs::remove_dir_all(&dir);
}
