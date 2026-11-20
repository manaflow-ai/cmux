//! One clock for a launch subprocess and its standard streams. A helper can exit while a
//! descendant keeps its output open or its stdin unread. The parent's endpoints time out even
//! then; nothing needs to kill a successful helper's descendants or wait for them to exit.

use cmux_process::{Command, Output, Stdio};
use std::io::{self, Read, Write};
use std::os::{fd::OwnedFd, unix::net::UnixStream};
use std::time::{Duration, Instant};

struct Stream(UnixStream, Instant);

impl Stream {
    fn pair(deadline: Instant) -> io::Result<(Self, Stdio)> {
        let (parent, child) = UnixStream::pair()?;
        Ok((Self(parent, deadline), Stdio::from(OwnedFd::from(child))))
    }

    fn left(&self) -> io::Result<Duration> {
        self.1
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or_else(|| io::ErrorKind::TimedOut.into())
    }

    fn collect(mut self) -> io::Result<Vec<u8>> {
        let mut data = Vec::new();
        self.read_to_end(&mut data)?;
        Ok(data)
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.set_read_timeout(Some(self.left()?))?;
        self.0.read(buf)
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.set_write_timeout(Some(self.left()?))?;
        self.0.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub(super) fn output(mut cmd: Command, input: Option<&str>, limit: Duration) -> io::Result<Output> {
    let deadline = Instant::now() + limit;
    let (out, child_out) = Stream::pair(deadline)?;
    let (err, child_err) = Stream::pair(deadline)?;
    let writer = match input {
        Some(input) => {
            let (writer, child_in) = Stream::pair(deadline)?;
            cmd.stdin(child_in);
            Some((writer, input))
        }
        None => {
            cmd.stdin(Stdio::null());
            None
        }
    };
    let mut child = cmd.process_group(0).stdout(child_out).stderr(child_err).spawn()?;
    std::thread::scope(|scope| {
        let writer =
            writer.map(|(mut pipe, text)| scope.spawn(move || pipe.write_all(text.as_bytes())));
        let out = scope.spawn(move || out.collect());
        let err = scope.spawn(move || err.collect());
        let status = child.wait_timeout(deadline.saturating_duration_since(Instant::now()))?;
        drop(child);
        let status = status.ok_or(io::ErrorKind::TimedOut)?;
        let io_panic = |_| io::Error::other("cmux acp stream worker panicked");
        if let Some(writer) = writer {
            let wrote = writer.join().map_err(io_panic)?;
            // A refusal can close stdin before consuming the prompt; retain its diagnostic.
            if status.success() {
                wrote?;
            }
        }
        Ok(Output {
            status,
            stdout: out.join().map_err(io_panic)??,
            stderr: err.join().map_err(io_panic)??,
        })
    })
}
