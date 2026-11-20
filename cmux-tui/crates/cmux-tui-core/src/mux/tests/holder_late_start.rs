//! A daemon start while the terminal holder is slow to answer (a loaded
//! machine, a holder that is stopped or still starting): the holder still
//! runs the shell, so the start must keep the terminal and its tab, must not
//! wait for the holder, and the terminal must re-attach when the holder
//! answers.
//!
//! A stand-in for the holder takes each connect, holds it (or ends or
//! refuses it, when the test says so) and counts it, and answers only when
//! the test says so.
//! The start and the late thread wait by a clock the test steps
//! ([`StepClock`]), so a result here is a count of asks and never a time:
//! the waits in these tests are waits for an event, and their only limit is
//! a failure limit.

use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;

use cmux_holder::holder::error_code;
use cmux_holder::wire::{self, Kind, Out};

use super::*;
use crate::holder_runtime::HolderService;
use crate::mux::holder_late::{HolderClock, set_holder_clock_for_test};

mod quick_terminal;

const TERMINAL: &str = "0000000000004000800000000000002b";
const INCARNATION: &str = "1000000000004000800000000000002b";
/// The second terminal of a session with two.
const SECOND_TERMINAL: &str = "0000000000004000800000000000002c";
const SECOND_INCARNATION: &str = "1000000000004000800000000000002c";
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
/// A failure limit for a start whose clock stands: see [`StartWatch`].
const START_LIMIT: Duration = Duration::from_secs(20);

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
    /// The same, with each of these terminals listed.
    AnswerEach(Vec<Held>),
    /// End each connect it holds, and go on listening.
    DropConnects,
    /// Refuse each connect it holds with this code (an ERROR about the
    /// HELLO, no WELCOME), end it, and go on listening.
    RefuseHeld(u16),
    /// End each of the next connects it takes, this many, when it takes it.
    EndNext(usize),
    /// Refuse each of the next connects it takes, this many, with this code
    /// when it takes it (an ERROR about the HELLO, no WELCOME), and end it.
    RefuseNext(u16, usize),
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
            let mut answer: Option<Vec<Held>> = None;
            let mut answered = 0;
            let mut end_next = 0;
            let mut refuse_next = (0, 0);
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
                        if refuse_next.1 > 0 {
                            refuse_next.1 -= 1;
                            refuse(&stream, refuse_next.0);
                            continue;
                        }
                        held.push(stream);
                        continue;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(error) => panic!("the stand-in holder could not accept: {error}"),
                }
                if let Some(listed) = &answer {
                    while answered < held.len() {
                        welcome(&held[answered], listed);
                        answered += 1;
                    }
                }
                match inbox.try_recv() {
                    Ok(Order::Answer(listed)) => answer = Some(listed.into_iter().collect()),
                    Ok(Order::AnswerEach(listed)) => answer = Some(listed),
                    Ok(Order::DropConnects) => {
                        held.clear();
                        answered = 0;
                    }
                    Ok(Order::RefuseHeld(code)) => {
                        for stream in held.drain(..) {
                            refuse(&stream, code);
                        }
                        answered = 0;
                    }
                    Ok(Order::EndNext(count)) => end_next = count,
                    Ok(Order::RefuseNext(code, count)) => refuse_next = (code, count),
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

/// Read the HELLO the daemon sent on `stream`.
fn read_hello(stream: &UnixStream) {
    let fd = stream.as_raw_fd();
    let mut reader = wire::Reader::default();
    let hello = loop {
        if let Some(frame) = reader.next_frame().unwrap() {
            break frame;
        }
        assert!(reader.fill(fd).unwrap(), "the daemon ended its connect before the HELLO");
    };
    assert_eq!(hello.kind, Kind::Hello as u16);
}

/// Answer the HELLO on `stream` with a WELCOME that lists `listed`, each on
/// its own channel.
fn welcome(stream: &UnixStream, listed: &[Held]) {
    let fd = stream.as_raw_fd();
    read_hello(stream);
    let count = u32::try_from(listed.len()).unwrap();
    let payload = Out::default().u16(wire::VERSION).u32(count).0;
    wire::send_all(fd, &wire::encode(Kind::Welcome, 0, &payload), &[]).unwrap();
    for (held, chan) in listed.iter().zip(1u32..) {
        let entry = Out::default().i32(held.pid).u64(0).u64(0).u8(0).bytes(&held.id).0;
        let frame = wire::encode_with_fds(Kind::Listed, 0, chan, &entry, 1);
        wire::send_all(fd, &frame, &[held.master.as_raw_fd()]).unwrap();
    }
}

/// Answer the HELLO on `stream` with the frame a holder writes to a connect
/// it refuses: an ERROR about the HELLO with `code`, and no WELCOME before
/// it. [`error_code::SUPERSEDED`] is the code for a connect whose link
/// another connect took, [`error_code::BAD_TOKEN`] the one for a daemon the
/// holder does not serve.
fn refuse(stream: &UnixStream, code: u16) {
    read_hello(stream);
    let payload =
        Out::default().u16(Kind::Hello as u16).u16(code).bytes(b"refused by the stand-in").0;
    wire::send_all(stream.as_raw_fd(), &wire::encode(Kind::Error, 0, &payload), &[]).unwrap();
}

/// A failure limit for a start whose clock stands. Such a start ends only
/// when the holder ends or refuses its connect. A start that waits on a
/// connect the stand-in holds would never end: after [`START_LIMIT`] this
/// lets the clock run, so the start ends by time and the test fails by an
/// assert.
struct StartWatch {
    ended: mpsc::Sender<()>,
    thread: std::thread::JoinHandle<bool>,
}

impl StartWatch {
    fn of(clock: &Arc<StepClock>) -> Self {
        let clock = clock.clone();
        let (ended, start) = mpsc::channel();
        let thread = std::thread::spawn(move || {
            let late =
                matches!(start.recv_timeout(START_LIMIT), Err(mpsc::RecvTimeoutError::Timeout));
            if late {
                clock.run(STEP, AT_START);
            }
            late
        });
        Self { ended, thread }
    }

    /// The start ended: whether the limit ended it.
    fn ended_by_the_limit(self) -> bool {
        let _ = self.ended.send(());
        self.thread.join().unwrap()
    }
}

/// The terminal of these tests, as a holder lists it.
fn held(pid: i32, master: OwnedFd) -> Held {
    held_as(TERMINAL, pid, master)
}

/// The terminal `terminal`, as a holder lists it.
fn held_as(terminal: &str, pid: i32, master: OwnedFd) -> Held {
    let id = *TerminalId::from_hex(terminal).unwrap().as_bytes();
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

/// A session whose one terminal ran on the holder when its daemon stopped
/// (or its two terminals, each in its own tab of the one pane).
struct Session {
    name: &'static str,
    root: std::path::PathBuf,
    host_root: std::path::PathBuf,
    socket: std::path::PathBuf,
    tab: TabPublicId,
    second_tab: Option<TabPublicId>,
}

impl Session {
    fn new(name: &'static str) -> Self {
        Self::with_terminals(name, &[(TERMINAL, INCARNATION)])
    }

    fn with_two_terminals(name: &'static str) -> Self {
        Self::with_terminals(
            name,
            &[(TERMINAL, INCARNATION), (SECOND_TERMINAL, SECOND_INCARNATION)],
        )
    }

    fn with_terminals(name: &'static str, terminals: &[(&str, &str)]) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-mux-{name}-{}", crate::workspace_registry::new_uuid_v4()));
        let mut tabs = registry_with_running_terminals(&root, name, terminals).into_iter();
        let tab = tabs.next().unwrap();
        let second_tab = tabs.next();
        let host_root = crate::terminal_host_runtime::terminal_host_root(&root, name);
        std::fs::create_dir_all(&host_root).unwrap();
        std::fs::set_permissions(&host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = HolderService::socket_for_test(&host_root).unwrap();
        let _ = std::fs::remove_file(&socket);
        Self { name, root, host_root, socket, tab, second_tab }
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
        self.kept_terminal(mux, TERMINAL, &self.tab)
    }

    /// The same for the second terminal of a session with two.
    fn kept_second(&self, mux: &Mux) -> (bool, TerminalLifecycle, bool, bool) {
        self.kept_terminal(mux, SECOND_TERMINAL, self.second_tab.as_ref().unwrap())
    }

    fn kept_terminal(
        &self,
        mux: &Mux,
        terminal: &str,
        tab: &TabPublicId,
    ) -> (bool, TerminalLifecycle, bool, bool) {
        let resolved = mux.resolve_terminal(terminal).unwrap().unwrap();
        let tabs =
            mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap().tabs;
        (
            resolved.terminal.exit.is_none(),
            resolved.terminal.lifecycle,
            mux.terminal_is_pending(terminal),
            tabs.iter().any(|kept| &kept.public_id == tab),
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

    /// This shell as the holder's terminal `terminal`.
    fn listed_as(&self, terminal: &str) -> Held {
        held_as(terminal, self.pid(), self.pty.try_clone_reader_descriptor().unwrap())
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

/// One workspace with one pane and one tab for each of `terminals` (a
/// terminal id and its incarnation), each terminal running, as a daemon that
/// stopped left them. The tabs, in the order of `terminals`.
fn registry_with_running_terminals(
    root: &Path,
    session: &str,
    terminals: &[(&str, &str)],
) -> Vec<TabPublicId> {
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
    let tabs: Vec<TabPublicId> = (42u128..).take(terminals.len()).map(restore_tab_id).collect();
    let mut changes = vec![
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
            floating: Vec::new(),
        }),
        ResourceChange::UpsertPane(RegistryPane {
            public_id: pane.clone(),
            screen_id: screen.clone(),
            name: None,
            active_tab: tabs.first().cloned(),
            creation_ordinal: 1,
        }),
    ];
    let seeded = terminals.iter().zip(&tabs).zip(42u128..);
    for (position, ((&(terminal_id, _), tab), seed)) in seeded.enumerate() {
        let terminal_public_id = restore_terminal_id(seed);
        changes.push(ResourceChange::UpsertTerminal {
            public_id: terminal_public_id.clone(),
            terminal: RegistryTerminal {
                terminal_id: terminal_id.into(),
                workspace_key: workspace.key.clone(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({"command":["/bin/sh"]}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        });
        changes.push(ResourceChange::UpsertTab(RegistryTab {
            name_source: Default::default(),
            name_revision: 0,
            public_id: tab.clone(),
            pane_id: pane.clone(),
            position,
            content_id: ContentPublicId::Terminal(terminal_public_id),
            name: None,
            browser_url: None,
            terminal_id: Some(terminal_id.into()),
        }));
    }
    changes.extend([
        ResourceChange::SetWorkspaceOrder { workspace_ids: vec![workspace.public_id.clone()] },
        ResourceChange::SetScreenOrder {
            workspace_id: workspace.public_id.clone(),
            screen_ids: vec![screen],
        },
        ResourceChange::SetTabOrder { pane_id: pane, tab_ids: tabs.clone() },
        ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id) },
    ]);
    let mut registry = WorkspaceRegistry::open(root, session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon("seed-held-terminal", "test").unwrap(),
            "workspace.create",
            &serde_json::json!({"fixture":"held-terminal"}),
            None,
            Some(0),
            &ResourcePatch { changes },
            &serde_json::json!({"created":true}),
            &serde_json::json!([{"kind":"fixture.created"}]),
        )
        .unwrap();
    for &(terminal_id, incarnation) in terminals {
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
    }
    tabs
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

/// A holder that gave its link to another connect before it answered this
/// daemon, long after the start: two connects waited at the holder (this
/// daemon's, and one whose client is gone), and the holder read the other one
/// last. The daemon gets the holder's refusal on the connect it kept, and no
/// WELCOME. That is not a dead holder and not another daemon that runs: one
/// new connect in the same ask, with no pause, and the terminal re-attaches
/// on it.
///
/// A guard: this test passed when it was written.
#[test]
fn a_refused_kept_connect_of_a_late_holder_gets_one_new_connect_and_reattaches() {
    let session = Session::new("holder-late-start-taken");
    let holder = session.holder();
    let clock = StepClock::new(STEP, AT_START);
    let mux = session.start(&clock).unwrap();
    assert_eq!(holder.connects(), 1);

    clock.run(LATE_STEP, FAR);
    // The clock stands at its limit: the start is over, and the late thread
    // is in a wait on the connect the start made (a kept connect) that
    // cannot end by time.
    wait_until("the late thread waits far past the old bound", || clock.stands_in_a_wait());
    assert_eq!(
        (session.kept(&mux), holder.connects()),
        ((true, TerminalLifecycle::Running, true, true), 1),
        "((no end, lifecycle, adopting mark, tab), connects) before the refusal: the terminal \
         waits on the one connect of the start"
    );
    let pauses_before_the_refusal = clock.pauses();

    let shell = KeptShell::new();
    holder.order(Order::RefuseHeld(error_code::SUPERSEDED));
    holder.order(Order::Answer(Some(shell.listed())));
    wait_until("the late thread did its work on the terminal", || session.late_work_done(&mux));
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
        "(runtime, lifecycle, no end, incarnation, adopting mark): a refusal on the kept \
         connect must not end the terminal; the same shell, attached again"
    );
    assert_eq!(
        (holder.connects(), clock.pauses()),
        (2, pauses_before_the_refusal),
        "(connects, pauses): one new connect for the one the holder refused, made in the ask \
         that got the refusal, with no pause before it"
    );
    assert!(
        !HolderService::for_root(&session.host_root).unwrap().gave_way(),
        "the daemon gave way to another daemon: no link of its own was taken"
    );
    session.end(mux, holder);
}

/// Refusals in a row, long after the start: the kept connect, and then each
/// of the next 2 connects. The first new connect is made in the ask that got
/// the first refusal. Each later one is made after a pause, so a holder that
/// refuses each connect cannot make the daemon connect in a loop with no
/// pause. The terminal waits all that time, and re-attaches on the first
/// connect the holder answers.
#[test]
fn each_refused_new_connect_of_a_late_holder_costs_one_pause_and_keeps_the_terminal() {
    let session = Session::new("holder-late-start-taken-again");
    let holder = session.holder();
    let clock = StepClock::new(STEP, AT_START);
    let mux = session.start(&clock).unwrap();

    clock.run(LATE_STEP, FAR);
    wait_until("the late thread waits far past the old bound", || clock.stands_in_a_wait());
    let pauses_before_the_refusals = clock.pauses();

    // The stand-in reads the order for the next connects first: the daemon
    // makes its new connect only after the kept one is refused.
    holder.order(Order::RefuseNext(error_code::SUPERSEDED, 2));
    holder.order(Order::RefuseHeld(error_code::SUPERSEDED));
    wait_until("the daemon makes a connect that the holder does not refuse", || {
        holder.connects() >= 4
    });
    assert_eq!(
        session.kept(&mux),
        (true, TerminalLifecycle::Running, true, true),
        "(no end, lifecycle, adopting mark, tab) after 3 refusals in a row: a holder that \
         refuses a connect because another connect took its link still runs the shell"
    );

    let shell = KeptShell::new();
    holder.order(Order::Answer(Some(shell.listed())));
    wait_until("the late thread re-attaches the terminal", || session.late_work_done(&mux));
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(
        (
            resolved.surface.is_some(),
            resolved.terminal.lifecycle,
            resolved.terminal.exit.is_none(),
            resolved.terminal.incarnation.as_deref(),
        ),
        (true, TerminalLifecycle::Running, true, Some(INCARNATION)),
        "(runtime, lifecycle, no end, incarnation): the same shell, attached again"
    );
    assert_eq!(
        (holder.connects(), clock.pauses() - pauses_before_the_refusals),
        (4, 2),
        "(connects, pauses after the first refusal): the connect after the kept one comes \
         with no pause, and each connect after a refused new connect comes after one pause"
    );
    session.end(mux, holder);
}

/// A holder that refuses the token of this daemon does not serve it: that
/// refusal ends the terminals of the holder at the start, as before. Only
/// the refusal for a link that another connect took keeps them.
#[test]
fn a_start_ends_a_terminal_whose_holder_refuses_the_token_of_the_daemon() {
    a_start_ends_a_terminal_whose_holder_refuses(
        "holder-late-start-bad-token",
        error_code::BAD_TOKEN,
        "the token",
    );
}

/// The same for a holder that has no protocol version in common with this
/// daemon: it does not serve it, and its refusal ends the terminals too.
#[test]
fn a_start_ends_a_terminal_whose_holder_refuses_the_version_of_the_daemon() {
    a_start_ends_a_terminal_whose_holder_refuses(
        "holder-late-start-no-version",
        error_code::NO_COMMON_VERSION,
        "each protocol version",
    );
}

/// One start at a holder whose answer to the one ask is the refusal `code`
/// (it refuses `what` of this daemon) and no WELCOME.
fn a_start_ends_a_terminal_whose_holder_refuses(name: &'static str, code: u16, what: &str) {
    let session = Session::new(name);
    let holder = session.holder();
    holder.order(Order::RefuseNext(code, 1));
    // The stand-in read the order: it answers a count only after it.
    assert_eq!(holder.connects(), 0);
    let clock = StepClock::new(Duration::ZERO, AT_START);
    let watch = StartWatch::of(&clock);
    let mux = session.start(&clock).unwrap();
    assert!(
        !watch.ended_by_the_limit(),
        "the start did not end with the holder's refusal: it waited to the failure limit of \
         {START_LIMIT:?}"
    );
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(
        (
            resolved.terminal.lifecycle,
            resolved.terminal.exit.is_some(),
            mux.terminal_is_pending(TERMINAL),
        ),
        (TerminalLifecycle::Exited, true, false),
        "(lifecycle, recorded end, adopting mark): a holder that refuses {what} of this daemon \
         (code {code}) does not run a shell for it"
    );
    session.end(mux, holder);
}

/// A holder that gave its link to another connect before it answered the
/// one ask of the start: two connects waited at the holder (this daemon's,
/// and one whose client is gone), and the holder read the other one last.
/// The start gets the holder's refusal and no WELCOME. A holder that writes
/// a refusal runs, and it still runs every shell: the start must keep each
/// of its terminals, and the late thread re-attaches them on a new connect.
#[test]
fn a_start_keeps_each_terminal_of_a_holder_that_gave_its_link_to_another_connect() {
    let session = Session::with_two_terminals("holder-late-start-first-taken");
    let holder = session.holder();
    holder.order(Order::RefuseNext(error_code::SUPERSEDED, 1));
    // The stand-in read the order: it answers a count only after it.
    assert_eq!(holder.connects(), 0);
    // The clock does not move in the start, so the start's wait for the
    // holder does not end by time: it ends with the holder's refusal.
    let clock = StepClock::new(Duration::ZERO, AT_START);
    let watch = StartWatch::of(&clock);
    let mux = session.start(&clock).unwrap();
    assert!(
        !watch.ended_by_the_limit(),
        "the start did not end with the holder's refusal: it waited to the failure limit of \
         {START_LIMIT:?}"
    );
    assert_eq!(
        (session.kept(&mux), session.kept_second(&mux)),
        (
            (true, TerminalLifecycle::Running, true, true),
            (true, TerminalLifecycle::Running, true, true)
        ),
        "(no end, lifecycle, adopting mark, tab) of terminal {TERMINAL} and of terminal \
         {SECOND_TERMINAL}: a holder that refused the start's connect because another connect \
         took its link still runs the shells"
    );

    clock.run(LATE_STEP, FAR);
    let (first, second) = (KeptShell::new(), KeptShell::new());
    holder.order(Order::AnswerEach(vec![
        first.listed_as(TERMINAL),
        second.listed_as(SECOND_TERMINAL),
    ]));
    wait_until("the late thread re-attaches the terminals", || session.late_work_done(&mux));
    for (terminal, incarnation) in [(TERMINAL, INCARNATION), (SECOND_TERMINAL, SECOND_INCARNATION)]
    {
        let resolved = mux.resolve_terminal(terminal).unwrap().unwrap();
        assert_eq!(
            (
                resolved.surface.is_some(),
                resolved.terminal.lifecycle,
                resolved.terminal.exit.is_none(),
                resolved.terminal.incarnation.as_deref(),
                mux.terminal_is_pending(terminal),
            ),
            (true, TerminalLifecycle::Running, true, Some(incarnation), false),
            "(runtime, lifecycle, no end, incarnation, adopting mark) of {terminal}: the same \
             shell, attached again"
        );
    }
    assert_eq!(holder.connects(), 2, "one new connect of the late thread after the refusal");
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
    let watch = StartWatch::of(&clock);
    let mux = session.start(&clock).unwrap();
    assert!(
        !watch.ended_by_the_limit(),
        "the start did not end when the holder ended its connect: it waited on a connect \
         that the stand-in held, to the failure limit of {START_LIMIT:?}"
    );
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
