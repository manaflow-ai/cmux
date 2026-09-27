use std::io::Write;
use std::process::{Command, Stdio};

#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::io::Read;
#[cfg(unix)]
use std::os::fd::FromRawFd;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(unix)]
use std::time::{Duration, Instant};

use cmux_tui_core::terminal_host::{
    CAPABILITY_TOKEN_LEN, CapabilityToken, HostBootstrap, HostReady, TerminalId,
};
use cmux_tui_core::terminal_host_protocol::{
    MAX_FRAME_PAYLOAD, MessageKind, PROTOCOL_VERSION, encode_frame, read_frame,
};

#[test]
fn hidden_terminal_host_mode_bootstraps_over_private_stdio() {
    let terminal_id = TerminalId::from_bytes([0x31; 16]);
    let owner_token = CapabilityToken::from_bytes([0xa7; CAPABILITY_TOKEN_LEN]);
    let bootstrap = HostBootstrap {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        terminal_id,
        owner_token,
    };
    let input = encode_frame(&bootstrap.into_frame(99)).unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["__terminal-host", "--bootstrap-stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(&input).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(output.stderr.is_empty());
    assert!(
        !output.stdout.windows(CAPABILITY_TOKEN_LEN).any(|window| window == owner_token.as_bytes())
    );

    let frame = read_frame(&mut output.stdout.as_slice(), MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(frame.kind, MessageKind::Ready);
    assert_eq!(frame.request_id, 99);
    let ready = HostReady::decode(&frame.payload).unwrap();
    assert_eq!(ready.selected_version, PROTOCOL_VERSION);
    assert_eq!(ready.terminal_id, terminal_id);
}

#[test]
fn hidden_terminal_host_mode_rejects_unframed_invocation() {
    let output =
        Command::new(env!("CARGO_BIN_EXE_cmux-tui")).arg("__terminal-host").output().unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("requires --bootstrap-stdio"));
    assert!(output.stdout.is_empty());
}

#[cfg(unix)]
#[test]
fn hidden_terminal_host_closes_deliberately_inherited_non_stdio_pipe() {
    let mut pipe = [0; 2];
    // SAFETY: `pipe` points to storage for exactly two descriptors.
    assert_eq!(unsafe { libc::pipe(pipe.as_mut_ptr()) }, 0);
    for descriptor in pipe {
        // Keep the pipe out of unrelated concurrently spawned test children.
        // The pre-exec hook below deliberately opts it into this host only.
        // SAFETY: both descriptors were returned by pipe(2).
        assert_eq!(unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) }, 0);
    }
    // SAFETY: ownership of the read descriptor transfers to this File.
    let mut read_end = unsafe { File::from_raw_fd(pipe[0]) };
    // SAFETY: F_GETFL/F_SETFL operate on the valid read descriptor.
    let flags = unsafe { libc::fcntl(pipe[0], libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(unsafe { libc::fcntl(pipe[0], libc::F_SETFL, flags | libc::O_NONBLOCK) }, 0);

    let inherited_writer = pipe[1];
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["__terminal-host", "--bootstrap-stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // SAFETY: the hook calls only async-signal-safe fcntl(2), and its captured
    // descriptor is valid in the forked child. Clearing CLOEXEC deliberately
    // models the inherited integration-test pipe that caused the regression.
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(inherited_writer, libc::F_SETFD, 0) == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
    }
    let mut child = command.spawn().unwrap();
    // SAFETY: the parent no longer needs its writer after the child has
    // exec'd; EOF now depends solely on whether the hidden host retained it.
    assert_eq!(unsafe { libc::close(pipe[1]) }, 0);

    let deadline = Instant::now() + Duration::from_secs(2);
    let reached_eof = loop {
        let mut byte = [0; 1];
        match read_end.read(&mut byte) {
            Ok(0) => break true,
            Ok(_) => panic!("nothing writes to the inherited-descriptor test pipe"),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    break false;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) => panic!("read inherited-descriptor test pipe: {error}"),
        }
    };
    let host_was_alive = child.try_wait().unwrap().is_none();
    let _ = child.kill();
    let _ = child.wait();

    assert!(reached_eof, "terminal host retained an unrelated inherited descriptor");
    assert!(host_was_alive, "EOF came only from the terminal host exiting");
}
