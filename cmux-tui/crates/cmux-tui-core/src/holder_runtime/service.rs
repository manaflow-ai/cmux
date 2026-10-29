//! The daemon's holder for one terminal host root: start or reach it, spawn
//! terminals on it, and hand every live terminal to a new holder after a
//! holder crash.

use cmux_process::Stdio;
use std::collections::HashMap;
use std::io::{self, Write};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock, Weak};

use cmux_holder::link::{HolderLink, LinkEnd, TerminalSink};
use cmux_holder::{Listed, SpawnRequest};

use super::{HolderSink, HolderTerminal};
use crate::panic_free::RecoverPoison;

/// The current link and the CLOSEs waiting for one. Held only for a
/// moment: never while connecting, launching or re-adopting.
#[derive(Default)]
struct LinkSlot {
    link: Option<Arc<HolderLink>>,
    /// Every CLOSE asked for (`grace_ms` by channel), kept until the
    /// terminal is untracked: each new link sends them again once it
    /// re-adopted every terminal. A CLOSE written to a holder that was
    /// already dying (killed, its link not yet seen closed) is lost, and a
    /// new holder would otherwise keep the closed tab's shell running.
    pending_close: HashMap<u32, u32>,
}

/// The holder of one terminal host root (one daemon session).
pub(crate) struct HolderService {
    socket: PathBuf,
    token: [u8; 32],
    link: Mutex<LinkSlot>,
    /// Serializes connecting, launching and re-adopting. Its holder may
    /// take a surface's terminal lock (a re-adoption's prologue), so no
    /// caller that holds a surface lock may wait for it: a surface's kill
    /// and acknowledgements use [`Self::open_link`] only.
    connecting: Mutex<()>,
    next_chan: AtomicU32,
    /// Terminals this daemon runs on the holder, for a re-adoption after a
    /// holder crash.
    live: Mutex<HashMap<u32, Weak<HolderTerminal>>>,
    /// Held (shared) by a spawn or a re-attach from before its SPAWN or
    /// ATTACH goes out until its terminal is in `live` or its channel is in
    /// `abandoned`; held (exclusive) by a reconnect from before it reads
    /// either. So a reconnect never misses a terminal that is just being
    /// opened: it resumes or re-adopts it, or ends it as abandoned. A spawn
    /// on a link that is lost fails at once (the link fails its waiters
    /// before anyone reconnects), so the reconnect waits only for that.
    claiming: RwLock<()>,
    /// Channels whose SPAWN failed after it went out (a timeout, or the
    /// link broke before the answer), by channel, with the terminal id:
    /// the holder may run them though no surface of this daemon owns them.
    /// The only terminals a reconnect ends on its own ([`Self::end_abandoned`]).
    abandoned: Mutex<HashMap<u32, [u8; 16]>>,
    /// What the holder ran when this daemon first reached it: the
    /// terminals a restarted daemon re-attaches, by terminal id. Filled by
    /// the first connection only, emptied after the startup pass
    /// ([`Self::release_unclaimed`]).
    listed: Mutex<HashMap<[u8; 16], Listed>>,
    /// Another daemon of the session took the holder: this one never
    /// connects again, so the two do not take it from each other in turn.
    superseded: AtomicBool,
    /// The standalone holder failed to start once: this daemon starts the
    /// holder built into its host executable from then on.
    standalone_failed: AtomicBool,
}

impl HolderService {
    /// The service of `host_root`, made on first use. One per root in the
    /// process: every surface of a session reaches the same holder.
    pub(crate) fn for_root(host_root: &Path) -> io::Result<Arc<Self>> {
        static SERVICES: OnceLock<Mutex<HashMap<PathBuf, Arc<HolderService>>>> = OnceLock::new();
        let services = SERVICES.get_or_init(Mutex::default);
        let mut services = services.lock().recover_poison();
        if let Some(service) = services.get(host_root) {
            return Ok(service.clone());
        }
        let service = Arc::new(Self {
            socket: socket_path(host_root)?,
            token: load_or_create_token(host_root)?,
            link: Mutex::default(),
            connecting: Mutex::new(()),
            next_chan: AtomicU32::new(1),
            live: Mutex::default(),
            claiming: RwLock::new(()),
            abandoned: Mutex::default(),
            listed: Mutex::default(),
            superseded: AtomicBool::new(false),
            standalone_failed: AtomicBool::new(false),
        });
        services.insert(host_root.to_path_buf(), service.clone());
        Ok(service)
    }

    /// Whether a holder of `host_root` may run: its socket exists. Asking
    /// costs no file, process or token when none does.
    pub(crate) fn may_run(host_root: &Path) -> bool {
        socket_path(host_root).is_ok_and(|socket| socket.exists())
    }

    /// The live link: connects to a running holder, else starts one. A link
    /// made after a lost one hands every live terminal to the new holder.
    pub(crate) fn link(self: &Arc<Self>) -> io::Result<Arc<HolderLink>> {
        self.link_or_launch(true)
    }

    /// The link when one is open. Never connects, launches or waits for a
    /// connect: safe under any surface lock.
    fn open_link(&self) -> Option<Arc<HolderLink>> {
        self.link.lock().recover_poison().link.clone().filter(|link| link.is_open())
    }

    /// [`Self::link`]; with `launch` false a holder that does not run is not
    /// started (a restart only asks whether one kept terminals).
    fn link_or_launch(self: &Arc<Self>, launch: bool) -> io::Result<Arc<HolderLink>> {
        if let Some(link) = self.open_link() {
            return Ok(link);
        }
        let _connecting = self.connecting.lock().recover_poison();
        if let Some(link) = self.open_link() {
            return Ok(link);
        }
        if self.superseded.load(Ordering::Acquire) {
            return Err(io::Error::other(
                "another daemon of this session took the terminal holder",
            ));
        }
        let had_link = self.link.lock().recover_poison().link.is_some();
        let (link, listed) = match self.connect() {
            Ok(connected) => connected,
            Err(_) if launch => {
                self.launch()?;
                self.connect()?
            }
            Err(error) => return Err(error),
        };
        for entry in &listed {
            self.next_chan.fetch_max(entry.chan + 1, Ordering::AcqRel);
        }
        if had_link {
            // A reconnect: the holder lists this daemon's own terminals (the
            // same holder), nothing (a new one), or also terminals of
            // another daemon of the session (a restart overlap whose
            // SUPERSEDED never reached this one). Their master dups drop
            // here; the daemon keeps its own custody copies. The link is
            // published only after the re-adoption, so a CLOSE meanwhile
            // waits for it instead of reaching a holder that does not know
            // the terminal yet.
            let still_held: HashMap<u32, [u8; 16]> =
                listed.iter().map(|entry| (entry.chan, entry.id)).collect();
            drop(listed);
            let _claims = self.claiming.write().recover_poison();
            self.readopt(&link, &still_held);
            self.end_abandoned(&link, &still_held);
        } else {
            let mut known = self.listed.lock().recover_poison();
            for entry in listed {
                known.entry(entry.id).or_insert(entry);
            }
        }
        self.publish(&link);
        Ok(link)
    }

    /// After a reconnect: end every terminal this daemon abandoned (a SPAWN
    /// that failed after it went out, [`Self::spawn`]) that the holder
    /// still lists under the same channel and terminal id. Its CLOSE was
    /// lost with the link, or never sent: without this the holder would
    /// keep its shell, PTY and ring for the life of the link, the shell
    /// blocked behind output nobody acknowledges.
    ///
    /// Only those: what the holder lists is not this daemon's to end just
    /// because no surface of it runs the terminal. Another daemon of the
    /// session may run it (a restart overlap, where the old daemon saw a
    /// plain end of its link instead of SUPERSEDED and reconnects), and a
    /// surface of this one may be opening it (the `claiming` lock).
    ///
    /// An abandoned channel the holder does not list (or lists with
    /// another id) has ended and been forgotten, or never started: it is
    /// dropped. One it still lists stays, so a CLOSE this link loses too
    /// goes out again on the next one; once the holder forgot it, the next
    /// reconnect drops it.
    fn end_abandoned(&self, link: &HolderLink, listed: &HashMap<u32, [u8; 16]>) {
        let ending: Vec<u32> = {
            let mut abandoned = self.abandoned.lock().recover_poison();
            abandoned.retain(|chan, id| listed.get(chan) == Some(id));
            abandoned.keys().copied().collect()
        };
        for chan in ending {
            if let Err(error) = link.close(chan, ABANDONED_CLOSE_GRACE_MS) {
                eprintln!("cmux-tui: end abandoned holder terminal {chan}: {error}");
            }
        }
    }

    /// Make `link` the current link and send the CLOSEs that waited for it.
    fn publish(&self, link: &Arc<HolderLink>) {
        let pending: Vec<(u32, u32)> = {
            let mut slot = self.link.lock().recover_poison();
            slot.link = Some(link.clone());
            slot.pending_close.iter().map(|(chan, grace_ms)| (*chan, *grace_ms)).collect()
        };
        for (chan, grace_ms) in pending {
            if let Err(error) = link.close(chan, grace_ms) {
                eprintln!("cmux-tui: end holder terminal {chan}: {error}");
            }
        }
    }

    /// Start `request` on the holder. Returns the terminal (its custody
    /// master, pid and output sink); `seed` reaches the parser before the
    /// shell's first byte.
    pub(crate) fn spawn(
        self: &Arc<Self>,
        request: &SpawnRequest,
        seed: &[u8],
    ) -> io::Result<Arc<HolderTerminal>> {
        let link = self.link()?;
        let _claim = self.claiming.read().recover_poison();
        let chan = self.next_chan.fetch_add(1, Ordering::AcqRel);
        let sink = HolderSink::new(0);
        sink.prepend(seed);
        match link.spawn(chan, request, sink.clone() as Arc<dyn TerminalSink>) {
            Ok(spawned) => {
                Ok(self.track(chan, request.id, spawned.pid, (spawned.master, spawned.ring), sink))
            }
            Err(error) => {
                if cmux_holder::link::spawn_may_have_started(&error) {
                    self.abandoned.lock().recover_poison().insert(chan, request.id);
                }
                Err(error)
            }
        }
    }

    /// The terminal `id` a previous daemon left running on the holder, now
    /// streaming its kept output from the oldest byte, with the custody dup
    /// of its master the holder passed in its WELCOME. `None` when the
    /// holder does not run it.
    pub(crate) fn reattach(
        self: &Arc<Self>,
        id: &[u8; 16],
    ) -> io::Result<Option<Arc<HolderTerminal>>> {
        let link = self.link()?;
        let _claim = self.claiming.read().recover_poison();
        let Some(entry) = self.listed.lock().recover_poison().remove(id) else { return Ok(None) };
        // A shell that ended while no daemon ran still re-attaches: its last
        // output replays and the holder's EXIT records its real status.
        let Some(custody) = entry.master else { return Ok(None) };
        let sink = HolderSink::new(entry.oldest);
        if entry.oldest > 0 {
            // The ring's first byte may be inside an escape sequence or a
            // UTF-8 character the ring dropped the start of.
            sink.prepend(&[super::sink::CANCEL]);
        }
        link.attach(entry.chan, entry.oldest, sink.clone() as Arc<dyn TerminalSink>)?;
        Ok(Some(self.track(entry.chan, *id, entry.pid, (custody, entry.ring), sink)))
    }

    /// Whether the holder ran terminal `id` (running or ended) when this
    /// daemon reached it.
    pub(crate) fn lists(self: &Arc<Self>, id: &[u8; 16]) -> bool {
        self.link_or_launch(false).is_ok() && self.listed.lock().recover_poison().contains_key(id)
    }

    /// After the startup pass: end every terminal the holder runs that no
    /// surface re-attached (its registry row ended, was removed, or never
    /// ran), and drop the master dups the holder passed for them. Without
    /// this the holder would keep those shells, their PTYs and their rings
    /// for ever. Starts no holder.
    pub(crate) fn release_unclaimed(self: &Arc<Self>) {
        let Ok(link) = self.link_or_launch(false) else { return };
        let unclaimed: Vec<Listed> =
            self.listed.lock().recover_poison().drain().map(|(_, entry)| entry).collect();
        for entry in unclaimed {
            // A shell's usual hang-up grace; the holder forgets it once it ended.
            if let Err(error) = link.close(entry.chan, 2000) {
                eprintln!("cmux-tui: end unclaimed holder terminal {}: {error}", entry.chan);
            }
        }
    }

    /// Tell the holder `chan`'s parser read every byte before `offset`.
    /// Starts no holder: without a link there is nothing to free.
    fn ack(&self, chan: u32, offset: u64) {
        if let Some(link) = self.open_link() {
            let _ = link.ack(chan, offset);
        }
    }

    /// Hand the holder a VT replay of `chan`'s screen at `base` (its
    /// prologue for a restarted daemon). Without an open link nothing is
    /// sent (a new holder gets a fresh replay with the master) and this
    /// returns false.
    pub(super) fn snapshot(&self, chan: u32, base: u64, replay: &[u8]) -> bool {
        self.open_link().is_some_and(|link| link.snapshot(chan, base, replay).is_ok())
    }

    /// Hang up `chan`'s terminal; SIGKILL its groups after `grace_ms`.
    /// Never connects or starts a holder, so a surface may call it under
    /// its own locks. The CLOSE is kept until `chan` is untracked and each
    /// new link (a holder restart) sends it again; without an open link
    /// this returns an error, so the caller can signal the shell itself.
    pub(crate) fn close(&self, chan: u32, grace_ms: u32) -> io::Result<()> {
        let link = {
            let mut slot = self.link.lock().recover_poison();
            slot.pending_close.insert(chan, grace_ms);
            match slot.link.clone().filter(|link| link.is_open()) {
                Some(link) => link,
                None => {
                    return Err(io::Error::new(
                        io::ErrorKind::NotConnected,
                        "no terminal holder link: the close waits for the next one",
                    ));
                }
            }
        };
        link.close(chan, grace_ms)
    }

    /// The daemon leaves `chan` running on the holder for its shutdown.
    /// Never connects.
    pub(super) fn detach(&self, chan: u32) {
        if let Some(link) = self.open_link() {
            let _ = link.detach(chan);
        }
    }

    /// Stop tracking `chan` (its terminal ended or its surface left).
    pub(crate) fn untrack(&self, chan: u32) {
        self.live.lock().recover_poison().remove(&chan);
        let link = {
            let mut slot = self.link.lock().recover_poison();
            slot.pending_close.remove(&chan);
            slot.link.clone()
        };
        if let Some(link) = link {
            link.forget(chan);
        }
    }

    fn track(
        self: &Arc<Self>,
        chan: u32,
        id: [u8; 16],
        pid: i32,
        (custody, ring): (OwnedFd, Option<OwnedFd>),
        sink: Arc<HolderSink>,
    ) -> Arc<HolderTerminal> {
        let service = Arc::downgrade(self);
        sink.set_acker(Box::new(move |offset| {
            if let Some(service) = service.upgrade() {
                service.ack(chan, offset);
            }
        }));
        let terminal = Arc::new(HolderTerminal {
            chan,
            id,
            pid,
            custody,
            ring: Mutex::new(ring),
            sink,
            service: self.clone(),
            replay: Mutex::new(None),
        });
        self.live.lock().recover_poison().insert(chan, Arc::downgrade(&terminal));
        terminal
    }

    /// End every live terminal as lost: no holder can stream it.
    fn lose_all(&self) {
        let live: Vec<_> =
            self.live.lock().recover_poison().values().filter_map(Weak::upgrade).collect();
        for terminal in live {
            terminal.sink.lose();
        }
    }

    /// After the link was lost: a terminal the holder `link` still runs
    /// (`still_held`, by channel: the same holder) resumes from the last
    /// byte this daemon received; every other live terminal goes to the new
    /// holder with its custody master, pid, ring segment and a prologue
    /// built at the exact offset the parser confirmed
    /// ([`HolderTerminal::adoption`]). Output the shells wrote meanwhile
    /// waited in their PTYs; output the dead holder read but never sent is
    /// in the ring segment. Each terminal's custody segment becomes the one
    /// the new holder says it writes (its ADOPTED answer), so the next
    /// crash never hands on a segment nobody wrote. Every ADOPT goes out
    /// before the first answer is waited for: one round trip, not one per
    /// terminal. Both resume and adopt count the holder's credit from the
    /// offset the parser confirmed, not the one it received.
    fn readopt(&self, link: &HolderLink, still_held: &HashMap<u32, [u8; 16]>) {
        let live: Vec<_> =
            self.live.lock().recover_poison().values().filter_map(Weak::upgrade).collect();
        let mut answers = Vec::new();
        for terminal in live {
            if still_held.get(&terminal.chan) == Some(&terminal.id) {
                // Its own ring holds every byte it read: nothing is lost.
                terminal.sink.forget_adoption();
                let sink = terminal.sink.clone() as Arc<dyn TerminalSink>;
                let at = (terminal.sink.received(), terminal.sink.confirmed());
                if let Err(error) = link.resume(terminal.chan, at, sink) {
                    eprintln!("cmux-tui: resume holder terminal {}: {error}", terminal.chan);
                }
                continue;
            }
            let adoption =
                terminal.adoption(link.takes_rings(), super::terminal::ADOPT_PROLOGUE_MAX_BYTES);
            let sink = terminal.sink.clone() as Arc<dyn TerminalSink>;
            match link.adopt(
                terminal.chan,
                &terminal.id,
                (terminal.pid, adoption.base, adoption.resume),
                (&terminal.custody, adoption.ring.as_ref()),
                (sink, &adoption.prologue),
            ) {
                Ok(answer) => answers.push((terminal, answer)),
                // The ADOPT did not go out whole, so the holder never
                // adopted the terminal: the custody segment stays, and the
                // next adoption plans its loss again.
                Err(error) => {
                    terminal.sink.forget_adoption();
                    eprintln!(
                        "cmux-tui: hand terminal {} to the new holder: {error}",
                        terminal.chan
                    );
                }
            }
        }
        for (terminal, answer) in answers {
            // Without an answer nobody knows which segment the holder
            // writes: no custody segment then (the next crash replays the
            // parser's queue instead of a ring nobody can vouch for).
            let segment = answer.wait().unwrap_or_else(|error| {
                eprintln!("cmux-tui: holder terminal {} ring: {error}", terminal.chan);
                None
            });
            terminal.keep_ring(segment);
        }
    }

    fn connect(self: &Arc<Self>) -> io::Result<(Arc<HolderLink>, Vec<Listed>)> {
        let weak = Arc::downgrade(self);
        HolderLink::connect(
            &self.socket,
            &self.token,
            Box::new(move |end| {
                let Some(service) = weak.upgrade() else { return };
                if end == LinkEnd::Superseded {
                    // Another daemon of this session took the holder (a
                    // restart overlap): taking it back would make the two
                    // take turns for ever. This daemon is on its way out.
                    eprintln!("cmux-tui: another daemon took the terminal holder");
                    service.superseded.store(true, Ordering::Release);
                    return;
                }
                if let LinkEnd::Fault(code) = end {
                    // The holder still runs every terminal and counted no
                    // crash: the next link takes them back as after a drop.
                    eprintln!(
                        "cmux-tui: the terminal holder could not read this daemon's link \
                         (error code {code}); connecting again"
                    );
                }
                // The holder died: start a new one and hand it every master.
                let _ =
                    std::thread::Builder::new().name("holder-restart".into()).spawn(move || {
                        if let Err(error) = service.link() {
                            // No holder streams their output any more: their
                            // terminals end as lost (the shells may still run).
                            eprintln!("cmux-tui: restart the terminal holder: {error}");
                            service.lose_all();
                        }
                    });
            }),
        )
    }

    /// Start a holder and wait until it listens: the standalone
    /// `cmux-holder` (std and libc only, its own content-addressed copy on
    /// macOS, `crate::host_exe::holder_executable`) when the daemon has one
    /// that speaks its wire, else the holder built into the host executable
    /// (`cmux-tui-host __holder`).
    fn launch(&self) -> io::Result<()> {
        let configure =
            |command: &mut cmux_process::Command| {
                command
                    .arg("--socket")
                    .arg(&self.socket)
                    // Every shell gets back the open-file limit cmux started
                    // with; the holder keeps the daemon's raised one.
                    .envs(
                        cmux_pty::original_open_file_limit()
                            .map(|soft| (cmux_holder::NOFILE_SOFT_ENV, soft.to_string())),
                    )
                    // A DEV build's, debug build's or test's grace, as its hosts
                    // get: the holder ends its terminals once no daemon came back.
                    .envs(crate::terminal_host_runtime::spawned_orphan_grace().map(|grace| {
                        (cmux_holder::ORPHAN_GRACE_ENV, grace.as_millis().to_string())
                    }))
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null());
            };
        if !self.standalone_failed.load(Ordering::Acquire)
            && let Some(path) = standalone_holder()
        {
            let mut command = cmux_process::Command::new(&path);
            command.arg0(crate::host_exe::HOLDER_NAME);
            configure(&mut command);
            // Not to a file `CMUX_TUI_HOLDER_EXE` names: that is a test's
            // stand-in for an older holder, which refuses arguments it
            // does not know.
            if std::env::var_os(crate::host_exe::HOLDER_ENV).is_none_or(|value| value.is_empty()) {
                command.args(crate::terminal_host_runtime::host_owner_args());
            }
            let started = command.spawn().and_then(|child| self.handshake(child));
            match started {
                Ok(()) => return Ok(()),
                // It lost a race to another holder of this session, which
                // listens now: connect to that one.
                Err(_) if std::os::unix::net::UnixStream::connect(&self.socket).is_ok() => {
                    return Ok(());
                }
                Err(error) => {
                    // A standalone holder that answers `--version` but does
                    // not start (a startup error, a crash in serve, a hang
                    // before `ready`, a macOS major it fails on) must not
                    // cost every holder terminal: this daemon runs the
                    // built-in holder from now on.
                    eprintln!(
                        "cmux-tui: the terminal holder {} did not start ({error}); \
                         using the built-in holder",
                        path.display()
                    );
                    self.standalone_failed.store(true, Ordering::Release);
                }
            }
        }
        let child = crate::host_exe::spawn_host_isolated(|command| {
            command.arg("__holder");
            configure(command);
            command.args(crate::terminal_host_runtime::host_owner_args());
        })?;
        self.handshake(child)
    }

    /// Hand a just-started holder its token and wait for its `ready`. A
    /// holder that answers anything else, or nothing in time, is killed and
    /// reaped; one that is ready is reaped whenever it exits while this
    /// daemon runs.
    fn handshake(&self, mut child: cmux_process::Child) -> io::Result<()> {
        match first_line(&mut child, &self.token) {
            Ok(line) if line.trim() == "ready" => {}
            answer => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(match answer {
                    Ok(line) => {
                        io::Error::other(format!("the terminal holder did not start: {line:?}"))
                    }
                    Err(error) => error,
                });
            }
        }
        let _ = std::thread::Builder::new().name("holder-reaper".into()).spawn(move || {
            let _ = child.wait();
        });
        Ok(())
    }
}

/// The grace a CLOSE gives the shell of an abandoned terminal before
/// SIGKILL: a shell's usual hang-up grace.
const ABANDONED_CLOSE_GRACE_MS: u32 = 2000;

/// Write `token` to a just-started holder's stdin and read the first line
/// it prints (`ready` once it listens), waiting at most
/// [`cmux_holder::client::READY_TIMEOUT`]: a holder that hangs before it
/// (and does not exit) must not hold the `connecting` lock, and with it
/// every terminal create and holder restart, for ever.
fn first_line(child: &mut cmux_process::Child, token: &[u8; 32]) -> io::Result<String> {
    let hex: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
    let mut stdin = child.stdin.take().ok_or_else(|| io::Error::other("no holder stdin"))?;
    stdin.write_all(format!("{hex}\n").as_bytes())?;
    drop(stdin);
    let mut stdout = child.stdout.take().ok_or_else(|| io::Error::other("no holder stdout"))?;
    cmux_holder::client::first_line_within(&mut stdout, cmux_holder::client::READY_TIMEOUT)
}

/// The standalone holder this daemon starts, when it has one whose wire
/// range it speaks (`cmux-holder --version`).
pub(crate) fn standalone_holder() -> Option<PathBuf> {
    crate::host_exe::holder_executable(&|answer| {
        cmux_holder::parse_version_line(answer).is_some_and(|(min, max)| {
            min <= cmux_holder::wire::VERSION && max >= cmux_holder::wire::MIN_VERSION
        })
    })
}

/// Make the standalone holder's copy and run its `--version` on a
/// background thread, so the first terminal of a session does not pay for
/// the copy, its hash and its first exec. Only with the holder model on.
/// A daemon calls it when it starts serving (unit tests start none).
#[cfg(not(test))]
pub(crate) fn prepare_in_background() {
    if !super::enabled() {
        return;
    }
    let _ = std::thread::Builder::new().name("cmux-holder-exe".into()).spawn(|| {
        let _ = standalone_holder();
    });
}

/// `/tmp/cmux-hd-<uid>/<hash of the host root>.sock`: short enough for
/// `sun_path`, one per session, in a 0700 directory of this user.
fn socket_path(host_root: &Path) -> io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    // SAFETY: getuid cannot fail.
    let uid = unsafe { libc::getuid() };
    let dir = PathBuf::from(format!("/tmp/cmux-hd-{uid}"));
    match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let meta = std::fs::symlink_metadata(&dir)?;
    if !meta.is_dir() || meta.uid() != uid || meta.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::other(format!("{} is not a private directory", dir.display())));
    }
    Ok(dir.join(format!("{:016x}.sock", fnv1a(host_root.as_os_str().as_encoded_bytes()))))
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100_0000_01b3)
    })
}

/// The owner token in `<host root>/holder.token` (0600), made on first use.
/// A restarted daemon of the session reads it to reach the same holder.
fn load_or_create_token(host_root: &Path) -> io::Result<[u8; 32]> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::create_dir_all(host_root)?;
    let path = host_root.join("holder.token");
    if let Ok(text) = std::fs::read_to_string(&path)
        && let Some(token) = parse_hex(text.trim())
    {
        return Ok(token);
    }
    let token = *crate::terminal_host::CapabilityToken::random()
        .map_err(|error| io::Error::other(error.to_string()))?
        .as_bytes();
    let hex: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
    let temporary = path.with_extension("tmp");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(hex.as_bytes())?;
    file.sync_all()?;
    std::fs::rename(&temporary, &path)?;
    Ok(token)
}

fn parse_hex(hex: &str) -> Option<[u8; 32]> {
    if hex.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (index, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(index * 2..index * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use std::os::fd::AsRawFd;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::time::Duration;

    use cmux_holder::wire::{self, Frame, Kind, Out};

    use super::*;

    /// The next frame the link sent on `stream`; panics when it ends.
    fn next_frame(stream: &UnixStream, reader: &mut wire::Reader, what: &str) -> Frame {
        loop {
            if let Some(frame) = reader.next_frame().unwrap() {
                return frame;
            }
            match reader.fill(stream.as_raw_fd()) {
                Ok(true) => {}
                other => panic!("the daemon sent no {what}: {other:?}"),
            }
        }
    }

    /// Answer a HELLO with a WELCOME listing `listed` (channel, terminal id).
    fn welcome(stream: &UnixStream, reader: &mut wire::Reader, listed: &[(u32, [u8; 16])]) {
        let hello = next_frame(stream, reader, "HELLO");
        assert_eq!(hello.kind, Kind::Hello as u16);
        let fd = stream.as_raw_fd();
        let count = u32::try_from(listed.len()).unwrap();
        let payload = Out::default().u16(wire::VERSION).u32(count).0;
        wire::send_all(fd, &wire::encode(Kind::Welcome, 0, &payload), &[]).unwrap();
        for (chan, id) in listed {
            // Every LISTED passes its master: a stand-in, a pipe's end.
            let (master, _write_end) = io::pipe().unwrap();
            let entry = Out::default().i32(0).u64(0).u64(0).u8(0).bytes(id).0;
            let frame = wire::encode_with_fds(Kind::Listed, 0, *chan, &entry, 1);
            wire::send_all(fd, &frame, &[master.as_raw_fd()]).unwrap();
        }
    }

    /// Review 2 of pl-holder-11: a reconnect ends only the terminals this
    /// daemon abandoned, never the other terminals the holder lists. Daemon
    /// A's SPAWN of terminal `a` goes out and its link breaks before the
    /// answer (as when another daemon B took the holder and A's SUPERSEDED
    /// stayed behind queued output, so A sees a plain end and reconnects).
    /// The holder then lists `a` (A's abandoned terminal) and two shells B
    /// spawned. A's reconnect sends exactly one CLOSE, for `a`. Before, A
    /// closed every listed terminal that was not in its `live` map: B's
    /// shells too, and a terminal of A's own between its SPAWNED and its
    /// `track`.
    #[test]
    fn a_reconnect_ends_only_the_terminals_this_daemon_abandoned() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        let dir = std::env::temp_dir().join(format!("chs-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("h.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (a, b1, b2) = ([0xa1; 16], [0xb1; 16], [0xb2; 16]);
        let stand_in = std::thread::spawn(move || {
            let (first, _) = listener.accept().unwrap();
            first.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
            let mut reader = wire::Reader::default();
            welcome(&first, &mut reader, &[]);
            let spawn = next_frame(&first, &mut reader, "SPAWN");
            assert_eq!((spawn.kind, spawn.chan), (Kind::Spawn as u16, 1));
            let attach = next_frame(&first, &mut reader, "ATTACH");
            assert_eq!((attach.kind, attach.chan), (Kind::Attach as u16, 1));
            // The link ends before the SPAWNED: a plain end, no SUPERSEDED.
            first.shutdown(std::net::Shutdown::Both).unwrap();
            drop(first);

            let (second, _) = listener.accept().unwrap();
            second.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
            let mut reader = wire::Reader::default();
            welcome(&second, &mut reader, &[(1, a), (2, b1), (3, b2)]);
            let mut closed = Vec::new();
            loop {
                let frame = next_frame(&second, &mut reader, "the test's SIGNAL");
                match Kind::from_u16(frame.kind) {
                    Some(Kind::Close) => closed.push(frame.chan),
                    Some(Kind::Signal) if frame.chan == 999 => break,
                    _ => {}
                }
            }
            (closed, second)
        });

        let service = Arc::new(HolderService {
            socket,
            token: [0x44; 32],
            link: Mutex::default(),
            connecting: Mutex::new(()),
            next_chan: AtomicU32::new(1),
            live: Mutex::default(),
            claiming: RwLock::new(()),
            abandoned: Mutex::default(),
            listed: Mutex::default(),
            superseded: AtomicBool::new(false),
            standalone_failed: AtomicBool::new(false),
        });
        let request = SpawnRequest { id: a, argv: vec![b"/bin/sh".to_vec()], ..Default::default() };
        assert!(service.spawn(&request, b"").is_err(), "the link broke before the SPAWNED");
        // The holder-restart thread or this call reconnects; either way the
        // link comes back only after the reconnect's CLOSEs went out.
        let link = service.link().expect("the reconnect to the same holder");
        link.signal(999, 0).unwrap();
        let (closed, second) = stand_in.join().expect("the stand-in saw the test's SIGNAL");
        assert_eq!(closed, vec![1], "only A's abandoned terminal is closed, not B's shells");
        assert_eq!(
            *service.abandoned.lock().unwrap(),
            HashMap::from([(1, a)]),
            "a terminal the holder still lists stays abandoned until it is gone"
        );

        // No restart may launch a holder once the stand-in's link ends.
        service.superseded.store(true, Ordering::Release);
        drop(link);
        drop(service);
        drop(second);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
