//! Wakes the CDP reader thread without a timer (p14-energy-077m).
//!
//! The reader thread owns the socket: it writes the queued commands and reads
//! the browser's messages. It sleeps in `poll(2)` on the socket and on the
//! read end of a socket pair. A writer that queues a command, or a close from
//! another thread, writes one byte to the other end ([`ReaderWaker::wake`]);
//! the client's drop closes that end, which also ends the wait. An idle
//! connection then wakes nobody, where the old loop read with a 20 ms timeout
//! (50 wakes a second per connection). Chromium's message pump waits the same
//! way: `MessagePumpLibevent` / `MessagePumpKqueue` block on the fds with no
//! timeout and a pipe or `EVFILT_USER` wakes them.

use std::time::Duration;

/// The writers' end, kept in the client's shared state.
pub(super) struct ReaderWaker {
    #[cfg(unix)]
    tx: std::os::unix::net::UnixStream,
}

/// The reader thread's end.
pub(super) struct ReaderWake {
    #[cfg(unix)]
    rx: std::os::unix::net::UnixStream,
}

pub(super) fn reader_wake() -> std::io::Result<(ReaderWaker, ReaderWake)> {
    #[cfg(unix)]
    {
        let (tx, rx) = std::os::unix::net::UnixStream::pair()?;
        tx.set_nonblocking(true)?;
        rx.set_nonblocking(true)?;
        Ok((ReaderWaker { tx }, ReaderWake { rx }))
    }
    #[cfg(not(unix))]
    {
        Ok((ReaderWaker {}, ReaderWake {}))
    }
}

impl ReaderWaker {
    /// Wakes the reader. A full buffer means a wake is already pending.
    pub(super) fn wake(&self) {
        #[cfg(unix)]
        {
            use std::io::Write;
            let _ = (&self.tx).write(&[1]);
        }
    }
}

impl ReaderWake {
    /// Sleeps until `socket` is readable (or closed), a writer wakes the
    /// reader, or the client drops; with `retry`, at most that long. True
    /// when the socket has something for a read.
    #[cfg(unix)]
    pub(super) fn wait(
        &self,
        socket: &std::net::TcpStream,
        retry: Option<Duration>,
    ) -> std::io::Result<bool> {
        use std::io::Read;
        use std::os::fd::AsRawFd;

        let mut fds = [
            libc::pollfd { fd: socket.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: self.rx.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        let retry_ms = retry
            .map(|retry| i32::try_from(retry.as_nanos().div_ceil(1_000_000)).unwrap_or(i32::MAX));
        loop {
            let ready = if let Some(retry_ms) = retry_ms {
                // wakeup-allow: bounded the event backlog retry, only while the consumer's event channel is full
                // SAFETY: `fds` is a valid array of two pollfd for the call.
                unsafe { libc::poll(fds.as_mut_ptr(), 2, retry_ms) }
            } else {
                // SAFETY: `fds` is a valid array of two pollfd for the call.
                unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) }
            };
            if ready >= 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        if fds[1].revents != 0 {
            let mut sink = [0_u8; 64];
            while matches!((&self.rx).read(&mut sink), Ok(read) if read > 0) {}
        }
        Ok(fds[0].revents != 0)
    }

    /// Without `poll(2)` the reader reads at once; the socket's short read
    /// timeout paces it, as before p14-energy-077m.
    #[cfg(not(unix))]
    pub(super) fn wait(
        &self,
        _socket: &std::net::TcpStream,
        _retry: Option<Duration>,
    ) -> std::io::Result<bool> {
        Ok(true)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::io::Write;
    use std::net::{TcpListener, TcpStream};
    use std::sync::mpsc::{RecvTimeoutError, channel};
    use std::thread;
    use std::time::Duration;

    use super::reader_wake;

    fn connected() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        (client, server)
    }

    #[test]
    fn an_idle_wait_sleeps_until_a_writer_wakes_it() {
        let (waker, wake) = reader_wake().unwrap();
        let (socket, _server) = connected();
        let (done_tx, done_rx) = channel();
        let reader = thread::spawn(move || {
            done_tx.send(wake.wait(&socket, None).unwrap()).unwrap();
            // The wake was consumed: the next wait sleeps until its retry.
            done_tx.send(wake.wait(&socket, Some(Duration::from_millis(50))).unwrap()).unwrap();
        });
        assert_eq!(
            done_rx.recv_timeout(Duration::from_millis(300)),
            Err(RecvTimeoutError::Timeout),
            "an idle wait returned without the socket or a writer"
        );
        waker.wake();
        waker.wake();
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(2)), Ok(false));
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(2)), Ok(false));
        reader.join().unwrap();
    }

    #[test]
    fn data_on_the_socket_ends_the_wait() {
        let (_waker, wake) = reader_wake().unwrap();
        let (socket, mut server) = connected();
        server.write_all(b"x").unwrap();
        assert!(wake.wait(&socket, None).unwrap());
    }

    #[test]
    fn dropping_the_waker_ends_the_wait() {
        let (waker, wake) = reader_wake().unwrap();
        let (socket, _server) = connected();
        let reader = thread::spawn(move || wake.wait(&socket, None).unwrap());
        drop(waker);
        assert!(!reader.join().unwrap());
    }
}
