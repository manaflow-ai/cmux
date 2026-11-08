//! One seed's run on a paused-clock tokio runtime: the real `RemoteDaemon` and the real
//! `ClientConnection` (Noise handshake, reliable session, heartbeat, reconnect policy at its
//! production defaults) over the simulated carrier (`net.rs`), with an app layer on each side
//! shaped like acpmux's: the machine keeps a durable event log and turns that write to it, the
//! app attaches after the last event it has and resends a prompt by id until its turn starts.
//!
//! The daemon's session lives in memory, so a daemon restart ends it; the event log is on the
//! machine's disk, so it survives. What the carrier must give: inside one session every frame
//! once and in order across any number of reconnects; a session that cannot resume ends with
//! the typed `SessionUnavailable`, so the app knows to start a new one.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectPolicy,
};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{
    DEFAULT_RESUME_LEASE, DaemonSessionPolicy, RemoteDaemon, ServerConnection,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use tempfile::TempDir;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::net::{DaemonSlot, Route, SimGroup, lock};
use crate::plan::{Fault, Plan, Way};
use crate::rng::Rng;

/// The app's own stream on each lane (stream 0 of Control is the connection's).
const APP_STREAM: u64 = 1;
/// How often the app pings the daemon: a recovery counts only once a ping sent after the heal is
/// answered (the staging leg's identify has the same cadence).
const PING: Duration = Duration::from_millis(250);
/// After the plan ends, how long the run may take to converge before it fails.
const CONVERGE: Duration = Duration::from_secs(20 * 60);
/// How often the monitor samples the connection for the recovery times.
const SAMPLE: Duration = Duration::from_millis(50);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    Started,
    Chunk(u32),
    /// The turn ended; `interrupted` when a daemon restart cut it short.
    Result {
        interrupted: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub seq: u64,
    pub prompt: u32,
    pub kind: Kind,
}

impl Event {
    fn encode(&self) -> Bytes {
        let kind = match &self.kind {
            Kind::Started => "started".to_string(),
            Kind::Chunk(n) => format!("chunk{n}"),
            Kind::Result { interrupted } => {
                format!("result{}", if *interrupted { "!" } else { "" })
            }
        };
        Bytes::from(format!("{} {} {kind}", self.seq, self.prompt))
    }

    fn decode(raw: &[u8]) -> Option<(u64, u32, bool)> {
        let text = std::str::from_utf8(raw).ok()?;
        let mut parts = text.split(' ');
        let seq = parts.next()?.parse().ok()?;
        let prompt = parts.next()?.parse().ok()?;
        Some((seq, prompt, parts.next()? == "started"))
    }
}

/// The machine's disk: the event log and the prompts received, which a restart keeps.
#[derive(Default)]
pub struct Disk {
    pub log: Vec<Event>,
    /// Prompt ids in the order they were first received.
    pub received: Vec<u32>,
    /// Received and not yet started.
    pub queue: Vec<u32>,
}

impl Disk {
    fn append(&mut self, prompt: u32, kind: Kind) {
        let seq = self.log.len() as u64 + 1;
        self.log.push(Event { seq, prompt, kind });
    }
}

/// What the app saw.
#[derive(Default)]
pub struct Seen {
    /// Every event seq in the order delivered (duplicates and gaps kept, for the invariants).
    pub seqs: Vec<u64>,
    pub last: u64,
    /// Prompts whose turn the app saw start.
    pub started: BTreeSet<u32>,
    /// Each session's end: `None` for the last one (still open at the end).
    pub ends: Vec<String>,
    pub sessions: u32,
    /// An end that was not the typed `SessionUnavailable`.
    pub untyped_ends: Vec<String>,
    /// When the newest answered ping was sent.
    pub answered_ping_sent: Option<Instant>,
}

/// One fault's recovery: from the end of its cause until the app is connected and has every
/// event the log held at that moment.
#[derive(Clone, Debug)]
pub struct Recovery {
    pub kind: String,
    pub healed_at: Duration,
    pub took: Option<Duration>,
    /// Another fault began before this one's recovery was over, so its time is not this fault's.
    pub interrupted: bool,
}

pub struct Outcome {
    pub plan: Plan,
    pub log: Vec<Event>,
    pub received: Vec<u32>,
    pub seqs: Vec<u64>,
    pub sessions: u32,
    pub ends: Vec<String>,
    pub untyped_ends: Vec<String>,
    pub recoveries: Vec<Recovery>,
    pub restarts: u32,
    /// Faults longer than the resume lease (or daemon restarts): each may end a session.
    pub session_enders: u32,
    pub error: Option<String>,
    pub simulated: Duration,
    pub trace: Vec<String>,
}

type Tasks = Arc<Mutex<Vec<JoinHandle<()>>>>;

struct Machine {
    dir: TempDir,
    disk: Arc<Mutex<Disk>>,
    /// Bumped on every log append, so pushers wake.
    appended: watch::Sender<u64>,
    slot: DaemonSlot,
    /// Every task of the running daemon incarnation (its accepts too), aborted when it dies.
    tasks: Tasks,
    plan: Plan,
    restarts: u32,
    trace: Arc<Mutex<Vec<String>>>,
    start: Instant,
}

impl Machine {
    fn start(&mut self) -> Result<(), String> {
        let auth = AuthDatabase::load_or_create(self.dir.path(), "carrier-sim", false)
            .map_err(|e| format!("auth database: {e}"))?;
        let (daemon, mut accepted) = RemoteDaemon::with_policy(
            auth,
            SessionLimits::default(),
            DaemonSessionPolicy { resume_lease: DEFAULT_RESUME_LEASE },
        )
        .map_err(|e| format!("daemon: {e}"))?;
        // Startup: a turn the last incarnation left open ends interrupted, as acpmux closes a
        // turn a crash cut short.
        {
            let mut disk = lock(&self.disk);
            let open = disk.log.iter().rev().find_map(|e| match e.kind {
                Kind::Started => Some(Some(e.prompt)),
                Kind::Result { .. } => Some(None),
                Kind::Chunk(_) => None,
            });
            if let Some(Some(prompt)) = open {
                disk.append(prompt, Kind::Result { interrupted: true });
                self.appended.send_modify(|n| *n += 1);
            }
        }
        *lock(&self.slot) = Some(daemon);
        let disk = self.disk.clone();
        let appended = self.appended.clone();
        let tasks = self.tasks.clone();
        let (trace, start) = (self.trace.clone(), self.start);
        let serve = tokio::spawn(async move {
            while let Some(connection) = accepted.recv().await {
                let handler = tokio::spawn(serve_connection(
                    connection,
                    disk.clone(),
                    appended.clone(),
                    trace.clone(),
                    start,
                ));
                lock(&tasks).push(handler);
            }
        });
        let agent =
            tokio::spawn(agent(self.disk.clone(), self.appended.clone(), self.plan.clone()));
        lock(&self.tasks).extend([serve, agent]);
        Ok(())
    }

    /// The process dies: no clean close, every link it held drops.
    fn kill(&mut self, routes: &[Arc<Route>; 2]) {
        *lock(&self.slot) = None;
        for task in std::mem::take(&mut *lock(&self.tasks)) {
            task.abort();
        }
        for route in routes {
            route.cut();
        }
        self.restarts += 1;
    }
}

/// The machine's agent: one turn at a time from the queue, each streaming its chunks to the log.
async fn agent(disk: Arc<Mutex<Disk>>, appended: watch::Sender<u64>, plan: Plan) {
    let mut wake = appended.subscribe();
    loop {
        let next = {
            let mut d = lock(&disk);
            if d.queue.is_empty() {
                None
            } else {
                let prompt = d.queue.remove(0);
                d.append(prompt, Kind::Started);
                Some(prompt)
            }
        };
        let Some(prompt) = next else {
            let _ = wake.changed().await;
            continue;
        };
        appended.send_modify(|n| *n += 1);
        let shape = &plan.prompts[prompt as usize];
        for n in 0..shape.chunks {
            tokio::time::sleep(shape.chunk_every).await;
            lock(&disk).append(prompt, Kind::Chunk(n));
            appended.send_modify(|n| *n += 1);
        }
        lock(&disk).append(prompt, Kind::Result { interrupted: false });
        appended.send_modify(|n| *n += 1);
    }
}

/// One client session on the daemon: `attach N` starts the stream after event N, `prompt ID`
/// queues a turn unless that id was received before.
async fn serve_connection(
    connection: Arc<ServerConnection>,
    disk: Arc<Mutex<Disk>>,
    appended: watch::Sender<u64>,
    trace: Arc<Mutex<Vec<String>>>,
    start: Instant,
) {
    let cursor: watch::Sender<Option<u64>> = watch::channel(None).0;
    // The newest ping, answered from a task of its own so a pong held by a full window never
    // stops the reads that bring the acks to free it.
    let ping: watch::Sender<u64> = watch::channel(0).0;
    let ponger = tokio::spawn({
        let connection = connection.clone();
        let mut ping = ping.subscribe();
        async move {
            while ping.changed().await.is_ok() {
                let n = *ping.borrow_and_update();
                let pong = Bytes::from(format!("pong {n}"));
                if connection
                    .send(Lane::Control, APP_STREAM, pong, FrameFlags::empty())
                    .await
                    .is_err()
                {
                    return;
                }
            }
        }
    });
    let pusher = tokio::spawn({
        let connection = connection.clone();
        let disk = disk.clone();
        let mut cursor = cursor.subscribe();
        let mut wake = appended.subscribe();
        let (trace, start) = (trace.clone(), start);
        async move {
            let mut sent = loop {
                if let Some(after) = *cursor.borrow_and_update() {
                    break after;
                }
                if cursor.changed().await.is_err() {
                    return;
                }
            };
            loop {
                let next = lock(&disk).log.get(sent as usize).cloned();
                let Some(event) = next else {
                    wake.borrow_and_update();
                    if wake.changed().await.is_err() {
                        return;
                    }
                    continue;
                };
                if let Err(e) = connection
                    .send(Lane::Interactive, APP_STREAM, event.encode(), FrameFlags::empty())
                    .await
                {
                    lock(&trace).push(format!("{:?} daemon push ended: {e}", start.elapsed()));
                    return;
                }
                sent = event.seq;
            }
        }
    });
    loop {
        let frame = match connection.receive().await {
            Ok(Some(frame)) => frame,
            Ok(None) => {
                lock(&trace).push(format!("{:?} daemon session closed", start.elapsed()));
                break;
            }
            Err(e) => {
                lock(&trace).push(format!("{:?} daemon receive ended: {e}", start.elapsed()));
                break;
            }
        };
        if frame.lane != Lane::Control || frame.stream != APP_STREAM {
            continue;
        }
        let text = String::from_utf8_lossy(&frame.payload).into_owned();
        if let Some(n) = text.strip_prefix("ping ").and_then(|n| n.parse().ok()) {
            ping.send_replace(n);
        } else if let Some(after) = text.strip_prefix("attach ").and_then(|n| n.parse().ok()) {
            cursor.send_replace(Some(after));
        } else if let Some(id) = text.strip_prefix("prompt ").and_then(|n| n.parse().ok()) {
            let mut d = lock(&disk);
            if !d.received.contains(&id) {
                d.received.push(id);
                d.queue.push(id);
                drop(d);
                appended.send_modify(|n| *n += 1);
            }
        }
    }
    pusher.abort();
    ponger.abort();
}

fn client_config(session: SessionId, expected: [u8; 32]) -> Result<ClientConnectionConfig, String> {
    Ok(ClientConnectionConfig {
        identity: StaticIdentity::generate().map_err(|e| format!("identity: {e}"))?,
        expected_daemon: Some(expected),
        auth: ClientAuthMode::Carrier,
        device_name: "carrier-sim".into(),
        session,
        lane_policy: LanePolicy::Auto,
        limits: SessionLimits::default(),
        // The carrier dial's policy (`cmux-tui/src/carrier/client.rs` uses the defaults), with
        // jitter off so a seed is one schedule.
        reconnect: ReconnectPolicy { full_jitter: false, ..ReconnectPolicy::default() },
    })
}

/// When a fault's cause ends, what ends it, its kind, and whether its recovery is timed from then.
type Heal = (Instant, Box<dyn FnOnce(&mut Machine) + Send>, String, bool);

/// What the app runs with.
struct App {
    group: Arc<SimGroup>,
    expected: [u8; 32],
    plan: Plan,
    seen: Arc<Mutex<Seen>>,
    connected: watch::Sender<bool>,
    done: watch::Receiver<bool>,
    rng: Rng,
    trace: Arc<Mutex<Vec<String>>>,
}

/// The app: one session after another until every prompt's turn is in, each attaching after the
/// last event it has and resending the prompts whose turn it has not seen start.
async fn app(app: App) -> Result<(), String> {
    let App { group, expected, plan, seen, connected, done, mut rng, trace } = app;
    let start = Instant::now();
    // The prompts the app has been asked to send so far: they go out at their plan times.
    let asked: watch::Sender<u32> = watch::channel(0).0;
    let schedule = tokio::spawn({
        let asked = asked.clone();
        let times: Vec<Duration> = plan.prompts.iter().map(|p| p.at).collect();
        async move {
            for (n, at) in times.into_iter().enumerate() {
                tokio::time::sleep_until(start + at).await;
                asked.send_replace(n as u32 + 1);
            }
        }
    });
    // A redial after a failed connect: the carrier dial's backoff (250 ms doubling to 10 s,
    // `carrier/contract.rs`), without its jitter.
    let mut delay = Duration::from_millis(250);
    let result = loop {
        let mut id = [0_u8; 16];
        for b in &mut id {
            *b = rng.range(0, 255) as u8;
        }
        let session = SessionId(id);
        let config = client_config(session, expected)?;
        let client = match ClientConnection::connect(group.for_new_session(), config).await {
            Ok(client) => client,
            Err(e) => {
                lock(&trace).push(format!("{:?} connect failed: {e}", start.elapsed()));
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(Duration::from_secs(10));
                continue;
            }
        };
        delay = Duration::from_millis(250);
        lock(&seen).sessions += 1;
        lock(&trace).push(format!(
            "{:?} session {} connected",
            start.elapsed(),
            lock(&seen).sessions
        ));
        let end = run_session(&client, &seen, &asked, &connected, done.clone()).await;
        connected.send_replace(false);
        if matches!(end, SessionEnd::Ended(..)) {
            let daemon = lock(&group.daemon).clone();
            let held = match daemon {
                Some(d) => format!("{:?}", d.connection_snapshots().await),
                None => "no daemon".into(),
            };
            let mine = client.snapshot().await;
            lock(&trace).push(format!(
                "{:?} at the end, client: {mine:?}; daemon: {held}",
                start.elapsed()
            ));
        }
        let _ = tokio::time::timeout(Duration::from_secs(3), client.close()).await;
        match end {
            SessionEnd::Done => break Ok(()),
            SessionEnd::Ended(why, typed) => {
                lock(&trace).push(format!("{:?} session ended: {why}", start.elapsed()));
                let mut s = lock(&seen);
                s.ends.push(why.clone());
                if !typed {
                    s.untyped_ends.push(why);
                }
            }
        }
    };
    schedule.abort();
    result
}

enum SessionEnd {
    Done,
    /// Why, and whether it was the typed `SessionUnavailable`.
    Ended(String, bool),
}

async fn run_session(
    client: &Arc<ClientConnection>,
    seen: &Arc<Mutex<Seen>>,
    asked: &watch::Sender<u32>,
    connected: &watch::Sender<bool>,
    done: watch::Receiver<bool>,
) -> SessionEnd {
    let last = lock(seen).last;
    let attach = Bytes::from(format!("attach {last}"));
    if let Err(e) = client.send(Lane::Control, APP_STREAM, attach, FrameFlags::empty()).await {
        return ended(e);
    }
    connected.send_replace(true);
    // Every send goes from a task of its own, so a send held by a full window or a recovery never
    // stops the receives that bring the acks to free it (as an app's reader and writer are apart).
    let pings: Arc<Mutex<BTreeMap<u64, Instant>>> = Arc::default();
    let mut sender =
        tokio::spawn(send_app(client.clone(), seen.clone(), asked.subscribe(), pings.clone()));
    let end = tokio::select! {
        end = serve_app(client, seen, &pings, done) => end,
        sent = &mut sender => match sent {
            Ok(Err(e)) => ended(e),
            Ok(Ok(())) | Err(_) => SessionEnd::Ended("the sender stopped".into(), false),
        },
    };
    sender.abort();
    end
}

/// The app's sends: each prompt asked for and not seen started, once per session (the session's
/// own replay carries them across reconnects; a new session needs them again), and a ping every
/// `PING`.
async fn send_app(
    client: Arc<ClientConnection>,
    seen: Arc<Mutex<Seen>>,
    mut asked: watch::Receiver<u32>,
    pings: Arc<Mutex<BTreeMap<u64, Instant>>>,
) -> Result<(), ConnectionError> {
    let send = |text: String| {
        let client = client.clone();
        async move {
            client.send(Lane::Control, APP_STREAM, Bytes::from(text), FrameFlags::empty()).await
        }
    };
    let mut sent_here = 0_u32;
    let mut next_ping = Instant::now() + PING;
    for n in 1_u64.. {
        let want = *asked.borrow_and_update();
        while sent_here < want {
            let id = sent_here;
            sent_here += 1;
            if !lock(&seen).started.contains(&id) {
                send(format!("prompt {id}")).await?;
            }
        }
        tokio::select! {
            _ = asked.changed() => continue,
            () = tokio::time::sleep_until(next_ping) => {}
        }
        next_ping = Instant::now() + PING;
        lock(&pings).insert(n, Instant::now());
        send(format!("ping {n}")).await?;
    }
    Ok(())
}

async fn serve_app(
    client: &Arc<ClientConnection>,
    seen: &Arc<Mutex<Seen>>,
    pings: &Arc<Mutex<BTreeMap<u64, Instant>>>,
    mut done: watch::Receiver<bool>,
) -> SessionEnd {
    loop {
        if *done.borrow_and_update() {
            return SessionEnd::Done;
        }
        tokio::select! {
            _ = done.changed() => {}
            frame = client.receive() => match frame {
                Ok(Some(frame)) => {
                    if frame.lane == Lane::Control && frame.stream == APP_STREAM {
                        let text = String::from_utf8_lossy(&frame.payload);
                        // A pong answers the newest ping the daemon had; older ones are moot.
                        let sent = text.strip_prefix("pong ").and_then(|n| n.parse::<u64>().ok()).and_then(
                            |n| {
                                let mut pings = lock(pings);
                                let sent = pings.remove(&n);
                                *pings = pings.split_off(&n);
                                sent
                            },
                        );
                        if let Some(sent) = sent {
                            let mut s = lock(seen);
                            s.answered_ping_sent = s.answered_ping_sent.max(Some(sent));
                        }
                        continue;
                    }
                    if frame.lane != Lane::Interactive || frame.stream != APP_STREAM {
                        continue;
                    }
                    let Some((seq, prompt, started)) = Event::decode(&frame.payload) else {
                        continue;
                    };
                    let mut s = lock(seen);
                    s.seqs.push(seq);
                    s.last = s.last.max(seq);
                    if started {
                        s.started.insert(prompt);
                    }
                }
                Ok(None) => return SessionEnd::Ended("the connection closed".into(), false),
                Err(e) => return ended(e),
            },
        }
    }
}

fn ended(e: ConnectionError) -> SessionEnd {
    let typed = matches!(e, ConnectionError::SessionUnavailable);
    SessionEnd::Ended(e.to_string(), typed)
}

pub fn human(d: Duration) -> String {
    let s = d.as_secs();
    if s >= 3600 {
        format!("{}h{:02}m", s / 3600, (s % 3600) / 60)
    } else if s >= 60 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{:.1}s", d.as_secs_f64())
    }
}

/// Run one seed.
pub fn run(seed: u64, faults: bool) -> Outcome {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .expect("runtime");
    runtime.block_on(run_world(seed, faults))
}

async fn run_world(seed: u64, faults: bool) -> Outcome {
    let mut rng = Rng::new(seed);
    let plan = Plan::new(&mut rng.split(1), faults);
    let trace = Arc::new(Mutex::new(Vec::new()));
    let routes = [
        Route::new("relay-a", rng.split(2), plan.latency_ms[0], trace.clone()),
        Route::new("relay-b", rng.split(3), plan.latency_ms[1], trace.clone()),
    ];
    let mut outcome = Outcome {
        plan: plan.clone(),
        log: Vec::new(),
        received: Vec::new(),
        seqs: Vec::new(),
        sessions: 0,
        ends: Vec::new(),
        untyped_ends: Vec::new(),
        recoveries: Vec::new(),
        restarts: 0,
        session_enders: plan
            .faults
            .iter()
            .filter(|s| {
                matches!(s.fault, Fault::DaemonRestart { .. })
                    || s.fault.lasts() > DEFAULT_RESUME_LEASE
            })
            .count() as u32,
        error: None,
        simulated: Duration::ZERO,
        trace: Vec::new(),
    };
    let dir = match tempfile::tempdir() {
        Ok(dir) => dir,
        Err(e) => {
            outcome.error = Some(format!("tempdir: {e}"));
            return outcome;
        }
    };
    let mut machine = Machine {
        dir,
        disk: Arc::new(Mutex::new(Disk::default())),
        appended: watch::channel(0).0,
        slot: Arc::new(Mutex::new(None)),
        tasks: Arc::new(Mutex::new(Vec::new())),
        plan: plan.clone(),
        restarts: 0,
        trace: trace.clone(),
        start: Instant::now(),
    };
    if let Err(e) = machine.start() {
        outcome.error = Some(e);
        return outcome;
    }
    let expected = match lock(&machine.slot).as_ref().map(|d| d.auth().identity().public_key()) {
        Some(key) => key,
        None => {
            outcome.error = Some("no daemon after start".into());
            return outcome;
        }
    };
    let active = Arc::new(Mutex::new(0_usize));
    let group = Arc::new(SimGroup::new(
        routes.clone(),
        active.clone(),
        machine.slot.clone(),
        machine.tasks.clone(),
        trace.clone(),
    ));
    let seen = Arc::new(Mutex::new(Seen::default()));
    let connected = watch::channel(false).0;
    // Every prompt's turn has its result and the app has the whole log.
    let done = watch::channel(false).0;
    let start = Instant::now();
    let mut app_task = tokio::spawn(app(App {
        group,
        expected,
        plan: plan.clone(),
        seen: seen.clone(),
        connected: connected.clone(),
        done: done.subscribe(),
        rng: rng.split(5),
        trace: trace.clone(),
    }));

    // The fault driver, then the wait for the app to finish, sampling for recoveries.
    let mut pending: Vec<(String, Instant, u64)> = Vec::new();
    let mut steps = plan.faults.iter().peekable();
    // When each fault's cause ends, what ends it, and whether its recovery is timed from then
    // (a swap's is timed from its start: the other relay is there at once).
    let mut heals: Vec<Heal> = Vec::new();
    let deadline = start
        + plan.faults.last().map_or(Duration::ZERO, |s| s.at + s.fault.lasts())
        + plan.prompts.last().map_or(Duration::ZERO, |p| p.at)
        + CONVERGE;
    let mut traced: Option<(bool, u64, usize)> = None;
    let result = loop {
        let now = Instant::now();
        // Apply what is due.
        while let Some(step) = steps.next_if(|step| start + step.at <= now) {
            let step = *step;
            lock(&trace).push(format!("{:?} fault {:?}", step.at, step.fault));
            for (kind, healed, _) in pending.drain(..) {
                outcome.recoveries.push(Recovery {
                    kind,
                    healed_at: healed - start,
                    took: None,
                    interrupted: true,
                });
            }
            let kind = step.fault.kind();
            let lasts = step.fault.lasts();
            match step.fault {
                Fault::Cut => {
                    for r in &routes {
                        r.cut();
                    }
                }
                Fault::Drop { way, .. } => {
                    let route = routes[*lock(&active)].clone();
                    route.set(|c| {
                        c.down = true;
                        c.frozen_up |= way != Way::Down;
                        c.frozen_down |= way != Way::Up;
                    });
                    heals.push((
                        now + lasts,
                        Box::new(move |_| {
                            route.set(|c| {
                                c.down = false;
                                c.frozen_up = false;
                                c.frozen_down = false;
                            });
                        }),
                        kind.clone(),
                        true,
                    ));
                }
                Fault::Slow { factor, .. } => {
                    let route = routes[*lock(&active)].clone();
                    route.set(|c| c.slow = factor);
                    heals.push((
                        now + lasts,
                        Box::new(move |_| route.set(|c| c.slow = 1)),
                        kind.clone(),
                        true,
                    ));
                }
                Fault::Swap { .. } => {
                    let from = *lock(&active);
                    let old = routes[from].clone();
                    old.set(|c| {
                        c.frozen_up = true;
                        c.frozen_down = true;
                    });
                    *lock(&active) = 1 - from;
                    pending.push((kind.clone(), now, lock(&machine.disk).log.len() as u64));
                    heals.push((
                        now + lasts,
                        Box::new(move |_| {
                            old.set(|c| {
                                c.frozen_up = false;
                                c.frozen_down = false;
                            });
                        }),
                        kind.clone(),
                        false,
                    ));
                }
                Fault::DaemonRestart { .. } => {
                    machine.kill(&routes);
                    heals.push((
                        now + lasts,
                        Box::new(|m: &mut Machine| {
                            if let Err(e) = m.start() {
                                eprintln!("carrier sim: daemon restart failed: {e}");
                            }
                        }),
                        kind.clone(),
                        true,
                    ));
                }
            }
            if lasts.is_zero() {
                pending.push((kind, now, lock(&machine.disk).log.len() as u64));
            }
        }
        // Heal what is due.
        let mut i = 0;
        while i < heals.len() {
            if heals[i].0 <= now {
                let (_, heal, kind, timed) = heals.remove(i);
                heal(&mut machine);
                let daemon = lock(&machine.slot).clone();
                let sessions = match daemon {
                    Some(d) => format!("{:?}", d.connection_snapshots().await),
                    None => "no daemon".into(),
                };
                lock(&trace).push(format!("{:?} healed {kind}; daemon: {sessions}", now - start));
                if timed {
                    pending.push((kind, now, lock(&machine.disk).log.len() as u64));
                }
            } else {
                i += 1;
            }
        }
        // The trace: each change of the app's connection or of what it has.
        {
            let state = (*connected.borrow(), lock(&seen).last, lock(&machine.disk).log.len());
            if Some(state) != traced {
                lock(&trace).push(format!(
                    "{:?} app connected={} has {} of {} events",
                    now - start,
                    state.0,
                    state.1,
                    state.2
                ));
                traced = Some(state);
            }
        }
        // A recovery is over once the app is connected, has what the log held at the heal, and has
        // an answer to a ping it sent after the heal (the session works again, not only a flag).
        {
            let (caught_up, answered) = {
                let s = lock(&seen);
                (s.last, s.answered_ping_sent)
            };
            let up = *connected.borrow();
            pending.retain(|(kind, healed, target)| {
                if up && caught_up >= *target && answered.is_some_and(|sent| sent >= *healed) {
                    outcome.recoveries.push(Recovery {
                        kind: kind.clone(),
                        healed_at: *healed - start,
                        took: Some(now - *healed),
                        interrupted: false,
                    });
                    false
                } else {
                    true
                }
            });
        }
        // The app is done when every prompt's turn has its result and every fault is over and measured: a
        // recovery is timed only while the app is still connected.
        if steps.peek().is_none() && heals.is_empty() && pending.is_empty() {
            let disk = lock(&machine.disk);
            let results = disk.log.iter().filter(|e| matches!(e.kind, Kind::Result { .. })).count();
            let all = results == plan.prompts.len();
            let last = disk.log.len() as u64;
            drop(disk);
            done.send_replace(all && lock(&seen).last >= last);
        }
        if app_task.is_finished() {
            break match (&mut app_task).await {
                Ok(Ok(())) => None,
                Ok(Err(e)) => Some(e),
                Err(e) => Some(format!("app task: {e}")),
            };
        }
        if now >= deadline {
            app_task.abort();
            break Some(format!("did not converge {} after the plan ended", human(CONVERGE)));
        }
        tokio::time::sleep(SAMPLE).await;
    };
    for (kind, healed, _) in pending {
        outcome.recoveries.push(Recovery {
            kind,
            healed_at: healed - start,
            took: None,
            interrupted: false,
        });
    }
    outcome.simulated = start.elapsed();
    outcome.error = result;
    {
        let disk = lock(&machine.disk);
        outcome.log = disk.log.clone();
        outcome.received = disk.received.clone();
    }
    {
        let s = lock(&seen);
        outcome.seqs = s.seqs.clone();
        outcome.sessions = s.sessions;
        outcome.ends = s.ends.clone();
        outcome.untyped_ends = s.untyped_ends.clone();
    }
    outcome.restarts = machine.restarts;
    outcome.trace = std::mem::take(&mut *lock(&trace));
    for task in std::mem::take(&mut *lock(&machine.tasks)) {
        task.abort();
    }
    outcome
}
