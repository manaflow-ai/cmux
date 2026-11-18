//! `cmux link project`: a folder of this Mac projected onto a Cloud machine instead of copied (RFD
//! 0007, "projected folders"; Leo, 2026-11-17: "Big folders: projection is the chosen design;
//! build it next").
//!
//! The folder is listed by the copy's own rules ([`super::local::listed`]: in git the tracked and
//! unignored files plus the allowed parts of `.git`, never secrets, heavy folders or links that
//! leave it) and sent as a stat-only manifest: nothing is read or hashed. The machine mounts it at
//! the chat's folder (`projection-v1`, `cmux_tui_core::projection`), so the agent's first turn
//! starts as soon as the manifest is there, and every file of the folder is in it, not a first
//! pass. A file's bytes come from this Mac when something on the machine first reads it: this
//! process stays behind as the folder's server, answering over the dial it opened, and dials
//! again when the link drops (the machine never dials this Mac).
//!
//! On by default for every chat started from a local folder, whatever its size and whether or
//! not it is a git repository: a chat started from a GitHub repository the person picked is
//! cloned on the machine instead, by its own path, never this one. `cmux link project disable` (or
//! `CMUX_PROJECTED_FOLDERS=0`) turns it off, and `enable` turns it back on. What the agent writes stays on the machine for now; bringing it back is the
//! next slice.
//!
//!     cmux link project serve --socket S --at REMOTE [--name N] FOLDER
//!     cmux link project enable | disable | status

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::{FileExt as _, MetadataExt as _};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context as _, bail};
use cmux_projection::link::{Source, answer_asks};
use cmux_projection::manifest::{Item, Kind, Manifest};
use cmux_projection::wire::{self, Part};
use serde_json::{Value, json};

use super::local::Source as Origin;
use super::local::{self, LocalFile, Rules};

/// How long a start waits for the machine to mount the folder.
const START_WAIT: Duration = Duration::from_secs(120);
/// How long the server keeps dialing a machine it cannot reach before it stops.
const GIVE_UP_AFTER: Duration = Duration::from_secs(6 * 60 * 60);
/// The env switch that overrides the setting (`1`/`true` on, `0`/`false` off).
const ENV: &str = "CMUX_PROJECTED_FOLDERS";

/// A start's outcome when the folder is not projected: it goes as a copy, as before.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum NotProjected {
    /// Projection is off.
    Off,
    /// The folder is within the copy's limits: a copy is the right answer for it.
    Small,
    /// The machine does not serve `projection-v1`.
    Unserved,
}

/// The listed folder: its manifest and, by manifest entry, what each file is read from.
struct Listed {
    manifest: Manifest,
    served: Vec<Option<Served>>,
}

fn ok(answer: &Value) -> bool {
    answer.get("ok").and_then(Value::as_bool) == Some(true)
}

fn code(answer: &Value) -> Option<&str> {
    answer.get("error_code").and_then(Value::as_str)
}

/// One file of the manifest as this Mac reads it.
struct Served {
    file: LocalFile,
    size: u64,
    mtime_ns: i64,
}

/// `cmux link project ...`: one JSON line on stdout, exit 0 on success.
pub(crate) fn run(args: &[String]) -> i32 {
    let outcome = match args.first().map(String::as_str) {
        Some("serve") => serve_command(args.get(1..).unwrap_or_default()),
        Some("enable") => set_enabled(true).map(|()| json!({"ok": true, "enabled": true})),
        Some("disable") => set_enabled(false).map(|()| json!({"ok": true, "enabled": false})),
        Some("status") => Ok(json!({"ok": true, "enabled": enabled()})),
        Some("stop") => stop(args.get(1..).unwrap_or_default()),
        _ => Err(anyhow::anyhow!(
            "usage: cmux link project serve --socket S --at REMOTE [--name N] FOLDER | stop --at \
             REMOTE | enable | disable | status"
        )),
    };
    match outcome {
        Ok(Value::Null) => 0,
        Ok(answer) => {
            println!("{answer}");
            0
        }
        Err(error) => {
            println!(
                "{}",
                json!({"ok": false, "error": format!("{error:#}"), "error_code": "project_failed"})
            );
            1
        }
    }
}

/// Whether chats from big folders are projected: on unless [`ENV`] or `cmux link project disable`
/// turned it off.
pub(crate) fn enabled() -> bool {
    match std::env::var(ENV).ok().as_deref() {
        Some("1" | "true") => return true,
        Some("0" | "false") => return false,
        _ => {}
    }
    !off_path().is_some_and(|path| path.exists())
}

/// The opt-out marker: present only after `cmux link project disable`.
fn off_path() -> Option<PathBuf> {
    Some(
        cmux_tui_core::platform::workspace_state_dir()?
            .join("link-sync")
            .join("projected-folders-off"),
    )
}

fn set_enabled(on: bool) -> anyhow::Result<()> {
    let path = off_path().context("this Mac has no state folder")?;
    if on {
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
    } else {
        std::fs::create_dir_all(path.parent().context("no state folder")?)?;
        std::fs::write(&path, b"off\n")?;
    }
    Ok(())
}

/// The projection name for the chat whose start key is `key` (the page's UUID). There is one per
/// chat, so two chats on the same folder never share an upper layer. A later step (Bring Back)
/// finds that chat's edits under this name, in `projections/<name>/upper` and `whiteouts` in the
/// machine daemon's state folder, which an unmount never deletes.
#[must_use]
pub(crate) fn chat_name(key: &str) -> String {
    format!("chat-{key}")
}

/// What this Mac names the server it runs for the mount point `remote` (its log and pid files),
/// and the projection's name when it was started without a chat (`serve` by hand).
fn name_of(remote: &str) -> String {
    let hash = remote.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("p{hash:016x}")
}

/// Projects `local` at `remote` on the machine at `socket` when projection is on, the folder is
/// attached from this Mac (always, when on) and the machine serves it: starts this Mac's server for it (a process of
/// its own, which outlives this one) and answers once the machine has mounted it. Otherwise why
/// not, and the caller copies as before.
pub(crate) fn start(
    socket: &Path,
    local: &Path,
    remote: &str,
    chat: &str,
) -> anyhow::Result<Result<Value, NotProjected>> {
    if !enabled() {
        return Ok(Err(NotProjected::Off));
    }
    if !machine_serves(socket) {
        return Ok(Err(NotProjected::Unserved));
    }
    let exe = std::env::current_exe().context("cannot find this cmux binary")?;
    let log = cmux_tui_core::platform::workspace_state_dir()
        .map(|dir| dir.join("link-sync").join("projections"))
        .context("this Mac has no state folder")?;
    std::fs::create_dir_all(&log)?;
    // The server's files go by its mount point (`stop --at`), the projection by its chat.
    let server = name_of(remote);
    let name = chat_name(chat);
    let stderr = std::fs::File::create(log.join(format!("{server}.log")))?;
    let mut command = cmux_process::Command::new(exe);
    command
        .args(["link", "project", "serve", "--socket"])
        .arg(socket)
        .args(["--at", remote, "--name", &name])
        .arg(local)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(stderr)
        // Its own process group: the server outlives this command and the app's run of it.
        .process_group(0);
    let mut child = command.spawn().context("cannot start the folder's server")?;
    let stdout = child.stdout.take().context("no pipe from the folder's server")?;
    // The server answers one line once the machine mounted the folder or refused it; its own dial
    // waits are bounded (START_WAIT), and an exit closes the pipe.
    let mut line = String::new();
    BufReader::new(stdout).read_line(&mut line).context("reading the folder's server")?;
    let answer: Value = serde_json::from_str(line.trim())
        .with_context(|| format!("the folder's server answered {line:?}"))?;
    if ok(&answer) {
        // It runs on as the folder's server; `cmux link project stop --at REMOTE` ends it.
        let _ = std::fs::write(log.join(format!("{server}.pid")), child.id().to_string());
        child.detach("the folder's server outlives the start that made it");
        drop(child);
        let mut answer = answer;
        if let Some(data) = answer.get_mut("data").and_then(Value::as_object_mut) {
            data.insert("name".into(), Value::from(name));
        }
        return Ok(Ok(answer));
    }
    let _ = child.wait();
    match code(&answer) {
        Some("projection.small") => return Ok(Err(NotProjected::Small)),
        Some("projection.unavailable") => return Ok(Err(NotProjected::Unserved)),
        _ => {}
    }
    bail!(
        "{}",
        answer.get("error").and_then(Value::as_str).unwrap_or("the machine refused the projection")
    )
}

/// `stop --at REMOTE`: ends the server [`start`] left running for the projection at `REMOTE`.
fn stop(args: &[String]) -> anyhow::Result<Value> {
    let at = match args {
        [flag, at] if flag == "--at" => at,
        _ => bail!("usage: cmux link project stop --at REMOTE"),
    };
    let name = name_of(at);
    let pid_file = cmux_tui_core::platform::workspace_state_dir()
        .map(|dir| dir.join("link-sync").join("projections").join(format!("{name}.pid")))
        .context("this Mac has no state folder")?;
    let Ok(pid) = std::fs::read_to_string(&pid_file) else {
        return Ok(json!({"ok": true, "stopped": false}));
    };
    let pid = pid.trim().parse::<u32>().context("a bad pid file")?;
    let stopped = cmux_process::Command::new("kill")
        .arg(pid.to_string())
        .status()
        .is_ok_and(|status| status.success());
    let _ = std::fs::remove_file(&pid_file);
    Ok(json!({"ok": true, "stopped": stopped}))
}

/// Whether the machine's `identify` lists `projection-v1`.
fn machine_serves(socket: &Path) -> bool {
    super::machine_call(socket, "identify", json!({})).is_ok_and(|identity| {
        identity.get("capabilities").and_then(Value::as_array).is_some_and(|served| {
            served.iter().any(|name| name == cmux_tui_core::projection::PROJECTION_CAPABILITY)
        })
    })
}

/// `serve`: lists the folder, dials the machine, sends the manifest and prints the machine's
/// answer as one line; then answers the machine's reads until the dial ends, and dials again.
fn serve_command(args: &[String]) -> anyhow::Result<Value> {
    let (mut socket, mut at, mut name, mut folder, mut any_size) = (None, None, None, None, false);
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--socket" => socket = words.next().map(PathBuf::from),
            "--at" => at = words.next().cloned(),
            "--name" => name = words.next().cloned(),
            // Projects a folder within the copy's limits too (tests and the bench).
            "--any-size" => any_size = true,
            other if other.starts_with("--") => bail!("unknown flag {other}"),
            other => folder = Some(PathBuf::from(other)),
        }
    }
    let socket = socket.context("--socket is required")?;
    let at = at.context("--at is required")?;
    let folder = folder.context("the folder is required")?;
    let name = name.unwrap_or_else(|| name_of(&at));
    let folder = std::fs::canonicalize(&folder)
        .with_context(|| format!("cannot open {}", folder.display()))?;
    let started = Instant::now();
    let listed = list(&folder)?;
    let listed_ms = elapsed_ms(started);
    // Every attached folder is projected, a small one too (`--any-size` stays for old callers).
    let _ = any_size;
    let encoded = listed.manifest.encode()?;
    let (stream, mut answer) = dial(&socket, &name, &at, &encoded)?;
    if !ok(&answer) {
        return Ok(answer);
    }
    if let Some(data) = answer.get_mut("data").and_then(Value::as_object_mut) {
        data.insert("listed_ms".into(), json!(listed_ms));
        data.insert("manifest_bytes".into(), json!(encoded.len()));
        data.insert("ready_ms".into(), json!(elapsed_ms(started)));
    }
    let mut stdout = std::io::stdout();
    let _ = writeln!(stdout, "{answer}");
    let _ = stdout.flush();
    serve_until_gone(&socket, &name, &at, &encoded, &listed, stream);
    Ok(Value::Null)
}

fn elapsed_ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Answers the machine over `stream` until it ends, then dials again (attaching to the mount the
/// machine still has, or mounting the manifest again after the machine's daemon restarted), until
/// the machine has been unreachable for [`GIVE_UP_AFTER`].
fn serve_until_gone(
    socket: &Path,
    name: &str,
    at: &str,
    encoded: &[u8],
    listed: &Listed,
    first: BufReader<UnixStream>,
) {
    let mut stream = Some(first);
    let mut unreachable_since: Option<Instant> = None;
    let mut backoff = Duration::from_millis(200);
    loop {
        if let Some(reader) = stream.take() {
            unreachable_since = None;
            backoff = Duration::from_millis(200);
            if let Ok(writer) = reader.get_ref().try_clone() {
                // Lines both ways: the Cloud carrier moves whole lines only (`dial`).
                let _ = answer_asks(
                    cmux_tui_core::projection::LineReader::new(reader),
                    cmux_tui_core::projection::LineWriter::new(writer),
                    listed,
                );
            }
        }
        let since = *unreachable_since.get_or_insert_with(Instant::now);
        if since.elapsed() > GIVE_UP_AFTER {
            eprintln!(
                "cmux link project: {at} unreachable for {} s; stopping",
                GIVE_UP_AFTER.as_secs()
            );
            return;
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(Duration::from_secs(10));
        match dial(socket, name, at, &[]) {
            Ok((reader, answer)) if ok(&answer) => stream = Some(reader),
            Ok((_, answer)) if code(&answer) == Some("projection.unknown") => {
                match dial(socket, name, at, encoded) {
                    Ok((reader, answer)) if ok(&answer) => stream = Some(reader),
                    Ok((_, answer)) => {
                        eprintln!(
                            "cmux link project: the machine refused the folder again: {answer}"
                        );
                        return;
                    }
                    Err(error) => eprintln!("cmux link project: {error:#}"),
                }
            }
            Ok((_, answer)) => {
                eprintln!("cmux link project: the machine refused: {answer}");
                return;
            }
            Err(error) => eprintln!("cmux link project: {error:#}"),
        }
    }
}

/// Dials the machine and asks it to serve projection `name` at `at` (`encoded`: the manifest, or
/// nothing to attach again). The stream, buffered, and the machine's answer.
fn dial(
    socket: &Path,
    name: &str,
    at: &str,
    encoded: &[u8],
) -> anyhow::Result<(BufReader<UnixStream>, Value)> {
    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("cannot reach the machine at {}", socket.display()))?;
    let line = json!({
        "id": 1,
        "cmd": cmux_tui_core::projection::SERVE,
        "name": name,
        "at": at,
        "manifest_bytes": encoded.len(),
        // Every byte after this line goes as text lines, both ways: the Cloud carrier carries
        // the dial as a `mux-control` stream, which moves whole lines only.
        "lines": true,
    });
    let mut bytes = serde_json::to_vec(&line)?;
    bytes.push(b'\n');
    stream.write_all(&bytes)?;
    cmux_tui_core::projection::LineWriter::new(&stream).write_all(encoded)?;
    stream.flush()?;
    stream.set_read_timeout(Some(START_WAIT))?;
    let mut reader = BufReader::with_capacity(256 * 1024, stream);
    let mut answer = String::new();
    reader.read_line(&mut answer)?;
    reader.get_ref().set_read_timeout(None)?;
    let answer: Value = serde_json::from_str(answer.trim())
        .with_context(|| format!("the machine answered {answer:?}"))?;
    Ok((reader, answer))
}

/// The folder as the copy lists it ([`local::listed`], no cap), with every file's size and
/// modification time, as a manifest.
fn list(folder: &Path) -> anyhow::Result<Listed> {
    let (set, _) = local::listed(folder, Rules::Copy, None)?;
    let root_mtime = std::fs::metadata(folder).map(|meta| mtime_ns(&meta)).unwrap_or(0);
    let files: Vec<(String, LocalFile)> = set.files.into_iter().collect();
    let stats = stat_all(&files);
    let mut items = Vec::with_capacity(files.len() + set.links.len());
    let mut kept = Vec::with_capacity(files.len());
    for ((relative, file), stat) in files.into_iter().zip(stats) {
        // A file gone or changed into something else since the listing is left out.
        let Some((size, mtime)) = stat else { continue };
        items.push(Item {
            path: relative.clone(),
            kind: Kind::File,
            mode: file.permissions,
            size,
            mtime_ns: mtime,
            link: None,
        });
        kept.push((relative, Served { file, size, mtime_ns: mtime }));
    }
    for (relative, linked) in set.links {
        let mtime = std::fs::symlink_metadata(folder.join(&relative))
            .map(|meta| mtime_ns(&meta))
            .unwrap_or(0);
        items.push(Item {
            path: relative,
            kind: Kind::Link,
            mode: 0o777,
            size: 0,
            mtime_ns: mtime,
            link: Some(linked.target),
        });
    }
    let manifest = Manifest::build(root_mtime, items)?;
    let mut served: Vec<Option<Served>> = Vec::new();
    served.resize_with(manifest.len(), || None);
    for (relative, file) in kept {
        if let Some(slot) =
            manifest.resolve(&relative).and_then(|index| served.get_mut(index as usize))
        {
            *slot = Some(file);
        }
    }
    Ok(Listed { manifest, served })
}

fn mtime_ns(meta: &std::fs::Metadata) -> i64 {
    meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec())
}

/// Every file's size and modification time, read on a few threads (a stat each, no bytes).
fn stat_all(files: &[(String, LocalFile)]) -> Vec<Option<(u64, i64)>> {
    let threads = std::thread::available_parallelism().map_or(4, std::num::NonZero::get).min(16);
    let per = files.len().div_ceil(threads).max(1);
    std::thread::scope(|scope| {
        let parts: Vec<_> = files
            .chunks(per)
            .map(|part| {
                scope.spawn(move || part.iter().map(|(_, file)| stat(file)).collect::<Vec<_>>())
            })
            .collect();
        parts.into_iter().flat_map(|part| part.join().unwrap_or_default()).collect()
    })
}

fn stat(file: &LocalFile) -> Option<(u64, i64)> {
    match &file.source {
        Origin::File(path) => {
            let meta = std::fs::symlink_metadata(path).ok().filter(std::fs::Metadata::is_file)?;
            Some((meta.len(), mtime_ns(&meta)))
        }
        Origin::Checked(_) => {
            let meta = open(file).ok()?.metadata().ok()?;
            Some((meta.len(), mtime_ns(&meta)))
        }
        Origin::Bytes(bytes) => Some((bytes.len() as u64, 0)),
    }
}

/// Opens `file` the way the copy does: no symlink followed, and only the file that was listed.
fn open(file: &LocalFile) -> anyhow::Result<std::fs::File> {
    match &file.source {
        Origin::File(path) => local::open_listed(path, file.id),
        Origin::Checked(checked) => {
            let (opened, identity, root) =
                super::place::open_beneath(&checked.root, &checked.relative)?;
            if identity != checked.identity || root != checked.root_identity {
                bail!("{} changed after it was checked", checked.relative);
            }
            Ok(opened)
        }
        Origin::Bytes(_) => bail!("made here, not a file"),
    }
}

impl Source for Listed {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        let Some(Some(served)) = self.served.get(entry as usize) else {
            return Part::status(wire::REFUSED);
        };
        if let Origin::Bytes(bytes) = &served.file.source {
            let start = usize::try_from(offset).unwrap_or(usize::MAX).min(bytes.len());
            let end = start.saturating_add(len as usize).min(bytes.len());
            return Part::ok(bytes.get(start..end).unwrap_or_default().to_vec());
        }
        let Ok(opened) = open(&served.file) else { return Part::status(wire::FAILED) };
        // The file the manifest named, unchanged: else the machine is told it changed.
        let Ok(meta) = opened.metadata() else { return Part::status(wire::FAILED) };
        if meta.len() != served.size || mtime_ns(&meta) != served.mtime_ns {
            return Part::status(wire::CHANGED);
        }
        let want = u64::from(len).min(served.size.saturating_sub(offset));
        let mut bytes = vec![0u8; usize::try_from(want).unwrap_or(0)];
        let mut got = 0usize;
        while let Some(rest) = bytes.get_mut(got..).filter(|rest| !rest.is_empty()) {
            match opened.read_at(rest, offset.saturating_add(got as u64)) {
                Ok(0) => break,
                Ok(read) => got += read,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => return Part::status(wire::FAILED),
            }
        }
        bytes.truncate(got);
        Part::ok(bytes)
    }

    fn whole(&self, entry: u32) -> Part {
        let size = self
            .served
            .get(entry as usize)
            .and_then(Option::as_ref)
            .map_or(0, |served| served.size);
        match u32::try_from(size) {
            Ok(len) if len <= wire::MAX_READ => self.read(entry, 0, len),
            _ => Part::status(wire::FAILED),
        }
    }
}

#[cfg(test)]
#[path = "project_tests.rs"]
mod tests;
