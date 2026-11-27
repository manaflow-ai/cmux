//! One terminal on the holder, and the local-runtime launch the daemon
//! parses it on.

use std::io::{self, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::sync::Arc;

use cmux_holder::ExitStatus;
use cmux_pty::ChildKiller;

use super::sink::{AdoptionCuts, Pending, SinkEnd, SnapshottingReader};
use super::{HolderService, HolderSink};
use crate::surface::spawn::LocalLaunch;
use crate::terminal_end::TerminalEnd;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// A shell the holder runs for this daemon.
pub(crate) struct HolderTerminal {
    /// The holder's channel for it.
    pub(crate) chan: u32,
    /// The terminal id the holder lists it under.
    pub(crate) id: [u8; 16],
    /// The shell's pid (leader of its session and process group).
    pub(crate) pid: i32,
    /// The daemon's dup of the PTY master: input, resize, and the copy that
    /// keeps the shell alive if the holder dies.
    pub(crate) custody: OwnedFd,
    /// The daemon's dup of the terminal's ring segment: the copy that keeps
    /// the output a dying holder read but never sent, handed to the next
    /// holder. Always the segment the current holder writes (its SPAWNED,
    /// LISTED or ADOPTED said so); `None` while the terminal runs on a
    /// holder that passes none, or whose segment this daemon cannot know (a
    /// version 4 holder that adopted it), and once the terminal ended.
    pub(super) ring: std::sync::Mutex<Option<OwnedFd>>,
    pub(crate) sink: Arc<HolderSink>,
    pub(super) service: Arc<HolderService>,
    /// A VT replay of the daemon's parsed screen, handed to a new holder
    /// after a holder crash as the terminal's prologue.
    pub(super) replay: std::sync::Mutex<Option<Replay>>,
}

/// Builds a terminal's VT replay of at most the given bytes, empty when it
/// does not fit (its surface registers it). It calls the second argument
/// once while it holds the terminal lock, at the instant the replay shows:
/// a caller reads there what the parser has not parsed yet
/// ([`super::HolderSink::pending`]).
pub(crate) type Replay = Box<dyn Fn(usize, &mut dyn FnMut()) -> Vec<u8> + Send + Sync>;

/// What a new holder gets for a terminal after a holder crash.
pub(super) struct Adoption {
    /// Where the prologue's screen is in the holder's offsets.
    pub(super) base: u64,
    /// Where the stream to this daemon continues (the newest byte it has).
    pub(super) resume: u64,
    pub(super) prologue: Vec<u8>,
    /// A dup of the ring segment to hand over, when the holder takes one.
    pub(super) ring: Option<OwnedFd>,
}

/// The largest prologue handed to a new holder with the master: it must
/// fit one ADOPT frame (1 MiB) with room to spare.
pub(super) const ADOPT_PROLOGUE_MAX_BYTES: usize = 768 * 1024;
/// The largest screen snapshot sent while the terminal runs: the screen,
/// its modes and the newest history that fits. It goes over the shared
/// link once per burst of output, so it stays small.
pub(super) const SNAPSHOT_MAX_BYTES: usize = 128 * 1024;

impl HolderTerminal {
    /// The daemon exits and leaves the shell to the holder: the reader and
    /// the wait end without recording an end, and the holder hears DETACH
    /// (the link's end is no strike against the terminal's stream).
    pub(crate) fn detach(&self) {
        self.sink.detach();
        self.service.detach(self.chan);
        self.service.untrack(self.chan);
    }

    /// How to replay the screen for a new holder (the surface sets it).
    pub(crate) fn set_replay(&self, replay: Replay) {
        *self.replay.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(replay);
    }

    /// The screen replay (at most `max_bytes`); empty when none is known
    /// or it does not fit. Called on the reader thread (a snapshot), where
    /// the parser has parsed every byte it took.
    pub(super) fn prologue(&self, max_bytes: usize) -> Vec<u8> {
        self.replay_at(max_bytes, &mut || {})
    }

    fn replay_at(&self, max_bytes: usize, at_point: &mut dyn FnMut()) -> Vec<u8> {
        let replay = self.replay.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match replay.as_ref() {
            Some(replay) => replay(max_bytes, at_point),
            None => {
                at_point();
                Vec::new()
            }
        }
    }

    /// Hand the holder a fresh snapshot of the screen now, at the offset the
    /// parser confirmed (read at the replay's instant): after clear-history,
    /// so a restarted daemon restores the cleared screen and only the output
    /// since, not the history the older snapshot and ring still hold.
    pub(crate) fn resnapshot(&self) {
        let mut base = None;
        let replay = self.replay_at(SNAPSHOT_MAX_BYTES, &mut || {
            base = Some(self.sink.pending().confirmed);
        });
        if let Some(base) = base.filter(|_| !replay.is_empty()) {
            let reached = self.service.snapshot(self.chan, base, &replay);
            self.sink.snapshot_taken(base, reached);
        }
    }

    /// What a new holder needs to take this terminal over after the old
    /// holder died (the replay race, holder item 1). The screen replay and
    /// the bytes the parser has not finished are read at one instant, under
    /// the terminal lock, so neither a chunk the reader holds nor one still
    /// queued is lost or played twice:
    ///
    /// - `rings` (the new holder takes ring segments) and the terminal has
    ///   one: the new holder continues the dead holder's ring. The prologue
    ///   is the screen at the offset the parser confirmed, with the seed the
    ///   parser has not finished; a restarted daemon then replays the ring
    ///   from there, and this daemon gets from the newest byte it has the
    ///   bytes the dead holder read but never sent.
    /// - otherwise the prologue is the screen plus every byte not parsed
    ///   yet, at the newest byte received; with `rings` a fresh segment
    ///   starts there, so the next crash loses nothing either.
    ///
    /// `max_bytes` bounds the prologue (one ADOPT frame). The custody
    /// segment does not change here: the new holder's answer says which
    /// segment it writes ([`Self::keep_ring`]).
    pub(super) fn adoption(&self, rings: bool, max_bytes: usize) -> Adoption {
        // An earlier adoption nobody answered left its segment with nobody.
        self.sink.settle_unanswered_adoption();
        // No new output arrives meanwhile (the old link ended), so what is
        // pending now bounds what is pending at the replay's instant.
        let estimate = self.sink.pending();
        // A kept segment that ends before the newest byte received is stale
        // (with the ADOPTED answer only a segment no holder wrote since, say
        // after an ADOPT that failed on its way): continuing it would number
        // new output below what was received, and the sink would drop it.
        // Such a terminal gets a fresh segment at the newest byte instead.
        let custody = self
            .ring
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .and_then(|segment| segment.try_clone().ok());
        let kept = custody
            .as_ref()
            .filter(|_| rings)
            .filter(|segment| continues_at(segment, estimate.received))
            .and_then(|segment| segment.try_clone().ok());
        // Before the replay's instant, so a prologue that carries every
        // pending byte carries the CAN too.
        self.mark_lost_output(custody.as_ref(), kept.is_some(), rings, estimate.received);
        let extra = if kept.is_some() { estimate.head.len() } else { estimate.all.len() };
        let mut pending = None;
        let mut replay = self.replay_at(max_bytes.saturating_sub(extra), &mut || {
            pending = Some(self.sink.pending());
        });
        let Pending { confirmed, received, head, all } = pending.unwrap_or(estimate);
        if let Some(ring) = kept {
            replay.extend_from_slice(&head);
            return Adoption {
                base: confirmed,
                resume: received,
                prologue: fit(replay, max_bytes),
                ring: Some(ring),
            };
        }
        replay.extend_from_slice(&all);
        let replay = fit(replay, max_bytes);
        let ring = rings
            .then(|| cmux_holder::ring::create_segment(received, cmux_holder::holder::RING_BYTES))
            .and_then(Result::ok);
        Adoption { base: received, resume: received, prologue: replay, ring }
    }

    /// Output the dead holder took from the PTY that no holder hands on is
    /// lost, and the sink is told where ([`super::HolderSink::cut_at`]), so
    /// the stream is never spliced silently there. `segment` is the custody
    /// copy of the dead holder's ring, `kept` whether the ADOPT hands it to
    /// the new holder, `received` the newest byte this daemon has:
    ///
    /// - a new holder that continues the segment loses only a read the dead
    ///   holder died inside, at the end of its ring
    ///   (`cmux_holder::ring::interrupted_read`);
    /// - a fresh ring (the new holder takes no segment, or refuses the one
    ///   it is handed) starts at `received`, so everything the dead holder
    ///   read past it is lost too.
    ///
    /// Not kept, the loss is marked now. Kept, the new holder may still
    /// refuse the segment: the sink marks the loss its ADOPTED answer names
    /// ([`super::HolderSink::expect_adoption`]). On a holder that answers
    /// (`rings`) the plan is made either way, so an adoption whose answer
    /// never comes is cut at `received` by the next one. A stale segment
    /// (one that ends before `received`) names no loss.
    fn mark_lost_output(&self, segment: Option<&OwnedFd>, kept: bool, rings: bool, received: u64) {
        let interrupted =
            segment.and_then(|segment| cmux_holder::ring::interrupted_read(segment).ok().flatten());
        let end =
            segment.map(|segment| cmux_holder::ring::segment_end(segment).unwrap_or(received));
        let fresh = (end.is_some_and(|end| end > received)
            || interrupted.is_some_and(|at| at >= received))
        .then_some(received);
        if !kept && let Some(at) = fresh {
            self.sink.cut_at(at);
        }
        if rings {
            self.sink.expect_adoption(AdoptionCuts {
                resume: received,
                handed_end: end.filter(|_| kept),
                continued: interrupted.filter(|_| kept),
                fresh: fresh.filter(|_| kept),
            });
        }
    }

    /// Keep `segment` as the custody copy of the terminal's ring: the one
    /// the new holder said it writes after an adoption (`None`: none this
    /// daemon may hand on). A terminal that ended keeps none.
    pub(super) fn keep_ring(&self, segment: Option<OwnedFd>) {
        let mut ring = self.ring.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // Under the ring's lock: an end that takes the segment after this
        // takes this one, and one before it is seen here.
        *ring = segment.filter(|_| !self.sink.has_ended());
    }

    /// The terminal ended: no holder takes it over again, so the custody
    /// dup of its ring segment (up to a MiB of output no process maps)
    /// goes, and the holder may forget it.
    fn end(&self) {
        let _ = self.service.close(self.chan, 0);
        self.service.untrack(self.chan);
        self.ring.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    }

    pub(crate) fn is_detached(&self) -> bool {
        self.sink.is_detached()
    }

    /// Hang up the shell (an explicit close). Runs under the surface's
    /// runtime lock, so it only writes to a link that is already open:
    /// it never connects, starts a holder or re-adopts (which takes
    /// terminal locks). Without an open link (the holder died and its
    /// restart has not finished) the CLOSE waits for the next link and the
    /// daemon hangs up the shell's groups itself: same user, and it keeps
    /// the master.
    fn hang_up(&self) {
        if self.service.close(self.chan, 2000).is_err() {
            for signal in [libc::SIGHUP, libc::SIGTERM] {
                cmux_holder::pty::signal_terminal(self.pid, self.custody.as_raw_fd(), signal);
            }
        }
    }
}

/// Whether the kept ring `segment` may go to a new holder for a terminal
/// whose newest received byte ends at `received`: its writer published at
/// least that far. One that ends before is stale, and a holder continuing it
/// would number new output below `received`.
fn continues_at(segment: &OwnedFd, received: u64) -> bool {
    cmux_holder::ring::segment_end(segment).is_ok_and(|end| end >= received)
}

/// `prologue`, or a lone CAN when it does not fit one ADOPT frame (only a
/// seed bigger than the frame that the parser has not finished): the live
/// screen keeps everything, a later restart starts from the ring.
fn fit(prologue: Vec<u8>, max_bytes: usize) -> Vec<u8> {
    if prologue.len() <= max_bytes { prologue } else { vec![super::sink::CANCEL] }
}

/// The local-runtime launch of `terminal`: output from the holder's stream,
/// input and resize on the custody master, kill through the holder, and the
/// end the holder reports.
pub(crate) fn holder_local_launch(
    terminal: &Arc<HolderTerminal>,
    command: Vec<String>,
    cwd: Option<String>,
) -> anyhow::Result<LocalLaunch> {
    let master = cmux_pty::adopt_master(terminal.custody.try_clone()?)?;
    let writer = Box::new(WaitingWriter {
        inner: master.take_writer()?,
        master: terminal.custody.try_clone()?,
    });
    let waited = terminal.clone();
    let snapshotted = Arc::downgrade(terminal);
    let reader = SnapshottingReader {
        sink: terminal.sink.clone(),
        snapshot: Box::new(move |base| {
            let Some(terminal) = snapshotted.upgrade() else { return true };
            let replay = terminal.prologue(SNAPSHOT_MAX_BYTES);
            // An empty replay cannot be made better by asking again.
            replay.is_empty() || terminal.service.snapshot(terminal.chan, base, &replay)
        }),
        terminal_id: crate::terminal_host::TerminalId::from_bytes(terminal.id).to_hex(),
    };
    Ok(LocalLaunch {
        master,
        reader: Box::new(reader),
        writer,
        killer: Box::new(HolderKiller(terminal.clone())),
        wait: Box::new(move || {
            let end = waited.sink.wait_end();
            if end != SinkEnd::Detached {
                waited.end();
            }
            terminal_end(end)
        }),
        pid: u32::try_from(terminal.pid).ok(),
        command,
        cwd,
        supports_clear_history_key_fallback: true,
        holder: Some(terminal.clone()),
    })
}

fn terminal_end(end: SinkEnd) -> TerminalEnd {
    match end {
        SinkEnd::Exited(ExitStatus::Exited(code)) => {
            TerminalEnd::ProcessEnded(TerminalExit::now(TerminalExitOutcome::Exit { code }))
        }
        SinkEnd::Exited(ExitStatus::Signaled(signal)) => {
            TerminalEnd::ProcessEnded(TerminalExit::now(TerminalExitOutcome::Signal {
                signal,
                core_dumped: false,
            }))
        }
        SinkEnd::Exited(ExitStatus::Unobserved) => {
            TerminalEnd::ProcessEnded(TerminalExit::unknown(crate::terminal_end::EXIT_UNOBSERVED))
        }
        SinkEnd::Lost => TerminalEnd::host_lost("holder-lost"),
        // Detached for a daemon shutdown: never recorded (exit_state).
        SinkEnd::Detached => TerminalEnd::host_lost("holder-detached"),
    }
}

/// The surface's input writer on the custody master. The holder reads that
/// master non-blocking, and `O_NONBLOCK` belongs to the open file
/// description every dup shares, so a write the PTY's input queue (about 1
/// KiB on macOS) cannot take returns `WouldBlock`. This writer then waits
/// for room, as a write on a blocking master does: a paste or a burst of
/// mouse reports is never cut.
struct WaitingWriter {
    inner: Box<dyn Write + Send>,
    /// A dup of the master to wait on.
    master: OwnedFd,
}

impl Write for WaitingWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        loop {
            match self.inner.write(buffer) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait_writable(self.master.as_raw_fd())?;
                }
                result => return result,
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        loop {
            match self.inner.flush() {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait_writable(self.master.as_raw_fd())?;
                }
                result => return result,
            }
        }
    }
}

/// Block until the master takes input again. A master whose terminal ended
/// is an error rather than a wait that never ends.
fn wait_writable(master: std::os::fd::RawFd) -> io::Result<()> {
    loop {
        let mut poll_fd = libc::pollfd { fd: master, events: libc::POLLOUT, revents: 0 };
        // SAFETY: polls one live pollfd; -1 waits like a blocking write.
        let ready = unsafe { libc::poll(&mut poll_fd, 1, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if poll_fd.revents & libc::POLLOUT == 0
            && poll_fd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
        {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "the terminal's PTY closed"));
        }
        return Ok(());
    }
}

struct HolderKiller(Arc<HolderTerminal>);

impl ChildKiller for HolderKiller {
    fn kill(&mut self) -> io::Result<()> {
        self.0.hang_up();
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(Self(self.0.clone()))
    }
}

impl std::fmt::Debug for HolderKiller {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HolderKiller").field("chan", &self.0.chan).finish()
    }
}

#[cfg(test)]
mod tests {
    use std::io::Read;
    use std::os::fd::FromRawFd;

    use super::*;

    /// A raw PTY pair whose master is non-blocking, as the holder leaves it.
    fn nonblocking_pty() -> (OwnedFd, std::fs::File) {
        let (mut master, mut slave) = (-1, -1);
        // SAFETY: out-pointers to live locals; default termios and size.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(opened, 0, "openpty: {}", io::Error::last_os_error());
        // SAFETY: openpty returned two fresh descriptors this test owns.
        let (master, slave) =
            unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
        // SAFETY: termios calls on the slave this test owns; fcntl on its master.
        unsafe {
            let mut termios: libc::termios = std::mem::zeroed();
            assert_eq!(libc::tcgetattr(slave.as_raw_fd(), &mut termios), 0);
            libc::cfmakeraw(&mut termios);
            assert_eq!(libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios), 0);
            let flags = libc::fcntl(master.as_raw_fd(), libc::F_GETFL);
            libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
        (master, std::fs::File::from(slave))
    }

    #[test]
    fn a_kept_ring_segment_that_ends_before_the_received_offset_is_not_handed_on() {
        let segment = cmux_holder::ring::create_segment(100, 4096).unwrap();
        assert!(continues_at(&segment, 100), "a segment at the received offset continues");
        assert!(continues_at(&segment, 40), "a segment past the received offset continues");
        assert!(!continues_at(&segment, 101), "a segment behind the received offset is stale");
    }

    /// An ended terminal drops the custody dup of its ring segment (no
    /// holder takes it over again; up to a MiB of output would stay mapped
    /// by nobody for the surface's life), and an adoption's late answer does
    /// not bring one back.
    #[test]
    fn an_ended_terminal_drops_its_ring_segment_for_good() {
        use cmux_holder::link::TerminalSink;
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        let root = std::env::temp_dir()
            .join(format!("cmux-holder-ring-drop-{}-{stamp}", std::process::id()));
        let service = HolderService::for_root(&root).unwrap();
        let (master, _slave) = nonblocking_pty();
        let sink = HolderSink::new(0);
        let segment = || cmux_holder::ring::create_segment(0, 4096).unwrap();
        let terminal = Arc::new(HolderTerminal {
            chan: 1,
            id: [1; 16],
            pid: 0,
            custody: master,
            ring: std::sync::Mutex::new(Some(segment())),
            sink: sink.clone(),
            service,
            replay: std::sync::Mutex::new(None),
        });
        let launch = holder_local_launch(&terminal, Vec::new(), None).unwrap();
        sink.exit(ExitStatus::Exited(0), 0);
        let wait = launch.wait;
        let _ = wait();
        assert!(terminal.ring.lock().unwrap().is_none(), "the ended terminal kept its segment");
        terminal.keep_ring(Some(segment()));
        assert!(terminal.ring.lock().unwrap().is_none(), "an ended terminal took a segment back");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A terminal on a holder that is gone, with `segment` as its custody
    /// ring and `received` as every byte it received, from offset 0.
    fn orphaned_terminal(
        name: &str,
        segment: OwnedFd,
        received: &[u8],
    ) -> (Arc<HolderTerminal>, std::path::PathBuf) {
        use cmux_holder::link::TerminalSink;
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        let root = std::env::temp_dir().join(format!("{name}-{}-{stamp}", std::process::id()));
        let (master, _slave) = nonblocking_pty();
        let sink = HolderSink::new(0);
        sink.data(0, received);
        let terminal = Arc::new(HolderTerminal {
            chan: 1,
            id: [1; 16],
            pid: 0,
            custody: master,
            ring: std::sync::Mutex::new(Some(segment)),
            sink,
            service: HolderService::for_root(&root).unwrap(),
            replay: std::sync::Mutex::new(None),
        });
        (terminal, root)
    }

    /// Everything the terminal's parser gets, once its stream ended.
    fn parsed(terminal: &HolderTerminal, end: u64) -> Vec<u8> {
        use cmux_holder::link::TerminalSink;
        terminal.sink.exit(ExitStatus::Exited(0), end);
        let mut out = Vec::new();
        super::super::sink::SinkReader(terminal.sink.clone()).read_to_end(&mut out).unwrap();
        out
    }

    /// Review 1 of pl-holder-11: output a dead holder took from the PTY and
    /// no holder hands on is lost, never spliced. A holder killed inside a
    /// PTY read leaves its ring saying so (the adoption here runs while the
    /// read is in flight, as after a holder SIGKILLed there): the parser
    /// gets a CAN at that offset, before the new holder's first byte. And
    /// when the new holder takes no ring segment, the bytes the dead holder
    /// read past what the daemon received are lost: a CAN there too.
    #[test]
    fn output_a_dead_holder_took_and_nobody_hands_on_is_cancelled_not_spliced() {
        use cmux_holder::link::TerminalSink;
        let mut ring = cmux_holder::ring::Ring::new(0, 4096);
        let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
        ring.push(b"0123456789");
        let (terminal, root) = orphaned_terminal("cmux-holder-cut", segment, b"0123456789");
        ring.read_with(64, |room| {
            room[..3].copy_from_slice(b"lst");
            // The holder dies here: the read took 3 bytes, its end is not
            // published. A new holder that takes rings continues at 10.
            let adoption = terminal.adoption(true, ADOPT_PROLOGUE_MAX_BYTES);
            assert!(adoption.ring.is_some(), "the segment goes to the new holder");
            assert_eq!(adoption.resume, 10);
            3
        });
        // The new holder continues the segment: its ADOPTED names its end.
        terminal.sink.adopted(10);
        terminal.sink.data(10, b"new");
        assert_eq!(parsed(&terminal, 13), b"0123456789\x18new", "the lost read was spliced");
        let _ = std::fs::remove_dir_all(&root);

        // The dead holder published 10 bytes, the daemon received 5, and
        // the new holder takes no segment: 5 bytes are gone.
        let mut ring = cmux_holder::ring::Ring::new(0, 4096);
        let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
        ring.push(b"0123456789");
        drop(ring);
        let (terminal, root) = orphaned_terminal("cmux-holder-cut-fresh", segment, b"01234");
        let adoption = terminal.adoption(false, ADOPT_PROLOGUE_MAX_BYTES);
        assert!(adoption.ring.is_none());
        assert_eq!(adoption.resume, 5);
        terminal.sink.data(5, b"new");
        assert_eq!(parsed(&terminal, 8), b"01234\x18new", "the unsent bytes were spliced");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A dead holder's segment with 10 bytes published and a read in
    /// flight at 10, for a terminal that received the first 5: the
    /// adoption hands the segment on, resuming at 5.
    fn adoption_past_what_was_received(name: &str) -> (Arc<HolderTerminal>, std::path::PathBuf) {
        let mut ring = cmux_holder::ring::Ring::new(0, 4096);
        let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
        ring.push(b"0123456789");
        let mut handed = None;
        ring.read_with(64, |room| {
            room[..3].copy_from_slice(b"lst");
            // The holder dies inside this read.
            let (terminal, root) = orphaned_terminal(name, segment.try_clone().unwrap(), b"01234");
            let adoption = terminal.adoption(true, ADOPT_PROLOGUE_MAX_BYTES);
            assert!(adoption.ring.is_some(), "the segment goes to the new holder");
            assert_eq!(adoption.resume, 5);
            handed = Some((terminal, root));
            3
        });
        handed.unwrap()
    }

    /// Review 2 of pl-holder-11: which loss an adoption marks follows the
    /// new holder's ADOPTED answer, not a guess made before the ADOPT. The
    /// dead holder read past what the daemon received (10 bytes published,
    /// 5 received) and died inside a read at 10:
    ///
    /// - the new holder refuses the segment and starts a fresh ring at 5
    ///   (its answer ends at 5): bytes 5..10 are gone, so the parser gets
    ///   one CAN at 5 and none at 10, where the new stream is valid output;
    /// - it continues the segment (its answer ends at 10): it resends 5..10
    ///   from the ring and only the read at 10 is lost: one CAN at 10;
    /// - nobody answers (the link ended) and the next adoption has no
    ///   segment: a fresh ring at 5 again, one CAN at 5.
    ///
    /// Before, the cut was always at 10 for a handed segment: the refused
    /// case spliced 5..10 silently and put a false CAN inside new output.
    #[test]
    fn the_new_holders_answer_decides_where_lost_output_is_cancelled() {
        use cmux_holder::link::TerminalSink;
        let (terminal, root) = adoption_past_what_was_received("cmux-holder-cut-refused");
        terminal.sink.adopted(5);
        terminal.sink.data(5, b"abcdefgh");
        assert_eq!(parsed(&terminal, 13), b"01234\x18abcdefgh", "a refused segment");
        let _ = std::fs::remove_dir_all(&root);

        let (terminal, root) = adoption_past_what_was_received("cmux-holder-cut-continued");
        terminal.sink.adopted(10);
        terminal.sink.data(5, b"56789");
        terminal.sink.data(10, b"new");
        assert_eq!(parsed(&terminal, 13), b"0123456789\x18new", "a continued segment");
        let _ = std::fs::remove_dir_all(&root);

        let (terminal, root) = adoption_past_what_was_received("cmux-holder-cut-unanswered");
        // readopt keeps no custody segment when no answer came.
        terminal.keep_ring(None);
        let adoption = terminal.adoption(true, ADOPT_PROLOGUE_MAX_BYTES);
        assert_eq!(adoption.resume, 5);
        terminal.sink.data(5, b"abcdefgh");
        assert_eq!(parsed(&terminal, 13), b"01234\x18abcdefgh", "an unanswered adoption");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_paste_bigger_than_the_input_queue_waits_for_a_slow_program() {
        let (master, mut slave) = nonblocking_pty();
        let paste: Vec<u8> = (0..64 * 1024).map(|index| b'a' + (index % 26) as u8).collect();
        let expected = paste.clone();
        // The program reads nothing for a while, then everything.
        let program = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(300));
            let mut got = vec![0u8; expected.len()];
            slave.read_exact(&mut got).unwrap();
            got == expected
        });
        let pty = cmux_pty::adopt_master(master.try_clone().unwrap()).unwrap();
        let mut writer = WaitingWriter { inner: pty.take_writer().unwrap(), master };
        writer.write_all(&paste).expect("the paste waits for room instead of failing");
        writer.flush().unwrap();
        assert!(program.join().unwrap(), "the program got every byte, in order");
    }
}
