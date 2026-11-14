//! The machine side of `cmux link sync`: `fs-v1` request lines on the
//! machine daemon's socket (spec/commands.md, "fs-v1").

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead as _, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
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
/// How long a request whose answer is late may go on waiting while the machine still answers
/// `ping` on a connection of its own ([`alive`]): the copy's own bound (the app's
/// `CloudMoveCLI` gives a copy 30 minutes). A busy machine or link makes a copy slower, never
/// makes it fail.
const ANSWER_CEILING: Duration = Duration::from_secs(30 * 60);
/// How long the machine has to answer that `ping`.
const PROBE_DEADLINE: Duration = IO_DEADLINE;
/// How long a dropped connection is dialed again before the request fails
/// ([`Remote::reconnect`]): a machine link that redials comes back within it.
const RECONNECT_WINDOW: Duration = Duration::from_secs(3 * 60);
/// How many times one request is sent again on a new connection after its own dropped.
const MAX_REPLAYS: usize = 4;
/// How long past its budget a request waits on its own connection while the machine answers a
/// ping on another: past it, this connection counts as dropped (a link that redialed may leave
/// the old local stream open and silent), and a replayable request is sent again on a new one.
const STALE_CONNECTION: Duration = Duration::from_secs(10 * 60);
/// The requests sent again after a dropped connection ([`replayable`]): each reads, or
/// overwrites a whole file with the same bytes, so a second copy of one that landed changes
/// nothing, even when the first lands after it.
const REPLAYABLE: [&str; 9] = [
    "identify",
    "ping",
    "fs.stat",
    "fs.read",
    "fs.readlink",
    "fs.list",
    "fs.write",
    "git.seed.status",
    "blob.fetch.status",
];

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

/// The connection to the machine dropped (it closed, or a read or write
/// failed other than by timing out): a request that reads, or writes what it
/// wrote before, is sent again on a new one ([`Remote::reconnect`]).
#[derive(Debug)]
struct Dropped(String);

impl std::fmt::Display for Dropped {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Dropped {}

/// Whether `cmd` with `params` may be sent again after its connection dropped: one of
/// [`REPLAYABLE`], and a listing's first page only (a later page names a listing of the
/// connection that dropped).
///
/// A write is sent again only as a whole file's one overwrite: an append, or the first part of
/// a file written in parts, is not (its first copy may still land after the replay and the
/// appends that follow it, cutting the part file short).
fn replayable(cmd: &str, params: &Value) -> bool {
    match cmd {
        "fs.list" => params.get("cursor").is_none(),
        "fs.write" => {
            params.get("mode").and_then(Value::as_str) == Some("overwrite")
                && !params
                    .get("path")
                    .and_then(Value::as_str)
                    .is_some_and(|path| path.ends_with(PART_SUFFIX))
        }
        _ => REPLAYABLE.contains(&cmd),
    }
}

/// The name a file written in parts has until its rename ([`Remote::write_with_progress`]).
const PART_SUFFIX: &str = ".cmux-sync-part";

/// How a connection waits on a late answer and a dropped connection. Tests compress it.
#[derive(Clone, Copy, Debug)]
struct Patience {
    ceiling: Duration,
    stale: Duration,
    probe: Duration,
    reconnect: Duration,
    replays: usize,
}

const PATIENCE: Patience = Patience {
    ceiling: ANSWER_CEILING,
    stale: STALE_CONNECTION,
    probe: PROBE_DEADLINE,
    reconnect: RECONNECT_WINDOW,
    replays: MAX_REPLAYS,
};

/// One connection to the machine daemon.
pub(super) struct Remote {
    reader: BufReader<UnixStream>,
    /// The socket it was dialed on: a late answer asks the machine there whether it still
    /// answers, and a dropped connection is dialed again there. None (a test's socket pair):
    /// neither, as before.
    socket: Option<PathBuf>,
    patience: Patience,
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
        let stream = dial(socket, Some(IO_DEADLINE), Some(IO_DEADLINE))?;
        let mut remote = Self::on(stream);
        remote.socket = Some(socket.to_path_buf());
        Ok(remote)
    }

    /// A connection over `stream`, with no socket to ask or dial again.
    fn on(stream: UnixStream) -> Self {
        Self {
            reader: BufReader::new(stream),
            socket: None,
            patience: PATIENCE,
            next_id: 1,
            deflate: false,
            no_follow: false,
        }
    }

    /// Dials the socket again after the connection dropped, until it connects or the patience's
    /// reconnect window passes (a machine link that redials). The new connection keeps the
    /// socket timeouts and what the machine said it takes.
    fn reconnect(&mut self, progress: &mut dyn FnMut()) -> anyhow::Result<()> {
        let Some(socket) = self.socket.clone() else {
            bail!("the machine daemon closed the connection")
        };
        let (read, write) = (self.read_timeout(), self.write_timeout());
        let started = Instant::now();
        let mut pause = Duration::from_millis(100);
        loop {
            match dial(&socket, read, write) {
                Ok(stream) => {
                    self.reader = BufReader::new(stream);
                    return Ok(());
                }
                Err(error) if started.elapsed() >= self.patience.reconnect => {
                    return Err(error.context(format!(
                        "the connection to the machine dropped and did not come back within {} s",
                        self.patience.reconnect.as_secs()
                    )));
                }
                Err(_) => {}
            }
            progress();
            std::thread::sleep(pause.min(self.patience.reconnect));
            pause = (pause * 2).min(Duration::from_secs(5));
        }
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
    ///
    /// Past that budget the machine is asked whether it still answers
    /// ([`alive`]); while it does the answer is waited for, up to the
    /// patience's ceiling. A dropped connection is dialed again and the
    /// request sent again on it when it is [`replayable`]. Only a machine
    /// that stopped answering, or the ceiling, fails the call.
    fn call_with_progress(
        &mut self,
        cmd: &str,
        mut params: Value,
        progress: &mut dyn FnMut(),
    ) -> anyhow::Result<Value> {
        let started = Instant::now();
        let mut replays = 0;
        loop {
            // Each send, a replay too, passes the held copy's fence again: a replay may go out
            // minutes later, past the hold's lease.
            super::fence::check(cmd)?;
            if let Some(job) = super::fence::hold_for(cmd) {
                params.set("hold", json!(job));
            }
            match self.exchange(cmd, params.clone(), started, progress) {
                Err(error)
                    if error.is::<Dropped>()
                        && self.socket.is_some()
                        && replays < self.patience.replays
                        && replayable(cmd, &params) =>
                {
                    replays += 1;
                    self.reconnect(progress).map_err(|again| again.context(error.to_string()))?;
                }
                other => return other,
            }
        }
    }

    /// One send of the request and the wait for its answer ([`Remote::call_with_progress`]).
    fn exchange(
        &mut self,
        cmd: &str,
        mut params: Value,
        started: Instant,
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
                if timed_out(&error) {
                    stalled(error, "the machine took no bytes of the request", self.write_timeout())
                } else {
                    Dropped(format!("the connection to the machine dropped: {error}")).into()
                }
            })?;
            progress();
        }
        let silence = self.read_timeout();
        // Read here: the answer's reads below hold the connection.
        let (socket, patience) = (self.socket.clone(), self.patience);
        let alive = || socket.as_deref().is_some_and(|socket| alive(socket, patience.probe));
        let budget = answer_budget(silence, line.len());
        let mut answer_by = Instant::now().checked_add(budget);
        let stale_by = Instant::now().checked_add(budget.saturating_add(self.patience.stale));
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
                    // Late, but the machine still answers beside it: wait one more silence, and
                    // past `stale` call this connection dropped (sent again when replayable).
                    Err(error)
                        if timed_out(&error) && started.elapsed() < patience.ceiling && alive() =>
                    {
                        if stale_by.is_some_and(|by| Instant::now() >= by) {
                            return Err(Dropped(format!(
                                "the machine answers, but this connection was silent for {} s",
                                started.elapsed().as_secs()
                            ))
                            .into());
                        }
                        progress();
                        answer_by = Instant::now().checked_add(silence.unwrap_or(IO_DEADLINE));
                    }
                    Err(error) if timed_out(&error) => {
                        let waited = started.elapsed().as_secs();
                        let what = if socket.is_none() {
                            format!("the machine did not answer within {} s", budget.as_secs())
                        } else if started.elapsed() >= patience.ceiling {
                            format!(
                                "the machine did not answer within {waited} s, though it still answers"
                            )
                        } else {
                            format!(
                                "the machine stopped answering: no answer in {waited} s, and none to a ping"
                            )
                        };
                        return Err(stalled(error, &what, None));
                    }
                    Err(error) => {
                        return Err(Dropped(format!(
                            "the connection to the machine dropped: {error}"
                        ))
                        .into());
                    }
                }
            };
            if read == 0 {
                return Err(Dropped("the machine daemon closed the connection".into()).into());
            }
            if answer.last() != Some(&b'\n') {
                if u64::try_from(read).unwrap_or(u64::MAX) > MAX_ANSWER_BYTES {
                    bail!("the machine daemon's answer is too long");
                }
                return Err(Dropped("the machine daemon closed the connection".into()).into());
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
        let part = format!("{}/.{name}{PART_SUFFIX}", parent.trim_end_matches('/'));
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

/// Whether the machine at `socket` still answers: a `ping` on a connection of its own, answered
/// within `probe`. A machine busy with another connection's request answers it beside.
fn alive(socket: &Path, probe: Duration) -> bool {
    let Ok(mut stream) = dial(socket, Some(probe), Some(probe)) else { return false };
    if stream.write_all(b"{\"id\":1,\"cmd\":\"ping\"}\n").is_err() {
        return false;
    }
    let mut answer = Vec::new();
    let read =
        Read::take(&mut BufReader::new(&mut stream), 64 * 1024).read_until(b'\n', &mut answer);
    read.is_ok_and(|read| read > 0)
        && serde_json::from_slice::<Value>(&answer).is_ok_and(|answer| answer.is_object())
}

/// A connection to `socket` with these read and write timeouts.
fn dial(
    socket: &Path,
    read: Option<Duration>,
    write: Option<Duration>,
) -> anyhow::Result<UnixStream> {
    let stream = UnixStream::connect(socket)
        .with_context(|| format!("cannot connect to {}", socket.display()))?;
    stream.set_read_timeout(read)?;
    // A machine that stops reading must not hold a write (and a
    // caller's lock) forever either.
    stream.set_write_timeout(write)?;
    Ok(stream)
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
#[path = "remote_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "limits_tests.rs"]
mod limits_tests;
