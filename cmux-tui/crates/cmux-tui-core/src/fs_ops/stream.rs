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
//!        With `fs-write-deflate-v1` the request may also carry
//!        `"permissions"`, and `"encoding":"deflate"` with `"decoded_size"`:
//!        the `size` wire bytes are raw deflate, decoded as they come, never
//!        past `decoded_size` ([`super::encoding`]). With
//!        `fs-write-nofollow-v1`, `"no_follow":true` refuses a symlink as any
//!        component of `path` (`fs.symlink_in_path`).
//!
//! Backpressure is the socket itself: the daemon reads and writes through
//! one 256 KiB buffer and blocks on a full window. A write stream that ends
//! (or times out) before `size` bytes drops its [`PendingWrite`], which
//! unlinks the temporary file: nothing appears at `path`. A write the daemon
//! refuses after `ready` (bytes past `decoded_size`, a failed disk write) is
//! answered at once and the stream closes without reading the rest of the
//! `size` bytes: a client whose send then fails reads that answer.

use std::io::{self, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::FileExt as _;

use serde::Deserialize;
use serde_json::{Value, json};

use super::encoding::{Encoding, Inflater, Sink};
use super::entry::Meta;
use super::error::FsError;
use super::ops::FsService;
use super::sys;
use super::write::{PendingWrite, WriteMode};
use cmux_json::JsonSet as _;

/// Bytes moved per read or write.
pub const STREAM_CHUNK_BYTES: usize = 256 * 1024;

/// A request line that opens a byte stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamRequest {
    Read {
        id: Value,
        path: String,
        offset: u64,
    },
    Write {
        id: Value,
        path: String,
        mode: String,
        expected: Option<String>,
        size: u64,
        options: WriteOptions,
    },
}

/// The optional fields of a write stream (`fs-write-deflate-v1`,
/// `fs-write-nofollow-v1`); every one absent is the stream as before.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WriteOptions {
    pub permissions: Option<u32>,
    pub encoding: Option<String>,
    pub decoded_size: Option<u64>,
    pub no_follow: bool,
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
    #[serde(default)]
    permissions: Option<u32>,
    #[serde(default)]
    encoding: Option<String>,
    #[serde(default)]
    decoded_size: Option<u64>,
    #[serde(default)]
    no_follow: bool,
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
        let options = WriteOptions {
            permissions: line.permissions,
            encoding: line.encoding,
            decoded_size: line.decoded_size,
            no_follow: line.no_follow,
        };
        Some(Ok(Self::Write { id: line.id, path, mode, expected: line.expected, size, options }))
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
                value.set("error_details", details);
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
        StreamRequest::Write { path, mode, expected, size, options, .. } => {
            serve_write(service, &id, &path, (&mode, expected, &options), size, reader, writer)
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
    (mode, expected, options): (&str, Option<String>, &WriteOptions),
    size: u64,
    reader: &mut impl Read,
    writer: &mut impl Write,
) -> io::Result<()> {
    let begun =
        Encoding::parse(options.encoding.as_deref(), options.decoded_size).and_then(|encoding| {
            let decoded = match encoding {
                Encoding::Identity => size,
                Encoding::Deflate { decoded_size } => decoded_size,
            };
            let mode = WriteMode::parse(mode, expected)?;
            let mut pending = if options.no_follow {
                PendingWrite::begin_no_follow(service.roots(), path, mode, Some(decoded))?
            } else {
                PendingWrite::begin(service.roots(), path, mode, Some(decoded))?
            };
            if let Some(permissions) = options.permissions {
                pending.set_permissions(permissions)?;
            }
            Ok((encoding, pending))
        });
    let (encoding, mut pending) = match begun {
        Ok(begun) => begun,
        Err(error) => return send(writer, &answer(id, Err(error))),
    };
    send(writer, &answer(id, Ok(json!({ "ready": true }))))?;
    if let Encoding::Deflate { decoded_size } = encoding {
        let decoded = {
            let mut inflater = Inflater::new(&mut pending, decoded_size);
            match receive(reader, size, &mut inflater)? {
                Ok(()) => inflater.finish(),
                Err(error) => Err(error),
            }
        };
        if let Err(error) = decoded {
            return send(writer, &answer(id, Err(error)));
        }
        let result = pending.commit().map(|entry| json!({ "entry": entry }));
        return send(writer, &answer(id, result));
    }
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

/// Reads exactly `size` wire bytes from `reader` into `inflater`. The
/// outer error is the peer's (it ends the stream; the temporary file goes
/// with the [`PendingWrite`]); the inner one is answered.
fn receive<S: Sink>(
    reader: &mut impl Read,
    size: u64,
    inflater: &mut Inflater<'_, S>,
) -> io::Result<Result<(), FsError>> {
    let mut buffer = vec![0u8; STREAM_CHUNK_BYTES];
    let mut received = 0u64;
    while received < size {
        let left = size.saturating_sub(received).min(STREAM_CHUNK_BYTES as u64);
        let want = usize::try_from(left).unwrap_or(0);
        let Some(slot) = buffer.get_mut(..want) else { return Err(io::ErrorKind::Other.into()) };
        let read = match reader.read(slot) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if let Err(error) = inflater.push(buffer.get(..read).unwrap_or_default()) {
            return Ok(Err(error));
        }
        received = received.saturating_add(read as u64);
    }
    Ok(Ok(()))
}
