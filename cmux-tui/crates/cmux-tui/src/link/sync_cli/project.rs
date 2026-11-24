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
//! again when the link drops (the machine never dials this Mac). Against a Cloud machine it redials
//! on `carrier serve`'s quiet socket (`<socket>.quiet`), which closes the dial instead of waking a
//! machine that is asleep, so a dropped link never keeps a paused machine running.
//!
//! On by default for every chat started from a local folder, whatever its size and whether or
//! not it is a git repository: a chat started from a GitHub repository the person picked is
//! cloned on the machine instead, by its own path, never this one. `cmux link project disable` (or
//! `CMUX_PROJECTED_FOLDERS=0`) turns it off, and `enable` turns it back on.
//!
//! What the agent writes lands in the mount's upper layer on the machine and stays there until
//! Bring Back applies it here. `cmux link sync pull` takes it home like a copy's edits: the server
//! keeps a base for it here as it projects ([`keep_base`], kept across a redial), each file named by its size and mtime
//! ([`stand_in`]), so a pull reads and hashes only what the machine changed, and a file this Mac
//! changed since is a conflict. `project back` plans the same from the upper layer and its
//! whiteouts ([`super::project_back`]).
//!
//!     cmux link project serve --socket S --at REMOTE [--name N] FOLDER
//!     cmux link project back --socket S --at REMOTE FOLDER
//!     cmux link project release --socket S --at REMOTE FOLDER [--why archived|deleted]
//!     cmux link project enable | disable | status

use std::collections::BTreeMap;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::{FileExt as _, FileTypeExt as _, MetadataExt as _};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
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
/// How long a restart waits for the older server to exit.
const STOP_WAIT: Duration = Duration::from_secs(5);
/// How long the server keeps dialing a machine it cannot reach before it stops.
const GIVE_UP_AFTER: Duration = Duration::from_secs(6 * 60 * 60);
/// How often the server redials over a quiet socket: a refused quiet dial costs no platform call.
const QUIET_RETRY: Duration = Duration::from_millis(500);
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
    /// The symlinks kept as symlinks, as a push records them.
    links: BTreeMap<String, super::Linked>,
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

const USAGE: &str = "usage: cmux link project serve --socket S --at REMOTE [--name N] FOLDER | stop --at \
                     REMOTE | back --socket S --at REMOTE FOLDER | release --socket S --at REMOTE FOLDER [--why \
                     archived|deleted] | enable | disable | status | moves on|off";

/// `cmux link project ...`: one JSON line on stdout, exit 0 on success.
pub(crate) fn run(args: &[String]) -> i32 {
    // Asked-for help is a success on stdout; before, it was a `project_failed` error, exit 1.
    if matches!(args.first().map(String::as_str), Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return 0;
    }
    let outcome = match args.first().map(String::as_str) {
        Some("serve") => serve_command(args.get(1..).unwrap_or_default()),
        Some("enable") => set_enabled(true).map(|()| json!({"ok": true, "enabled": true})),
        Some("disable") => set_enabled(false).map(|()| json!({"ok": true, "enabled": false})),
        Some("status") => Ok(json!({"ok": true, "enabled": enabled(), "moves": moves_enabled()})),
        Some("moves") => match args.get(1).map(String::as_str) {
            Some("on") => set_moves(true).map(|()| json!({"ok": true, "moves": true})),
            Some("off") => set_moves(false).map(|()| json!({"ok": true, "moves": false})),
            _ => Err(anyhow::anyhow!("usage: cmux link project moves on|off")),
        },
        Some("stop") => stop(args.get(1..).unwrap_or_default()),
        Some("back") => super::project_back::back_command(args.get(1..).unwrap_or_default()),
        Some("release") => super::project_back::release_command(args.get(1..).unwrap_or_default()),
        _ => Err(anyhow::anyhow!(USAGE)),
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

/// The env switch for a moved chat's folder (`1`/`true` on, `0`/`false` off), over the setting.
const MOVES_ENV: &str = "CMUX_PROJECTED_MOVES";

/// Whether Move to Cloud projects the chat's folder (`cmux link seed push`, seed_cli.rs): off
/// unless [`MOVES_ENV`] or `cmux link project moves on` turned it on, and never while projection
/// itself is off. Off by default until Bring Back Local brings a projection's edits home: a
/// projected folder has no seed or copy record for Bring Back to merge against.
pub(crate) fn moves_enabled() -> bool {
    if !enabled() {
        return false;
    }
    match std::env::var(MOVES_ENV).ok().as_deref() {
        Some("1" | "true") => return true,
        Some("0" | "false") => return false,
        _ => {}
    }
    moves_on_path().is_some_and(|path| path.exists())
}

/// The opt-in marker for moves: present only after `cmux link project moves on`.
fn moves_on_path() -> Option<PathBuf> {
    Some(
        cmux_tui_core::platform::workspace_state_dir()?
            .join("link-sync")
            .join("projected-moves-on"),
    )
}

fn set_moves(on: bool) -> anyhow::Result<()> {
    let path = moves_on_path().context("this Mac has no state folder")?;
    if on {
        std::fs::create_dir_all(path.parent().context("no state folder")?)?;
        std::fs::write(&path, b"on\n")?;
    } else if path.exists() {
        std::fs::remove_file(&path)?;
    }
    Ok(())
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
    let Some(identity) = serving_identity(socket) else {
        return Ok(Err(NotProjected::Unserved));
    };
    let machine = identity.get("session_id").and_then(Value::as_str).unwrap_or_default();
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
    // The store this Mac signs in to goes to the server on its stdin (never its arguments), so
    // it can keep the folder's listing there and fetch it by hash on a resume.
    let handoff = super::store::handoff();
    command
        .args(["link", "project", "serve", "--socket"])
        .arg(socket)
        .args(["--at", remote, "--name", &name]);
    if handoff.is_some() {
        command.arg("--store-stdin");
    }
    command
        .arg(local)
        .stdin(if handoff.is_some() {
            cmux_process::Stdio::piped()
        } else {
            cmux_process::Stdio::null()
        })
        .stdout(cmux_process::Stdio::piped())
        .stderr(stderr)
        // Its own process group: the server outlives this command and the app's run of it.
        .process_group(0);
    let mut child = command.spawn().context("cannot start the folder's server")?;
    if let (Some(handoff), Some(mut stdin)) = (handoff, child.stdin.take()) {
        let _ = stdin.write_all(handoff.as_bytes());
    }
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
        // What it serves and to which machine: a moved chat's frozen push projects it again
        // ([`projected_at`], [`restart`]).
        let served = ServerRecord {
            machine: machine.to_owned(),
            chat: chat.to_owned(),
            local: local.to_path_buf(),
        };
        let _ = std::fs::write(log.join(format!("{server}.served")), served.encode());
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
    let stopped = stop_server(at)?;
    Ok(json!({"ok": true, "stopped": stopped}))
}

/// This Mac's folder for its projection servers' pid and record files.
fn servers_dir() -> anyhow::Result<PathBuf> {
    cmux_tui_core::platform::workspace_state_dir()
        .map(|dir| dir.join("link-sync").join("projections"))
        .context("this Mac has no state folder")
}

/// Ends the server [`start`] left running for the projection at `remote`, and forgets what it
/// served. Whether there was one to end.
pub(crate) fn stop_server(remote: &str) -> anyhow::Result<bool> {
    let dir = servers_dir()?;
    let server = name_of(remote);
    let pid_file = dir.join(format!("{server}.pid"));
    let _ = std::fs::remove_file(dir.join(format!("{server}.served")));
    let Ok(pid) = std::fs::read_to_string(&pid_file) else {
        return Ok(false);
    };
    let pid = pid.trim().parse::<u32>().context("a bad pid file")?;
    if !still_serving(remote) {
        // A server that ended (it gives up, or the Mac restarted) leaves its pid file; that pid
        // may be another process's now.
        let _ = std::fs::remove_file(&pid_file);
        return Ok(false);
    }
    let stopped = cmux_process::Command::new("kill")
        .arg(pid.to_string())
        .status()
        .is_ok_and(|status| status.success());
    let _ = std::fs::remove_file(&pid_file);
    if stopped {
        // Gone before the next server dials: a server that lived on would dial the machine again
        // with its older manifest and mount that one back over the new one.
        let deadline = Instant::now() + STOP_WAIT;
        while Instant::now() < deadline && alive(pid) {
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    Ok(stopped)
}

/// The lock file a server for `remote` holds for as long as it runs ([`hold_lock`]).
fn lock_path(remote: &str) -> anyhow::Result<PathBuf> {
    Ok(servers_dir()?.join(format!("{}.lock", name_of(remote))))
}

/// Held by the server for `remote` until it exits, however it exits: its pid file outlives it (it
/// gives up, the Mac restarts), and that pid may be another process's by then. None when the lock
/// cannot be taken; the server runs on without it.
fn hold_lock(remote: &str) -> Option<std::fs::File> {
    let path = lock_path(remote).ok()?;
    std::fs::create_dir_all(path.parent()?).ok()?;
    let file =
        std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(path).ok()?;
    file.try_lock().ok()?;
    Some(file)
}

/// Whether the pid on record for `remote` is still its server: its lock is held. A server from an
/// older build left no lock file, and its pid is taken at its word, as before.
fn still_serving(remote: &str) -> bool {
    let Ok(path) = lock_path(remote) else {
        return true;
    };
    let Ok(file) = std::fs::OpenOptions::new().write(true).open(path) else {
        return true;
    };
    matches!(file.try_lock(), Err(std::fs::TryLockError::WouldBlock))
}

/// Whether process `pid` still runs (`kill -0`).
fn alive(pid: u32) -> bool {
    cmux_process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stderr(cmux_process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// What a projection server [`start`] left serves (its `.served` file beside its pid file): the
/// machine it projects to (`identify`'s `session_id`, empty when it answers none), the chat key its projection is named for
/// ([`chat_name`]) and this Mac's folder, NUL-separated, the folder last.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ServerRecord {
    pub(crate) machine: String,
    pub(crate) chat: String,
    pub(crate) local: PathBuf,
}

impl ServerRecord {
    fn encode(&self) -> Vec<u8> {
        use std::os::unix::ffi::OsStrExt as _;
        let mut bytes = self.machine.as_bytes().to_vec();
        bytes.push(0);
        bytes.extend_from_slice(self.chat.as_bytes());
        bytes.push(0);
        bytes.extend_from_slice(self.local.as_os_str().as_bytes());
        bytes
    }

    fn decode(bytes: &[u8]) -> Option<Self> {
        use std::os::unix::ffi::OsStrExt as _;
        let mut parts = bytes.splitn(3, |byte| *byte == 0);
        let (machine, chat, local) = (parts.next()?, parts.next()?, parts.next()?);
        if chat.is_empty() || local.is_empty() {
            return None;
        }
        Some(Self {
            machine: String::from_utf8(machine.to_vec()).ok()?,
            chat: String::from_utf8(chat.to_vec()).ok()?,
            local: PathBuf::from(std::ffi::OsStr::from_bytes(local)),
        })
    }
}

/// What the server [`start`] left for `remote` serves; None when none is on record. Read by the
/// folder and the machine's id, not the link socket: the app's link to the machine may have been
/// made again between a move's push and its push once the chat is frozen.
pub(crate) fn projected_at(remote: &str) -> Option<ServerRecord> {
    let dir = servers_dir().ok()?;
    let server = name_of(remote);
    if !dir.join(format!("{server}.pid")).exists() {
        return None;
    }
    ServerRecord::decode(&std::fs::read(dir.join(format!("{server}.served"))).ok()?)
}

/// A new projection name for a chat that moves to a machine (Move to Cloud's `cmux link seed
/// push`): one per move, so a later move of the folder there never mounts an earlier move's edits
/// over the Mac's newer files. The move's push once the chat is frozen (`--since-last`) reuses it
/// from the server's record ([`projected_at`]), its upper layer kept.
#[must_use]
pub(crate) fn move_key(remote: &str) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    // 64 bits of the time: the daemon's names are at most 64 letters, digits, - or _.
    format!("move-{}-{:x}", name_of(remote), u64::try_from(now).unwrap_or(u64::MAX))
}

/// [`start`] after ending the server already projecting `local` at `remote` to the same machine
/// (an earlier push of this move, or of an earlier move of the folder there; a server projecting it
/// to another machine runs on). The new server lists the
/// folder as it is now: the machine mounts that manifest in place of the older one, which it would
/// otherwise answer every read of a changed file from as `changed`, and never list a new one.
pub(crate) fn restart(
    socket: &Path,
    local: &Path,
    remote: &str,
    chat: &str,
) -> anyhow::Result<Result<Value, NotProjected>> {
    if enabled()
        && let Some(on) = projected_at(remote)
        && on.local == local
        && machine_id(socket).unwrap_or_default() == on.machine
    {
        stop_server(remote)?;
    }
    start(socket, local, remote, chat)
}

/// The machine's `identify` when it lists `projection-v1`.
fn serving_identity(socket: &Path) -> Option<Value> {
    super::machine_call(socket, "identify", json!({})).ok().filter(|identity| {
        identity.get("capabilities").and_then(Value::as_array).is_some_and(|served| {
            served.iter().any(|name| name == cmux_tui_core::projection::PROJECTION_CAPABILITY)
        })
    })
}

/// The machine's store id (`identify`'s `session_id`).
fn machine_id(socket: &Path) -> Option<String> {
    let identity = super::machine_call(socket, "identify", json!({})).ok()?;
    identity.get("session_id").and_then(Value::as_str).map(str::to_owned)
}

/// `serve`: lists the folder, dials the machine, sends the manifest and prints the machine's
/// answer as one line; then answers the machine's reads until the dial ends, and dials again.
fn serve_command(args: &[String]) -> anyhow::Result<Value> {
    let (mut socket, mut at, mut name, mut folder, mut any_size) = (None, None, None, None, false);
    let mut store_handed = false;
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--socket" => socket = words.next().map(PathBuf::from),
            "--at" => at = words.next().cloned(),
            "--name" => name = words.next().cloned(),
            // Projects a folder within the copy's limits too (tests and the bench).
            "--any-size" => any_size = true,
            // The store this server keeps the folder's listing in, on stdin ([`start`]).
            "--store-stdin" => store_handed = true,
            other if other.starts_with("--") => bail!("unknown flag {other}"),
            other => folder = Some(PathBuf::from(other)),
        }
    }
    if store_handed && let Err(error) = super::store::take_handoff(&mut std::io::stdin().lock()) {
        eprintln!("cmux link project: no store for the listing: {error:#}");
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
    let encoded_ms = elapsed_ms(started);
    // Bring Back's base, made here while the machine mounts the folder, unless one is kept.
    let kept_already = super::base::kept(&folder, &at);
    let (dialed, made) = std::thread::scope(|scope| {
        let made = (!kept_already).then(|| scope.spawn(|| base_of_listing(&folder, &listed)));
        (dial(&socket, &name, &at, &encoded, None), made.map(|made| made.join()))
    });
    let (stream, mut answer) = dialed?;
    if !ok(&answer) {
        return Ok(answer);
    }
    // The folder is mounted and the chat can start; without a base, Bring Back says so
    // (`sync_no_base`) rather than guess.
    let kept = match made {
        None => Ok(()),
        Some(Ok(made)) => made.and_then(|base| keep_base(&folder, &at, &base)),
        Some(Err(_)) => Err(anyhow::anyhow!("its thread panicked")),
    };
    if let Err(error) = kept {
        eprintln!("cmux link project: no base for Bring Back: {error:#}");
    }
    let timing = ready_timing(
        listed.manifest.len(),
        listed_ms,
        encoded_ms,
        encoded.len(),
        elapsed_ms(started),
        answer.pointer("/data/mount_ms").and_then(Value::as_u64),
    );
    // The start's gate, split, in the server's log (`start` makes it `projections/<server>.log`): the
    // start-chat answer does not reach `cloud start-chat --from-folder`'s caller, and the log does
    // (cmuxterm-hq goals/cloud-no-network-wait.md, "Ceiling": is the O(files) cost the listing or the send).
    eprintln!("cmux link project: ready {timing}");
    if let (Some(data), Value::Object(timing)) =
        (answer.get_mut("data").and_then(Value::as_object_mut), timing)
    {
        data.extend(timing);
    }
    // Taken before the answer, so the pid [`start`] writes on it is never one without the lock.
    let _lock = hold_lock(&at);
    // What Bring Back plans against (project_back.rs): the manifest this session starts from.
    if let Err(error) = super::project_back::record(&name, &at, &folder, &encoded) {
        eprintln!("cmux link project: cannot keep the manifest for Bring Back: {error:#}");
    }
    let mut stdout = std::io::stdout();
    let _ = writeln!(stdout, "{answer}");
    let _ = stdout.flush();
    // The listing goes to the store in the background: the chat is already running, and a resume
    // fetches it from there instead of sending it over this Mac's uplink.
    let published: Published = Arc::new(Mutex::new(None));
    let mut revisions = Revisions { published: Arc::clone(&published), resent: 0 };
    let pair = pair_of(&name);
    std::thread::scope(|scope| {
        if super::store::on() {
            scope.spawn(|| match super::store::publish(&listed.manifest, &pair) {
                Ok(done) => {
                    eprintln!(
                        "cmux link project: the listing is in the store: {} pieces, {} bytes sent",
                        done.pieces, done.sent
                    );
                    if let Ok(mut slot) = published.lock() {
                        *slot = Some(done.root);
                    }
                }
                Err(error) => {
                    eprintln!("cmux link project: the listing stays off the store: {error:#}");
                }
            });
        }
        serve_until_gone(&socket, &name, &at, &encoded, &listed, stream, &mut revisions);
    });
    Ok(Value::Null)
}

/// The revision of the listing this server published, once it has.
type Published = Arc<Mutex<Option<String>>>;

/// How a redial names the listing without sending it.
struct Revisions {
    published: Published,
    /// Redials that fell back to the whole manifest.
    resent: u32,
}

impl Revisions {
    /// The reference to send in place of the manifest, when the listing is in the store.
    fn reference(&self) -> Option<Value> {
        let root = self.published.lock().ok()?.clone()?;
        match super::store::reference(&root) {
            Ok(reference) => Some(reference),
            Err(error) => {
                eprintln!("cmux link project: no read grant for the listing: {error:#}");
                None
            }
        }
    }
}

/// The store pair that keeps projection `name`'s listing alive.
fn pair_of(name: &str) -> String {
    let clean: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '-' })
        .collect();
    format!("listing.{clean}").chars().take(128).collect()
}

/// What the start waited for, by step: the listing, the manifest's encoding and the machine's
/// answer (`ready_ms`, the whole gate), each from the server's start, and the machine's own
/// decode and mount (`mount_ms`, its answer's); `ready_ms - encoded_ms - mount_ms` is the send.
fn ready_timing(
    entries: usize,
    listed_ms: u64,
    encoded_ms: u64,
    manifest_bytes: usize,
    ready_ms: u64,
    mount_ms: Option<u64>,
) -> Value {
    json!({
        "entries": entries,
        "listed_ms": listed_ms,
        "encoded_ms": encoded_ms,
        "manifest_bytes": manifest_bytes,
        "ready_ms": ready_ms,
        "mount_ms": mount_ms,
    })
}

fn elapsed_ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Answers the machine over `stream` until it ends, then dials again (attaching to the mount the
/// machine still has, or mounting the manifest again after the machine's daemon restarted), until
/// the machine has been unreachable for [`GIVE_UP_AFTER`]. A redial goes to the quiet socket when
/// `socket` has one ([`redial`]), every [`QUIET_RETRY`]; otherwise to `socket` with a backoff of
/// 200 ms doubling to 10 s.
fn serve_until_gone(
    socket: &Path,
    name: &str,
    at: &str,
    encoded: &[u8],
    listed: &Listed,
    first: BufReader<UnixStream>,
    revisions: &mut Revisions,
) {
    let mut stream = Some(first);
    let mut unreachable_since: Option<Instant> = None;
    let mut backoff = Duration::from_millis(200);
    let mut via_quiet = quiet_socket(socket).is_some();
    // The last failure written: a quiet socket refuses every 500 ms while the machine sleeps, and
    // each refusal is the same line.
    let mut last_error: Option<String> = None;
    loop {
        if let Some(reader) = stream.take() {
            unreachable_since = None;
            backoff = Duration::from_millis(200);
            last_error = None;
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
        std::thread::sleep(retry_wait(via_quiet, &mut backoff));
        let (dialed, quiet) = redial(socket, name, at, &[], None);
        via_quiet = quiet;
        match dialed {
            Ok((reader, answer)) if ok(&answer) => stream = Some(reader),
            Ok((_, answer)) if code(&answer) == Some("projection.unknown") => {
                // The machine forgot the folder: it fetches the listing from the store when it
                // can, and only then is the whole manifest sent over this Mac's uplink.
                let by_store = revisions
                    .reference()
                    .map(|reference| redial(socket, name, at, &[], Some(&reference)).0);
                let again = match by_store {
                    Some(Ok((reader, answer))) if ok(&answer) => Some(Ok((reader, answer))),
                    Some(Ok((_, answer))) => {
                        eprintln!(
                            "cmux link project: the machine would not fetch the listing: {answer}"
                        );
                        None
                    }
                    Some(Err(error)) => Some(Err(error)),
                    None => None,
                };
                let again = match again {
                    Some(done) => done,
                    None => {
                        revisions.resent += 1;
                        eprintln!(
                            "cmux link project: sending the whole listing ({} so far)",
                            revisions.resent
                        );
                        redial(socket, name, at, encoded, None).0
                    }
                };
                match again {
                    Ok((reader, answer)) if ok(&answer) => stream = Some(reader),
                    Ok((_, answer)) => {
                        eprintln!(
                            "cmux link project: the machine refused the folder again: {answer}"
                        );
                        return;
                    }
                    Err(error) => note_failure(&mut last_error, &error),
                }
            }
            Ok((_, answer)) => {
                eprintln!("cmux link project: the machine refused: {answer}");
                return;
            }
            Err(error) => note_failure(&mut last_error, &error),
        }
    }
}

/// Writes `error` unless it is the one written last.
fn note_failure(last: &mut Option<String>, error: &anyhow::Error) {
    let text = format!("{error:#}");
    if last.as_deref() != Some(text.as_str()) {
        eprintln!("cmux link project: {text}");
        *last = Some(text);
    }
}

/// How long to wait before the next redial: [`QUIET_RETRY`] after a dial over the quiet socket,
/// else `backoff`, which doubles (to 10 s) for the next one.
fn retry_wait(via_quiet: bool, backoff: &mut Duration) -> Duration {
    if via_quiet {
        return QUIET_RETRY;
    }
    let wait = *backoff;
    *backoff = (*backoff * 2).min(Duration::from_secs(10));
    wait
}

/// `carrier serve`'s quiet socket beside `socket` (`<socket>.quiet`), when there is one: a dial
/// there rides the machine's session or, with none, is closed unanswered while the machine sleeps
/// instead of waking it. An older `carrier serve`, or a daemon's own socket, has none.
fn quiet_socket(socket: &Path) -> Option<PathBuf> {
    let mut path = socket.as_os_str().to_owned();
    path.push(".quiet");
    let path = PathBuf::from(path);
    std::fs::symlink_metadata(&path).ok().filter(|meta| meta.file_type().is_socket())?;
    Some(path)
}

/// One redial: on the quiet socket when `socket` has one that accepts, else on `socket` (as
/// before there was a quiet socket). The dial's outcome and whether it went over the quiet socket.
fn redial(
    socket: &Path,
    name: &str,
    at: &str,
    encoded: &[u8],
    revision: Option<&Value>,
) -> (anyhow::Result<(BufReader<UnixStream>, Value)>, bool) {
    if let Some(quiet) = quiet_socket(socket)
        && let Ok(stream) = UnixStream::connect(&quiet)
    {
        return (ask(stream, name, at, encoded, revision), true);
    }
    (dial(socket, name, at, encoded, revision), false)
}

/// Dials the machine and asks it to serve projection `name` at `at` (`encoded`: the manifest, or
/// nothing to attach again). The stream, buffered, and the machine's answer.
fn dial(
    socket: &Path,
    name: &str,
    at: &str,
    encoded: &[u8],
    revision: Option<&Value>,
) -> anyhow::Result<(BufReader<UnixStream>, Value)> {
    let stream = UnixStream::connect(socket)
        .with_context(|| format!("cannot reach the machine at {}", socket.display()))?;
    ask(stream, name, at, encoded, revision)
}

/// A dial the machine closed before it answered (a quiet socket while the machine sleeps).
const UNANSWERED: &str = "the machine closed the link without answering (asleep or unreachable)";

/// A dial's I/O error: a close by the other side before any answer (a reset or a broken pipe,
/// which is how Linux reports a close with the ask still unread) is [`UNANSWERED`]; anything else
/// keeps its own words.
fn unanswered(error: std::io::Error) -> anyhow::Error {
    use std::io::ErrorKind::{BrokenPipe, ConnectionAborted, ConnectionReset};
    match error.kind() {
        ConnectionReset | ConnectionAborted | BrokenPipe => {
            anyhow::anyhow!("{UNANSWERED}: {error}")
        }
        _ => error.into(),
    }
}

/// Asks the machine on `stream` to serve projection `name` at `at`, as [`dial`] does.
fn ask(
    mut stream: UnixStream,
    name: &str,
    at: &str,
    encoded: &[u8],
    revision: Option<&Value>,
) -> anyhow::Result<(BufReader<UnixStream>, Value)> {
    let mut line = json!({
        "id": 1,
        "cmd": cmux_tui_core::projection::SERVE,
        "name": name,
        "at": at,
        "manifest_bytes": encoded.len(),
        // Every byte after this line goes as text lines, both ways: the Cloud carrier carries
        // the dial as a `mux-control` stream, which moves whole lines only.
        "lines": true,
    });
    if let (Some(revision), Some(object)) = (revision, line.as_object_mut()) {
        // The listing is in the store: the machine fetches it from there by this reference.
        object.insert("revision".into(), revision.clone());
    }
    let mut bytes = serde_json::to_vec(&line)?;
    bytes.push(b'\n');
    let sent = stream
        .write_all(&bytes)
        .and_then(|()| cmux_tui_core::projection::LineWriter::new(&stream).write_all(encoded))
        .and_then(|()| stream.flush());
    if let Err(error) = sent {
        return Err(unanswered(error));
    }
    stream.set_read_timeout(Some(START_WAIT))?;
    let mut reader = BufReader::with_capacity(256 * 1024, stream);
    let mut answer = String::new();
    // A quiet socket closes the dial unanswered while the machine sleeps: an end of file, or on
    // Linux a reset, since the ask it never read was still queued when it closed.
    if reader.read_line(&mut answer).map_err(unanswered)? == 0 {
        bail!(UNANSWERED);
    }
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
    for (relative, linked) in &set.links {
        let mtime = std::fs::symlink_metadata(folder.join(relative))
            .map(|meta| mtime_ns(&meta))
            .unwrap_or(0);
        items.push(Item {
            path: relative.clone(),
            kind: Kind::Link,
            mode: 0o777,
            size: 0,
            mtime_ns: mtime,
            link: Some(linked.target.clone()),
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
    Ok(Listed { manifest, served, links: set.links })
}

/// What a projected file's bytes are named by in Bring Back's base until a pull reads them: its
/// size and modification time on this Mac when the folder was projected. Its bytes are this Mac's
/// file's for as long as that file still has both ([`stand_in_matches`]); a pull hashes only the
/// files the machine changed.
pub(super) fn stand_in(size: u64, mtime_ns: i64) -> String {
    format!("{STAND_IN}s{size}-n{mtime_ns}")
}

const STAND_IN: &str = "projected:";

/// Whether `sha256` is a [`stand_in`], not a hash.
pub(super) fn is_stand_in(sha256: &str) -> bool {
    sha256.starts_with(STAND_IN)
}

/// Whether this Mac's file `meta` is still the one the [`stand_in`] `sha256` names.
pub(super) fn stand_in_matches(sha256: &str, meta: &std::fs::Metadata) -> bool {
    meta.is_file() && sha256 == stand_in(meta.len(), mtime_ns(meta))
}

/// Keeps `base` as Bring Back's base for `folder` projected at `at`, unless one is kept already.
/// That one stays whether the machine attaches to its old mount or mounts this newer listing: the
/// mount's upper layer survives either way, with the record a Bring Back since left there, and
/// that record matches the kept base, not this listing. Replacing it made every Bring Back after
/// the server restarted a `sync_base_mismatch`. With no Bring Back yet, the older base still
/// merges: what changed here since reads the same on both sides.
fn keep_base(folder: &Path, at: &str, base: &super::Manifest) -> anyhow::Result<()> {
    if super::base::kept(folder, at) {
        return Ok(());
    }
    super::base::save(folder, at, base)
}

/// Bring Back's base for `folder` as [`list`] found it: the files by [`stand_in`] (their
/// revision the one the machine's `fs-v1` gives a file of that size and mtime, which the
/// projection reports for every file it did not change), the symlinks, and in git the branch and
/// staged changes. `cmux link sync pull` merges against it as against a push's record.
fn base_of_listing(folder: &Path, listed: &Listed) -> anyhow::Result<super::Manifest> {
    let manifest = &listed.manifest;
    let mut files = BTreeMap::new();
    for index in 0..u32::try_from(manifest.len()).unwrap_or(u32::MAX) {
        let Some(entry) = manifest.entry(index).filter(|entry| entry.kind == Kind::File) else {
            continue;
        };
        let mtime_ms = u64::try_from(entry.mtime_ns / 1_000_000).ok();
        files.insert(
            manifest.path_of(index),
            super::Pushed {
                sha256: stand_in(entry.size, entry.mtime_ns),
                permissions: entry.mode,
                revision: cmux_tui_core::fs_ops::revision(entry.size, mtime_ms),
            },
        );
    }
    let git = local::GitDirs::of(folder)?.map(|_| super::git_back::base_of(folder)).transpose()?;
    let repos = super::git_back::nested_bases(folder, files.keys());
    Ok(super::Manifest {
        version: 1,
        files,
        git,
        links: listed.links.clone(),
        projected: true,
        repos,
    })
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
