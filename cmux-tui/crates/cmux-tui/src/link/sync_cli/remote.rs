//! The machine side of `cmux link sync`: `fs-v1` request lines on the
//! machine daemon's socket (spec/commands.md, "fs-v1").

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead as _, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Context as _, anyhow, bail};
use base64::Engine as _;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// Bytes per `fs.write` line: the daemon takes 12 MiB, so a part stays
/// under it with room for the request around its base64.
pub(super) const PART_BYTES: usize = 8 * 1024 * 1024;
/// Bytes of a request line sent per socket write, so a caller watching
/// progress hears of bytes moving within one part, not only after its answer.
const SEND_SLICE_BYTES: usize = 256 * 1024;
/// How long one socket read or write may block. A caller that times out a
/// silent transfer waits longer than this (CloudAccessCLI's upload idle).
pub(super) const IO_DEADLINE: Duration = Duration::from_secs(60);
/// The slowest link a request's answer is still waited for on. The machine
/// link's forwarder takes a whole `fs.write` part into its own buffer at
/// once, so the request's last byte "reaches the socket" long before it
/// reaches the machine, and the answer only starts once all of it has
/// crossed: a part of [`PART_BYTES`] (about 11 MB of base64) needs about
/// 6 minutes at this rate before [`IO_DEADLINE`] of silence counts.
const MIN_LINK_BYTES_PER_SECOND: u64 = 32 * 1024;
/// Bytes per `fs.read` answer asked for.
const READ_BYTES: u64 = 8 * 1024 * 1024;
/// Entries per `fs.list` page (the daemon's maximum).
const LIST_LIMIT: u64 = 1000;
/// Most bytes [`Remote::read`] holds in memory (a manifest, an index, a ref).
const READ_CAP: u64 = 1 << 30;
/// Most bytes of one answer line: an `fs.read` part of [`READ_BYTES`] in
/// base64, with room for the JSON around it.
const MAX_ANSWER_BYTES: u64 = 16 * 1024 * 1024;
/// Most answers for other requests one call skips before it gives up.
const MAX_OTHER_ANSWERS: usize = 16;
/// Bytes of a file's first part that decide whether it is compressed: a
/// file whose start does not shrink (a git pack, an image, an archive) is
/// sent as it is, without spending time on the rest.
const PROBE_BYTES: usize = 64 * 1024;
/// The refusal of a no-follow write that met a symlink on its path.
pub(super) const SYMLINK_IN_PATH: &str = "fs.symlink_in_path";
/// The deflate level: about as fast as a link of hundreds of MB/s, and
/// within a few percent of the best size on source text.
const DEFLATE_LEVEL: u32 = 3;

/// A listing named something other than one plain component.
#[derive(Debug)]
pub(super) struct UnsafeName(pub String);

impl std::fmt::Display for UnsafeName {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "the machine listed an unsafe name {:?}; nothing was brought back",
            self.0
        )
    }
}

impl std::error::Error for UnsafeName {}

/// What a listing says about one entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct RemoteEntry {
    pub kind: String,
    pub revision: Option<String>,
}

/// An `fs-v1` error the daemon answered.
#[derive(Debug)]
pub(super) struct FsRefusal {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for FsRefusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for FsRefusal {}

/// One connection to the machine daemon.
pub(super) struct Remote {
    reader: BufReader<UnixStream>,
    next_id: u64,
    /// The machine takes deflate write bytes (`fs-write-deflate-v1`,
    /// [`Remote::negotiate`]); otherwise every write is plain base64.
    deflate: bool,
    /// The machine refuses a write through a symlink on its path
    /// (`fs-write-nofollow-v1`, [`Remote::negotiate`]): every write says
    /// `no_follow`, so a caller need not `fs.stat` the target first.
    no_follow: bool,
}

impl Remote {
    pub(super) fn connect(socket: &Path) -> anyhow::Result<Self> {
        let stream = UnixStream::connect(socket)
            .with_context(|| format!("cannot connect to {}", socket.display()))?;
        stream.set_read_timeout(Some(IO_DEADLINE))?;
        // A machine that stops reading must not hold a write (and a
        // caller's lock) forever either.
        stream.set_write_timeout(Some(IO_DEADLINE))?;
        Ok(Self { reader: BufReader::new(stream), next_id: 1, deflate: false, no_follow: false })
    }

    /// [`Remote::connect`], then asks the machine which write encodings it
    /// takes ([`Remote::negotiate`]).
    pub(super) fn connect_negotiated(socket: &Path) -> anyhow::Result<Self> {
        let mut remote = Self::connect(socket)?;
        remote.negotiate();
        Ok(remote)
    }

    /// Writes compressed bytes from now on when the machine's `identify`
    /// lists `fs-write-deflate-v1`, and no-follow writes when it lists
    /// `fs-write-nofollow-v1`. A machine that lacks them, or does not answer
    /// `identify`, gets every write exactly as before.
    pub(super) fn negotiate(&mut self) {
        let served: Vec<String> = self
            .call("identify", json!({}))
            .ok()
            .and_then(|identity| {
                identity["capabilities"].as_array().map(|served| {
                    served.iter().filter_map(|name| name.as_str().map(str::to_string)).collect()
                })
            })
            .unwrap_or_default();
        let serves = |capability: &str| served.iter().any(|name| name == capability);
        self.deflate = serves(cmux_tui_core::fs_ops::FS_WRITE_DEFLATE_CAPABILITY);
        self.no_follow = serves(cmux_tui_core::fs_ops::FS_WRITE_NOFOLLOW_CAPABILITY);
    }

    /// Whether every write of this connection refuses a symlink on its path
    /// (`fs.symlink_in_path`) instead of following it.
    pub(super) fn no_follow(&self) -> bool {
        self.no_follow
    }

    /// `request` with `no_follow` when the machine takes it.
    fn guarded(&self, mut request: Value) -> Value {
        if self.no_follow {
            request.set("no_follow", json!(true));
        }
        request
    }

    /// Sends one request and returns its `data`; an `ok: false` answer is
    /// an [`FsRefusal`].
    pub(super) fn call(&mut self, cmd: &str, params: Value) -> anyhow::Result<Value> {
        self.call_with_progress(cmd, params, &mut || {})
    }

    /// [`Remote::call`], calling `progress` after each [`SEND_SLICE_BYTES`]
    /// of the request reach the socket and once more when its answer comes:
    /// a slow link that is still taking bytes is heard from while a part of
    /// [`PART_BYTES`] is in flight, so only a link silent past
    /// [`IO_DEADLINE`] stalls. The answer is waited for as long as the
    /// request could still be crossing the link ([`answer_budget`]), not
    /// one socket timeout: a timed-out read (EAGAIN, os error 35 on macOS)
    /// within that budget is read again, never the call's failure.
    fn call_with_progress(
        &mut self,
        cmd: &str,
        mut params: Value,
        progress: &mut dyn FnMut(),
    ) -> anyhow::Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        params.set("id", json!(id));
        params.set("cmd", json!(cmd));
        let mut line = params.to_string();
        line.push('\n');
        for slice in line.as_bytes().chunks(SEND_SLICE_BYTES) {
            self.reader.get_mut().write_all(slice).map_err(|error| {
                stalled(error, "the machine took no bytes of the request", self.write_timeout())
            })?;
            progress();
        }
        let silence = self.read_timeout();
        let budget = answer_budget(silence, line.len());
        let answer_by = Instant::now().checked_add(budget);
        // The machine is not trusted: an answer line has a size limit, and
        // only so many answers for other requests are skipped.
        for _ in 0..=MAX_OTHER_ANSWERS {
            let mut answer = Vec::new();
            let mut limited = Read::take(&mut self.reader, MAX_ANSWER_BYTES + 1);
            let read = loop {
                // `read_until` keeps what it read before an error in
                // `answer`, and `limited` keeps its count, so a read again
                // goes on where the timed-out one stopped.
                match limited.read_until(b'\n', &mut answer) {
                    Ok(_) => break answer.len(),
                    // Still within the budget: the caller hears of it, so an
                    // upload's idle deadline does not end a part in flight.
                    Err(error)
                        if timed_out(&error) && answer_by.is_none_or(|by| Instant::now() < by) =>
                    {
                        progress();
                    }
                    Err(error) => {
                        let what =
                            format!("the machine did not answer within {} s", budget.as_secs());
                        return Err(stalled(error, &what, None));
                    }
                }
            };
            if read == 0 {
                bail!("the machine daemon closed the connection");
            }
            if answer.last() != Some(&b'\n') {
                if u64::try_from(read).unwrap_or(u64::MAX) > MAX_ANSWER_BYTES {
                    bail!("the machine daemon's answer is too long");
                }
                bail!("the machine daemon closed the connection");
            }
            let answer: Value =
                serde_json::from_slice(&answer).context("the answer is not JSON")?;
            if answer["id"] != json!(id) {
                continue;
            }
            progress();
            if answer["ok"] == json!(true) {
                return Ok(answer["data"].clone());
            }
            return Err(FsRefusal {
                code: answer["error_code"].as_str().unwrap_or("fs.unknown").to_string(),
                message: answer["error"].as_str().unwrap_or_default().to_string(),
            }
            .into());
        }
        bail!("the machine daemon kept answering other requests")
    }

    /// The entries of the folder at `path` by name; None when it is not there.
    pub(super) fn list(
        &mut self,
        path: &str,
    ) -> anyhow::Result<Option<BTreeMap<String, RemoteEntry>>> {
        let mut entries = BTreeMap::new();
        let request = json!({ "path": path, "limit": LIST_LIMIT, "filter": { "hidden": true } });
        let mut page = match self.call("fs.list", request) {
            Ok(page) => page,
            Err(error) if refusal_code(&error) == Some("fs.not_found") => return Ok(None),
            Err(error) => return Err(error),
        };
        let listing = page.get("listing").cloned();
        let mut cursors = BTreeSet::new();
        loop {
            if page.get("listing") != listing.as_ref() {
                bail!("the machine changed the listing of {path}");
            }
            let batch = page["entries"].as_array().context("fs.list answered no entries")?;
            for entry in batch {
                let name = entry["name"].as_str().unwrap_or_default().to_string();
                // The machine is not trusted: a listed name is one plain
                // component, or the whole listing is refused.
                if !super::names::plain_name(&name) {
                    return Err(UnsafeName(name).into());
                }
                let kind = entry["kind"].as_str().unwrap_or_default().to_string();
                let revision = entry["size"]
                    .as_u64()
                    .map(|size| cmux_tui_core::fs_ops::revision(size, entry["mtime"].as_u64()));
                if entries.insert(name, RemoteEntry { kind, revision }).is_some() {
                    bail!("the machine repeated an entry in the listing of {path}");
                }
            }
            let Some(cursor) = page["cursor"].as_str().map(str::to_string) else {
                return Ok(Some(entries));
            };
            // Pagination may run for any number of pages, but every page
            // must advance within the same snapshot. A repeated cursor or
            // an empty nonterminal page is a protocol error, not a big folder.
            if batch.is_empty() || !cursors.insert(cursor.clone()) {
                bail!("the machine's listing of {path} made no progress");
            }
            page = self.call(
                "fs.list",
                json!({ "listing": listing, "cursor": cursor, "limit": LIST_LIMIT }),
            )?;
        }
    }

    /// Creates the folder `path` and any missing folder above it.
    pub(super) fn mkdir_all(&mut self, path: &str) -> anyhow::Result<()> {
        if self.is_dir(path)? {
            return Ok(());
        }
        let (parent, name) = split(path)?;
        self.mkdir_all(parent)?;
        match self.call("fs.mkdir", json!({ "path": parent, "name": name })) {
            Ok(_) => Ok(()),
            Err(error) if refusal_code(&error) == Some("fs.exists") && self.is_dir(path)? => Ok(()),
            Err(error) => Err(error),
        }
    }

    /// The socket's read timeout: how long one read waits with nothing
    /// coming ([`IO_DEADLINE`] from [`Remote::connect`]).
    fn read_timeout(&self) -> Option<Duration> {
        self.reader.get_ref().read_timeout().ok().flatten()
    }

    fn write_timeout(&self) -> Option<Duration> {
        self.reader.get_ref().write_timeout().ok().flatten()
    }

    fn is_dir(&mut self, path: &str) -> anyhow::Result<bool> {
        Ok(self.kind(path)?.as_deref() == Some("dir"))
    }

    /// The kind of the entry at `path` (`file`, `dir`, `symlink`, `other`);
    /// None when nothing is there.
    pub(super) fn kind(&mut self, path: &str) -> anyhow::Result<Option<String>> {
        Ok(self.stat(path)?.and_then(|stat| stat["kind"].as_str().map(str::to_string)))
    }

    /// The `fs.stat` answer for `path`; None when nothing is there.
    pub(super) fn stat(&mut self, path: &str) -> anyhow::Result<Option<Value>> {
        match self.call("fs.stat", json!({ "path": path })) {
            Ok(stat) => Ok(Some(stat)),
            Err(error) if refusal_code(&error) == Some("fs.not_found") => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// Writes what `reader` gives to `path`, replacing a file there. Over
    /// [`PART_BYTES`] it is written in parts to a temporary name in the same
    /// folder, then renamed into place. Returns the file's new revision.
    pub(super) fn write(
        &mut self,
        path: &str,
        reader: &mut dyn Read,
        permissions: u32,
    ) -> anyhow::Result<String> {
        let mut ignored = || {};
        self.write_with_progress(path, reader, permissions, &mut ignored)
    }

    /// Writes a file while notifying the caller as its bytes reach the
    /// socket (every [`SEND_SLICE_BYTES`]) and as each part's answer comes.
    /// The callback is synchronous: upload callers use it to emit a stdout
    /// heartbeat that keeps their bounded idle deadline alive.
    pub(super) fn write_with_progress(
        &mut self,
        path: &str,
        reader: &mut dyn Read,
        permissions: u32,
        progress: &mut dyn FnMut(),
    ) -> anyhow::Result<String> {
        let first = read_part(reader)?;
        let compress = self.deflate && shrinks(&first);
        let second = if first.len() == PART_BYTES { read_part(reader)? } else { Vec::new() };
        if second.is_empty() {
            let request = self
                .guarded(json!({ "path": path, "mode": "overwrite", "permissions": permissions }));
            let entry = self.call_with_progress(
                "fs.write",
                with_bytes(request, &first, compress)?,
                progress,
            )?;
            return revision_of(&entry);
        }
        let (parent, name) = split(path)?;
        let part = format!("{}/.{name}.cmux-sync-part", parent.trim_end_matches('/'));
        let request =
            self.guarded(json!({ "path": part, "mode": "overwrite", "permissions": permissions }));
        let mut revision = revision_of(&self.call_with_progress(
            "fs.write",
            with_bytes(request, &first, compress)?,
            progress,
        )?)?;
        let mut chunk = second;
        while !chunk.is_empty() {
            let request =
                self.guarded(json!({ "path": part, "mode": "append", "expected": revision }));
            revision = revision_of(&self.call_with_progress(
                "fs.write",
                with_bytes(request, &chunk, compress)?,
                progress,
            )?)?;
            chunk = read_part(reader)?;
        }
        // Only a file is replaced; a folder in the way stays and the rename
        // answers fs.exists. A symlink there stays too, and with no-follow
        // writes the caller hears of it as the daemon would say it.
        match self.kind(path)?.as_deref() {
            Some("file") => self.delete(&[path.to_string()])?,
            Some("symlink") if self.no_follow => {
                self.delete(std::slice::from_ref(&part))?;
                return Err(FsRefusal {
                    code: SYMLINK_IN_PATH.to_string(),
                    message: "a symlink is on the path".to_string(),
                }
                .into());
            }
            _ => {}
        }
        let entry = self.call("fs.rename", json!({ "path": part, "name": name }))?;
        // A rename keeps size and mtime, so the revision is the last part's.
        Ok(entry["entry"]["revision"].as_str().map_or(revision, str::to_string))
    }

    /// Reads the whole file at `path` into memory, up to [`READ_CAP`]
    /// bytes; None when it is not there.
    pub(super) fn read(&mut self, path: &str) -> anyhow::Result<Option<Vec<u8>>> {
        struct Buffer(Vec<u8>);
        impl Write for Buffer {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if (self.0.len() as u64).saturating_add(bytes.len() as u64) > READ_CAP {
                    return Err(std::io::Error::other("in-memory read is over 1 GiB"));
                }
                self.0.extend_from_slice(bytes);
                Ok(bytes.len())
            }

            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut bytes = Buffer(Vec::new());
        Ok(self.read_into(path, &mut bytes)?.map(|_| bytes.0))
    }

    /// Streams the file at `path` into `out` through bounded range reads.
    /// Returns its size; None when it is not there.
    pub(super) fn read_into(
        &mut self,
        path: &str,
        out: &mut dyn Write,
    ) -> anyhow::Result<Option<u64>> {
        let mut size = 0u64;
        loop {
            let answer = match self
                .call("fs.read", json!({ "path": path, "offset": size, "max_bytes": READ_BYTES }))
            {
                Ok(answer) => answer,
                Err(error) if refusal_code(&error) == Some("fs.not_found") => return Ok(None),
                Err(error) => return Err(error),
            };
            let decoded;
            let part: &[u8] = match (answer["text"].as_str(), answer["bytes_base64"].as_str()) {
                (Some(text), _) => text.as_bytes(),
                (None, Some(encoded)) => {
                    decoded = base64::engine::general_purpose::STANDARD
                        .decode(encoded)
                        .context("bad base64")?;
                    &decoded
                }
                (None, None) => bail!("fs.read answered no bytes"),
            };
            size = size.checked_add(part.len() as u64).context("fs.read offset overflow")?;
            out.write_all(part)?;
            if answer["truncated"] != json!(true) {
                return Ok(Some(size));
            }
            if part.is_empty() {
                bail!("fs.read of {path} made no progress");
            }
        }
    }

    /// The text of the symlink at `path` (`fs-symlink-v1`): None when
    /// nothing is there.
    pub(super) fn readlink(&mut self, path: &str) -> anyhow::Result<Option<String>> {
        match self.call("fs.readlink", json!({ "path": path })) {
            Ok(answer) => Ok(Some(
                answer
                    .get("target")
                    .and_then(Value::as_str)
                    .context("fs.readlink answered no target")?
                    .to_string(),
            )),
            Err(error) if refusal_code(&error) == Some("fs.not_found") => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// Makes a symlink at `path` whose text is `target` (`fs-symlink-v1`);
    /// nothing may be there.
    pub(super) fn symlink(&mut self, path: &str, target: &str) -> anyhow::Result<()> {
        self.call("fs.symlink", json!({ "path": path, "target": target })).map(drop)
    }

    /// Deletes the files or folders at `paths`; ones already gone are fine.
    pub(super) fn delete(&mut self, paths: &[String]) -> anyhow::Result<()> {
        for path in paths {
            match self.call("fs.delete", json!({ "paths": [path], "permanent": true })) {
                Ok(_) => {}
                Err(error) if refusal_code(&error) == Some("fs.not_found") => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}

/// Whether `error` says the machine's daemon has no symlink ops
/// (`fs-symlink-v1`): it refused the op itself (unknown to it, or denied by
/// an older link gate), not the one path.
pub(super) fn lacks_symlinks(error: &anyhow::Error) -> bool {
    refusal_code(error).is_some_and(|code| {
        code == "fs.unavailable" || !(code.starts_with("fs.") || code == "params.invalid")
    })
}

pub(super) fn refusal_code(error: &anyhow::Error) -> Option<&str> {
    error.downcast_ref::<FsRefusal>().map(|refusal| refusal.code.as_str())
}

/// How long a request of `request_bytes` may wait for its answer: one
/// `silence` (the socket's read timeout) plus the time the request takes to
/// cross a link at [`MIN_LINK_BYTES_PER_SECOND`].
fn answer_budget(silence: Option<Duration>, request_bytes: usize) -> Duration {
    let bytes = u64::try_from(request_bytes).unwrap_or(u64::MAX);
    let crossing = Duration::from_millis(bytes.saturating_mul(1000) / MIN_LINK_BYTES_PER_SECOND);
    silence.unwrap_or(IO_DEADLINE).saturating_add(crossing)
}

/// Whether `error` is a socket timeout: SO_RCVTIMEO and SO_SNDTIMEO end a
/// blocking read or write with EAGAIN (`WouldBlock`; os error 35 on macOS,
/// 11 on Linux), and some platforms answer `TimedOut`.
fn timed_out(error: &std::io::Error) -> bool {
    matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut)
}

/// A socket error as the person reads it: a timeout says what stalled and
/// for how long instead of "Resource temporarily unavailable (os error 35)".
fn stalled(error: std::io::Error, what: &str, silence: Option<Duration>) -> anyhow::Error {
    if !timed_out(&error) {
        return error.into();
    }
    match silence {
        Some(silence) => anyhow!("{what} (nothing moved for {} s)", silence.as_secs()),
        None => anyhow!("{what}"),
    }
}

/// Up to [`PART_BYTES`] from `reader`; empty at its end.
fn read_part(reader: &mut dyn Read) -> anyhow::Result<Vec<u8>> {
    let mut part = Vec::with_capacity(PART_BYTES.min(1 << 20));
    Read::take(&mut *reader, PART_BYTES as u64).read_to_end(&mut part)?;
    Ok(part)
}

fn encode(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// `request` with the bytes of `part`: deflate (with `decoded_size`) when
/// `compress` and that is smaller, else plain base64 as before.
fn with_bytes(mut request: Value, part: &[u8], compress: bool) -> anyhow::Result<Value> {
    if compress {
        let wire = deflate(part)?;
        if wire.len() < part.len() {
            request.set("bytes_base64", json!(encode(&wire)));
            request.set("encoding", json!(cmux_tui_core::fs_ops::DEFLATE));
            request.set("decoded_size", json!(part.len()));
            return Ok(request);
        }
    }
    request.set("bytes_base64", json!(encode(part)));
    Ok(request)
}

/// Whether the start of `part` shrinks by more than a tenth (and by more
/// than the fields that say it is compressed).
fn shrinks(part: &[u8]) -> bool {
    let probe = part.get(..PROBE_BYTES).unwrap_or(part);
    deflate(probe).is_ok_and(|wire| {
        wire.len().saturating_add(64) < probe.len()
            && wire.len().saturating_mul(10) < probe.len().saturating_mul(9)
    })
}

fn deflate(bytes: &[u8]) -> std::io::Result<Vec<u8>> {
    let level = flate2::Compression::new(DEFLATE_LEVEL);
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), level);
    encoder.write_all(bytes)?;
    encoder.finish()
}

fn revision_of(data: &Value) -> anyhow::Result<String> {
    data["entry"]["revision"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| anyhow!("the write answered no revision"))
}

/// `path`'s parent folder and last name.
pub(super) fn split(path: &str) -> anyhow::Result<(&str, &str)> {
    let trimmed = path.trim_end_matches('/');
    let (parent, name) =
        trimmed.rsplit_once('/').ok_or_else(|| anyhow!("not an absolute path: {path}"))?;
    Ok((if parent.is_empty() { "/" } else { parent }, name))
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead as _, BufReader, Read as _, Write as _};
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    use serde_json::{Value, json};

    use super::{PART_BYTES, Remote};

    /// A part in flight on a slow link reports progress before its answer:
    /// the machine takes the first MiB of one 8 MiB `fs.write` and waits to
    /// hear of progress before taking the rest. Progress only after each
    /// answer (the 30 s upload idle killing a healthy slow upload) never
    /// comes, and the machine records that.
    #[test]
    fn a_part_in_flight_reports_progress_before_its_answer() {
        let (client, mut server) = UnixStream::pair().unwrap();
        client.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let (tick, ticks) = std::sync::mpsc::channel::<()>();
        let machine = std::thread::spawn(move || {
            let mut head = vec![0u8; 1 << 20];
            server.read_exact(&mut head).unwrap();
            let heard = ticks.recv_timeout(Duration::from_secs(5)).is_ok();
            let mut rest = Vec::new();
            BufReader::new(server.try_clone().unwrap()).read_until(b'\n', &mut rest).unwrap();
            let line = [head, rest].concat();
            let request: Value = serde_json::from_slice(&line).unwrap();
            let answer =
                json!({"id": request["id"], "ok": true, "data": {"entry": {"revision": "r1"}}});
            server.write_all(format!("{answer}\n").as_bytes()).unwrap();
            heard
        });
        let mut remote =
            Remote { reader: BufReader::new(client), next_id: 1, deflate: false, no_follow: false };
        let data = vec![7u8; PART_BYTES];
        let mut progress = || {
            let _ = tick.send(());
        };
        let revision = remote
            .write_with_progress("/work/f.bin", &mut data.as_slice(), 0o600, &mut progress)
            .unwrap();
        assert_eq!(revision, "r1");
        assert!(machine.join().unwrap(), "no progress while the part was in flight");
    }

    /// A part the link's forwarder took whole is still crossing to the
    /// machine, so its answer comes later than one socket timeout. Machine
    /// update copied the cmux-tui build this way and failed with "Resource
    /// temporarily unavailable (os error 35)": the socket's read timeout
    /// (EAGAIN) was taken for the call's failure. The machine here takes the
    /// whole request at once, then answers after five read timeouts.
    #[test]
    fn an_answer_slower_than_one_read_timeout_is_still_waited_for() {
        let (client, mut server) = UnixStream::pair().unwrap();
        let timeout = Duration::from_millis(100);
        client.set_read_timeout(Some(timeout)).unwrap();
        client.set_write_timeout(Some(Duration::from_secs(20))).unwrap();
        let machine = std::thread::spawn(move || {
            let mut line = Vec::new();
            BufReader::new(server.try_clone().unwrap()).read_until(b'\n', &mut line).unwrap();
            let request: Value = serde_json::from_slice(&line).unwrap();
            std::thread::sleep(timeout * 5);
            let answer =
                json!({"id": request["id"], "ok": true, "data": {"entry": {"revision": "r1"}}});
            server.write_all(format!("{answer}\n").as_bytes()).unwrap();
        });
        let mut remote =
            Remote { reader: BufReader::new(client), next_id: 1, deflate: false, no_follow: false };
        let data = vec![7u8; 256 * 1024];
        let revision = remote.write("/work/cmux-tui", &mut data.as_slice(), 0o755).unwrap();
        assert_eq!(revision, "r1");
        machine.join().unwrap();
    }

    /// A machine that never answers still fails, once the request's budget
    /// is spent, and says so instead of "os error 35".
    #[test]
    fn a_machine_that_never_answers_fails_with_what_stalled() {
        let mut remote = hostile(|requests, _| {
            requests.next();
        });
        remote.reader.get_ref().set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let started = std::time::Instant::now();
        let error = remote.stat("/work").unwrap_err().to_string();
        assert!(error.contains("did not answer"), "{error}");
        assert!(!error.contains("os error"), "{error}");
        assert!(started.elapsed() < Duration::from_secs(5), "waited {:?}", started.elapsed());
    }

    /// A [`Remote`] whose machine is `serve`: it gets each request and the
    /// connection to answer on, then the connection stays open (a machine
    /// that hangs) until the test ends.
    fn hostile(
        serve: impl FnOnce(&mut dyn Iterator<Item = Value>, &mut UnixStream) + Send + 'static,
    ) -> Remote {
        let (client, mut server) = UnixStream::pair().unwrap();
        client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        std::thread::spawn(move || {
            let reader = BufReader::new(server.try_clone().unwrap());
            let mut requests = reader
                .lines()
                .map_while(Result::ok)
                .map(|line| serde_json::from_str(&line).unwrap());
            serve(&mut requests, &mut server);
            std::thread::sleep(Duration::from_secs(30));
        });
        Remote { reader: BufReader::new(client), next_id: 1, deflate: false, no_follow: false }
    }

    /// An answer line that never ends is refused, not held in memory.
    #[test]
    fn an_answer_line_over_the_limit_is_refused() {
        let mut remote = hostile(|requests, server| {
            requests.next();
            let chunk = vec![b'x'; 1 << 20];
            for _ in 0..20 {
                if server.write_all(&chunk).is_err() {
                    return;
                }
            }
        });
        let error = remote.call("fs.stat", json!({"path": "/x"})).unwrap_err();
        assert!(format!("{error:#}").contains("too long"), "{error:#}");
    }

    /// Answers that never carry the request's id are refused.
    #[test]
    fn answers_for_other_requests_are_refused() {
        let mut remote = hostile(|requests, server| {
            requests.next();
            for _ in 0..2000 {
                let line = format!("{}\n", json!({"id": 999, "ok": true, "data": {}}));
                if server.write_all(line.as_bytes()).is_err() {
                    return;
                }
            }
        });
        let error = remote.call("fs.stat", json!({"path": "/x"})).unwrap_err();
        assert!(format!("{error:#}").contains("other requests"), "{error:#}");
    }

    /// A machine whose `identify` lists `capabilities` and that answers every
    /// `fs.write` with a revision; the returned channel gets each write.
    fn recording(capabilities: Value) -> (Remote, std::sync::mpsc::Receiver<Value>) {
        let (seen, writes) = std::sync::mpsc::channel();
        let remote = hostile(move |requests, server| {
            for request in requests {
                let data = match request["cmd"].as_str() {
                    Some("identify") => json!({"capabilities": capabilities}),
                    Some("fs.write") => {
                        let _ = seen.send(request.clone());
                        json!({"entry": {"revision": "r1"}})
                    }
                    _ => json!({"entry": {"revision": "r1"}}),
                };
                let answer = json!({"id": request["id"], "ok": true, "data": data});
                if server.write_all(format!("{answer}\n").as_bytes()).is_err() {
                    return;
                }
            }
        });
        (remote, writes)
    }

    fn decoded(request: &Value) -> Vec<u8> {
        use base64::Engine as _;
        let wire = base64::engine::general_purpose::STANDARD
            .decode(request["bytes_base64"].as_str().unwrap())
            .unwrap();
        if request["encoding"] != json!("deflate") {
            return wire;
        }
        let mut out = Vec::new();
        std::io::Read::read_to_end(
            &mut flate2::read::DeflateDecoder::new(wire.as_slice()),
            &mut out,
        )
        .unwrap();
        assert_eq!(request["decoded_size"], json!(out.len()));
        out
    }

    /// A machine without `fs-write-deflate-v1` (every image before it) gets
    /// plain base64 writes, exactly the old request.
    #[test]
    fn a_machine_without_the_capability_gets_plain_base64() {
        let (mut remote, writes) = recording(json!(["fs-v1"]));
        remote.negotiate();
        let text = "fn main() {}\n".repeat(10_000);
        remote.write("/work/main.rs", &mut text.as_bytes(), 0o644).unwrap();
        let request = writes.recv().unwrap();
        assert!(request.get("encoding").is_none(), "{request}");
        assert!(request.get("decoded_size").is_none(), "{request}");
        assert!(request.get("no_follow").is_none(), "{request}");
        assert_eq!(decoded(&request), text.as_bytes());
    }

    /// With `fs-write-nofollow-v1` every write says `no_follow`: the one of
    /// a small file, and each part and append of a large one.
    #[test]
    fn a_machine_with_no_follow_writes_gets_it_on_every_part() {
        let (mut remote, writes) = recording(json!(["fs-v1", "fs-write-nofollow-v1"]));
        remote.negotiate();
        assert!(remote.no_follow() && !remote.deflate);
        remote.write("/work/small.rs", &mut b"x".as_slice(), 0o644).unwrap();
        assert_eq!(writes.recv().unwrap()["no_follow"], true);
        let data = vec![1u8; PART_BYTES + 1];
        remote.write("/work/big.bin", &mut data.as_slice(), 0o644).unwrap();
        let first = writes.recv().unwrap();
        let append = writes.recv().unwrap();
        assert_eq!(
            (first["mode"].as_str(), append["mode"].as_str()),
            (Some("overwrite"), Some("append"))
        );
        assert_eq!((&first["no_follow"], &append["no_follow"]), (&json!(true), &json!(true)));
    }

    /// With the capability, text goes compressed and the parts of a file
    /// over one part still decode to the file; bytes that do not shrink go
    /// as they are.
    #[test]
    fn a_machine_with_the_capability_gets_deflate_for_what_shrinks() {
        let (mut remote, writes) = recording(json!(["fs-v1", "fs-write-deflate-v1"]));
        remote.negotiate();
        let text: Vec<u8> = "let value = compute(input);\n".repeat(400_000).into_bytes();
        assert!(text.len() > PART_BYTES);
        remote.write("/work/big.rs", &mut text.as_slice(), 0o755).unwrap();
        let mut rebuilt = Vec::new();
        let mut wire = 0;
        for _ in 0..text.len().div_ceil(PART_BYTES) {
            let request = writes.recv().unwrap();
            assert_eq!(request["encoding"], "deflate", "{}", request["mode"]);
            wire += request["bytes_base64"].as_str().unwrap().len();
            rebuilt.extend(decoded(&request));
        }
        assert!(rebuilt == text, "the parts do not decode to the file");
        assert!(wire * 20 < text.len(), "{wire} wire bytes for {}", text.len());

        let mut noise = vec![0u8; 256 * 1024];
        getrandom::fill(&mut noise).unwrap();
        remote.write("/work/blob.pack", &mut noise.as_slice(), 0o644).unwrap();
        let request = writes.recv().unwrap();
        assert!(request.get("encoding").is_none(), "noise was compressed");
        assert_eq!(decoded(&request), noise);
    }

    /// A listing that cycles cursors is refused promptly.
    #[test]
    fn a_listing_with_a_repeated_cursor_is_refused() {
        let mut remote = hostile(|requests, server| {
            for (page, request) in requests.enumerate().take(5000) {
                let answer = json!({"id": request["id"], "ok": true, "data": {
                    "entries": [{"name": format!("n{page}"), "kind": "file", "size": 1, "mtime": 1}],
                    "cursor": "c1",
                    "listing": "l",
                }});
                if server.write_all(format!("{answer}\n").as_bytes()).is_err() {
                    return;
                }
            }
        });
        let error = remote.list("/x").unwrap_err();
        assert!(format!("{error:#}").contains("no progress"), "{error:#}");
    }
}

#[cfg(test)]
#[path = "limits_tests.rs"]
mod limits_tests;
