//! `cmux link agent move --from-socket LOCAL --surface ID --to-socket MACHINE
//! --cwd FOLDER [--interrupt] [--ask-first] [--vm-kind KIND]`: moves the agent chat of tab `ID` of the
//! daemon at `LOCAL` to the machine daemon at `MACHINE` (Move to Cloud,
//! cmuxterm-hq#1874 slice 1c), over `agent-transfer-v1` (spec/commands.md,
//! "Agent chat transfer"). `FOLDER` is where the chat runs there. Neither
//! daemon reaches the other: this pump copies the bundle between them.
//!
//! `MACHINE` is the `local_socket` that `cmux-tui remote connect --headless
//! --json` names in its first `connection-snapshot` event (the app's Cloud
//! link runs it). cmux-remote's mux-control service carries that socket to
//! the VM daemon's own Unix socket, where the pump is a trusted local client
//! (`agent-transfer-*` ride its bulk lane). It is NOT the machine link's
//! socket that `cmux link sync push` uses: the link's remote entry admits
//! only the `fs-v1` ops.
//!
//! 1. begin on the source (the chat freezes there); with `--ask-first` the
//!    source first narrows the chat to an asking policy, rules and mode
//!    (Bring Back Local's "Ask first, then bring back" after a Mac's guard
//!    refused it, cx-rppd.10);
//! 2. receive on the target with the begin manifest;
//! 3. every bundle file, page by page, read from the source and written to
//!    the target;
//! 4. finish on the target (the chat runs there);
//! 5. commit on the source (the chat closes here).
//!
//! The source gives the chat back (abort) only when the target provably
//! lacks it. Before the finish is sent it cannot have it: the receive is
//! dropped there and the source aborts. Once the finish is sent, a failed
//! or lost finish is settled by asking the target (`agent-transfer-
//! receive-abort` of the receive, which also forgets the move there so a
//! late finish can never land it): landed commits, not landed aborts, no
//! answer leaves the chat frozen and reports `move_unresolved`. "Cannot say
//! yet" (the target's finish of that receive still runs) is asked again until
//! the finish's own bound has passed.
//!
//! A Mac source names no target acpmux could ask on its own, so the move is
//! recorded under the state folder until it ends ([`record`]); running the
//! same command again resolves a recorded move first (asks the target, then
//! commits or aborts), and after an abort moves the chat anew.
//!
//! The pump commits or aborts only a move whose id its own record holds, and
//! only while the tab still shows the chat the record names (the source's
//! `agent-transfer-source` read of the tab's store record, which does not
//! attach the chat). Any other move the chat is in (a begin
//! whose answer was lost, another client's move) is left alone: the source
//! refuses the begin as `transfer.moving` with that move's id, and the pump
//! answers `move_unresolved` with it and `retry_after_seconds` (the source's
//! lease: a move nobody reads is aborted by the source on its own).
//!
//! A begin whose answer is lost is this command's own, though, when the
//! source lists `agent-transfer-begin-token-v1`: the pump records a fresh
//! random `begin_token` (and the chat the tab shows) before it sends the
//! begin with it, and acpmux keeps the token with the move, across a restart.
//! A rerun whose begin is refused as `transfer.moving` with that same token
//! learned no transfer id, so no receive was asked and no target can have the
//! chat: it aborts that move at the source (while the tab still shows the
//! recorded chat) and begins anew, instead of leaving the chat frozen for the
//! lease. No token handed back, or another one: left alone, as above.
//!
//! `--vm-kind KIND`: the caller says the target is a Cloud machine and gives
//! the Cloud API's `vmKind` for it on its link (Move to Cloud passes `owner`
//! or `none`). A Cloud VM's daemon takes a chat only on `owner`, never on its
//! own record: the pump sends it as `vm_kind` on the receive and the finish to
//! a daemon with `agent-transfer-vm-kind-v1`. An older daemon would trust its
//! own record, so there the pump refuses any kind but `owner` before the chat
//! freezes (`agent_session.host_unverified`). Nothing the target advertises
//! changes that: a guest can hide any sign of being a Cloud VM. Without the
//! flag the caller says the target is not a Cloud machine (Bring Back
//! Local's Mac); a current Cloud daemon still refuses a chat with no word.
//!
//! `--to-pid PID`: the process the caller read that answer from, which
//! listens on `--to-socket` (the Cloud link's `cmux-tui remote connect`).
//! The receive and the finish go over one connection, and with this flag the
//! pump sends them only when that connection's peer is that process (Linux
//! `SO_PEERCRED`, macOS `LOCAL_PEERPID`); otherwise the link was replaced
//! after the caller asked, and the pump refuses before the receive
//! (`agent_session.host_unverified`) and gives the chat back. A replacement
//! link keeps the socket path, so a rerun still resolves an unresolved move.
//!
//! `--sync push|pull|seed --sync-socket LINK --sync-local LOCAL --sync-remote
//! REMOTE`: once the chat is frozen (after the begin, before the receive), the
//! pump copies its folder's last changes, `cmux link sync push LOCAL REMOTE`
//! (Move to Cloud), `cmux link seed push --since-last LOCAL REMOTE` (Move to
//! Cloud of a folder `cmux link seed push` put there: a delta bundle, or a
//! re-push of its copy) or `cmux link seed pull --or-copy LOCAL REMOTE` (Bring
//! Back Local: a seeded folder's diff, else `cmux link sync pull`) over the
//! machine link socket `LINK`. A chat moved mid-turn
//! (`--interrupt`) made changes up to the freeze, after the caller's own sync; this takes
//! them along, so the turn goes on there with them (acpmux queues its
//! continuation, cmuxterm-hq#5846 item 1). A sync that fails, or a pull that
//! conflicts (`sync_conflict` with `conflicts`), gives the chat back. It runs
//! `--sync relay --sync-from-socket SOURCE_LINK` (Move to another Cloud
//! machine): both ends are machines, `--sync-local` is the folder on the
//! source machine, and the copy is `cmux link sync relay`, pumped through
//! this process. The relay runs twice: its bulk before the begin (the chat
//! still runs), then once frozen, which sends only what changed since. It runs
//! inside the source's lease (an unread move is aborted after
//! `SOURCE_LEASE_SECONDS`), so the caller syncs the bulk before the move and
//! this copies only what changed since.
//!
//! `--sync` may be given more than once, each with its own `--sync-socket`,
//! `--sync-local` and `--sync-remote`; the copies run in that order, and the
//! first that fails gives the chat back. Move to Another Machine passes one
//! `--sync relay`: machine to machine, never through this Mac's folder (as git
//! when this Mac seeded the folder, [`super::seed_cli::hop_bulk`]), so the chat
//! lands with every change the old machine made up to the freeze.
//!
//! `--login-stdin`: the owner's agent login, `{"env":{"NAME":"VALUE"}}` on stdin
//! (cmux-cloud-start-core `moves::login`), goes to the target with the finish, so the moved
//! chat's agent starts signed in before it resumes or runs the continuation turn (a chat moved to
//! a new machine answered "Claude is not signed in here"). Read before the chat freezes; sent only
//! with `--vm-kind owner` (else `agent_session.owner_only`) to a target that serves
//! `agent-transfer-credentials-v1` (else `machine_outdated`, side `target`), and refused there off
//! the owner's own Cloud VM. Unreadable stdin is `agent_session.login_unreadable`. The value never
//! reaches argv, the move's record, a phase or an error text.
//!
//! `--interrupt` stops a running turn only on a source whose `identify` lists
//! `agent-transfer-continues-v1` (its acpmux continues the turn where the
//! chat lands); an older source refuses the move while the turn runs.
//!
//! Output: one JSON line on stdout, `{"ok":true,"session_id":...,
//! "transfer_id":...,"bytes":N,"pages":N,"resolved":bool,"phases":{...},
//! "frozen_ms"?:N,"total_ms":N}` (exit 0), or
//! `{"ok":false,"error":...,"error_code":...,"transfer_id"?:...,
//! "retry_after_seconds"?:N,"side"?:"source"|"target","phases":{...},
//! "total_ms":N}` (exit 1); bad usage exits 64. `side` names the daemon a
//! `machine_outdated` is about. `phases` is each step's wall time in whole
//! milliseconds (monotonic clock), only the steps this run reached: `state`
//! (the move record), `gate` (both daemons' capabilities and the target's
//! kind), `bulk_sync` (a relay's bulk, chat still running), `connect` (the
//! source connection and its capability check), `begin` (the chat freezes),
//! `abort_own` (a rerun giving back the move a lost begin answer left),
//! `frozen_sync` (`--sync` once frozen), `receive` (target connection and
//! receive), `copy` (every bundle page), `finish`, `commit`, or `resolve` (a
//! rerun ending an earlier move). `frozen_ms`: the begin's start to the
//! commit's end, how long the chat could not run (a fresh move that landed).
//! `frozen_sync_phases` (a move that ran `--sync`): where `frozen_sync` went
//! ([`super::spans`]): `spans`, each machine request, git run, fixed wait and
//! sync step summed by name as `{"ms":N,"n":N}`, and `remote`, the machine
//! jobs' own `timings`.
//!
//! `--history-later TURNS` (or `ACPMUX_MOVE_HISTORY_LATER=TURNS`): only the
//! chat's last turns go before it runs on the machine, staged there while it
//! still runs here (phase `prepare`); its packed history follows after the
//! commit (phase `history`), see [`history_later`]. The line then adds
//! `live_ms` (start to commit: the chat runs there), `history_ms` and
//! `history_records`, or `history_error` with the history left on the source.

use cmux_json::JsonSet as _;

mod daemon;
mod history_later;
mod record;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};

use cmux_cloud_start_core::moves::login::{self, FLAG as LOGIN_FLAG, Login};
use daemon::{BEGIN_TIMEOUT, CALL_TIMEOUT, CallError, Daemon, FINISH_TIMEOUT, call_once};
use record::{Record, Records};

const USAGE: &str = "usage: cmux link agent move --from-socket LOCAL_DAEMON_SOCKET \
--surface SURFACE_ID --to-socket REMOTE_CONNECT_SOCKET --cwd REMOTE_FOLDER [--interrupt] \
[--ask-first] [--vm-kind KIND [--to-pid PID]] [--login-stdin] [--state-dir DIR] \
[--history-later TURNS] \
[--sync push|pull|seed --sync-socket LINK_SOCKET --sync-local LOCAL --sync-remote REMOTE]... \
[--sync relay --sync-from-socket SOURCE_LINK --sync-socket TARGET_LINK --sync-local SOURCE_FOLDER --sync-remote TARGET_FOLDER [--sync-seed-local LOCAL]]
  --to-socket: the local_socket of `cmux-tui remote connect --headless --json` for the \
machine (its connection-snapshot event), not the machine link socket of `cmux link sync`";
/// Bytes asked for per page (the daemon serves at most 4 MiB).
const PAGE_BYTES: u64 = 1 << 20;
/// acpmux's `TRANSFER_LEASE`: a move nobody reads for that long is aborted
/// by its source.
const SOURCE_LEASE_SECONDS: u64 = 300;

struct Args {
    from: PathBuf,
    surface: u64,
    to: PathBuf,
    cwd: String,
    interrupt: bool,
    /// Narrow the chat on the source to an asking policy and mode first.
    ask_first: bool,
    /// `--vm-kind`: the Cloud API's answer for the caller (module docs).
    vm_kind: Option<String>,
    /// `--to-pid`: the process that answer belongs to (module docs).
    to_pid: Option<u32>,
    state_dir: Option<PathBuf>,
    /// `--sync`: the folder's last changes, copied once the chat is frozen, in order.
    syncs: Vec<Sync>,
    /// `--login-stdin`: the owner's agent login comes on stdin (module docs).
    login_stdin: bool,
    /// `--history-later TURNS` ([`history_later`]); `ACPMUX_MOVE_HISTORY_LATER` when absent.
    history_later: Option<u64>,
}

/// `--sync push|pull|seed --sync-socket --sync-local --sync-remote` (module docs), or
/// `--sync relay --sync-from-socket --sync-socket --sync-local --sync-remote`, where
/// `local` is the folder on the source machine.
struct Sync {
    way: Way,
    socket: PathBuf,
    local: PathBuf,
    remote: String,
    /// `--sync relay`: the source machine's link socket.
    from_socket: Option<PathBuf>,
    /// `--sync relay --sync-seed-local`: this Mac's folder a seed put on the source machine.
    /// Once the move commits its seed record follows to the target ([`super::seed_cli::follow`]).
    seed_local: Option<PathBuf>,
    /// The move this copy is part of (the source daemon and the chat's surface): a hop's records
    /// are its own ([`super::seed_cli::hop_bulk`]).
    owner: String,
}

/// Which way `--sync` copies.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Way {
    Push,
    Pull,
    Seed,
    /// Machine to machine, through this process (`cmux link sync relay`).
    Relay,
}

/// What acpmux's refusal of a bundle file a guarded move does not take says.
const UNTAKEN_FILE: &str = "is not a file a guarded move takes";

/// A move that failed, as its JSON line reports it.
struct Failed {
    code: String,
    error: String,
    transfer_id: Option<String>,
    /// When a rerun may find the chat free (the source's lease).
    retry_after_seconds: Option<u64>,
    /// The daemon the failure is about, when it is one side's.
    side: Option<&'static str>,
    /// `sync_conflict`: the paths changed on both sides (boxed: `Failed` is every call's error).
    conflicts: Option<Box<[String]>>,
}

impl Failed {
    fn new(code: impl Into<String>, error: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            error: error.into(),
            transfer_id: None,
            retry_after_seconds: None,
            side: None,
            conflicts: None,
        }
    }

    /// A call to the `side` daemon that failed: its refusal code, or
    /// `<side>_unreachable` when no answer came.
    fn call(side: &str, error: &CallError) -> Self {
        match error {
            CallError::Refused { message, .. }
                if side == "target" && message.contains(UNTAKEN_FILE) =>
            {
                Self::untaken_file(message)
            }
            CallError::Refused { code, message, .. } => Self::new(code.clone(), message.clone()),
            CallError::Lost(message) => Self::new(format!("{side}_unreachable"), message.clone()),
        }
    }

    /// A target that refuses a file of the bundle (acpmux `transfer_guard.rs`, `transfer_in.rs`)
    /// runs a cmux-tui older than the source's, which wrote the file: [`taken_by_target`] leaves
    /// such files out when it can ask the target, so this is the move it could not ask. It reads
    /// as the machine being outdated (the app says "update the machine"), never the raw
    /// `transfer.path` line; the source's chat is untouched (2026-11-24 kill-mid-move drills).
    fn untaken_file(message: &str) -> Self {
        let mut failed = Self::new(
            super::machine_gate::OUTDATED,
            format!(
                "the machine runs an older cmux-tui that refused a file of this chat ({message}); update the machine"
            ),
        );
        failed.side = Some("target");
        failed
    }

    fn bad_answer(error: impl Into<String>) -> Self {
        Self::new("bad_answer", error)
    }

    fn state(error: &anyhow::Error) -> Self {
        Self::new("state_unavailable", format!("{error:#}"))
    }

    fn with_transfer(mut self, transfer_id: &str) -> Self {
        self.transfer_id = Some(transfer_id.to_owned());
        self
    }
}

/// A chat that now lives on the machine.
struct Moved {
    session_id: String,
    transfer_id: String,
    bytes: u64,
    /// An earlier run's move was resolved, not a new one made.
    resolved: bool,
}

/// Each step's wall time (module docs, `phases`): a lap closes the step that ran since the last.
struct Clock {
    start: Instant,
    last: Instant,
    phases: Vec<(&'static str, u128)>,
    /// When the begin was sent: the chat cannot run from then until the commit ends.
    frozen_at: Option<Instant>,
    frozen_ms: Option<u128>,
    pages: u64,
    /// Where the frozen `--sync` went ([`super::spans::take`]).
    frozen_sync: Option<Value>,
    /// `--history-later`: the start to the commit's end (the chat runs there).
    live_ms: Option<u128>,
    /// `--history-later`: what the history's follow did.
    history: Option<Value>,
}

impl Clock {
    fn new() -> Self {
        let now = Instant::now();
        Self {
            start: now,
            last: now,
            phases: Vec::new(),
            frozen_at: None,
            frozen_ms: None,
            pages: 0,
            frozen_sync: None,
            live_ms: None,
            history: None,
        }
    }

    /// Closes step `name`; its time is added to an earlier lap of the same name.
    fn lap(&mut self, name: &'static str) {
        let now = Instant::now();
        let ms = now.duration_since(self.last).as_millis();
        self.last = now;
        match self.phases.iter_mut().find(|(phase, _)| *phase == name) {
            Some((_, sum)) => *sum += ms,
            None => self.phases.push((name, ms)),
        }
    }

    fn freeze(&mut self) {
        self.frozen_at = Some(Instant::now());
    }

    fn thaw(&mut self) {
        self.frozen_ms = self.frozen_at.map(|at| at.elapsed().as_millis());
    }

    /// Sets `phases`, `total_ms` and, when known, `frozen_ms` on `line`.
    fn report(&self, line: &mut Value) {
        let phases: serde_json::Map<String, Value> =
            self.phases.iter().map(|(name, ms)| ((*name).to_owned(), json!(ms))).collect();
        line.set("phases", Value::Object(phases));
        if let Some(ms) = self.frozen_ms {
            line.set("frozen_ms", json!(ms));
        }
        if let Some(spans) = &self.frozen_sync {
            line.set("frozen_sync_phases", spans.clone());
        }
        if let Some(ms) = self.live_ms {
            line.set("live_ms", json!(ms));
        }
        if let Some(Value::Object(history)) = &self.history {
            for (key, value) in history {
                line.set(key, value.clone());
            }
        }
        line.set("total_ms", json!(self.start.elapsed().as_millis()));
    }
}

pub(super) fn run(args: &[String]) -> i32 {
    let help = args.first().map(String::as_str) == Some("help")
        || args.iter().any(|arg| matches!(arg.as_str(), "-h" | "--help"));
    if help {
        println!("{USAGE}");
        return 0;
    }
    let Some(mut args) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let env = std::env::var("ACPMUX_MOVE_HISTORY_LATER").ok();
    args.history_later = history_later::turns(args.history_later, env.as_deref());
    let mut clock = Clock::new();
    match move_chat(&args, &mut clock) {
        Ok(moved) => {
            let mut line = json!({"ok": true, "session_id": moved.session_id,
                              "transfer_id": moved.transfer_id, "bytes": moved.bytes,
                              "pages": clock.pages, "resolved": moved.resolved});
            clock.report(&mut line);
            println!("{line}");
            0
        }
        Err(failed) => {
            let mut line = json!({"ok": false, "error": failed.error, "error_code": failed.code});
            clock.report(&mut line);
            if let Some(transfer_id) = failed.transfer_id {
                line.set("transfer_id", json!(transfer_id));
            }
            if let Some(seconds) = failed.retry_after_seconds {
                line.set("retry_after_seconds", json!(seconds));
            }
            if let Some(side) = failed.side {
                line.set("side", json!(side));
            }
            if let Some(conflicts) = failed.conflicts {
                line.set("conflicts", json!(conflicts));
            }
            println!("{line}");
            1
        }
    }
}

fn parse(args: &[String]) -> Option<Args> {
    let [action, rest @ ..] = args else { return None };
    if action != "move" {
        return None;
    }
    let (mut from, mut surface, mut to, mut cwd, mut state_dir) = (None, None, None, None, None);
    let (mut vm_kind, mut to_pid) = (None, None);
    // Each `--sync` group's flags, in any order: a flag its group has already starts the next group.
    let mut groups: Vec<SyncFlags> = Vec::new();
    let (mut interrupt, mut ask_first, mut login_stdin) = (false, false, false);
    let mut history_later = None;
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--from-socket" => from = Some(PathBuf::from(rest.next()?)),
            "--surface" => surface = Some(rest.next()?.parse::<u64>().ok()?),
            "--to-socket" => to = Some(PathBuf::from(rest.next()?)),
            "--cwd" => cwd = Some(rest.next()?.clone()),
            "--state-dir" => state_dir = Some(PathBuf::from(rest.next()?)),
            "--vm-kind" => vm_kind = Some(rest.next()?.clone()),
            "--to-pid" => to_pid = Some(rest.next()?.parse::<u32>().ok()?),
            "--history-later" => history_later = Some(rest.next()?.parse::<u64>().ok()?),
            "--interrupt" => interrupt = true,
            "--ask-first" => ask_first = true,
            LOGIN_FLAG => login_stdin = true,
            "--sync" => {
                let way = match rest.next()?.as_str() {
                    "push" => Way::Push,
                    "pull" => Way::Pull,
                    "seed" => Way::Seed,
                    "relay" => Way::Relay,
                    _ => return None,
                };
                SyncFlags::group(&mut groups, |g| g.way.is_none())?.way = Some(way);
            }
            "--sync-socket" => {
                let socket = PathBuf::from(rest.next()?);
                SyncFlags::group(&mut groups, |g| g.socket.is_none())?.socket = Some(socket);
            }
            "--sync-local" => {
                let local = PathBuf::from(rest.next()?);
                SyncFlags::group(&mut groups, |g| g.local.is_none())?.local = Some(local);
            }
            "--sync-remote" => {
                let remote = rest.next()?.clone();
                SyncFlags::group(&mut groups, |g| g.remote.is_none())?.remote = Some(remote);
            }
            "--sync-from-socket" => {
                let from = PathBuf::from(rest.next()?);
                SyncFlags::group(&mut groups, |g| g.from_socket.is_none())?.from_socket =
                    Some(from);
            }
            "--sync-seed-local" => {
                let local = PathBuf::from(rest.next()?);
                SyncFlags::group(&mut groups, |g| g.seed_local.is_none())?.seed_local = Some(local);
            }
            _ => return None,
        }
    }
    let cwd = cwd.filter(|cwd| cwd.starts_with('/'))?;
    // Each group has all four; the remote folder is absolute, as `cmux link sync` takes it.
    let (from, surface) = (from?, surface?);
    let owner = format!("{}#{surface}", from.display());
    let syncs = groups.into_iter().map(|g| g.sync(&owner)).collect::<Option<Vec<_>>>()?;
    Some(Args {
        from,
        surface,
        to: to?,
        cwd,
        interrupt,
        ask_first,
        vm_kind,
        to_pid,
        state_dir,
        syncs,
        login_stdin,
        history_later,
    })
}

/// One `--sync` group's flags as `parse` reads them.
#[derive(Default)]
struct SyncFlags {
    way: Option<Way>,
    socket: Option<PathBuf>,
    local: Option<PathBuf>,
    remote: Option<String>,
    from_socket: Option<PathBuf>,
    seed_local: Option<PathBuf>,
}

impl SyncFlags {
    /// The group a flag goes in: the last one while `free` (it lacks that flag), else a new one.
    fn group(groups: &mut Vec<Self>, free: impl Fn(&Self) -> bool) -> Option<&mut Self> {
        if !groups.last().is_some_and(&free) {
            groups.push(Self::default());
        }
        groups.last_mut()
    }

    fn sync(self, owner: &str) -> Option<Sync> {
        let remote = self.remote.filter(|remote| remote.starts_with('/'))?;
        let (way, local) = (self.way?, self.local?);
        // A relay names both machines and two absolute folders; no other way has a source socket.
        let relay = way == Way::Relay;
        if relay != self.from_socket.is_some()
            || (relay && !local.is_absolute())
            || (!relay && self.seed_local.is_some())
        {
            return None;
        }
        Some(Sync {
            way,
            socket: self.socket?,
            local,
            remote: remote.trim_end_matches('/').to_owned(),
            from_socket: self.from_socket,
            seed_local: self.seed_local,
            owner: owner.to_owned(),
        })
    }
}

fn move_chat(args: &Args, clock: &mut Clock) -> Result<Moved, Failed> {
    let records = Records::open(args.state_dir.clone(), &args.from, args.surface).map_err(|e| {
        match e.downcast_ref::<record::Busy>() {
            Some(busy) => Failed::new("move_in_progress", busy.to_string()),
            None => Failed::state(&e),
        }
    })?;
    let earlier = records.load().map_err(|e| Failed::state(&e))?;
    clock.lap("state");
    // A begin whose answer was lost left only its token: the move it may have begun is this
    // command's own if the source hands that token back.
    let mut token = None;
    let mut tab = None;
    if let Some(record) = earlier {
        if record.transfer_id.is_empty() {
            token = record.begin_token;
            tab = record.source_tab;
        } else {
            let resolved = resolve(args, &records, record);
            clock.lap("resolve");
            if let Some(moved) = resolved? {
                return Ok(moved);
            }
        }
    }
    fresh(args, &records, clock, token, tab)
}

/// Ends the move an earlier run left: the chat landed there (the source
/// commits), or it was given back here (`None`: a new move may start).
fn resolve(args: &Args, records: &Records, mut record: Record) -> Result<Option<Moved>, Failed> {
    if record.to_socket != args.to {
        let error = format!(
            "an earlier move of this chat to {} is unresolved; run it again with that --to-socket",
            record.to_socket.display()
        );
        return Err(unresolved(&record, error));
    }
    if !same_chat(args, &record) {
        // The source's commit closes the chat, so a tab that no longer shows it is what a run
        // killed after that commit finds: the move is over when the target says the chat
        // landed. Only the tail of the commit is left (the seed record), never a second commit.
        if record.landed == Some(true) && ask_landed(&record) == Some(true) {
            return Ok(Some(commit_landed(args, records, &record, 0, true)));
        }
        let error = "cannot confirm the tab still shows the chat this move took; nothing was ended";
        return Err(unresolved(&record, error));
    }
    let landed = record.landed.or_else(|| {
        if record.finish_sent || record.receive_id.is_some() {
            ask_landed(&record)
        } else {
            // No receive id ever reached anyone: nothing can finish it.
            Some(false)
        }
    });
    match landed {
        Some(true) => commit(args, records, &mut record, 0, true).map(Some),
        Some(false) => give_back(args, records, &mut record).map(|()| None),
        None => {
            Err(unresolved(&record, "the machine cannot say yet whether the chat landed there"))
        }
    }
}

/// A new move: begin, receive, copy, finish, then commit or abort. `token`: the begin token of
/// an earlier run whose begin answer was lost.
fn fresh(
    args: &Args,
    records: &Records,
    clock: &mut Clock,
    token: Option<String>,
    earlier_tab: Option<String>,
) -> Result<Moved, Failed> {
    if let Some(tab) = &earlier_tab {
        // An earlier run's begin may have frozen the chat, and its source may have been killed
        // since: wait until the daemon is back and has the tab (a restart gives it a new
        // surface slot, so only the tab's public id names it) before anything asks it anything.
        let _ = call_source(&args.from, "agent-transfer-source", json!({"tab": tab}));
    }
    let login = read_login(args, &mut std::io::stdin().lock())?;
    // Before the chat freezes: a daemon too old for the move says so
    // (`machine_outdated`) instead of failing the receive or the begin.
    // `side` says which: the app names a machine only when it is the machine.
    for (side, socket) in [("target", &args.to), ("source", &args.from)] {
        let capability = cmux_tui_core::server::agent_transfer::AGENT_TRANSFER_CAPABILITY;
        if let Some(outdated) = super::machine_gate::outdated(socket, &[capability]) {
            // Not "update the machine": the outdated side may be this Mac's own daemon.
            let build = outdated.build.as_deref().unwrap_or("unknown build");
            let missing = outdated.missing.join(", ");
            let message = if outdated.older {
                format!("the {side} daemon runs an older cmux-tui ({build}) without {missing}")
            } else {
                format!(
                    "the {side} daemon ({build}) is not older but does not serve {missing} on this connection"
                )
            };
            let mut failed = Failed::new(outdated.code(), message);
            failed.side = Some(side);
            return Err(failed);
        }
    }
    let vm_kind = target_vm_kind(args)
        .and_then(|kind| login.as_ref().map_or(Ok(()), |_| login_gate(args)).map(|()| kind));
    clock.lap("gate");
    let vm_kind = vm_kind?;
    // A relay makes its bulk copy before the chat freezes, so the frozen pass below sends only
    // what changed since and the chat is frozen for that delta alone.
    if args.syncs.iter().any(|sync| sync.way == Way::Relay) {
        let bulk = args.syncs.iter().filter(|sync| sync.way == Way::Relay).try_for_each(relay_bulk);
        clock.lap("bulk_sync");
        bulk?;
    }
    let source = Daemon::connect(&args.from).map_err(|e| Failed::call("source", &e));
    // A running turn stops for the move only where it goes on afterwards: an older source would
    // stop it for good, so there the move is refused while it runs, as before `--interrupt`.
    let (continues, keeps_token) =
        if source.is_ok() { source_serves(&args.from) } else { (false, false) };
    let interrupt = args.interrupt && continues;
    clock.lap("connect");
    let mut source = source?;
    // Recorded before the begin: a run whose begin answer is lost knows the move it began by
    // this token, which the source hands back when it refuses a begin as `transfer.moving`.
    let pinned = if keeps_token { pin_begin(args, records, token, earlier_tab) } else { None };
    // Asked for: the chat's last turns are staged there while it still runs here.
    let staged = args.history_later.and_then(|keep| {
        let staged = history_later::stage(args, &mut source, keep, &vm_kind, &mut clock.pages);
        clock.lap("prepare");
        staged
    });
    let mut params = match pinned.as_ref().and_then(|pinned| pinned.source_tab.as_ref()) {
        Some(tab) => json!({"tab": tab, "interrupt": interrupt}),
        None => json!({"surface": args.surface, "interrupt": interrupt}),
    };
    if args.ask_first {
        params.set("ask_first", json!(true));
    }
    if let Some(pinned) = &pinned {
        params.set("begin_token", json!(pinned.begin_token));
    }
    let mut staged_params = params.clone();
    if let Some(staged) = &staged {
        staged_params.set("prepare_id", json!(staged.prepare_id));
    }
    clock.freeze();
    let mut begun = source.call("agent-transfer-begin", staged_params, BEGIN_TIMEOUT);
    // A prefix the source no longer holds as it was: the chat moves whole.
    if staged.is_some()
        && matches!(&begun, Err(CallError::Refused { message, .. })
            if message.contains("transfer.diverged"))
    {
        begun = source.call("agent-transfer-begin", params.clone(), BEGIN_TIMEOUT);
    }
    clock.lap("begin");
    if let (Some(pinned), Err(CallError::Refused { details, .. })) = (&pinned, &begun)
        && let Some(moving) = details["transfer_id"].as_str().filter(|id| !id.is_empty())
        && details["begin_token"]
            .as_str()
            .is_some_and(|echoed| pinned.begin_token.as_deref() == Some(echoed))
    {
        // This command's own move, begun by a run that lost the answer: no transfer id was
        // learned, so no receive was asked and no target can have the chat. Given back here
        // (only while the tab shows the chat pinned then), then begun anew.
        let mut own = Record { transfer_id: moving.to_owned(), ..pinned.clone() };
        if !same_chat(args, &own) {
            let error = "cannot confirm the tab still shows the chat this move took; nothing was \
                         ended";
            return Err(unresolved(&own, error));
        }
        give_back(args, records, &mut own)?;
        clock.lap("abort_own");
        let _ = records.save(pinned);
        begun = source.call("agent-transfer-begin", params, BEGIN_TIMEOUT);
        clock.lap("begin");
    }
    let begun = match begun {
        Ok(begun) => begun,
        Err(CallError::Refused { code, message, details }) => {
            let Some(moving) = details["transfer_id"].as_str().filter(|id| !id.is_empty()) else {
                return Err(Failed::new(code, message));
            };
            // Not a move this command recorded: never ended here.
            let error = "the chat is frozen in a move this command has no record of; a move \
                         nobody reads is aborted by the source after its lease";
            return Err(frozen(error, Some(moving)));
        }
        Err(lost) => {
            let error = if pinned.is_some() {
                format!(
                    "the begin was not answered ({}); the chat may be frozen until this command \
                     runs again or the source's lease ends that unread move",
                    lost.message()
                )
            } else {
                format!(
                    "the begin was not answered ({}); the chat may be frozen until the source's \
                     lease ends that unread move",
                    lost.message()
                )
            };
            return Err(frozen(&error, None));
        }
    };
    let transfer_id = begun["transfer_id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| Failed::bad_answer("the source's begin named no move"))?;
    let mut record = Record {
        transfer_id: transfer_id.to_owned(),
        source_session_id: begun["source_session"].as_str().map(str::to_owned),
        to_socket: args.to.clone(),
        cwd: args.cwd.clone(),
        source_tab: begun
            .get("tab")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
            .or_else(|| pinned.as_ref().and_then(|pinned| pinned.source_tab.clone())),
        begin_token: pinned.and_then(|pinned| pinned.begin_token),
        ..Record::default()
    };
    // The chat is frozen: its folder's last changes go with it. No receive was asked yet, so
    // the target cannot have the chat, and a sync that fails gives it back.
    if !args.syncs.is_empty()
        && let Err(failed) = {
            // Recorded first: a run that dies while it copies is resolved by the next one.
            let _ = records.save(&record);
            // Only the frozen pass's own requests and runs.
            let _ = super::spans::take();
            let synced = args.syncs.iter().try_for_each(sync_frozen);
            clock.lap("frozen_sync");
            clock.frozen_sync = Some(super::spans::take());
            synced
        }
    {
        return Err(match give_back(args, records, &mut record) {
            Ok(()) => failed.with_transfer(&record.transfer_id),
            Err(stuck) => Failed { error: format!("{}; {}", failed.error, stuck.error), ..stuck },
        });
    }
    let manifest = begun.get("manifest").unwrap_or(&Value::Null);
    // The begin took the staged prefix: the bundle holds only what follows it.
    let staged = staged.filter(|_| begun["staged"] == json!(true));
    let stage_id = staged.as_ref().map(|staged| staged.stage_id.as_str());
    let owes_history = staged.is_some() && begun["history_later"] == json!(true);
    let (mut target, bytes) = match up_to_finish(
        args,
        &mut source,
        records,
        &mut record,
        (manifest, stage_id),
        &vm_kind,
        clock,
    ) {
        Ok(copied) => copied,
        Err(failed) => {
            // No finish was sent: the target cannot have the chat.
            drop_receive(&record);
            return Err(match give_back(args, records, &mut record) {
                Ok(()) => failed.with_transfer(&record.transfer_id),
                Err(stuck) => {
                    Failed { error: format!("{}; {}", failed.error, stuck.error), ..stuck }
                }
            });
        }
    };
    let receive_id = record.receive_id.clone().unwrap_or_default();
    let mut finish = json!({"receive_id": receive_id});
    if let Some(kind) = &vm_kind {
        finish.set("vm_kind", json!(kind));
    }
    // Only the finish carries the login; the record and every phase never do.
    if let Some(login) = &login {
        finish.set("credentials", login.wire());
    }
    let finished = target.call("agent-transfer-finish", finish, FINISH_TIMEOUT);
    clock.lap("finish");
    let (landed, finish_error) = match finished {
        Ok(answer) => {
            if let Some(id) = answer["session"]["sessionId"].as_str() {
                record.session_id = Some(id.to_owned());
            }
            (Some(true), None)
        }
        Err(error) => (ask_landed(&record), Some(error)),
    };
    let finish_error = finish_error.as_ref();
    let why = finish_error.map_or("", CallError::message);
    match landed {
        Some(true) => {
            let bytes = bytes + staged.as_ref().map_or(0, |staged| staged.bytes);
            let committed = commit(args, records, &mut record, bytes, false);
            clock.lap("commit");
            if committed.is_ok() {
                clock.thaw();
            }
            if committed.is_ok() && owes_history {
                clock.live_ms = Some(clock.start.elapsed().as_millis());
                drop(target);
                let followed = history_later::follow(
                    args,
                    &record.transfer_id,
                    &receive_id,
                    &vm_kind,
                    &mut clock.pages,
                );
                clock.lap("history");
                clock.history = Some(match followed {
                    Ok(followed) => json!({"history_ms": followed.ms,
                                           "history_records": followed.records,
                                           "history_through_seq": followed.through_seq,
                                           "history_bytes": followed.bytes}),
                    Err(failed) => {
                        eprintln!(
                            "cmux: the chat moved, but its history did not follow: {}; it is \
                             still on the source",
                            failed.error
                        );
                        json!({"history_error": failed.error})
                    }
                });
            }
            committed
        }
        Some(false) => {
            give_back(args, records, &mut record)?;
            let code = finish_error.and_then(CallError::code).unwrap_or("move_failed");
            let error = format!("the machine did not take the chat: {why}");
            Err(Failed::new(code, error).with_transfer(&record.transfer_id))
        }
        None => {
            let error = format!(
                "the finish was not answered ({why}) and the machine cannot say whether the chat \
                 landed; the chat stays frozen here until this command runs again"
            );
            Err(unresolved(&record, error))
        }
    }
}

/// A relay's bulk copy, before the chat freezes. A git folder goes as git, machine to machine
/// (`seed_cli::hop`): the second machine clones from GitHub and gets the seed's diff when a Move
/// to Cloud seeded it from this Mac (`--sync-seed-local`), else the first machine's own changes
/// since its upstream (a chat that started on a Cloud machine), or only what changed since the
/// chat left when it moves back to a machine that still has its folder. This Mac's folder is
/// never read or written. A folder the hop cannot take (one copied rather than seeded, one with
/// no GitHub remote, say) copies machine to machine, file by file.
fn relay_bulk(sync: &Sync) -> Result<(), Failed> {
    if let Some(from) = &sync.from_socket {
        let from_root = sync.local.to_string_lossy();
        let hopped = super::seed_cli::hop_bulk(
            from,
            &from_root,
            &sync.socket,
            &sync.remote,
            sync.seed_local.as_deref(),
            &sync.owner,
        );
        match hopped {
            Ok(()) => return Ok(()),
            Err(error) => {
                let warning = json!({"warning": "hop_fell_back", "error": format!("{error:#}")});
                eprintln!("{warning}");
            }
        }
    }
    sync_frozen(sync)
}

/// `--sync`'s copy of a frozen chat's folder (module docs).
fn sync_frozen(sync: &Sync) -> Result<(), Failed> {
    use super::sync_cli::{self, Back};
    match sync.way {
        Way::Push => {
            return sync_cli::push(&sync.socket, &sync.local, &sync.remote).map(|_| ()).map_err(
                |e| {
                    Failed::new(
                        sync_cli::push_failure_code(&e),
                        format!("the folder's last changes: {e:#}"),
                    )
                },
            );
        }
        Way::Seed => {
            return super::seed_cli::push_since_last(&sync.socket, &sync.local, &sync.remote)
                .map(|_| ())
                .map_err(|e| {
                    Failed::new(
                        super::seed_cli::failure_code(&e),
                        format!(
                            "the folder's last changes: {}",
                            super::seed_cli::failure_message(&e)
                        ),
                    )
                });
        }
        Way::Relay => {
            let from = sync.from_socket.as_deref().ok_or_else(|| {
                Failed::new("bad_request", "a relay names the source machine's socket".to_string())
            })?;
            let failed = |e: anyhow::Error| {
                Failed::new(
                    super::seed_cli::failure_code(&e),
                    format!("the folder's last changes: {}", super::seed_cli::failure_message(&e)),
                )
            };
            // A folder the bulk pass sent as git sends its last changes as git too ([`relay_bulk`]).
            let local = sync.seed_local.as_deref();
            if super::seed_cli::hop_started(local, &sync.remote, &sync.owner) {
                let from_root = sync.local.to_string_lossy();
                let hopped = super::seed_cli::hop_frozen(
                    from,
                    &from_root,
                    &sync.socket,
                    &sync.remote,
                    local,
                    &sync.owner,
                );
                match hopped {
                    // The stash grew older entries than a seed carries: what the bulk seeded goes
                    // and the folder relays whole below.
                    Err(error) if super::seed_cli::many_stashes(&error) => {
                        super::seed_cli::hop_abandon(
                            &sync.socket,
                            &sync.remote,
                            local,
                            &sync.owner,
                        )
                        .map_err(failed)?;
                    }
                    hopped => return hopped.map_err(failed),
                }
            }
            let mut quiet = |_: sync_cli::Progress| {};
            return sync_cli::relay(
                from,
                &sync.local.to_string_lossy(),
                &sync.socket,
                &sync.remote,
                &sync.owner,
                &mut quiet,
            )
            .map(|_| ())
            .map_err(|e| {
                Failed::new(
                    sync_cli::push_failure_code(&e),
                    format!("the folder's last changes: {e:#}"),
                )
            });
        }
        Way::Pull => {}
    }
    // A seeded folder comes back as the seed's diff, a copied one as the copy's pull.
    match super::seed_cli::bring_back(&sync.socket, &sync.local, &sync.remote) {
        Back::Done(_) => Ok(()),
        Back::Conflict(conflicts, reasons) => {
            let mut error = format!(
                "{} changed both here and on the machine while the chat ran; nothing was brought \
                 back",
                conflicts.join(", ")
            );
            if !reasons.is_empty() {
                error = format!("{error} ({})", reasons.join("; "));
            }
            Err(Failed {
                conflicts: Some(conflicts.into_boxed_slice()),
                ..Failed::new("sync_conflict", error)
            })
        }
        Back::Failed { code, error } => {
            Err(Failed::new(code, format!("the folder's last changes: {error}")))
        }
    }
}

/// What the source daemon's `identify` lists that the move uses: whether its acpmux continues a
/// turn the move stops, and whether it keeps a begin token. False for what it does not say, or
/// when it does not answer.
fn source_serves(socket: &std::path::Path) -> (bool, bool) {
    use cmux_tui_core::server::agent_transfer::{
        AGENT_TRANSFER_BEGIN_TOKEN_CAPABILITY, AGENT_TRANSFER_CONTINUES_CAPABILITY,
    };
    let identity = super::machine_gate::reach(socket).ok();
    let served = identity.as_ref().and_then(super::machine_gate::served).unwrap_or_default();
    (
        served.contains(&AGENT_TRANSFER_CONTINUES_CAPABILITY),
        served.contains(&AGENT_TRANSFER_BEGIN_TOKEN_CAPABILITY),
    )
}

/// A fresh begin token: 128 random bits as hex.
fn new_begin_token() -> Option<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).ok()?;
    Some(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// `--login-stdin`'s login, read before the chat freezes; none without the flag.
fn read_login(args: &Args, stdin: &mut dyn std::io::Read) -> Result<Option<Login>, Failed> {
    use std::io::Read as _;
    if !args.login_stdin {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    let limit = u64::try_from(login::MAX_STDIN_BYTES).unwrap_or(u64::MAX).saturating_add(1);
    let read = stdin.take(limit).read_to_end(&mut bytes);
    let login = read.map_err(|_| login::Refusal::Unreadable).and_then(|_| login::read(&bytes));
    login.map(Some).map_err(refused_login)
}

/// Whether the target takes the login (module docs): the Cloud API said `owner`, and its daemon
/// serves `agent-transfer-credentials-v1`.
fn login_gate(args: &Args) -> Result<(), Failed> {
    let identity = super::machine_gate::reach(&args.to).ok();
    let served = identity.as_ref().and_then(super::machine_gate::served);
    login::gate(args.vm_kind.as_deref(), served.as_deref()).map_err(refused_login)
}

fn refused_login(refusal: login::Refusal) -> Failed {
    let mut failed = Failed::new(refusal.code(), refusal.message());
    failed.side = refusal.side();
    failed
}

/// The `vm_kind` the target is sent (module docs): none without
/// `--vm-kind` (the caller says it is not a Cloud machine); `--vm-kind` for a
/// daemon with `agent-transfer-vm-kind-v1`; none for an older one, which
/// trusts its own record, so it is refused unless the Cloud API said `owner`.
fn target_vm_kind(args: &Args) -> Result<Option<String>, Failed> {
    let Some(kind) = &args.vm_kind else { return Ok(None) };
    let capability = cmux_tui_core::server::agent_transfer::AGENT_TRANSFER_VM_KIND_CAPABILITY;
    let identity = super::machine_gate::reach(&args.to).ok();
    let served = identity.as_ref().and_then(super::machine_gate::served);
    if served.is_some_and(|served| served.contains(&capability)) {
        return Ok(Some(kind.clone()));
    }
    if kind == "owner" {
        return Ok(None);
    }
    let error = "the Cloud API did not say this machine is yours, and its cmux-tui cannot check";
    let mut failed = Failed::new("agent_session.host_unverified", error);
    failed.side = Some("target");
    Err(failed)
}

/// Steps 2 and 3, each step recorded first: the receive on the target, then
/// every page, then the record that the finish is about to be sent.
/// Returns the target connection and the bytes copied.
fn up_to_finish(
    args: &Args,
    source: &mut Daemon,
    records: &Records,
    record: &mut Record,
    (manifest, stage_id): (&Value, Option<&str>),
    vm_kind: &Option<String>,
    clock: &mut Clock,
) -> Result<(Daemon, u64), Failed> {
    records.save(record).map_err(|e| Failed::state(&e))?;
    let target_failed = |e: CallError| Failed::call("target", &e);
    let mut target = Daemon::connect(&args.to).map_err(target_failed)?;
    if let Some(pid) = args.to_pid
        && target.peer_pid() != Some(pid)
    {
        let error = "the Cloud link this machine's answer came from has ended; nothing was sent";
        let mut failed = Failed::new("agent_session.host_unverified", error);
        failed.side = Some("target");
        return Err(failed);
    }
    let manifest = &taken_by_target(args, manifest, &record.transfer_id);
    let mut params = json!({"manifest": manifest, "cwd": args.cwd});
    if let Some(kind) = vm_kind {
        params.set("vm_kind", json!(kind));
    }
    if let Some(stage_id) = stage_id {
        params.set("stage_id", json!(stage_id));
    }
    let received = target.call("agent-transfer-receive", params, CALL_TIMEOUT);
    clock.lap("receive");
    let received = received.map_err(target_failed)?;
    let receive_id = received["receive_id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| Failed::bad_answer("the machine's receive named no receive"))?;
    record.receive_id = Some(receive_id.to_owned());
    record.session_id = received["session_id"].as_str().map(str::to_owned);
    records.save(record).map_err(|e| Failed::state(&e))?;
    let files = manifest["files"]
        .as_array()
        .ok_or_else(|| Failed::bad_answer("the begin manifest lists no files"))?;
    let mut bytes = 0;
    for file in files {
        let (Some(path), Some(size)) = (file["path"].as_str(), file["size"].as_u64()) else {
            return Err(Failed::bad_answer("the begin manifest lists a file without path or size"));
        };
        let receive_id = record.receive_id.as_deref().unwrap_or_default();
        let copied = copy_file(
            source,
            &mut target,
            &record.transfer_id,
            receive_id,
            path,
            size,
            &mut clock.pages,
        );
        if copied.is_err() {
            clock.lap("copy");
        }
        bytes += copied?;
    }
    record.finish_sent = true;
    let saved = records.save(record);
    clock.lap("copy");
    saved.map_err(|e| Failed::state(&e))?;
    Ok((target, bytes))
}

/// The begin `manifest` less each optional bundle file the machine's daemon does not list (acpmux
/// `capabilities::OPTIONAL_BUNDLE_FILES`, which a current daemon's `identify` lists as an agent
/// transfer capability): a machine image older than the file would refuse the whole move for it
/// (2026-11-24: `transfer.path: "composers.json" is not a file a guarded move takes`), so the
/// chat moves without it and the pump says so in one line.
fn taken_by_target(args: &Args, manifest: &Value, transfer_id: &str) -> Value {
    // A target that could not be asked is not an older target: the manifest goes whole, so a
    // failed read never costs the person their unsent text or prompt images.
    let Ok(identity) = super::machine_gate::reach(&args.to) else {
        return manifest.clone();
    };
    let served = super::machine_gate::served(&identity).unwrap_or_default();
    let mut manifest = manifest.clone();
    let left = acpmux::capabilities::leave_out_untaken(&mut manifest, |c| served.contains(&c));
    if let Some(line) = acpmux::capabilities::left_out_line(&left) {
        let warning = json!({"warning": "optional_files_left", "transfer_id": transfer_id,
                             "files": left, "error": line});
        eprintln!("{warning}");
    }
    manifest
}

/// Copies one file page by page, read from the source's move (or prepare)
/// `transfer_id` and written to the machine's receive (or stage)
/// `receive_id`; an empty file needs no page.
fn copy_file(
    source: &mut Daemon,
    target: &mut Daemon,
    transfer_id: &str,
    receive_id: &str,
    path: &str,
    size: u64,
    pages: &mut u64,
) -> Result<u64, Failed> {
    let mut offset = 0u64;
    while offset < size {
        let params = json!({"transfer_id": transfer_id, "path": path, "offset": offset,
                            "limit": PAGE_BYTES});
        let page = source
            .call("agent-transfer-read", params, CALL_TIMEOUT)
            .map_err(|e| Failed::call("source", &e))?;
        let data = page["data"].as_str().unwrap_or_default();
        let len = BASE64.decode(data).map_or(0, |bytes| bytes.len() as u64);
        if len == 0 || offset + len > size {
            return Err(Failed::bad_answer(format!("the source served a bad page of {path}")));
        }
        let params = json!({"receive_id": receive_id, "path": path, "offset": offset,
                            "data": data});
        let written = target
            .call("agent-transfer-write", params, CALL_TIMEOUT)
            .map_err(|e| Failed::call("target", &e))?;
        if written["next"].as_u64() != Some(offset + len) {
            return Err(Failed::bad_answer(format!("the machine took a page of {path} short")));
        }
        *pages += 1;
        offset += len;
    }
    Ok(size)
}

/// How long a pump waits between questions while the target is still finishing the receive.
const FINISHING_PAUSE: Duration = Duration::from_millis(250);

/// Asks the target whether the chat landed, forgetting the move there so a
/// late finish can never land it: `None` when it cannot say. While the
/// target answers "cannot say yet" (its finish of this receive is still
/// running, after a finish answer was lost or a rerun came in during it),
/// the pump asks again until that finish's own bound has passed: a cut
/// connection that dropped only the answer otherwise left the chat open
/// there and frozen here until someone ran the move again. A target daemon
/// that answers while its acpmux is not back yet (`agent_transfer.unavailable`:
/// the machine's processes were killed and are restarting) is waited for the
/// same way: it cannot say yet, and it will once acpmux is up.
fn ask_landed(record: &Record) -> Option<bool> {
    let deadline = Instant::now() + FINISH_TIMEOUT + CALL_TIMEOUT;
    loop {
        match ask_landed_once(record) {
            Asked::Settled(landed) => return Some(landed),
            Asked::Finishing | Asked::Restarting if Instant::now() < deadline => {
                std::thread::sleep(FINISHING_PAUSE);
            }
            Asked::Finishing | Asked::Restarting | Asked::NoAnswer => return None,
        }
    }
}

enum Asked {
    Settled(bool),
    /// The target answered and cannot say yet: nothing was forgotten there.
    Finishing,
    /// The target daemon answered without its acpmux (restarting): nothing was forgotten there.
    Restarting,
    NoAnswer,
}

fn ask_landed_once(record: &Record) -> Asked {
    let Some(receive_id) = record.receive_id.as_deref() else { return Asked::NoAnswer };
    let params = json!({"receive_id": receive_id});
    let answer =
        match call_once(&record.to_socket, "agent-transfer-receive-abort", params, CALL_TIMEOUT) {
            Ok(answer) => answer,
            Err(CallError::Refused { code, .. }) if code == "agent_transfer.unavailable" => {
                return Asked::Restarting;
            }
            Err(_) => return Asked::NoAnswer,
        };
    match (answer["landed"].as_bool(), answer["forgotten"].as_bool()) {
        (Some(true), _) => Asked::Settled(true),
        // Only a forgotten move stays not landed.
        (Some(false), Some(true)) => Asked::Settled(false),
        (None, Some(false)) => Asked::Finishing,
        _ => Asked::NoAnswer,
    }
}

/// Drops the receive on the target, if there is one (a best effort: an
/// unfinished receive is swept there after 24 h).
fn drop_receive(record: &Record) {
    if let Some(receive_id) = &record.receive_id {
        let params = json!({"receive_id": receive_id});
        let _ = call_once(&record.to_socket, "agent-transfer-receive-abort", params, CALL_TIMEOUT);
    }
}

/// How long a pump waits for a source daemon that is down or restarting (killed, its processes
/// coming back) before it gives up on a call that must reach it: the chat is frozen there or
/// already landed on the target, and only the source can unfreeze or close it.
const SOURCE_RESTART_WAIT: Duration = Duration::from_secs(120);

/// How long "not an agent tab" is waited out: a restarted source restores its tabs a moment
/// after it answers, but a tab that is really gone (closed by a commit whose answer was lost)
/// never comes back.
const SOURCE_TAB_RESTORE_WAIT: Duration = Duration::from_secs(30);

/// Whether `error` is a source daemon that is not back yet: it does not answer (`Lost`), its
/// acpmux is not up (`agent_transfer.unavailable`), or it does not have the tab yet
/// (`agent_transfer.unknown_tab`, only for a tab named by its public id, which a restart keeps).
fn source_restarting(error: &CallError, by_tab: bool) -> Option<Duration> {
    match error {
        CallError::Lost(_) => Some(SOURCE_RESTART_WAIT),
        CallError::Refused { code, .. } if code == "agent_transfer.unavailable" => {
            Some(SOURCE_RESTART_WAIT)
        }
        CallError::Refused { code, .. } if by_tab && code == "agent_transfer.unknown_tab" => {
            Some(SOURCE_TAB_RESTORE_WAIT)
        }
        CallError::Refused { .. } => None,
    }
}

/// `call_once` to the source, waiting out a source daemon that is restarting: a kill of the
/// source mid-move otherwise left the chat frozen there (give back failed), or open there and
/// on the target (commit failed), and an immediate rerun failed the same way.
fn call_source(socket: &std::path::Path, cmd: &str, params: Value) -> Result<Value, CallError> {
    let by_tab = params.get("tab").is_some();
    let start = Instant::now();
    loop {
        let error = match call_once(socket, cmd, params.clone(), CALL_TIMEOUT) {
            Ok(answer) => return Ok(answer),
            Err(error) => error,
        };
        match source_restarting(&error, by_tab) {
            Some(wait) if start.elapsed() < wait => std::thread::sleep(FINISHING_PAUSE),
            _ => return Err(error),
        }
    }
}

/// The source gives the chat back (the target provably lacks it).
fn give_back(args: &Args, records: &Records, record: &mut Record) -> Result<(), Failed> {
    // Kept for a rerun if the source cannot be told now.
    record.landed = Some(false);
    let _ = records.save(record);
    let mut params = source_tab(args, record);
    params.set("transfer_id", json!(record.transfer_id));
    match call_source(&args.from, "agent-transfer-abort", params) {
        Ok(_) => {}
        // Ended already (the source's own lease aborts an unread move), as
        // long as the tab still shows this move's chat.
        Err(CallError::Refused { code, message, .. })
            if code == "agent_transfer.refused"
                && message.contains("transfer.unknown")
                && same_chat(args, record) => {}
        Err(error) => {
            let error = format!("the chat could not be given back here: {}", error.message());
            return Err(unresolved(record, error));
        }
    }
    records.clear();
    Ok(())
}

/// The source closes the chat (it landed on the target).
fn commit(
    args: &Args,
    records: &Records,
    record: &mut Record,
    bytes: u64,
    resolved: bool,
) -> Result<Moved, Failed> {
    record.landed = Some(true);
    let _ = records.save(record);
    let mut params = source_tab(args, record);
    params.set("transfer_id", json!(record.transfer_id));
    params.set("to", json!({"cwd": record.cwd}));
    if let Err(error) = call_source(&args.from, "agent-transfer-commit", params) {
        let error = format!("the chat landed there but did not close here: {}", error.message());
        return Err(unresolved(record, error));
    }
    Ok(commit_landed(args, records, record, bytes, resolved))
}

/// What follows the source's commit: the seed record follows the chat, the pump's record clears.
fn commit_landed(
    args: &Args,
    records: &Records,
    record: &Record,
    bytes: u64,
    resolved: bool,
) -> Moved {
    // Bring Back Local from the new machine merges against the seed this Mac sent the first one.
    // Before the record clears: a run that dies here moves it on its next run.
    for sync in &args.syncs {
        let Some(from) = &sync.from_socket else { continue };
        let Some(seed_local) = &sync.seed_local else {
            // No folder of this Mac's: a hop's waiting record goes, nothing else is kept.
            let _ = super::seed_cli::land(None, &sync.remote, &sync.owner);
            continue;
        };
        let local_root = sync.local.to_string_lossy();
        let moved =
            super::seed_cli::land(Some(seed_local), &sync.remote, &sync.owner).and_then(|landed| {
                if landed {
                    return Ok(true);
                }
                super::seed_cli::follow(seed_local, &local_root, &sync.remote, from, &sync.socket)
            });
        if let Err(error) = moved {
            // The move stands; Bring Back Local then copies instead of merging.
            eprintln!(
                "{}",
                json!({"warning": "seed_record_not_moved", "error": format!("{error:#}")})
            );
        }
    }
    records.clear();
    Moved {
        session_id: record.session_id.clone().unwrap_or_default(),
        transfer_id: record.transfer_id.clone(),
        bytes,
        resolved,
    }
}

/// The record a begin with a token leaves before it is sent: no transfer id yet, the token
/// (an earlier lost begin's, else a fresh one) and the chat the tab shows now, which a rerun
/// ends a move of only while the tab still shows it. None when that is not saved: the begin
/// then goes without a token, as to a source that keeps none.
fn pin_begin(
    args: &Args,
    records: &Records,
    token: Option<String>,
    earlier_tab: Option<String>,
) -> Option<Record> {
    let params = match &earlier_tab {
        Some(tab) => json!({"tab": tab}),
        None => json!({"surface": args.surface}),
    };
    let answer = call_source(&args.from, "agent-transfer-source", params).ok()?;
    let session = answer["session"].as_str().filter(|id| !id.is_empty())?;
    let record = Record {
        source_session_id: Some(session.to_owned()),
        source_tab: answer.get("tab").and_then(serde_json::Value::as_str).map(str::to_owned),
        to_socket: args.to.clone(),
        cwd: args.cwd.clone(),
        begin_token: Some(token.or_else(new_begin_token)?),
        ..Record::default()
    };
    records.save(&record).ok()?;
    Some(record)
}

/// Whether the tab still shows the chat `record`'s move took (the source's
/// `agent-transfer-source` read, which never attaches it); false when that
/// cannot be told.
fn same_chat(args: &Args, record: &Record) -> bool {
    let Some(pinned) = record.source_session_id.as_deref() else { return false };
    let params = source_tab(args, record);
    call_source(&args.from, "agent-transfer-source", params)
        .is_ok_and(|answer| answer["session"].as_str() == Some(pinned))
}

/// How the source verbs of `record`'s move name its tab: by the public id the source answered
/// (it outlives a restart of the source daemon, which gives the tab a new surface), else by
/// `--surface` (a source too old to answer one).
fn source_tab(args: &Args, record: &Record) -> Value {
    match &record.source_tab {
        Some(tab) => json!({"tab": tab}),
        None => json!({"surface": args.surface}),
    }
}

/// The chat is frozen in a move this command did not record.
fn frozen(error: &str, transfer_id: Option<&str>) -> Failed {
    let mut failed = Failed::new("move_unresolved", error);
    failed.transfer_id = transfer_id.map(str::to_owned);
    failed.retry_after_seconds = Some(SOURCE_LEASE_SECONDS);
    failed
}

fn unresolved(record: &Record, error: impl Into<String>) -> Failed {
    Failed::new("move_unresolved", error).with_transfer(&record.transfer_id)
}

#[cfg(test)]
mod tests;
