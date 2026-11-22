//! The daemon's holder for one terminal host root: start or reach it, spawn
//! terminals on it, and hand every live terminal to a new holder after a
//! holder crash.

use std::collections::HashMap;
use std::io::{self, Write};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock, Weak};
use std::time::{Duration, Instant};

use cmux_holder::client::{PendingClient, link_taken_before_the_answer};
use cmux_holder::link::{HolderLink, LinkEnd, TerminalSink};
use cmux_holder::{Listed, SpawnRequest};

use super::{HolderSink, HolderTerminal};
use crate::panic_free::RecoverPoison;

mod launch;

#[cfg(not(test))]
pub(crate) use launch::prepare_in_background;

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
    /// A connect the holder took and did not answer while its caller waited
    /// ([`Self::connect`]): the next connect waits on it again, so a holder
    /// that is slow to answer gets one connect from this daemon and not one
    /// for each wait. Read and written under `connecting` only.
    pending: Mutex<Option<PendingClient>>,
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
    /// Spacing of relinks after links that ended before they were healthy
    /// ([`RELINK_HEALTHY`]): a holder that takes every link and drops it
    /// at once is not reconnected in a tight loop.
    relink: Mutex<crate::backoff::Backoff>,
    /// The holder could not be reached or started ([`Self::available`]):
    /// until then a new terminal runs on a host of its own without asking
    /// again, so a broken holder costs one start timeout per window and not
    /// one per terminal.
    unavailable_until: Mutex<Option<Instant>>,
}

/// A link that stayed up this long was healthy: when it ends, the next link
/// is made at once (a holder crash), and the relink spacing starts over.
const RELINK_HEALTHY: Duration = Duration::from_secs(10);
/// First and longest wait before a relink after a link that ended sooner.
const RELINK_INITIAL: Duration = Duration::from_millis(10);
const RELINK_MAX: Duration = Duration::from_secs(5);
/// How long a connect waits for the holder's answer when its caller gives no
/// bound of its own.
const CONNECT_WAIT: Duration = Duration::from_secs(10);
/// After the holder failed to start or answer, new terminals run on hosts of
/// their own this long before a create asks the holder again.
const UNAVAILABLE_RETRY: Duration = Duration::from_secs(30);

/// What one ask of the holder found ([`HolderService::reach`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HolderReach {
    /// The holder answered: its link is open.
    Linked,
    /// The holder took the connect and did not answer while the caller
    /// waited. The connect stays open: the next ask waits on it again.
    Silent,
    /// The holder ended the connect before its answer, or refused it
    /// because another connect took its link in that time. Such a holder may
    /// still run every terminal: a new connect asks it again.
    Dropped,
    /// No holder serves the socket, the holder refused this daemon, or the
    /// ask failed in another way.
    Absent,
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
        let service =
            Arc::new(Self::new(socket_path(host_root)?, load_or_create_token(host_root)?));
        services.insert(host_root.to_path_buf(), service.clone());
        Ok(service)
    }

    /// The service of the holder at `socket`, which takes `token`.
    fn new(socket: PathBuf, token: [u8; 32]) -> Self {
        Self {
            socket,
            token,
            link: Mutex::default(),
            connecting: Mutex::new(()),
            pending: Mutex::default(),
            next_chan: AtomicU32::new(1),
            live: Mutex::default(),
            claiming: RwLock::new(()),
            abandoned: Mutex::default(),
            listed: Mutex::default(),
            superseded: AtomicBool::new(false),
            standalone_failed: AtomicBool::new(false),
            relink: Mutex::new(crate::backoff::Backoff::new(RELINK_INITIAL, RELINK_MAX)),
            unavailable_until: Mutex::default(),
        }
    }

    /// The wait before relinking after a link that was made at `linked_at`
    /// ended: none after a healthy link, else growing with each such end
    /// in a row.
    fn relink_delay(&self, linked_at: Instant) -> Duration {
        let mut relink = self.relink.lock().recover_poison();
        if linked_at.elapsed() >= RELINK_HEALTHY {
            relink.reset();
            return Duration::ZERO;
        }
        relink.next_delay()
    }

    /// Whether a holder of `host_root` may run: its socket exists. Asking
    /// costs no file, process or token when none does.
    pub(crate) fn may_run(host_root: &Path) -> bool {
        socket_path(host_root).is_ok_and(|socket| socket.exists())
    }

    /// The socket of `host_root`'s holder, for a test that stands in for one.
    #[cfg(test)]
    pub(crate) fn socket_for_test(host_root: &Path) -> io::Result<PathBuf> {
        socket_path(host_root)
    }

    /// For a test that stands in for a holder: this service connects no
    /// more, so the end of the stand-in's link starts no real holder.
    #[cfg(test)]
    pub(crate) fn retire_for_test(&self) {
        self.superseded.store(true, Ordering::Release);
    }

    /// The live link: connects to a running holder, else starts one. A link
    /// made after a lost one hands every live terminal to the new holder.
    pub(crate) fn link(self: &Arc<Self>) -> io::Result<Arc<HolderLink>> {
        self.link_or_launch(true)
    }

    /// Whether a new terminal can run on this holder: its link is open, or a
    /// connect or start made one. `false` when the holder failed to start or
    /// answer, or another daemon of the session took it: the caller then
    /// runs the terminal on a host of its own (the per-terminal fallback),
    /// so a holder that cannot start never costs a terminal. After a failure
    /// the holder is not asked again for [`UNAVAILABLE_RETRY`].
    pub(crate) fn available(self: &Arc<Self>) -> bool {
        if self.open_link().is_some() {
            return true;
        }
        if self.superseded.load(Ordering::Acquire) {
            return false;
        }
        if self
            .unavailable_until
            .lock()
            .recover_poison()
            .is_some_and(|until| Instant::now() < until)
        {
            return false;
        }
        match self.link() {
            Ok(_) => {
                *self.unavailable_until.lock().recover_poison() = None;
                true
            }
            Err(error) => {
                eprintln!(
                    "cmux-tui: the terminal holder is not available ({error}); new terminals \
                     run on hosts of their own for {}s",
                    UNAVAILABLE_RETRY.as_secs()
                );
                *self.unavailable_until.lock().recover_poison() =
                    Some(Instant::now() + UNAVAILABLE_RETRY);
                false
            }
        }
    }

    /// The link when one is open. Never connects, launches or waits for a
    /// connect: safe under any surface lock.
    fn open_link(&self) -> Option<Arc<HolderLink>> {
        self.link.lock().recover_poison().link.clone().filter(|link| link.is_open())
    }

    /// Ask the holder for its link without starting one, and wait for its
    /// answer only while `left` is not zero (`left` is asked before each read
    /// of the socket and bounds that read). Says how the ask ended; a
    /// [`HolderReach::Silent`] holder keeps the connect, and a later ask (or
    /// any other use of the link) waits on the same one.
    pub(crate) fn reach(self: &Arc<Self>, left: &dyn Fn() -> Duration) -> HolderReach {
        match self.link_or_launch_while(false, Some(left)) {
            Ok(_) => HolderReach::Linked,
            Err(error) => match error.kind() {
                io::ErrorKind::TimedOut => HolderReach::Silent,
                io::ErrorKind::UnexpectedEof
                | io::ErrorKind::ConnectionReset
                | io::ErrorKind::BrokenPipe => {
                    eprintln!("cmux-tui: the terminal holder ended the connect: {error}");
                    HolderReach::Dropped
                }
                // A holder that wrote this refusal runs: it gave its link
                // to a connect that it read after this one (for example a
                // connect of a daemon that is gone). It is not a holder
                // that refuses this daemon, and not one that is gone.
                _ if link_taken_before_the_answer(&error) => {
                    eprintln!(
                        "cmux-tui: the terminal holder gave its link to another connect \
                         before its answer: {error}"
                    );
                    HolderReach::Dropped
                }
                _ => {
                    eprintln!("cmux-tui: no terminal holder to reach: {error}");
                    HolderReach::Absent
                }
            },
        }
    }

    /// Whether another daemon of the session took the holder: this daemon is
    /// on its way out and does not reach the holder again.
    pub(crate) fn gave_way(&self) -> bool {
        self.superseded.load(Ordering::Acquire)
    }

    /// [`Self::link`]; with `launch` false a holder that does not run is not
    /// started (a restart only asks whether one kept terminals).
    fn link_or_launch(self: &Arc<Self>, launch: bool) -> io::Result<Arc<HolderLink>> {
        self.link_or_launch_while(launch, None)
    }

    /// [`Self::link_or_launch`], waiting for the holder's answer while
    /// `patience` is not zero instead of [`CONNECT_WAIT`].
    fn link_or_launch_while(
        self: &Arc<Self>,
        launch: bool,
        patience: Option<&dyn Fn() -> Duration>,
    ) -> io::Result<Arc<HolderLink>> {
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
        let (link, listed) = match self.connect(patience) {
            Ok(connected) => connected,
            Err(_) if launch => {
                self.launch()?;
                // A holder listens now: a new one, or the one that did not
                // answer (a launch that lost to it also returns `Ok`). The
                // kept connect is dropped either way and one new connect
                // asks.
                drop(self.pending.lock().recover_poison().take());
                self.connect(patience)?
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
    /// surface re-attached and whose registry row `ended` (the shell exited,
    /// or the person closed it), and drop the master dups the holder passed
    /// for them, so the holder does not keep those shells, PTYs and rings for
    /// ever. Any other unclaimed terminal stays held for the next start (QUIT
    /// P0: a start never ends a shell a person still has). Starts no holder.
    pub(crate) fn release_unclaimed(self: &Arc<Self>, ended: impl Fn(&[u8; 16]) -> bool) {
        let Ok(link) = self.link_or_launch(false) else { return };
        let unclaimed: Vec<([u8; 16], Listed)> =
            self.listed.lock().recover_poison().drain().collect();
        for (id, entry) in unclaimed {
            if !ended(&id) {
                eprintln!(
                    "cmux-tui: keep unclaimed holder terminal {} (channel {}): its row has not ended",
                    crate::terminal_host::TerminalId::from_bytes(id).to_hex(),
                    entry.chan
                );
                continue;
            }
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
    pub(crate) fn detach(&self, chan: u32) {
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

    /// Connect to the holder, or go on with the connect an earlier wait left
    /// pending, and wait for its answer: [`CONNECT_WAIT`], or while
    /// `patience` is not zero. A wait that times out keeps the connect for
    /// the next call. A kept connect that ended while nobody waited on it is
    /// replaced with one new connect. Called under `connecting`.
    fn connect(
        self: &Arc<Self>,
        patience: Option<&dyn Fn() -> Duration>,
    ) -> io::Result<(Arc<HolderLink>, Vec<Listed>)> {
        let deadline = Instant::now() + CONNECT_WAIT;
        let wait = || deadline.saturating_duration_since(Instant::now());
        let left: &dyn Fn() -> Duration = match patience {
            Some(patience) => patience,
            None => &wait,
        };
        let hello = || PendingClient::hello(&self.socket, &self.token, cmux_holder::wire::VERSION);
        let (mut pending, mut kept) = match self.pending.lock().recover_poison().take() {
            Some(pending) => (pending, true),
            None => (hello()?, false),
        };
        loop {
            match pending.welcomed(left) {
                Ok(()) => break,
                Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                    *self.pending.lock().recover_poison() = Some(pending);
                    return Err(error);
                }
                Err(error) => {
                    if !std::mem::take(&mut kept) {
                        return Err(error);
                    }
                    eprintln!(
                        "cmux-tui: the terminal holder ended or refused the connect that \
                         waited for its answer ({error}): one new connect"
                    );
                    pending = hello()?;
                }
            }
        }
        let weak = Arc::downgrade(self);
        let linked_at = Instant::now();
        HolderLink::from_pending(
            pending,
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
                // A link that ended before it was healthy waits first, longer
                // each time in a row: a holder that drops every link (or a
                // daemon link it faults at once) would otherwise be linked
                // again in a tight loop of connects, LISTs and threads.
                let delay = service.relink_delay(linked_at);
                let _ =
                    std::thread::Builder::new().name("holder-restart".into()).spawn(move || {
                        if !delay.is_zero() {
                            std::thread::sleep(delay);
                            // Another daemon took the holder meanwhile: this
                            // one is on its way out and keeps its terminals,
                            // as on its own Superseded end.
                            if service.superseded.load(Ordering::Acquire) {
                                return;
                            }
                        }
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

/// The grace a CLOSE gives the shell of an abandoned terminal before
/// SIGKILL: a shell's usual hang-up grace.
const ABANDONED_CLOSE_GRACE_MS: u32 = 2000;

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
    // The name from before NEXT's folder move, so a new daemon reaches the holder an older one started.
    let identity = cmux_agent_pane_policy::build_identity::path_identity(host_root);
    Ok(dir.join(format!("{:016x}.sock", fnv1a(identity.as_os_str().as_encoded_bytes()))))
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
#[path = "service_tests.rs"]
mod tests;
