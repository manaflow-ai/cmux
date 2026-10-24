//! The daemon's holder for one terminal host root: start or reach it, spawn
//! terminals on it, and hand every live terminal to a new holder after a
//! holder crash.
//!
//! One ownership rule holds on every path ([`ownership`]): after any
//! connect, every terminal the holder runs is claimed by a live terminal of
//! this daemon, by an entry kept for a re-attach (the startup pass's, or a
//! terminal this daemon left for the next one at its shutdown), or it is
//! ended. A spawn or re-attach in flight finishes before a new link decides
//! ([`HolderService::claimed_link`]), so what it claims is live by then,
//! and a terminal that ends gives up its claim at one instant
//! ([`HolderService::end`]).

use std::collections::{HashMap, HashSet};
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock, RwLockReadGuard, Weak};

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

/// What this daemon claims on the holder, under one lock so a terminal
/// moves from live to kept at one instant and an ownership pass sees each
/// one in exactly one place.
#[derive(Default)]
struct Owned {
    /// Terminals this daemon runs on the holder, for a re-adoption after a
    /// holder crash.
    live: HashMap<u32, Weak<HolderTerminal>>,
    /// Terminals kept for a re-attach, by terminal id, each with the
    /// custody dups of its master and ring: what the holder ran when the
    /// startup pass first reached it (emptied after that pass,
    /// [`HolderService::release_unclaimed`]) and the terminals this daemon
    /// left for the next one at its shutdown. Kept across a reconnect
    /// (refreshed, or handed to a new holder).
    reserved: HashMap<[u8; 16], Listed>,
    /// The channels of the kept entries this daemon left for the next
    /// daemon ([`HolderService::leave`]): each new link gets their DETACH
    /// once its ownership pass ran (a pass that saw one still live resumed
    /// it) and routes them nowhere.
    left: HashSet<u32>,
}

/// Starts a holder that serves the socket with the owner token and returns
/// once it listens. The service's own is [`launch_holder`] (the holder
/// executable); a test starts its holder its own way.
type Launcher = Box<dyn Fn(&Path, &[u8; 32]) -> io::Result<()> + Send + Sync>;

/// The holder of one terminal host root (one daemon session).
pub(crate) struct HolderService {
    socket: PathBuf,
    token: [u8; 32],
    /// Starts a holder when none runs ([`Reach::Launch`]).
    launcher: Launcher,
    link: Mutex<LinkSlot>,
    /// Serializes connecting, launching and re-adopting. Its holder may
    /// take a surface's terminal lock (a re-adoption's prologue), so no
    /// caller that holds a surface lock may wait for it: a surface's kill
    /// and acknowledgements use [`Self::open_link`] only.
    connecting: Mutex<()>,
    next_chan: AtomicU32,
    owned: Mutex<Owned>,
    /// Held shared by a spawn or re-attach from the moment it takes the
    /// link until the terminal it claims is live (or it failed), and by a
    /// terminal's end while it gives up its claim; exclusively by a new
    /// link's ownership pass: that pass never ends or misses a terminal an
    /// operation in flight is about to claim, and never resumes one whose
    /// CLOSE was just dropped.
    claims: RwLock<()>,
    /// Another daemon of the session took the holder: this one never
    /// connects again, so the two do not take it from each other in turn.
    superseded: AtomicBool,
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
        let service = Self::new(
            socket_path(host_root)?,
            load_or_create_token(host_root)?,
            Box::new(launch_holder),
        );
        services.insert(host_root.to_path_buf(), service.clone());
        Ok(service)
    }

    /// A service for the holder at `socket` with owner `token`, starting a
    /// holder with `launcher` when none runs. Not shared: [`Self::for_root`]
    /// keeps the one service of a host root.
    fn new(socket: PathBuf, token: [u8; 32], launcher: Launcher) -> Arc<Self> {
        Arc::new(Self {
            socket,
            token,
            launcher,
            link: Mutex::default(),
            connecting: Mutex::new(()),
            next_chan: AtomicU32::new(1),
            owned: Mutex::default(),
            claims: RwLock::new(()),
            superseded: AtomicBool::new(false),
        })
    }

    /// Whether a holder of `host_root` may run: its socket exists. Asking
    /// costs no file, process or token when none does.
    pub(crate) fn may_run(host_root: &Path) -> bool {
        socket_path(host_root).is_ok_and(|socket| socket.exists())
    }

    /// The live link: connects to a running holder, else starts one. A link
    /// made after a lost one hands every live terminal to the new holder.
    pub(crate) fn link(self: &Arc<Self>) -> io::Result<Arc<HolderLink>> {
        self.link_or_launch(Reach::Launch)
    }

    /// The open link (made if needed) and a claim on it: no new link's
    /// ownership pass runs until the claim drops, so a terminal the caller
    /// makes live before then is resumed or re-adopted by the next link,
    /// never ended or missed. The claim is taken before the link is read,
    /// and a missing link is made without it (making one takes the claims
    /// exclusively).
    fn claimed_link(self: &Arc<Self>) -> io::Result<(Arc<HolderLink>, RwLockReadGuard<'_, ()>)> {
        loop {
            let claim = self.claims.read().recover_poison();
            if let Some(link) = self.open_link() {
                return Ok((link, claim));
            }
            drop(claim);
            self.link()?;
        }
    }

    /// The link when one is open. Never connects, launches or waits for a
    /// connect: safe under any surface lock.
    fn open_link(&self) -> Option<Arc<HolderLink>> {
        self.link.lock().recover_poison().link.clone().filter(|link| link.is_open())
    }

    /// [`Self::link`] for `reach`: only [`Reach::Launch`] starts a holder
    /// that does not run, and only [`Reach::Startup`] keeps what a first
    /// link lists that nobody claims yet.
    fn link_or_launch(self: &Arc<Self>, reach: Reach) -> io::Result<Arc<HolderLink>> {
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
        // Spawns and re-attaches in flight on the lost link settle first:
        // each terminal they claim is live before this link decides.
        let _claims = self.claims.write().recover_poison();
        let first = self.link.lock().recover_poison().link.is_none();
        let (link, listed) = match self.connect() {
            Ok(connected) => connected,
            Err(_) if reach == Reach::Launch => {
                (self.launcher)(&self.socket, &self.token)?;
                self.connect()?
            }
            Err(error) => return Err(error),
        };
        for entry in &listed {
            self.next_chan.fetch_max(entry.chan + 1, Ordering::AcqRel);
        }
        // The link is published only after its ownership pass, so a CLOSE
        // meanwhile waits for it instead of reaching a holder that does not
        // know the terminal yet.
        self.take_ownership(&link, listed, first && reach == Reach::Startup);
        self.publish(&link);
        Ok(link)
    }

    /// Apply a new link's ownership pass ([`ownership`]) to what it lists,
    /// this daemon's live terminals and its kept entries. The master dups of
    /// what it lists drop here unless an entry keeps them: the daemon keeps
    /// its own custody copies.
    fn take_ownership(&self, link: &HolderLink, listed: Vec<Listed>, reserve_new: bool) {
        // One snapshot of both: a terminal that moves from live to kept
        // meanwhile is in exactly one of them.
        let owned = self.owned.lock().recover_poison();
        let live: HashMap<u32, Arc<HolderTerminal>> = owned
            .live
            .values()
            .filter_map(Weak::upgrade)
            .map(|terminal| (terminal.chan, terminal))
            .collect();
        let reserved_by_chan: HashMap<u32, [u8; 16]> =
            owned.reserved.values().map(|entry| (entry.chan, entry.id)).collect();
        drop(owned);
        let claims = ownership(
            &listed.iter().map(|entry| (entry.chan, entry.id)).collect::<Vec<_>>(),
            &live.values().map(|terminal| (terminal.chan, terminal.id)).collect::<Vec<_>>(),
            &reserved_by_chan.iter().map(|(chan, id)| (*chan, *id)).collect::<Vec<_>>(),
            reserve_new,
        );
        // Live terminals and channels to end first: an adoption reads its
        // surface's screen, under that surface's lock, with no lock of
        // this service held.
        for (chan, claim) in &claims {
            match (claim, live.get(chan)) {
                (Claim::Resume, Some(terminal)) => resume(link, terminal),
                (Claim::Adopt, Some(terminal)) => adopt(link, terminal),
                (Claim::Close, _) => {
                    // A shell's usual hang-up grace; the holder forgets it
                    // once it ended.
                    if let Err(error) = link.close(*chan, 2000) {
                        eprintln!("cmux-tui: end unowned holder terminal {chan}: {error}");
                    }
                }
                _ => {}
            }
        }
        // Kept entries for a new holder leave the map while their ADOPTs are
        // written: no lock of this service is held across a socket write (a
        // surface's leave takes it under its runtime lock). Nothing else
        // takes a kept entry meanwhile: a re-attach waits for this pass.
        let mut handed: Vec<Listed> = {
            let mut owned = self.owned.lock().recover_poison();
            claims
                .iter()
                .filter(|(_, claim)| *claim == Claim::HandOver)
                .filter_map(|(chan, _)| reserved_by_chan.get(chan))
                .filter_map(|id| owned.reserved.remove(id))
                .collect()
        };
        for entry in &mut handed {
            hand_over(link, entry);
        }
        let mut listed: HashMap<u32, Listed> =
            listed.into_iter().map(|entry| (entry.chan, entry)).collect();
        let mut owned = self.owned.lock().recover_poison();
        for entry in handed {
            owned.reserved.insert(entry.id, entry);
        }
        for (chan, claim) in claims {
            match claim {
                Claim::Refresh => {
                    if let (Some(id), Some(entry)) =
                        (reserved_by_chan.get(&chan), listed.remove(&chan))
                    {
                        owned.reserved.insert(*id, entry);
                    }
                }
                Claim::Reserve => {
                    if let Some(entry) = listed.remove(&chan) {
                        owned.reserved.entry(entry.id).or_insert(entry);
                    }
                }
                Claim::Resume | Claim::Adopt | Claim::HandOver | Claim::Close => {}
            }
        }
    }

    /// Make `link` the current link and send the CLOSEs that waited for it,
    /// and the DETACH of every terminal left for the next daemon. The link
    /// is set before the left channels are read, and [`Self::leave`] marks
    /// its channel before it reads the link, so a leave meanwhile either is
    /// in this list or sends its DETACH on this link itself.
    fn publish(&self, link: &Arc<HolderLink>) {
        let pending: Vec<(u32, u32)> = {
            let mut slot = self.link.lock().recover_poison();
            slot.link = Some(link.clone());
            slot.pending_close.iter().map(|(chan, grace_ms)| (*chan, *grace_ms)).collect()
        };
        let left: Vec<u32> = self.owned.lock().recover_poison().left.iter().copied().collect();
        for (chan, grace_ms) in pending {
            if let Err(error) = link.close(chan, grace_ms) {
                eprintln!("cmux-tui: end holder terminal {chan}: {error}");
            }
        }
        for chan in left {
            link.forget(chan);
            let _ = link.detach(chan);
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
        let (link, _claim) = self.claimed_link()?;
        let chan = self.next_chan.fetch_add(1, Ordering::AcqRel);
        let sink = HolderSink::new(0);
        sink.prepend(seed);
        match link.spawn(chan, request, sink.clone() as Arc<dyn TerminalSink>) {
            Ok(spawned) => {
                Ok(self.track(chan, request.id, spawned.pid, (spawned.master, spawned.ring), sink))
            }
            Err(error) => {
                // The holder may run it anyway: a SPAWNED after the wait
                // gave up, or one the lost link never carried. A CLOSE on
                // this link ends it whenever it appears; a link that is
                // gone takes it along, and the next link's ownership pass
                // ends the channel, which no live terminal claims.
                if link.is_open()
                    && let Err(close_error) = link.close(chan, 0)
                {
                    eprintln!("cmux-tui: end failed holder spawn {chan}: {close_error}");
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
        let (link, _claim) = self.claimed_link()?;
        let (entry, custody) = {
            let mut owned = self.owned.lock().recover_poison();
            let Some(mut entry) = owned.reserved.remove(id) else { return Ok(None) };
            let Some(custody) = entry.master.take() else {
                // Never from a listing (it carries the master): left to the
                // startup pass's release, which ends it.
                owned.reserved.insert(*id, entry);
                return Err(io::Error::other("the holder listed a terminal without its master"));
            };
            // Live again (a next daemon in this process): no link detaches it.
            owned.left.remove(&entry.chan);
            (entry, custody)
        };
        // A shell that ended while no daemon ran still re-attaches: its last
        // output replays and the holder's EXIT records its real status.
        let sink = HolderSink::new(entry.oldest);
        if entry.oldest > 0 {
            // The ring's first byte may be inside an escape sequence or a
            // UTF-8 character the ring dropped the start of.
            sink.prepend(&[super::sink::CANCEL]);
        }
        // Live before its ATTACH: a link that breaks meanwhile is followed
        // by one whose ownership pass resumes or re-adopts it.
        let terminal = self.track(entry.chan, *id, entry.pid, (custody, entry.ring), sink.clone());
        if let Err(error) = link.attach(entry.chan, entry.oldest, sink as Arc<dyn TerminalSink>) {
            eprintln!("cmux-tui: re-attach holder terminal {}: {error}", entry.chan);
        }
        Ok(Some(terminal))
    }

    /// Whether the holder ran terminal `id` (running or ended) when this
    /// daemon reached it.
    pub(crate) fn lists(self: &Arc<Self>, id: &[u8; 16]) -> bool {
        self.link_or_launch(Reach::Startup).is_ok()
            && self.owned.lock().recover_poison().reserved.contains_key(id)
    }

    /// After the startup pass: end every terminal the holder runs that no
    /// surface re-attached (its registry row ended, was removed, or never
    /// ran), and drop the master dups the holder passed for them. Without
    /// this the holder would keep those shells, their PTYs and their rings
    /// for ever. Starts no holder.
    pub(crate) fn release_unclaimed(self: &Arc<Self>) {
        let link = self.link_or_launch(Reach::Existing);
        let _claims = self.claims.write().recover_poison();
        let unclaimed: Vec<Listed> = {
            let mut owned = self.owned.lock().recover_poison();
            owned.left.clear();
            owned.reserved.drain().map(|(_, entry)| entry).collect()
        };
        // No holder runs: their master dups close here, and with the dead
        // holder's gone the shells hang up.
        let Ok(link) = link else { return };
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
    /// sent: a new holder gets a fresh replay with the master.
    pub(super) fn snapshot(&self, chan: u32, base: u64, replay: &[u8]) {
        if let Some(link) = self.open_link() {
            let _ = link.snapshot(chan, base, replay);
        }
    }

    /// Hang up `chan`'s terminal; SIGKILL its groups after `grace_ms`.
    /// Never connects or starts a holder, so a surface may call it under
    /// its own locks. The CLOSE is kept until the terminal ends
    /// ([`Self::end`]) and each new link (a holder restart) sends it again;
    /// without an open link this returns an error, so the caller can signal
    /// the shell itself.
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

    /// The daemon leaves `terminal` running on the holder for the next
    /// daemon (its shutdown): it stops being live and is kept like a
    /// startup-pass entry, with dups of its custody master and ring. Every
    /// other terminal still streams and reconnects as before; a new link's
    /// pass keeps this one on the same holder and hands it to a new holder
    /// unattached, never ends it, and the link gets its DETACH. Never waits
    /// for a connect (a surface calls it under its runtime lock): the move
    /// takes the one lock of [`Owned`], so a pass sees the terminal live or
    /// kept, not neither.
    pub(super) fn leave(&self, terminal: &HolderTerminal) {
        let chan = terminal.chan;
        let master = terminal.custody.try_clone();
        if let Err(error) = &master {
            // Then only the same holder keeps it for the next daemon.
            eprintln!("cmux-tui: keep holder terminal {chan} for the next daemon: {error}");
        }
        let ring = terminal
            .ring
            .lock()
            .recover_poison()
            .as_ref()
            .and_then(|segment| segment.try_clone().ok());
        let received = terminal.sink.received();
        let entry = Listed {
            chan,
            id: terminal.id,
            pid: terminal.pid,
            oldest: received,
            end: received,
            exited: false,
            master: master.ok(),
            ring,
        };
        {
            let mut owned = self.owned.lock().recover_poison();
            owned.live.remove(&chan);
            owned.reserved.insert(terminal.id, entry);
            owned.left.insert(chan);
        }
        // After the mark: a link published meanwhile is the one read here,
        // or its publish reads the mark ([`Self::publish`]).
        if let Some(link) = self.open_link() {
            link.forget(chan);
            let _ = link.detach(chan);
        }
    }

    /// This daemon is done with `chan`: its terminal ended, or its surface
    /// never came to be. CLOSE it (now, or on the next link) and stop
    /// tracking it, under a claim, so a new link's pass sees it either still
    /// live (and the CLOSE goes to that link once it is published) or gone
    /// (and the pass ends it as nobody's). Before, a pass could resume it
    /// in between and its CLOSE was dropped: the ended terminal and its ring
    /// stayed on the holder.
    pub(crate) fn end(&self, chan: u32) {
        let _claim = self.claims.read().recover_poison();
        let _ = self.close(chan, 0);
        self.untrack(chan);
    }

    /// Stop tracking `chan` ([`Self::end`]).
    fn untrack(&self, chan: u32) {
        self.owned.lock().recover_poison().live.remove(&chan);
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
        self.owned.lock().recover_poison().live.insert(chan, Arc::downgrade(&terminal));
        terminal
    }

    /// End every live terminal as lost: no holder can stream it.
    fn lose_all(&self) {
        let live: Vec<_> =
            self.owned.lock().recover_poison().live.values().filter_map(Weak::upgrade).collect();
        for terminal in live {
            terminal.sink.lose();
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
}

/// Start a holder and wait until it listens: the standalone
/// `cmux-holder` (std and libc only, its own content-addressed copy on
/// macOS, `crate::host_exe::holder_executable`) when the daemon has one
/// that speaks its wire, else the holder built into the host executable
/// (`cmux-tui-host __holder`).
fn launch_holder(socket: &Path, token: &[u8; 32]) -> io::Result<()> {
    let configure = |command: &mut std::process::Command| {
        command
            .arg("--socket")
            .arg(socket)
            // Every shell gets back the open-file limit cmux started
            // with; the holder keeps the daemon's raised one.
            .envs(
                cmux_pty::original_open_file_limit()
                    .map(|soft| (cmux_holder::NOFILE_SOFT_ENV, soft.to_string())),
            )
            // A DEV build's, debug build's or test's grace, as its hosts
            // get: the holder ends its terminals once no daemon came back.
            .envs(
                crate::terminal_host_runtime::spawned_orphan_grace()
                    .map(|grace| (cmux_holder::ORPHAN_GRACE_ENV, grace.as_millis().to_string())),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
    };
    let standalone = standalone_holder().and_then(|path| {
        use std::os::unix::process::CommandExt;
        let mut command = std::process::Command::new(&path);
        command.arg0(crate::host_exe::HOLDER_NAME);
        configure(&mut command);
        command
            .spawn()
            .inspect_err(|error| {
                eprintln!("cmux-tui: start the terminal holder {}: {error}", path.display());
            })
            .ok()
    });
    let mut child = match standalone {
        Some(child) => child,
        None => crate::host_exe::spawn_host(|command| {
            command.arg("__holder");
            configure(command);
        })?,
    };
    let hex: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
    let mut stdin = child.stdin.take().ok_or_else(|| io::Error::other("no holder stdin"))?;
    stdin.write_all(format!("{hex}\n").as_bytes())?;
    drop(stdin);
    let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no holder stdout"))?;
    let mut line = String::new();
    BufReader::new(stdout).read_line(&mut line)?;
    // Reap the holder if it ever exits while this daemon runs.
    let _ = std::thread::Builder::new().name("holder-reaper".into()).spawn(move || {
        let _ = child.wait();
    });
    if line.trim() != "ready" {
        return Err(io::Error::other(format!("the terminal holder did not start: {line:?}")));
    }
    Ok(())
}

/// Why a link is wanted ([`HolderService::link_or_launch`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Reach {
    /// The startup pass asks what the holder runs: start no holder, and
    /// keep what the first link lists for that pass to re-attach.
    Startup,
    /// The startup pass's release: start no holder.
    Existing,
    /// A spawn, a re-attach or a restart after a holder crash: start a
    /// holder when none runs.
    Launch,
}

/// What a new link does with one terminal it lists, this daemon shows
/// (live) or keeps for the startup pass ([`ownership`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Claim {
    /// A live terminal the holder still runs on its channel (the same
    /// holder): stream it again from the newest byte this daemon has.
    Resume,
    /// A live terminal the holder does not run (a new holder): hand it the
    /// custody master, pid, ring segment and a prologue built at the exact
    /// offset the parser confirmed ([`HolderTerminal::adoption`]). Output
    /// the shell wrote meanwhile waited in its PTY; output the dead holder
    /// read but never sent is in the ring segment.
    Adopt,
    /// A startup-pass entry the holder still runs: keep it, with this
    /// listing's descriptors and offsets.
    Refresh,
    /// A startup-pass entry whose holder died: hand its custody master and
    /// ring to this holder, unattached, for the startup pass to re-attach.
    HandOver,
    /// A listed terminal nobody claims yet, kept for the startup pass.
    Reserve,
    /// A listed terminal nobody claims: end it.
    Close,
}

/// The ownership pass of a new link, the one rule for which of the holder's
/// terminals this daemon owns. `listed` is what the holder runs, `live`
/// what this daemon shows and `reserved` what it keeps for its startup
/// pass, each as (channel, terminal id). A live terminal resumes when the
/// holder runs it on its channel and is adopted otherwise (a new holder); a
/// startup-pass entry is refreshed or handed to a new holder the same way;
/// any other terminal the holder runs is kept for the startup pass when
/// `reserve_new` (the first link that pass makes), else ended. Pure:
/// [`HolderService::take_ownership`] applies it.
fn ownership(
    listed: &[(u32, [u8; 16])],
    live: &[(u32, [u8; 16])],
    reserved: &[(u32, [u8; 16])],
    reserve_new: bool,
) -> Vec<(u32, Claim)> {
    let held: HashMap<u32, [u8; 16]> = listed.iter().copied().collect();
    let same = |(chan, id): &(u32, [u8; 16])| held.get(chan) == Some(id);
    let mut claims = Vec::new();
    for terminal in live {
        claims.push((terminal.0, if same(terminal) { Claim::Resume } else { Claim::Adopt }));
    }
    for entry in reserved {
        claims.push((entry.0, if same(entry) { Claim::Refresh } else { Claim::HandOver }));
    }
    // A channel this daemon claims is never ended: if the holder runs
    // another terminal on it, the adoption is refused and the live terminal
    // ends lost (channels are this daemon's, so that never happens).
    let claimed: HashSet<u32> = live.iter().chain(reserved).map(|(chan, _)| *chan).collect();
    for (chan, _) in listed.iter().filter(|(chan, _)| !claimed.contains(chan)) {
        claims.push((*chan, if reserve_new { Claim::Reserve } else { Claim::Close }));
    }
    claims
}

/// Stream `terminal` again on `link`, the same holder after the link
/// dropped, from the newest byte this daemon received.
fn resume(link: &HolderLink, terminal: &Arc<HolderTerminal>) {
    let sink = terminal.sink.clone() as Arc<dyn TerminalSink>;
    if let Err(error) = link.resume(terminal.chan, terminal.sink.received(), sink) {
        eprintln!("cmux-tui: resume holder terminal {}: {error}", terminal.chan);
    }
}

/// Hand `terminal` to the new holder of `link` ([`Claim::Adopt`]).
fn adopt(link: &HolderLink, terminal: &Arc<HolderTerminal>) {
    let adoption = terminal.adoption(link.has_rings(), super::terminal::ADOPT_PROLOGUE_MAX_BYTES);
    let sink = terminal.sink.clone() as Arc<dyn TerminalSink>;
    if let Err(error) = link.adopt(
        terminal.chan,
        &terminal.id,
        (terminal.pid, adoption.base, adoption.resume),
        (&terminal.custody, adoption.ring.as_ref()),
        (sink, &adoption.prologue),
    ) {
        eprintln!("cmux-tui: hand terminal {} to the new holder: {error}", terminal.chan);
    }
}

/// Hand a startup-pass entry whose holder died to the new holder of `link`
/// ([`Claim::HandOver`]): its custody master and (when the link takes
/// rings) the dead holder's ring, which the new holder continues. Without
/// the ring the new holder starts a fresh one at the entry's end, so the
/// entry then starts there too.
fn hand_over(link: &HolderLink, entry: &mut Listed) {
    let Some(master) = entry.master.as_ref() else { return };
    let ring = entry.ring.as_ref().filter(|_| link.has_rings());
    let offsets = (entry.pid, entry.oldest, entry.end);
    match link.hand_over(entry.chan, &entry.id, offsets, (master, ring), &[]) {
        Ok(()) if ring.is_none() => entry.oldest = entry.end,
        Ok(()) => {}
        Err(error) => {
            eprintln!("cmux-tui: hand holder terminal {} to the new holder: {error}", entry.chan);
        }
    }
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
mod tests;
