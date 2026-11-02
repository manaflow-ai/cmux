//! The machine side of `cmux link sync`: `fs-v1` request lines on the
//! machine daemon's socket (spec/commands.md, "fs-v1").

use std::collections::BTreeMap;
use std::io::{BufRead as _, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

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
/// Most pages and entries of one folder's listing.
const MAX_LIST_PAGES: usize = 1000;
const MAX_LIST_ENTRIES: usize = 200_000;

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
}

impl Remote {
    pub(super) fn connect(socket: &Path) -> anyhow::Result<Self> {
        let stream = UnixStream::connect(socket)
            .with_context(|| format!("cannot connect to {}", socket.display()))?;
        stream.set_read_timeout(Some(IO_DEADLINE))?;
        // A machine that stops reading must not hold a write (and a
        // caller's lock) forever either.
        stream.set_write_timeout(Some(IO_DEADLINE))?;
        Ok(Self { reader: BufReader::new(stream), next_id: 1 })
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
    /// [`IO_DEADLINE`] stalls.
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
            self.reader.get_mut().write_all(slice)?;
            progress();
        }
        // The machine is not trusted: an answer line has a size limit, and
        // only so many answers for other requests are skipped.
        for _ in 0..=MAX_OTHER_ANSWERS {
            let mut answer = Vec::new();
            let read = Read::take(&mut self.reader, MAX_ANSWER_BYTES + 1)
                .read_until(b'\n', &mut answer)?;
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
        for _ in 0..MAX_LIST_PAGES {
            for entry in page["entries"].as_array().into_iter().flatten() {
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
                entries.insert(name, RemoteEntry { kind, revision });
            }
            if entries.len() > MAX_LIST_ENTRIES {
                bail!("the machine's listing of {path} never ends");
            }
            let Some(cursor) = page["cursor"].as_str().map(str::to_string) else {
                return Ok(Some(entries));
            };
            let listing = page["listing"].clone();
            page = self.call(
                "fs.list",
                json!({ "listing": listing, "cursor": cursor, "limit": LIST_LIMIT }),
            )?;
        }
        bail!("the machine's listing of {path} never ends")
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
        let second = if first.len() == PART_BYTES { read_part(reader)? } else { Vec::new() };
        if second.is_empty() {
            let entry = self.call_with_progress(
                "fs.write",
                json!({ "path": path, "bytes_base64": encode(&first), "mode": "overwrite", "permissions": permissions }),
                progress,
            )?;
            return revision_of(&entry);
        }
        let (parent, name) = split(path)?;
        let part = format!("{}/.{name}.cmux-sync-part", parent.trim_end_matches('/'));
        let mut revision = revision_of(&self.call_with_progress(
            "fs.write",
            json!({ "path": part, "bytes_base64": encode(&first), "mode": "overwrite", "permissions": permissions }),
            progress,
        )?)?;
        let mut chunk = second;
        while !chunk.is_empty() {
            revision = revision_of(&self.call_with_progress(
                "fs.write",
                json!({ "path": part, "bytes_base64": encode(&chunk), "mode": "append", "expected": revision }),
                progress,
            )?)?;
            chunk = read_part(reader)?;
        }
        // Only a file is replaced; a folder in the way stays and the rename
        // answers fs.exists.
        if self.kind(path)?.as_deref() == Some("file") {
            self.delete(&[path.to_string()])?;
        }
        let entry = self.call("fs.rename", json!({ "path": part, "name": name }))?;
        // A rename keeps size and mtime, so the revision is the last part's.
        Ok(entry["entry"]["revision"].as_str().map_or(revision, str::to_string))
    }

    /// Reads the whole file at `path` into memory, up to [`READ_CAP`]
    /// bytes; None when it is not there.
    pub(super) fn read(&mut self, path: &str) -> anyhow::Result<Option<Vec<u8>>> {
        let mut bytes = Vec::new();
        Ok(self.read_into(path, &mut bytes, READ_CAP)?.map(|_| bytes))
    }

    /// Streams the file at `path` into `out`, refusing one over `cap` bytes.
    /// Returns its size; None when it is not there.
    pub(super) fn read_into(
        &mut self,
        path: &str,
        out: &mut dyn Write,
        cap: u64,
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
            size += part.len() as u64;
            if size > cap {
                bail!("the machine's {path} is over {cap} bytes");
            }
            out.write_all(part)?;
            if answer["truncated"] != json!(true) {
                return Ok(Some(size));
            }
            if part.is_empty() {
                bail!("fs.read of {path} made no progress");
            }
        }
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

pub(super) fn refusal_code(error: &anyhow::Error) -> Option<&str> {
    error.downcast_ref::<FsRefusal>().map(|refusal| refusal.code.as_str())
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
        let mut remote = Remote { reader: BufReader::new(client), next_id: 1 };
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
        Remote { reader: BufReader::new(client), next_id: 1 }
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

    /// A listing whose pages never end is refused.
    #[test]
    fn a_listing_that_never_ends_is_refused() {
        let mut remote = hostile(|requests, server| {
            for (page, request) in requests.enumerate().take(5000) {
                let answer = json!({"id": request["id"], "ok": true, "data": {
                    "entries": [{"name": format!("n{page}"), "kind": "file", "size": 1, "mtime": 1}],
                    "cursor": format!("c{page}"),
                    "listing": "l",
                }});
                if server.write_all(format!("{answer}\n").as_bytes()).is_err() {
                    return;
                }
            }
        });
        let error = remote.list("/x").unwrap_err();
        assert!(format!("{error:#}").contains("never ends"), "{error:#}");
    }
}
