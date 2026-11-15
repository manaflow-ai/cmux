//! A daemon start while the terminal holder is slow to answer (a loaded
//! machine, a holder that is stopped or still starting): the holder still
//! runs the shell, so the start must keep the terminal and its tab, must not
//! wait for the holder, and the terminal must re-attach when the holder
//! answers.
//!
//! A stand-in for the holder takes each connect, holds it (or ends it, when
//! the test says so) and counts it, and answers only when the test says so.
//! The start and the late thread wait by a clock the test steps
//! ([`StepClock`]), so a result here is a count of asks and never a time:
//! the waits in these tests are waits for an event, and their only limit is
//! a failure limit.

use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;

use cmux_holder::wire::{self, Kind, Out};

use super::*;
use crate::holder_runtime::HolderService;
use crate::mux::holder_late::{HolderClock, set_holder_clock_for_test};

const TERMINAL: &str = "0000000000004000800000000000002b";
const INCARNATION: &str = "1000000000004000800000000000002b";
/// One step of the clock in the start pass: the start's wait for the holder
/// ends after a handful of asks.
const STEP: Duration = Duration::from_millis(50);
/// Where the clock stands after the start: past the start's deadline for
/// the holder, and before the late thread's first wait.
const AT_START: Duration = Duration::from_millis(400);
/// One step of the clock after the start: each wait of the late thread
/// reads the socket one time.
const LATE_STEP: Duration = Duration::from_millis(600);
/// Far past every bound a start had for the holder (it was 30 s).
const FAR: Duration = Duration::from_secs(120);

/// A clock that moves only when it is asked: each `now` moves it one step
/// and each pause moves it by the pause, up to a limit. At its limit it
/// stands, and a wait by it goes on until the test moves the limit.
struct StepClock {
    start: Instant,
    steps: Mutex<Steps>,
}

struct Steps {
    moved: Duration,
    step: Duration,
    limit: Duration,
    pauses: usize,
    asks_at_limit: usize,
}

impl StepClock {
    fn new(step: Duration, limit: Duration) -> Arc<Self> {
        Arc::new(Self {
            start: Instant::now(),
            steps: Mutex::new(Steps {
                moved: Duration::ZERO,
                step,
                limit,
                pauses: 0,
                asks_at_limit: 0,
            }),
        })
    }

    fn moved(&self) -> Duration {
        self.steps.lock().unwrap().moved
    }

    /// How many pauses the daemon made by this clock. The late thread makes
    /// one after each wait that ended with no answer.
    fn pauses(&self) -> usize {
        self.steps.lock().unwrap().pauses
    }

    /// Whether the late thread is in a wait that cannot end by time: the
    /// clock stands at its limit and the thread asked it there two times.
    /// (A wait that began before the limit can end at the first ask there;
    /// the thread then pauses, and its next wait begins at the limit, with
    /// the second ask.)
    fn stands_in_a_wait(&self) -> bool {
        self.steps.lock().unwrap().asks_at_limit >= 2
    }

    /// Let the clock go on to `limit`, `step` at each ask.
    fn run(&self, step: Duration, limit: Duration) {
        let mut steps = self.steps.lock().unwrap();
        steps.step = step;
        steps.limit = limit;
        steps.asks_at_limit = 0;
    }
}

impl HolderClock for StepClock {
    fn now(&self) -> Instant {
        let mut steps = self.steps.lock().unwrap();
        let now = self.start + steps.moved;
        if steps.moved == steps.limit {
            steps.asks_at_limit += 1;
        }
        steps.moved = (steps.moved + steps.step).min(steps.limit);
        now
    }

    fn read_slice(&self) -> Duration {
        Duration::from_millis(1)
    }

    fn pause(&self, pause: Duration) {
        {
            let mut steps = self.steps.lock().unwrap();
            steps.moved = (steps.moved + pause).min(steps.limit);
            steps.pauses += 1;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// A terminal the stand-in says it runs.
struct Held {
    id: [u8; 16],
    pid: i32,
    master: OwnedFd,
}

enum Order {
    /// From now on answer each connect it holds or takes: a WELCOME, with
    /// this terminal listed.
    Answer(Option<Held>),
    /// End each connect it holds, and go on listening.
    DropConnects,
    /// End each of the next connects it takes, this many, when it takes it.
    EndNext(usize),
    /// Say how many connects it took, after it took each one that waits.
    Count(mpsc::Sender<usize>),
    /// Stop: no holder serves the socket any more (its file stays).
    Die,
}

/// A stand-in for the terminal holder of one session.
struct StandIn {
    host_root: std::path::PathBuf,
    orders: mpsc::Sender<Order>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl StandIn {
    fn serve(listener: UnixListener, host_root: &Path) -> Self {
        listener.set_nonblocking(true).unwrap();
        let (orders, inbox) = mpsc::channel();
        let thread = std::thread::spawn(move || {
            let mut held: Vec<UnixStream> = Vec::new();
            let mut connects = 0;
            let mut answer: Option<Option<Held>> = None;
            let mut answered = 0;
            let mut end_next = 0;
            loop {
                match listener.accept() {
                    Ok((stream, _)) => {
                        connects += 1;
                        if end_next > 0 {
                            end_next -= 1;
                            continue;
                        }
                        // An accepted socket takes the listener's mode on macOS.
                        stream.set_nonblocking(false).unwrap();
                        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                        held.push(stream);
                        continue;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(error) => panic!("the stand-in holder could not accept: {error}"),
                }
                if let Some(listed) = &answer {
                    while answered < held.len() {
                        welcome(&held[answered], listed.as_ref());
                        answered += 1;
                    }
                }
                match inbox.try_recv() {
                    Ok(Order::Answer(listed)) => answer = Some(listed),
                    Ok(Order::DropConnects) => {
                        held.clear();
                        answered = 0;
                    }
                    Ok(Order::EndNext(count)) => end_next = count,
                    Ok(Order::Count(reply)) => {
                        let _ = reply.send(connects);
                    }
                    Ok(Order::Die) | Err(mpsc::TryRecvError::Disconnected) => return,
                    Err(mpsc::TryRecvError::Empty) => {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                }
            }
        });
        Self { host_root: host_root.to_path_buf(), orders, thread: Some(thread) }
    }

    fn order(&self, order: Order) {
        self.orders.send(order).unwrap();
    }

    /// How many connects the stand-in took so far.
    fn connects(&self) -> usize {
        let (reply, count) = mpsc::channel();
        self.order(Order::Count(reply));
        count.recv().unwrap()
    }

    /// The holder dies: its connects end, and a new connect is refused.
    fn die(&mut self) {
        let _ = self.orders.send(Order::Die);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for StandIn {
    fn drop(&mut self) {
        // The end of a test, also at a failed assert: the daemon's holder
        // service must start no real holder when the stand-in's link ends.
        if let Ok(service) = HolderService::for_root(&self.host_root) {
            service.retire_for_test();
        }
        self.die();
    }
}

/// Answer the HELLO on `stream` with a WELCOME that lists `listed`.
fn welcome(stream: &UnixStream, listed: Option<&Held>) {
    let fd = stream.as_raw_fd();
    let mut reader = wire::Reader::default();
    let hello = loop {
        if let Some(frame) = reader.next_frame().unwrap() {
            break frame;
        }
        assert!(reader.fill(fd).unwrap(), "the daemon ended its connect before the HELLO");
    };
    assert_eq!(hello.kind, Kind::Hello as u16);
    let count = u32::from(listed.is_some());
    let payload = Out::default().u16(wire::VERSION).u32(count).0;
    wire::send_all(fd, &wire::encode(Kind::Welcome, 0, &payload), &[]).unwrap();
    if let Some(held) = listed {
        let entry = Out::default().i32(held.pid).u64(0).u64(0).u8(0).bytes(&held.id).0;
        let frame = wire::encode_with_fds(Kind::Listed, 0, 1, &entry, 1);
        wire::send_all(fd, &frame, &[held.master.as_raw_fd()]).unwrap();
    }
}

/// The terminal of these tests, as a holder lists it.
fn held(pid: i32, master: OwnedFd) -> Held {
    let id = *TerminalId::from_hex(TERMINAL).unwrap().as_bytes();
    Held { id, pid, master }
}

/// Wait for an event. The limit only fails a test whose event never comes.
fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let limit = Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(Instant::now() < limit, "{what}: it did not happen");
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// A session whose one terminal ran on the holder when its daemon stopped.
struct Session {
    name: &'static str,
    root: std::path::PathBuf,
    host_root: std::path::PathBuf,
    socket: std::path::PathBuf,
    tab: TabPublicId,
}

impl Session {
    fn new(name: &'static str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-mux-{name}-{}", crate::workspace_registry::new_uuid_v4()));
        let tab = registry_with_running_terminal(&root, name, TERMINAL, INCARNATION);
        let host_root = crate::terminal_host_runtime::terminal_host_root(&root, name);
        std::fs::create_dir_all(&host_root).unwrap();
        std::fs::set_permissions(&host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = HolderService::socket_for_test(&host_root).unwrap();
        let _ = std::fs::remove_file(&socket);
        Self { name, root, host_root, socket, tab }
    }

    /// The socket of this session's holder, listening.
    fn listen(&self) -> UnixListener {
        UnixListener::bind(&self.socket).unwrap()
    }

    /// A stand-in for this session's holder: it takes each connect and does
    /// not answer, as a holder that is stopped or has no time for this
    /// daemon yet.
    fn holder(&self) -> StandIn {
        StandIn::serve(self.listen(), &self.host_root)
    }

    /// A creation of the terminal that a daemon crash interrupted.
    fn interrupt_a_creation(&self) {
        let mut registry = WorkspaceRegistry::open(&self.root, self.name).unwrap();
        let fingerprint = serde_json::json!({"operation":"tab.create_terminal"});
        let intent = serde_json::json!({"terminal_reservation":{"terminal_id":TERMINAL}});
        registry
            .prepare_resource_creation(
                "late-creation",
                "late-attempt",
                "tab.create_terminal",
                &fingerprint,
                &intent,
                true,
                None,
                None,
            )
            .unwrap();
        registry
            .mark_resource_effect_executing("late-attempt", "tab.create_terminal", &fingerprint)
            .unwrap();
    }

    /// Start the daemon's mux on this session, with `clock` for its holder.
    fn start(&self, clock: &Arc<StepClock>) -> anyhow::Result<Arc<Mux>> {
        set_holder_clock_for_test(&self.host_root, clock.clone());
        let options = SurfaceOptions {
            terminal_host_root: Some(self.host_root.clone()),
            ..SurfaceOptions::default()
        };
        Mux::open_persistent(self.name, options, &self.root)
    }

    /// What the start kept of the terminal: no recorded end, its lifecycle,
    /// the `adopting` mark of its tab, and the tab.
    fn kept(&self, mux: &Mux) -> (bool, TerminalLifecycle, bool, bool) {
        let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
        let tabs =
            mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap().tabs;
        (
            resolved.terminal.exit.is_none(),
            resolved.terminal.lifecycle,
            mux.terminal_is_pending(TERMINAL),
            tabs.iter().any(|kept| kept.public_id == self.tab),
        )
    }

    /// Whether the late thread did its work on the terminal: re-attached
    /// or ended it.
    fn late_work_done(&self, mux: &Mux) -> bool {
        mux.late_holder_terminals.lock().unwrap().is_empty()
    }

    fn end(self, mux: Arc<Mux>, holder: StandIn) {
        mux.shutdown();
        drop(mux);
        drop(holder);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// How many interrupted creations are not settled.
fn unsettled_creations(mux: &Mux) -> usize {
    mux.workspace_registry.lock().unwrap().interrupted_resource_creation_recoveries().unwrap().len()
}

/// The terminal's shell as a real holder would keep it: a PTY (its master
/// goes to the daemon) and a process to name. Dropped, the process ends.
struct KeptShell {
    pty: cmux_pty::PtyPair,
    process: std::process::Child,
}

impl KeptShell {
    fn new() -> Self {
        let size = cmux_pty::PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 };
        let pty = cmux_pty::open(size).unwrap();
        let process = std::process::Command::new("/bin/sleep").arg("600").spawn().unwrap();
        Self { pty, process }
    }

    /// The terminal as the holder lists it, with the PTY's master.
    fn listed(&self) -> Held {
        held(self.pid(), self.pty.try_clone_reader_descriptor().unwrap())
    }

    fn pid(&self) -> i32 {
        i32::try_from(self.process.id()).unwrap()
    }
}

impl Drop for KeptShell {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

/// One workspace with one tab whose terminal runs (`incarnation`), as a
/// daemon that stopped left it.
fn registry_with_running_terminal(
    root: &Path,
    session: &str,
    terminal_id: &str,
    incarnation: &str,
) -> TabPublicId {
    let workspace = RegistryWorkspace {
        id: 1,
        public_id: restore_workspace_id(42),
        key: "workspace-held".into(),
        name: "Held".into(),
        name_source: Default::default(),
        name_revision: 0,
        group_key: session.into(),
    };
    let screen = restore_screen_id(42);
    let pane = restore_pane_id(42);
    let tab = restore_tab_id(42);
    let terminal_public_id = restore_terminal_id(42);
    let terminal = RegistryTerminal {
        terminal_id: terminal_id.into(),
        workspace_key: workspace.key.clone(),
        incarnation: None,
        lifecycle: TerminalLifecycle::Launching,
        launch_spec: serde_json::json!({"command":["/bin/sh"]}),
        exit: None,
        on_exit: TerminalOnExit::Close,
    };
    let mut registry = WorkspaceRegistry::open(root, session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon("seed-held-terminal", "test").unwrap(),
            "workspace.create",
            &serde_json::json!({"fixture":"held-terminal"}),
            None,
            Some(0),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace {
                        workspace: workspace.clone(),
                        position: 0,
                        active_screen: Some(screen.clone()),
                    },
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen.clone(),
                        workspace_id: workspace.public_id.clone(),
                        position: 0,
                        name: None,
                        layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                        active_pane: pane.clone(),
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane.clone(),
                        screen_id: screen.clone(),
                        name: None,
                        active_tab: Some(tab.clone()),
                        creation_ordinal: 1,
                    }),
                    ResourceChange::UpsertTerminal {
                        public_id: terminal_public_id.clone(),
                        terminal,
                    },
                    ResourceChange::UpsertTab(RegistryTab {
                        name_source: Default::default(),
                        name_revision: 0,
                        public_id: tab.clone(),
                        pane_id: pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Terminal(terminal_public_id),
                        name: None,
                        browser_url: None,
                        terminal_id: Some(terminal_id.into()),
                    }),
                    ResourceChange::SetWorkspaceOrder {
                        workspace_ids: vec![workspace.public_id.clone()],
                    },
                    ResourceChange::SetScreenOrder {
                        workspace_id: workspace.public_id.clone(),
                        screen_ids: vec![screen],
                    },
                    ResourceChange::SetTabOrder { pane_id: pane, tab_ids: vec![tab.clone()] },
                    ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id) },
                ],
            },
            &serde_json::json!({"created":true}),
            &serde_json::json!([{"kind":"fixture.created"}]),
        )
        .unwrap();
    commit_terminal_lifecycle(
        &mut registry,
        "terminal-ready",
        "seed-running-terminal",
        terminal_id,
        TerminalLifecycle::Running,
        Some(incarnation),
        None,
    )
    .unwrap();
    tab
}

#[test]
fn a_start_keeps_a_terminal_whose_holder_does_not_answer_in_time() {
    let session = Session::new("holder-late-start");
    // The holder takes the connect and the HELLO and does not answer. Such
    // a holder still runs the shell of the terminal.
    let holder = session.holder();
    let clock = StepClock::new(STEP, AT_START);
    let mux = session.start(&clock).unwrap();

    assert_eq!(
        holder.connects(),
        1,
        "the start asks a holder one time for all its terminals, on one connect"
    );
    assert_eq!(
        session.kept(&mux),
        (true, TerminalLifecycle::Running, true, true),
        "(no end, lifecycle, adopting mark, tab): the holder had not answered yet, so the start \
         must keep the terminal and show its tab as adopting"
    );
    session.end(mux, holder);
}

/// A holder that never answers: no timer ends its terminal. The tab stays
/// adopting, on the one connect, and the person can close it.
#[test]
fn a_terminal_of_a_holder_that_never_answers_stays_adopting_and_can_be_closed() {
    let session = Session::new("holder-late-start-silent");
    let holder = session.holder();
    let clock = StepClock::new(STEP, AT_START);
    let mux = session.start(&clock).unwrap();

    clock.run(LATE_STEP, FAR);
    wait_until("the late thread waits far past the old bound", || clock.moved() >= FAR);
    assert_eq!(
        session.kept(&mux),
        (true, TerminalLifecycle::Running, true, true),
        "(no end, lifecycle, adopting mark, tab) after {FAR:?} of a silent holder"
    );
    assert_eq!(holder.connects(), 1, "a silent holder gets one connect from a daemon");

    mux.close_terminal(TERMINAL, INCARNATION).expect("the person closes the tab that waits");
    let closed = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(
        (closed.terminal.lifecycle, mux.terminal_is_pending(TERMINAL)),
        (TerminalLifecycle::Tombstoned, false),
        "the closed terminal (lifecycle, adopting mark)"
    );
    session.end(mux, holder);
}

/// A socket file that no holder serves (the holder died): its shells are
/// gone, and the start ends the terminal as before.
#[test]
fn a_start_ends_a_terminal_whose_holder_is_gone() {
    let session = Session::new("holder-late-start-gone");
    drop(session.listen());
    let clock = StepClock::new(Duration::ZERO, AT_START);
    let mux = session.start(&clock).unwrap();

    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(
        (resolved.terminal.lifecycle, resolved.terminal.exit.is_some()),
        (TerminalLifecycle::Exited, true),
        "(lifecycle, recorded end): a refused connect means no holder runs the shell"
    );
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&session.root);
}

/// A holder that answers long after the start: the terminal re-attaches
/// then, on the connect the start made.
#[test]
fn a_terminal_reattaches_when_its_late_holder_answers() {
    let session = Session::new("holder-late-start-answer");
    let holder = session.holder();
    let clock = StepClock::new(STEP, AT_START);
    let mux = session.start(&clock).unwrap();

    clock.run(LATE_STEP, FAR);
    wait_until("the late thread waits far past the old bound", || clock.stands_in_a_wait());
    assert_eq!(clock.moved(), FAR);
    assert_eq!(session.kept(&mux), (true, TerminalLifecycle::Running, true, true));
    // The clock stands at its limit, so the wait that the late thread is in
    // cannot end by time, and the count of its pauses stands with it.
    let waits_without_answer = clock.pauses();

    let shell = KeptShell::new();
    holder.order(Order::Answer(Some(shell.listed())));
    wait_until("the late thread re-attaches the terminal", || session.late_work_done(&mux));
    assert_eq!(
        clock.pauses(),
        waits_without_answer,
        "the terminal re-attached in the wait in which the holder answered: no wait ended \
         without the answer after it"
    );
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(
        (
            resolved.surface.is_some(),
            resolved.terminal.lifecycle,
            resolved.terminal.exit.is_none(),
            resolved.terminal.incarnation.as_deref(),
            mux.terminal_is_pending(TERMINAL),
        ),
        (true, TerminalLifecycle::Running, true, Some(INCARNATION), false),
        "(runtime, lifecycle, no end, incarnation, adopting mark): the same shell, attached again"
    );
    assert_eq!(holder.connects(), 1, "the answer came on the connect the start made");
    session.end(mux, holder);
}

/// A holder that ends the connect while the late thread waits on it (it
/// restarted its listener): one new connect for that end, and the terminal
/// is kept. (A holder that ends each new connect gets a new one each time,
/// after a pause that grows; no test here covers that.)
#[test]
fn an_ended_connect_of_a_late_holder_gets_one_new_connect_and_keeps_the_terminal() {
    let session = Session::new("holder-late-start-eof");
    let holder = session.holder();
    let clock = StepClock::new(STEP, AT_START);
    let mux = session.start(&clock).unwrap();
    assert_eq!(holder.connects(), 1);

    holder.order(Order::DropConnects);
    clock.run(LATE_STEP, FAR);
    wait_until("the daemon connects again after the end of file", || holder.connects() >= 2);
    wait_until("the late thread waits far past the old bound", || clock.moved() >= FAR);
    assert_eq!(holder.connects(), 2, "one new connect for the one that ended");
    assert_eq!(
        session.kept(&mux),
        (true, TerminalLifecycle::Running, true, true),
        "(no end, lifecycle, adopting mark, tab): an end of file is not a dead holder"
    );
    session.end(mux, holder);
}

/// A creation the last daemon's crash interrupted, whose terminal waits for
/// a late holder: the start does not wait for it (it waited 15 s and then
/// failed), and it settles when the holder answers.
#[test]
fn a_start_does_not_wait_for_a_creation_of_a_late_terminal_that_then_attaches() {
    let session = Session::new("holder-late-start-creation");
    session.interrupt_a_creation();
    let holder = session.holder();
    let clock = StepClock::new(STEP, AT_START);
    let mux = session.start(&clock).expect("the start does not wait for the late holder");
    assert_eq!(unsettled_creations(&mux), 1, "the creation waits for the holder's answer");
    assert_eq!(session.kept(&mux), (true, TerminalLifecycle::Running, true, true));

    clock.run(LATE_STEP, FAR);
    let shell = KeptShell::new();
    holder.order(Order::Answer(Some(shell.listed())));
    wait_until("the late thread re-attaches the terminal", || session.late_work_done(&mux));
    wait_until("the creation settles after the holder's answer", || unsettled_creations(&mux) == 0);
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(
        (resolved.surface.is_some(), resolved.terminal.lifecycle),
        (true, TerminalLifecycle::Running),
        "(runtime, lifecycle): the created terminal runs"
    );
    session.end(mux, holder);
}

/// The same creation when the late holder turns out to be gone: the
/// terminal ends, and the creation settles then.
#[test]
fn a_creation_of_a_late_terminal_settles_when_the_terminal_ends() {
    let session = Session::new("holder-late-start-creation-end");
    session.interrupt_a_creation();
    let mut holder = session.holder();
    let clock = StepClock::new(STEP, AT_START);
    let mux = session.start(&clock).expect("the start does not wait for the late holder");
    assert_eq!(unsettled_creations(&mux), 1, "the creation waits for the holder");

    // The holder dies: the connect ends and the next one is refused.
    holder.die();
    clock.run(LATE_STEP, FAR);
    wait_until("the creation settles after the terminal ended", || unsettled_creations(&mux) == 0);
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(
        (resolved.terminal.lifecycle, mux.terminal_is_pending(TERMINAL)),
        (TerminalLifecycle::Exited, false),
        "(lifecycle, adopting mark): no holder runs the shell any more"
    );
    session.end(mux, holder);
}

/// A terminal the holder lists and the start cannot re-attach is kept for
/// the next start (its row stays, the holder keeps the shell). When a crash
/// also interrupted its creation, the start must still come up: a start that
/// fails loses every tab.
#[test]
fn a_start_with_a_kept_terminal_of_an_interrupted_creation_does_not_fail() {
    let session = Session::new("holder-late-start-kept");
    session.interrupt_a_creation();
    let holder = session.holder();
    // The holder answers at once. The master it passes is not a PTY, so the
    // re-attach fails and the start keeps the terminal.
    let shell = KeptShell::new();
    let (not_a_pty, _write_end) = std::io::pipe().unwrap();
    holder.order(Order::Answer(Some(held(shell.pid(), OwnedFd::from(not_a_pty)))));
    let clock = StepClock::new(Duration::ZERO, AT_START);
    let mux = match session.start(&clock) {
        Ok(mux) => mux,
        Err(error) => panic!(
            "the start failed with a terminal kept for the next start and its creation \
             interrupted: {error:#}"
        ),
    };
    assert_eq!(
        session.kept(&mux),
        (true, TerminalLifecycle::Adopting, true, true),
        "(no end, lifecycle, adopting mark, tab): kept for the next start"
    );
    assert_eq!(unsettled_creations(&mux), 1, "the creation waits for the next start too");
    session.end(mux, holder);
}

/// A holder that ends the connect of the start before its answer (it
/// restarted its listener, or it had no room for the connect): it may still
/// run the shell, so the start keeps the terminal as for a silent holder,
/// and the terminal re-attaches on the new connect of the late thread.
#[test]
fn a_start_keeps_a_terminal_whose_holder_ends_the_first_connect() {
    let session = Session::new("holder-late-start-first-eof");
    let holder = session.holder();
    holder.order(Order::EndNext(1));
    // The stand-in read the order: it answers a count only after it.
    assert_eq!(holder.connects(), 0);
    // The clock does not move in the start, so the start's wait for the
    // holder does not end by time: it ends when the holder ends the connect.
    let clock = StepClock::new(Duration::ZERO, AT_START);
    let mux = session.start(&clock).unwrap();
    assert_eq!(
        session.kept(&mux),
        (true, TerminalLifecycle::Running, true, true),
        "(no end, lifecycle, adopting mark, tab): an ended connect is not a dead holder"
    );

    clock.run(LATE_STEP, FAR);
    let shell = KeptShell::new();
    holder.order(Order::Answer(Some(shell.listed())));
    wait_until("the late thread re-attaches the terminal", || session.late_work_done(&mux));
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(
        (
            resolved.surface.is_some(),
            resolved.terminal.lifecycle,
            resolved.terminal.exit.is_none(),
            mux.terminal_is_pending(TERMINAL),
        ),
        (true, TerminalLifecycle::Running, true, false),
        "(runtime, lifecycle, no end, adopting mark): the same shell, attached again"
    );
    assert_eq!(holder.connects(), 2, "one new connect for the one the holder ended");
    session.end(mux, holder);
}
