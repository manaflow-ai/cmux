//! The `fs.read` and `fs.write` byte streams: one dialed link stream per
//! transfer (the link's bulk class, transport.md 1), framed as
//!
//! read:  `{"id","cmd":"fs.read","path","offset"?,"stream":true}`
//!        -> header `{"id","ok":true,"data":{"size","length","revision"}}`
//!        -> exactly `length` raw bytes
//!        -> end `{"id","ok":true,"data":{"size","revision"}}`, or
//!           `fs.revision_mismatch` when the file changed while it was
//!           sent (the bytes are then not one version of the file).
//! write: `{"id","cmd":"fs.write","path","mode","expected"?,"stream":true,"size"}`
//!        -> ready `{"id","ok":true,"data":{"ready":true}}` (after the
//!           path, mode and free space are checked; nothing is sent before)
//!        -> exactly `size` raw bytes from the client
//!        -> `{"id","ok":true,"data":{"entry":{...}}}`.
//!
//! Backpressure is the socket itself: the daemon reads and writes through
//! one 256 KiB buffer and blocks on a full window. A write stream that ends
//! (or times out) before `size` bytes drops its [`PendingWrite`], which
//! unlinks the temporary file: nothing appears at `path`.

use std::io::{self, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::FileExt as _;

use serde::Deserialize;
use serde_json::{Value, json};

use super::entry::Meta;
use super::error::FsError;
use super::ops::FsService;
use super::sys;
use super::write::{PendingWrite, WriteMode};

/// Bytes moved per read or write.
pub const STREAM_CHUNK_BYTES: usize = 256 * 1024;
/// Largest write stream.
pub const MAX_STREAM_WRITE_BYTES: u64 = 64 * 1024 * 1024 * 1024;

/// A request line that opens a byte stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamRequest {
    Read { id: Value, path: String, offset: u64 },
    Write { id: Value, path: String, mode: String, expected: Option<String>, size: u64 },
}

#[derive(Deserialize)]
struct Line {
    #[serde(default)]
    id: Value,
    cmd: String,
    #[serde(default)]
    stream: bool,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    offset: Option<u64>,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    expected: Option<String>,
    #[serde(default)]
    size: Option<u64>,
}

impl StreamRequest {
    /// `Some` when `line` asks for a stream (`fs.read` or `fs.write` with
    /// `"stream": true`); the inner error answers a malformed one.
    #[must_use]
    pub fn parse(line: &str) -> Option<Result<Self, (Value, FsError)>> {
        let line: Line = serde_json::from_str(line).ok()?;
        if !line.stream || !matches!(line.cmd.as_str(), "fs.read" | "fs.write") {
            return None;
        }
        let id = line.id.clone();
        let invalid =
            |message: &str| Some(Err((id.clone(), FsError::ParamsInvalid(message.into()))));
        let Some(path) = line.path else { return invalid("path is required") };
        if line.cmd == "fs.read" {
            return Some(Ok(Self::Read { id: line.id, path, offset: line.offset.unwrap_or(0) }));
        }
        let Some(mode) = line.mode else { return invalid("mode is required") };
        let Some(size) = line.size else { return invalid("size is required for a write stream") };
        Some(Ok(Self::Write { id: line.id, path, mode, expected: line.expected, size }))
    }
}

/// One answer line in the v12 envelope (decision D1): `{id, ok:true,
/// data}` or `{id, ok:false, error, error_code, error_details?}`.
#[must_use]
pub fn answer(id: &Value, result: Result<Value, FsError>) -> Value {
    match result {
        Ok(data) => json!({ "id": id, "ok": true, "data": data }),
        Err(error) => {
            let mut value = json!({
                "id": id,
                "ok": false,
                "error": error.message(),
                "error_code": error.code(),
            });
            if let Some(details) = error.details() {
                value["error_details"] = details;
            }
            value
        }
    }
}

fn send(writer: &mut impl Write, value: &Value) -> io::Result<()> {
    let mut line = serde_json::to_vec(value).map_err(io::Error::other)?;
    line.push(b'\n');
    writer.write_all(&line)?;
    writer.flush()
}

/// Serves one stream on its own connection. `service` is `None` when this
/// daemon serves no file ops. An I/O error ends the stream (the peer is
/// gone); the caller closes the connection.
pub fn serve(
    service: Option<&FsService>,
    request: StreamRequest,
    reader: &mut impl Read,
    writer: &mut impl Write,
) -> io::Result<()> {
    let id = match &request {
        StreamRequest::Read { id, .. } | StreamRequest::Write { id, .. } => id.clone(),
    };
    let Some(service) = service else {
        return send(writer, &answer(&id, Err(FsError::Unavailable)));
    };
    match request {
        StreamRequest::Read { path, offset, .. } => serve_read(service, &id, &path, offset, writer),
        StreamRequest::Write { path, mode, expected, size, .. } => {
            serve_write(service, &id, &path, (&mode, expected), size, reader, writer)
        }
    }
}

fn serve_read(
    service: &FsService,
    id: &Value,
    path: &str,
    offset: u64,
    writer: &mut impl Write,
) -> io::Result<()> {
    let (file, meta) = match service.open_file(path) {
        Ok(opened) => opened,
        Err(error) => return send(writer, &answer(id, Err(error))),
    };
    let length = meta.size.saturating_sub(offset);
    let header = json!({ "size": meta.size, "length": length, "revision": meta.revision() });
    send(writer, &answer(id, Ok(header)))?;
    let mut buffer = vec![0u8; STREAM_CHUNK_BYTES];
    let mut sent = 0u64;
    let mut short = false;
    while sent < length {
        let want = usize::try_from((length - sent).min(STREAM_CHUNK_BYTES as u64)).unwrap_or(0);
        let read = if short { 0 } else { file.read_at(&mut buffer[..want], offset + sent)? };
        if read == 0 {
            // The file shrank: keep the promised length (zeros), and the end
            // line says the bytes are not one version.
            short = true;
            buffer[..want].fill(0);
            writer.write_all(&buffer[..want])?;
            sent += want as u64;
            continue;
        }
        writer.write_all(&buffer[..read])?;
        sent += read as u64;
    }
    let now = Meta::of(&sys::stat_fd(file.as_fd())?);
    let end = if short || now.revision() != meta.revision() {
        Err(FsError::RevisionMismatch { current: Some(now.revision()) })
    } else {
        Ok(json!({ "size": now.size, "revision": now.revision() }))
    };
    send(writer, &answer(id, end))
}

fn serve_write(
    service: &FsService,
    id: &Value,
    path: &str,
    (mode, expected): (&str, Option<String>),
    size: u64,
    reader: &mut impl Read,
    writer: &mut impl Write,
) -> io::Result<()> {
    if size > MAX_STREAM_WRITE_BYTES {
        return send(writer, &answer(id, Err(FsError::TooLarge { total: Some(size) })));
    }
    let begun = WriteMode::parse(mode, expected)
        .and_then(|mode| PendingWrite::begin(service.roots(), path, mode, Some(size)));
    let mut pending = match begun {
        Ok(pending) => pending,
        Err(error) => return send(writer, &answer(id, Err(error))),
    };
    send(writer, &answer(id, Ok(json!({ "ready": true }))))?;
    let mut buffer = vec![0u8; STREAM_CHUNK_BYTES];
    let mut received = 0u64;
    while received < size {
        let want = usize::try_from((size - received).min(STREAM_CHUNK_BYTES as u64)).unwrap_or(0);
        let read = match reader.read(&mut buffer[..want]) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            // `pending` drops here and unlinks the temporary file.
            Err(error) => return Err(error),
        };
        if let Err(error) = pending.write(&buffer[..read]) {
            return send(writer, &answer(id, Err(error)));
        }
        received += read as u64;
    }
    let result = pending.commit().map(|entry| json!({ "entry": entry }));
    send(writer, &answer(id, result))
}
