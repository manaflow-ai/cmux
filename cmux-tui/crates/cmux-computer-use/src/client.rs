//! A small client of the worker's agent socket for the cmux-tui daemon
//! (Unix sockets): one request on its own connection, or a connection kept
//! for a stream (`preview/watch`). acpmux's bridge has its own client with
//! retries ([`crate::wire`] is the protocol both speak).

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};

/// How long the hello and one request may take.
pub const WAIT: Duration = Duration::from_secs(10);

/// A connection past its hello: write requests, read lines.
pub struct Connection {
    pub writer: UnixStream,
    pub reader: BufReader<UnixStream>,
}

impl Connection {
    /// Connects to `socket` and presents `secret_hex`.
    pub fn open(socket: &str, secret_hex: &str) -> io::Result<Self> {
        let stream = UnixStream::connect(socket)?;
        stream.set_read_timeout(Some(WAIT))?;
        stream.set_write_timeout(Some(WAIT))?;
        let mut connection =
            Self { writer: stream.try_clone()?, reader: BufReader::new(stream) };
        connection.send(&json!({"secret": secret_hex}))?;
        let hello = connection.read()?;
        if hello.get("ok") != Some(&json!(true)) {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, hello.to_string()));
        }
        Ok(connection)
    }

    pub fn send(&mut self, value: &Value) -> io::Result<()> {
        let mut line = value.to_string();
        line.push('\n');
        self.writer.write_all(line.as_bytes())?;
        self.writer.flush()
    }

    /// The next line as JSON; `UnexpectedEof` when the worker closed it.
    pub fn read(&mut self) -> io::Result<Value> {
        let mut line = String::new();
        if self.reader.read_line(&mut line)? == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        serde_json::from_str(&line).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    /// Lifts the read timeout (a stream that waits for events).
    pub fn unbounded(&self) -> io::Result<()> {
        self.reader.get_ref().set_read_timeout(None)
    }

    /// Sends `request` (its `id` set) and returns the answer with that id.
    pub fn request(&mut self, request: &Value) -> io::Result<Value> {
        self.send(request)?;
        loop {
            let answer = self.read()?;
            if answer.get("id") == request.get("id") {
                return Ok(answer);
            }
        }
    }
}

/// One request on its own connection.
pub fn request(socket: &str, secret_hex: &str, request: &Value) -> io::Result<Value> {
    Connection::open(socket, secret_hex)?.request(request)
}
