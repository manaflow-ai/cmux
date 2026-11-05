//! The daemon's side of the mesh relay (`mesh.rs`): two loops and the delivery of one message.
//! [`start_configured`] starts them when config.json names a hub (`meshRelay`, `mesh_http.rs`);
//! without one nothing here runs. A send to a name nobody here resolves is `mesh_send.rs`'s.
//!
//! The heartbeat sends this daemon's sessions (`Hub::mesh_rows`) every `heartbeat_every`, or a
//! third of the hub's row TTL when that is sooner (never sooner than `min_poll_gap`). Its reply
//! names this daemon (`daemonId`); the inbox does not poll before that. It stops as the inbox
//! does; a stop sends one last, empty heartbeat (at most 5 s), so the address book drops this
//! daemon's rows at once rather than at their TTL. A refusal either loop meets stops both, so a
//! daemon whose inbox the hub refuses is not left listed.
//!
//! The inbox long-polls the hub (`inbox_wait`), never more often than `min_poll_gap`, after an
//! answer or a failure alike (a hub that answers at once, with nothing or an error, is no busy
//! loop), and delivers each message on its own task, at most `max_in_flight` at a time; a message
//! already being delivered is not started again. After a failed call each loop waits, doubling from `backoff_first` to `backoff_cap` (or the hub's
//! `retryAfterSeconds`, if longer), and logs only the first failure of a run of them and the
//! recovery. Both loops stop when [`MeshRelay`] is stopped or dropped, when the daemon stops (its
//! hub's `shutdown`, or the hub gone), or when the mesh hub refuses a call itself (a bad
//! credential, a request it will never take: retrying cannot help, so it logs that once and the
//! loop stays off until the daemon starts again); deliveries in flight then end unacked, and
//! their leases bring them back.
//!
//! A message is delivered as a send here is (`outbox.rs` `attempt_once`), on a connection of
//! `Origin::Peer`, so a relayed message is held to exactly a peer daemon's rules: it reads no
//! peer of this host, no peer state and no host suggestion. Only a session of this daemon takes
//! it ([`Hub::mesh_target`]); a name this daemon's peers list is refused, never forwarded. Its
//! prompt id is the message id, with `resend`, so a message the hub leases again (a lost ack, a
//! restart) answers with its first run instead of running twice (`hub/prompt_ledger.rs`).

use super::*;
use crate::mesh::{
    Ack, Backoff, ControlHook, Heartbeat, HubError, InMessage, Kind, MeshHub, Mode, StartWork,
};
use crate::mesh_http::MeshControlFrom;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Weak;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};

#[path = "mesh_control_ledger.rs"]
mod control_ledger;
use control_ledger::{Claim, ControlLedger};

/// A read of a session through the hub, both sides (`mesh_read.rs`).
#[path = "mesh_read.rs"]
pub(crate) mod read;

/// The loops' timings.
#[derive(Debug, Clone)]
pub struct RelayOptions {
    /// The longest time between two heartbeats.
    pub heartbeat_every: Duration,
    /// How long one inbox call waits for a message.
    pub inbox_wait: Duration,
    /// The least time between the starts of two inbox calls.
    pub min_poll_gap: Duration,
    pub backoff_first: Duration,
    pub backoff_cap: Duration,
    /// Deliveries running at once; the inbox waits for one to end past it.
    pub max_in_flight: usize,
}

impl Default for RelayOptions {
    fn default() -> Self {
        Self {
            heartbeat_every: Duration::from_secs(30),
            inbox_wait: Duration::from_secs(25),
            min_poll_gap: Duration::from_secs(1),
            backoff_first: Duration::from_secs(1),
            backoff_cap: Duration::from_secs(60),
            max_in_flight: 32,
        }
    }
}

/// The running relay. Dropping it stops it as [`MeshRelay::stop`] does, without waiting.
pub struct MeshRelay {
    /// Shared with both loops: a refusal one of them meets stops the other too.
    stop: Arc<watch::Sender<bool>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl MeshRelay {
    pub fn start(
        hub: &Arc<Hub>,
        client: Arc<dyn MeshHub>,
        control: Arc<dyn ControlHook>,
        options: RelayOptions,
    ) -> Self {
        let (stop, stopped) = watch::channel(false);
        let stop = Arc::new(stop);
        let options = Arc::new(options);
        // This daemon's id at the hub, from its heartbeat reply: a message naming it is ours, and
        // the inbox waits for it, so no message meets a daemon that does not know its own id yet.
        let (daemon, own) = watch::channel(None);
        let halt = Halt(stop.clone());
        let beat = Arc::new(Beat::new());
        let beats = heartbeats(
            Arc::downgrade(hub),
            client.clone(),
            options.clone(),
            daemon,
            beat.clone(),
            halt.clone(),
            stopped.clone(),
        );
        let inbox = inbox(Arc::downgrade(hub), client, control, options, own, beat, halt, stopped);
        let tasks = vec![tokio::spawn(beats), tokio::spawn(inbox)];
        Self { stop, tasks }
    }

    /// Whether its loops have ended: stopped, the daemon stopping, or refused by the mesh hub.
    pub fn is_finished(&self) -> bool {
        self.tasks.iter().all(tokio::task::JoinHandle::is_finished)
    }

    /// Stop both loops and wait for them: the last heartbeat is sent.
    pub async fn stop(mut self) {
        let _ = self.stop.send(true);
        for task in std::mem::take(&mut self.tasks) {
            let _ = task.await;
        }
    }
}

impl Drop for MeshRelay {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
    }
}

/// Resolves once the relay is stopped or its handle dropped.
async fn stopped(stop: &mut watch::Receiver<bool>) {
    while !*stop.borrow_and_update() {
        if stop.changed().await.is_err() {
            return;
        }
    }
}

/// Whether the daemon is stopping, or its hub gone.
fn hub_ended(hub: &Weak<Hub>) -> bool {
    hub.upgrade().is_none_or(|hub| hub.is_stopping())
}

/// How often a waiting loop reads the daemon's stopping flag, which some shutdown paths (a
/// signal, `shutdown_all`) set without notifying `Hub::shutdown`.
const STOPPING_RECHECK: Duration = Duration::from_secs(1);

/// Resolves once the relay is stopped or its handle dropped, or the daemon stops: its hub's
/// `shutdown` (registered before the stopping flag is read, so none is missed), its stopping flag
/// (read again every [`STOPPING_RECHECK`]) or the hub gone.
async fn ended(stop: &mut watch::Receiver<bool>, hub: &Weak<Hub>) {
    let Some(hub) = hub.upgrade() else { return };
    let shutdown = hub.shutdown.notified();
    tokio::pin!(shutdown);
    shutdown.as_mut().enable();
    let mut recheck = tokio::time::interval(STOPPING_RECHECK);
    recheck.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        if hub.is_stopping() {
            return;
        }
        tokio::select! {
            () = stopped(stop) => return,
            () = &mut shutdown => return,
            _ = recheck.tick() => {}
        }
    }
}

/// Waits for the daemon's startup (its sessions listed), unless the relay stops first.
async fn started(hub: &Weak<Hub>, stop: &mut watch::Receiver<bool>) -> bool {
    let Some(strong) = hub.upgrade() else { return false };
    tokio::select! {
        () = strong.wait_startup() => true,
        () = ended(stop, hub) => false,
    }
}

/// The relay config.json names, started with the HTTPS client, which also becomes the hub's
/// for sends (`Hub::mesh`). None, and nothing started, when none is named or it is unusable.
pub async fn start_configured(hub: &Arc<Hub>) -> Option<MeshRelay> {
    let config = hub.config.read().await.mesh_relay.clone()?;
    let client: Arc<dyn MeshHub> = match crate::mesh_http::HttpHub::new(&config) {
        Ok(client) => Arc::new(client),
        Err(e) => {
            tracing::warn!("mesh relay off: {e}");
            return None;
        }
    };
    let _ = hub.mesh.set(client.clone());
    // The origin only (no user, password or query is accepted in the URL).
    let shown = config.shown();
    tracing::info!("mesh relay: on, through {shown}");
    let ledger = hub.store.handoff_dir().map(|dir| dir.join("mesh-controls.json"));
    let control = Arc::new(
        MeshControlHook::new(config.control_from, ledger)
            .with_own_user(Arc::new(crate::cli::cloud_join::machine_user_id)),
    );
    Some(MeshRelay::start(hub, client, control, RelayOptions::default()))
}

/// The wait after a failed call: the next backoff, or the hub's own wait when longer.
fn after_failure(backoff: &mut Backoff, e: &HubError) -> Duration {
    backoff.next_wait().max(e.retry_after.unwrap_or_default())
}

/// The least time between heartbeats: the hub takes fewer than 30 a minute.
const HEARTBEAT_FLOOR: Duration = Duration::from_millis(2500);

/// The wait after a heartbeat the hub took: a third of its TTL, at most `heartbeat_every`.
fn heartbeat_wait(options: &RelayOptions, ttl_seconds: u64) -> Duration {
    let third = Duration::from_millis(ttl_seconds.saturating_mul(1000) / 3);
    if third.is_zero() { options.heartbeat_every } else { third.min(options.heartbeat_every) }
}

/// How long a start's ack waits for the heartbeat that lists its new session.
const START_LISTED_WAIT: Duration = Duration::from_secs(5);

/// A heartbeat on demand. A start through the hub acks only once a heartbeat that lists the new
/// session was taken, so the sender's next message to it finds it in the hub's address book
/// (the hub routes a name only to a session a heartbeat listed, `mesh.unknown_recipient`
/// otherwise); waiting for the timer left a send right after the start refused for up to 30 s.
struct Beat {
    nudge: tokio::sync::Notify,
    /// Requests made; a heartbeat covers every request made before it read the sessions.
    asked: std::sync::atomic::AtomicU64,
    /// The last request a heartbeat the hub took covered.
    listed: watch::Sender<u64>,
}

impl Beat {
    fn new() -> Self {
        Self {
            nudge: tokio::sync::Notify::new(),
            asked: Default::default(),
            listed: watch::channel(0).0,
        }
    }

    /// A heartbeat now (no sooner than the floor after the last one), and its taking, waited
    /// for at most `within`.
    async fn now(&self, within: Duration) {
        let want = self.asked.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let mut listed = self.listed.subscribe();
        self.nudge.notify_one();
        let _ = tokio::time::timeout(within, listed.wait_for(|n| *n >= want)).await;
    }

    /// The requests a heartbeat reading the sessions now covers.
    fn covers(&self) -> u64 {
        self.asked.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn taken(&self, covered: u64) {
        self.listed.send_if_modified(|n| {
            let newer = covered > *n;
            if newer {
                *n = covered;
            }
            newer
        });
    }
}

/// Stops both loops: what one loop does when the mesh hub refuses it for good, so the other
/// neither waits nor heartbeats on for a daemon that takes nothing.
#[derive(Clone)]
struct Halt(Arc<watch::Sender<bool>>);

impl Halt {
    fn all(&self) {
        let _ = self.0.send(true);
    }
}

async fn heartbeats(
    hub: Weak<Hub>,
    client: Arc<dyn MeshHub>,
    options: Arc<RelayOptions>,
    daemon: watch::Sender<Option<String>>,
    beat: Arc<Beat>,
    halt: Halt,
    mut stop: watch::Receiver<bool>,
) {
    if !started(&hub, &mut stop).await {
        return;
    }
    let host = crate::pairing::machine_name();
    let mut backoff = Backoff::new(options.backoff_first, options.backoff_cap);
    let mut failing = false;
    loop {
        if hub_ended(&hub) {
            break;
        }
        let began = tokio::time::Instant::now();
        let covered = beat.covers();
        let sessions = match hub.upgrade() {
            Some(hub) => hub.mesh_rows().await,
            None => break,
        };
        let listing = Heartbeat { host: host.clone(), sessions, leaving: false };
        let mut taken = false;
        let wait = tokio::select! {
            r = client.heartbeat(&listing) => match r {
                Ok(reply) => {
                    beat.taken(covered);
                    taken = true;
                    if std::mem::take(&mut failing) {
                        tracing::info!("mesh relay: the hub takes heartbeats again");
                    }
                    backoff.reset();
                    if !reply.daemon_id.is_empty() {
                        daemon.send_if_modified(|d| {
                            let new = d.as_deref() != Some(reply.daemon_id.as_str());
                            if new {
                                *d = Some(reply.daemon_id.clone());
                            }
                            new
                        });
                    }
                    heartbeat_wait(&options, reply.ttl_seconds)
                }
                Err(e) if e.ends_relay() => {
                    if matches!(e.code.as_deref(), Some("machine.revoked" | "mesh.unauthorized")) {
                        tracing::error!("revoked: run machine add again");
                    } else {
                        tracing::error!(
                            "mesh relay: the hub refused this daemon's heartbeat ({e}); the relay is off until the daemon restarts"
                        );
                    }
                    halt.all();
                    return;
                }
                Err(e) => {
                    if !std::mem::replace(&mut failing, true) {
                        tracing::warn!("mesh relay: heartbeat failed ({e}); retrying with backoff");
                    }
                    after_failure(&mut backoff, &e)
                }
            },
            () = ended(&mut stop, &hub) => break,
        };
        let floor = HEARTBEAT_FLOOR.max(options.min_poll_gap);
        let wait = wait.max(floor);
        // A start's request beats sooner, never under the floor nor during a backoff.
        let nudged = async {
            if !taken {
                return std::future::pending().await;
            }
            beat.nudge.notified().await;
            tokio::time::sleep_until(began + floor).await;
        };
        let read_receipts = async {
            if let Some(hub) = hub.upgrade() {
                let budget = wait.min(Duration::from_secs(5));
                let _ = tokio::time::timeout(budget, hub.flush_team_read_receipts(client.as_ref()))
                    .await;
            }
        };
        tokio::select! {
            () = async {
                tokio::join!(
                    async { tokio::select! { () = tokio::time::sleep(wait) => {}, () = nudged => {} } },
                    read_receipts
                );
            } => {}
            () = ended(&mut stop, &hub) => break,
        }
    }
    let last = Heartbeat { host, sessions: Vec::new(), leaving: true };
    let _ = tokio::time::timeout(Duration::from_secs(5), client.heartbeat(&last)).await;
}

async fn inbox(
    hub: Weak<Hub>,
    client: Arc<dyn MeshHub>,
    control: Arc<dyn ControlHook>,
    options: Arc<RelayOptions>,
    mut own: watch::Receiver<Option<String>>,
    beat: Arc<Beat>,
    halt: Halt,
    mut stop: watch::Receiver<bool>,
) {
    let mut backoff = Backoff::new(options.backoff_first, options.backoff_cap);
    let mut failing = false;
    let mut skipped = false;
    if !started(&hub, &mut stop).await {
        return;
    }
    // Not before the hub has named this daemon (its first heartbeat reply).
    tokio::select! {
        r = own.wait_for(Option::is_some) => if r.is_err() { return },
        () = ended(&mut stop, &hub) => return,
    }
    let mut deliveries = tokio::task::JoinSet::new();
    let in_flight: Arc<StdMutex<HashSet<String>>> = Arc::default();
    loop {
        while deliveries.try_join_next().is_some() {}
        if deliveries.len() >= options.max_in_flight.max(1) {
            tokio::select! {
                _ = deliveries.join_next() => continue,
                () = ended(&mut stop, &hub) => break,
            }
        }
        if hub_ended(&hub) {
            break;
        }
        let started = Instant::now();
        // Only as many as it can deliver now: a leased message waits for its ack.
        let room = options.max_in_flight.max(1) - deliveries.len();
        let polled = tokio::select! {
            r = client.inbox(options.inbox_wait, room) => r,
            () = ended(&mut stop, &hub) => break,
        };
        let wait = match polled {
            Ok(messages) => {
                if std::mem::take(&mut failing) {
                    tracing::info!("mesh relay: the hub's inbox answers again");
                }
                backoff.reset();
                for message in messages {
                    // A malformed id would go into the ack's path and the log: skipped, and its
                    // lease brings it back to be skipped again (logged once per run, without it).
                    if !crate::mesh::is_message_id(&message.message_id) {
                        if !std::mem::replace(&mut skipped, true) {
                            tracing::warn!("mesh relay: skipped a message whose id is malformed");
                        }
                        continue;
                    }
                    if !in_flight.lock_or_recover().insert(message.message_id.clone()) {
                        continue;
                    }
                    let Some(hub) = hub.upgrade() else { return };
                    let (client, control, in_flight, beat) =
                        (client.clone(), control.clone(), in_flight.clone(), beat.clone());
                    let own_id = own.borrow().clone();
                    deliveries.spawn(async move {
                        let ack =
                            deliver(&hub, &message, control.as_ref(), own_id.as_deref()).await;
                        // A started session is in the hub's address book before its sender
                        // hears the start went through.
                        if message.kind == Kind::Control
                            && message.op.as_deref() == Some("start")
                            && ack
                                .as_ref()
                                .is_some_and(|a| a.state == crate::mesh::AckState::Delivered)
                        {
                            beat.now(START_LISTED_WAIT).await;
                        }
                        if let Some(ack) = ack
                            && let Err(e) = client.ack(&message.message_id, &clip(ack)).await
                        {
                            // Its lease brings it back, and that delivery answers with this one.
                            tracing::warn!("mesh relay: ack of {} failed: {e}", message.message_id);
                        }
                        in_flight.lock_or_recover().remove(&message.message_id);
                    });
                }
                options.min_poll_gap.saturating_sub(started.elapsed())
            }
            Err(e) if e.ends_relay() => {
                if matches!(e.code.as_deref(), Some("machine.revoked" | "mesh.unauthorized")) {
                    tracing::error!("revoked: run machine add again");
                } else {
                    tracing::error!(
                        "mesh relay: the hub refused this daemon's inbox ({e}); the relay is off until the daemon restarts"
                    );
                }
                halt.all();
                break;
            }
            Err(e) => {
                if !std::mem::replace(&mut failing, true) {
                    tracing::warn!("mesh relay: inbox failed ({e}); retrying with backoff");
                }
                // Never sooner than the poll floor: the backoff's jitter only shortens a wait.
                let floor = options.min_poll_gap.saturating_sub(started.elapsed());
                after_failure(&mut backoff, &e).max(floor)
            }
        };
        if !wait.is_zero() {
            tokio::select! {
                () = tokio::time::sleep(wait) => {}
                () = ended(&mut stop, &hub) => break,
            }
        }
    }
}

/// A connection of the origin a relayed request runs as: a peer daemon's, proven
/// (`ConnAuth::PeerToken`). The control hook sends a start, resume or stop on one.
pub fn relay_connection(hub: &Arc<Hub>) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (in_tx, in_rx) = mpsc::channel(16);
    let (out_tx, out_rx) = mpsc::channel(1024);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Peer));
    (in_tx, out_rx)
}

/// Runs an owner-allowlisted hub control message through the same authenticated peer-origin
/// request path as a connected daemon. The relay hub only selected this daemon; it does not grant
/// ownership, and the request handlers below still apply their normal peer-origin and owner checks.
/// The person this machine recorded at `host join`, read at each control message so a
/// `host join --status` repair counts without a restart. None grants nothing to `sameUser`.
pub type OwnUser = Arc<dyn Fn() -> Option<String> + Send + Sync>;

pub struct MeshControlHook {
    /// Owner-configured grants. Only the hub-stamped daemon id or user can match an entry.
    pub allowed: Vec<MeshControlFrom>,
    own_user: OwnUser,
    ledger: ControlLedger,
    /// Lifecycle replay requires a store-backed handoff directory. Memory-only daemons fail
    /// closed rather than acknowledging a side effect that a restart could repeat.
    durable: bool,
    // A delivery lease can end before a start does. Retain its execution until its actual
    // outcome, independently of the 50 s ack wait; dropping this hook aborts all such tasks.
    tasks: StdMutex<tokio::task::JoinSet<()>>,
    slots: Arc<tokio::sync::Semaphore>,
}

impl MeshControlHook {
    pub fn new(allowed: Vec<MeshControlFrom>, path: Option<PathBuf>) -> Self {
        let durable = path.is_some();
        Self {
            allowed,
            own_user: Arc::new(|| None),
            ledger: ControlLedger::open(path),
            durable,
            tasks: StdMutex::new(Default::default()),
            slots: Arc::new(tokio::sync::Semaphore::new(RelayOptions::default().max_in_flight)),
        }
    }

    /// Where `sameUser` entries read this machine's own person.
    #[must_use]
    pub fn with_own_user(mut self, own_user: OwnUser) -> Self {
        self.own_user = own_user;
        self
    }
}

impl ControlHook for MeshControlHook {
    fn control<'a>(
        &'a self,
        hub: &'a Arc<Hub>,
        message: &'a InMessage,
    ) -> futures::future::BoxFuture<'a, Option<Ack>> {
        Box::pin(async move {
            // Authorize every delivery before consulting a cached result. Revoking an owner
            // grant takes effect even for a message whose earlier result remains in the ledger.
            let op = message.op.as_deref().unwrap_or_default();
            // Read the recorded person only when a `sameUser` entry could use it.
            let own_user = self
                .allowed
                .iter()
                .any(|entry| entry.same_user)
                .then(|| (self.own_user)())
                .flatten();
            if !self
                .allowed
                .iter()
                .any(|entry| entry.allows(&message.from, own_user.as_deref(), op))
            {
                return Some(Ack::refused("mesh.control_not_allowed"));
            }
            // A read changes nothing, so it needs no ledger: a repeat runs again and answers
            // the session as it is then.
            if op == "read" {
                return Some(read::answer(hub, message).await);
            }
            // The ledger keys a result by its sender: the stamped daemon, else the stamped person.
            let sender = match message.from.daemon_id.as_deref().filter(|id| !id.is_empty()) {
                Some(daemon) => daemon.to_owned(),
                None => format!("user:{}", message.from.user.as_deref().unwrap_or_default()),
            };
            if !crate::mesh::is_message_id(&message.message_id) {
                return None;
            }
            if !self.durable {
                return Some(Ack::refused("mesh.control_not_durable"));
            }
            let permit = self.slots.clone().try_acquire_owned().ok();
            let claim = self.ledger.claim(&sender, message, permit.is_some());
            let receiver = match claim {
                Claim::Done(ack) => return Some(ack),
                Claim::Unknown => return None,
                Claim::Conflict => return Some(Ack::refused("mesh.control_id_conflict")),
                Claim::Waiting(receiver) => {
                    drop(permit);
                    receiver
                }
                Claim::New { key, receiver } => {
                    let (hub, message) = (hub.clone(), message.clone());
                    let execution = self.ledger.execution(key);
                    let mut tasks = self.tasks.lock_or_recover();
                    while tasks.try_join_next().is_some() {}
                    tasks.spawn(async move {
                        let _permit = permit;
                        let shutdown = hub.shutdown.notified();
                        tokio::pin!(shutdown);
                        shutdown.as_mut().enable();
                        if hub.is_stopping() {
                            return;
                        }
                        let outcome = tokio::select! {
                            ack = run_control(&hub, &message) => ack,
                            () = &mut shutdown => None,
                        };
                        if let Some(ack) = outcome {
                            execution.finish(clip(ack));
                        }
                    });
                    receiver
                }
            };
            // A 60 s lease need not contain a 90 s agent startup. No ack means pending, never
            // refused; the retained task stores the later result for the next lease to replay.
            wait_control_result(receiver, Duration::from_secs(50)).await
        })
    }
}

async fn wait_control_result(
    mut receiver: watch::Receiver<Option<Ack>>,
    wait: Duration,
) -> Option<Ack> {
    tokio::time::timeout(wait, async move {
        loop {
            if let Some(ack) = receiver.borrow_and_update().clone() {
                return Some(ack);
            }
            if receiver.changed().await.is_err() {
                return None;
            }
        }
    })
    .await
    .ok()
    .flatten()
}

async fn run_control(hub: &Arc<Hub>, message: &InMessage) -> Option<Ack> {
    let Some(op) = message.op.as_deref() else {
        return Some(Ack::refused("control message has no operation"));
    };
    if message.body.len() > 64 * 1024 {
        return Some(Ack::refused("control body exceeds 64 KiB"));
    }
    let body: serde_json::Value = match serde_json::from_str(&message.body) {
        Ok(body) => body,
        Err(e) => return Some(Ack::refused(format!("invalid control body: {e}"))),
    };
    if body.get("version").and_then(serde_json::Value::as_u64) != Some(1) {
        return Some(Ack::refused("unsupported control body version"));
    }
    let mut params = match op {
        "start" => {
            let Some(params) = body.get("params").filter(|value| value.is_object()) else {
                return Some(Ack::refused("start control body has no params object"));
            };
            let params = params.clone();
            if params.get("host").is_some()
                || params.pointer("/_meta/acpmux/peer").is_some()
                || params.pointer("/_meta/acpmux/host").is_some()
            {
                return Some(Ack::refused("mesh control start cannot forward to another daemon"));
            }
            params
        }
        "resume" | "stop" => serde_json::json!({}),
        _ => return Some(Ack::refused(format!("unsupported control operation {op:?}"))),
    };
    if matches!(op, "resume" | "stop") {
        // Only exact sessions owned here. Resolving locally before RPC also prevents a
        // qualified target from being forwarded by the general request dispatcher.
        let target = crate::mesh::Target {
            session_id: message.to.session_id.clone(),
            name: message.to.name.clone(),
            ..Default::default()
        };
        let session = match hub.mesh_target(&target, None) {
            Ok(session) => session,
            Err(why) => return Some(Ack::refused(why)),
        };
        params["sessionId"] = serde_json::Value::String(session.id.clone());
    }
    let session_id = params.get("sessionId").cloned();
    let (tx, mut rx) = relay_connection(hub);
    let initialized = rpc_call(
        &tx,
        &mut rx,
        1,
        crate::rpc::method::INITIALIZE,
        serde_json::json!({
            "protocolVersion": 1,
            "clientCapabilities": {},
            "clientInfo": {"name": "acpmux-mesh-control", "version": crate::hub::VERSION},
        }),
    )
    .await;
    if let Err(error) = initialized {
        return error.ack();
    }
    let result = match op {
        "start" => rpc_call(&tx, &mut rx, 2, crate::rpc::method::SESSION_NEW, params).await,
        "stop" => rpc_call(&tx, &mut rx, 2, crate::rpc::method::SESSION_CLOSE, params).await,
        // ACP's `session/resume` reattaches a client to the session. The CLI's
        // `session resume` operation instead releases a held queue item, so use the same
        // queue-edit path here.
        "resume" => {
            let info = match rpc_call(&tx, &mut rx, 2, crate::rpc::method::MUX_INFO, params).await {
                Ok(info) => info,
                Err(error) => return error.ack(),
            };
            let held = info["queue"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|entry| entry["held"] == true)
                .and_then(|entry| entry["promptId"].as_str())
                .map(str::to_owned);
            match held {
                Some(prompt_id) => {
                    rpc_call(
                        &tx,
                        &mut rx,
                        3,
                        crate::rpc::method::MUX_QUEUE_EDIT,
                        serde_json::json!({
                            "sessionId": session_id,
                            "promptId": prompt_id,
                            "op": "resume"
                        }),
                    )
                    .await
                }
                None => Ok(serde_json::json!({"resumed": false})),
            }
        }
        _ => return Some(Ack::refused("unsupported control operation")),
    };
    match result {
        Ok(result) => {
            let detail =
                result.get("sessionId").and_then(serde_json::Value::as_str).map(str::to_owned);
            Some(Ack::delivered(&message.message_id, detail))
        }
        Err(error) => error.ack(),
    }
}

enum ControlFailure {
    /// An RPC error proves that the target handler refused this operation.
    Refused(String),
    /// Lost response/connection: execution may have happened; retain the pending fence.
    Unknown,
}

impl ControlFailure {
    fn ack(self) -> Option<Ack> {
        match self {
            Self::Refused(reason) => Some(Ack::refused(reason)),
            Self::Unknown => None,
        }
    }
}

async fn rpc_call(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value, ControlFailure> {
    tx.send(crate::rpc::Message::request(id, method, params).to_line())
        .await
        .map_err(|_| ControlFailure::Unknown)?;
    loop {
        let line = rx.recv().await.ok_or(ControlFailure::Unknown)?;
        let response = crate::rpc::Message::parse(&line).map_err(|_| ControlFailure::Unknown)?;
        if let crate::rpc::Message::Response { id: got, result, error } = response
            && got == serde_json::json!(id)
        {
            return match (result, error) {
                (Some(result), None) => Ok(result),
                (_, Some(error)) => Err(ControlFailure::Refused(error.to_string())),
                _ => Err(ControlFailure::Unknown),
            };
        }
    }
}

/// The longest ack detail the hub takes, in characters.
const MAX_DETAIL_CHARS: usize = 1000;

fn clip(mut ack: Ack) -> Ack {
    if let Some(detail) = ack.detail.as_mut()
        && detail.chars().count() > MAX_DETAIL_CHARS
    {
        *detail = detail.chars().take(MAX_DETAIL_CHARS).collect();
    }
    ack
}

/// How a relayed message names its sender to the session: `host/name`, one line, within
/// `fromAgent`'s length. Never empty: a message from another machine is never the person's.
fn sender_name(message: &InMessage) -> String {
    let clean = |s: &str| s.chars().filter(|c| !c.is_control()).collect::<String>();
    let field = |f: &Option<String>| clean(f.as_deref().unwrap_or_default().trim());
    if let Some(address) =
        message.from.team_address.as_deref().map(str::trim).filter(|v| !v.is_empty())
    {
        let address = clean(address);
        let address = if address.starts_with('@') { address } else { format!("@{address}") };
        return address.chars().take(crate::hub::MAX_FROM_AGENT_CHARS).collect();
    }
    let (host, name) = (field(&message.from.host), field(&message.from.name));
    let named = match (host.is_empty(), name.is_empty()) {
        (false, false) => format!("{host}/{name}"),
        (true, false) => name,
        (false, true) => format!("a session on {host}"),
        (true, true) => "a session on another machine".to_owned(),
    };
    named.chars().take(crate::hub::MAX_FROM_AGENT_CHARS).collect::<String>().trim().to_owned()
}

/// Deliver one message: the ack to send, or None to leave it unacked (a target that did not
/// answer in time, or this daemon's own connection failing), so its lease brings it back.
/// `own_daemon` is this daemon's id at the hub, when known; a message for another host or daemon
/// is refused before anything acts on it, a control message's hook included.
pub async fn deliver(
    hub: &Arc<Hub>,
    message: &InMessage,
    control: &dyn ControlHook,
    own_daemon: Option<&str>,
) -> Option<Ack> {
    // Sender display metadata alone must never change legacy session delivery semantics.
    let own_user = crate::cli::cloud_join::machine_user_id();
    let team = team_delivery(message, own_user.as_deref());
    if team
        && !hub.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.team_messaging)
    {
        return Some(Ack::refused("team messaging is off on this daemon"));
    }
    if let Err(why) = hub.mesh_for_here(&message.to, own_daemon) {
        return Some(Ack::refused(why));
    }
    match message.kind {
        Kind::Prompt => {}
        Kind::Control => return control.control(hub, message).await,
        Kind::Unknown => return Some(Ack::refused("a message kind this daemon does not know")),
    }
    if message.body.trim().is_empty() {
        return Some(Ack::refused("the message is empty"));
    }
    let session = match hub.mesh_target(&message.to, own_daemon) {
        Ok(session) => session,
        Err(why) => return Some(Ack::refused(why)),
    };
    let prompt_id = message.message_id.as_str();
    // Team messages are information by default. Record them in the target
    // session's event stream and acknowledge delivery without starting a
    // model turn; a later inbox read/ack records the durable user action.
    if team && !start_work_allowed(message) {
        let stored =
            hub.receive_team_information(&session, prompt_id, &sender_name(message), &message.body);
        if !stored {
            return None;
        }
        return Some(Ack::delivered(
            prompt_id,
            Some("information queued for the next turn boundary".into()),
        ));
    }
    if team && !hub.register_team_work(&session, prompt_id) {
        return None;
    }
    let body = if team {
        format!(
            "Team message from {}: {}\nThe team hub allows this message to start work; normal session permissions still apply.",
            sender_name(message),
            message.body
        )
    } else {
        message.body.clone()
    };
    let mut request = json!({
        "sessionId": session.id,
        "prompt": [{"type": "text", "text": body}],
        "_meta": {"acpmux": {
            "steer": !team && message.mode == Mode::Now,
            "promptId": prompt_id,
            "resend": true,
            "fromAgent": sender_name(message),
            "teamMessage": team,
            "startWork": message.start_work,
        }},
    });
    // The sending session's id, which its daemon set from the caller it proved
    // (`mesh_send.rs`), for display (`prompt_provenance::FROM_SESSION_ID`). The hub's sender
    // record carries no harness yet, so a relayed message names none.
    let sender = crate::prompt_provenance::BoundSender {
        session_id: message.from.session_id.clone(),
        harness: None,
    };
    crate::hub::merge_mux_meta(&mut request, sender.mux_fields());
    use super::outbox::Next;
    match super::outbox::attempt_once(hub, None, request, Origin::Peer).await {
        Ok(_) => Some(Ack::delivered(prompt_id, None)),
        // A paused agent pair holds it in the session's queue: the person's resume runs it.
        Err((why, Next::Held)) => Some(Ack::delivered(prompt_id, Some(format!("held: {why}")))),
        Err((why, Next::Fail)) => {
            Some(Ack { prompt_id: Some(prompt_id.to_owned()), ..Ack::refused(why) })
        }
        // No such session here is the lease's to bring back too, as before (`Next::NoSession`
        // settles only an outbox delivery).
        Err((why, Next::Retry | Next::Unsent | Next::NoSession)) => {
            tracing::info!(
                "mesh relay: {prompt_id} not delivered yet ({why}); its lease brings it back"
            );
            None
        }
    }
}

/// Whether `message` is delivered by the team rules (information unless the hub allows work).
/// A team address always is. A prompt to a session by id or name is too when the hub marked it
/// (`startWork`), unless the same person sent it: the hub marks every message `information` by
/// default, and the person's own machine prompting their own session is a turn, as a send from
/// this machine is (`acpmux send B/NAME`, own-machines e2e prompt-reply, 2026-11-05).
fn team_delivery(message: &InMessage, own_user: Option<&str>) -> bool {
    if message.to.team_address.is_some() {
        return true;
    }
    if message.start_work.is_none() {
        return false;
    }
    let own = own_user.filter(|own| !own.is_empty());
    let same_person = message.from.team_address.is_none()
        && own.is_some_and(|own| message.from.user.as_deref() == Some(own));
    !same_person
}

fn start_work_allowed(message: &InMessage) -> bool {
    matches!(message.start_work, Some(StartWork::Allowed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mesh::{AckState, Sender, Target};

    fn from(host: &str, name: &str) -> InMessage {
        InMessage {
            message_id: "m".into(),
            to: Target::default(),
            from: Sender { name: Some(name.into()), host: Some(host.into()), ..Sender::default() },
            body: "x".into(),
            mode: Mode::TurnEnd,
            attempt: 1,
            kind: Kind::Prompt,
            op: None,
            start_work: Some(StartWork::Information),
            state: Some("queued".into()),
            subject: None,
        }
    }

    #[test]
    fn a_relayed_message_always_names_a_sender_on_one_line() {
        assert_eq!(sender_name(&from("gcp-codex-lane-3", "lane-a")), "gcp-codex-lane-3/lane-a");
        assert_eq!(sender_name(&from("", "lane-a")), "lane-a");
        assert_eq!(sender_name(&from("vm", "")), "a session on vm");
        assert_eq!(sender_name(&from(" ", "")), "a session on another machine");
        assert_eq!(sender_name(&from("vm\n", "a\u{7}b")), "vm/ab");
        let long = sender_name(&from(&"h".repeat(80), "lane"));
        assert_eq!(long.chars().count(), crate::hub::MAX_FROM_AGENT_CHARS);
    }

    #[test]
    fn team_sender_names_are_explicitly_addressed() {
        let mut message = from("", "lane");
        message.from.team_address = Some("lawrence/coordinator".into());
        assert_eq!(sender_name(&message), "@lawrence/coordinator");
    }

    #[test]
    fn the_same_persons_direct_prompt_is_a_turn_and_any_other_marked_one_is_information() {
        let mut message = from("machine-a", "own-e2e");
        message.from.user = Some("person-1".into());
        // The hub marks every message `information` by default.
        assert!(!team_delivery(&message, Some("person-1")), "the same person's own prompt");
        assert!(team_delivery(&message, Some("person-2")), "another person's");
        assert!(team_delivery(&message, None), "no person recorded here");
        message.from.user = None;
        assert!(team_delivery(&message, Some("person-1")), "no hub-stamped sender");
        message.from.user = Some("person-1".into());
        message.from.team_address = Some("@person-1/lead".into());
        assert!(team_delivery(&message, Some("person-1")), "a team sender");
        message.from.team_address = None;
        message.to.team_address = Some("@person-1/coordinator".into());
        assert!(team_delivery(&message, Some("person-1")), "a team address always is");
        message.to.team_address = None;
        message.start_work = None;
        assert!(!team_delivery(&message, None), "an unmarked direct prompt, as before");
    }

    #[test]
    fn only_an_explicit_allowed_decision_can_start_work() {
        let mut message = from("", "lane");
        message.to.team_address = Some("@team/coordinator".into());
        message.start_work = None;
        assert!(!start_work_allowed(&message));
        message.start_work = Some(StartWork::Information);
        assert!(!start_work_allowed(&message));
        message.start_work = Some(StartWork::Allowed);
        assert!(start_work_allowed(&message));
    }

    #[test]
    fn heartbeats_come_at_a_third_of_the_ttl_at_most_every_heartbeat_every() {
        let options = RelayOptions::default();
        assert_eq!(heartbeat_wait(&options, 90), Duration::from_secs(30));
        assert_eq!(heartbeat_wait(&options, 30), Duration::from_secs(10));
        assert_eq!(heartbeat_wait(&options, 0), Duration::from_secs(30));
        let mut backoff = Backoff::new(Duration::from_secs(1), Duration::from_secs(4));
        let limited =
            HubError { retry_after: Some(Duration::from_secs(9)), ..HubError::unavailable("") };
        assert_eq!(after_failure(&mut backoff, &limited), Duration::from_secs(9));
    }

    #[tokio::test(start_paused = true)]
    async fn a_late_rpc_result_survives_the_delivery_lease() {
        let ledger = ControlLedger::open(None);
        let mut message = from("", "");
        message.kind = Kind::Control;
        message.op = Some("start".into());
        let Claim::New { key, receiver } = ledger.claim("sender", &message, true) else {
            panic!("a new operation must be admitted");
        };
        let (tx, mut requests) = mpsc::channel(1);
        let (replies, mut rx) = mpsc::channel(1);
        let target = tokio::spawn(async move {
            requests.recv().await.unwrap();
            tokio::time::sleep(Duration::from_secs(90)).await;
            replies
                .send(
                    crate::rpc::Message::ok(json!(2), json!({"sessionId": "stable-id"})).to_line(),
                )
                .await
                .unwrap();
        });
        let worker_ledger = ledger.clone();
        let worker = tokio::spawn(async move {
            let result =
                rpc_call(&tx, &mut rx, 2, crate::rpc::method::SESSION_NEW, json!({})).await;
            if let Ok(result) = result {
                worker_ledger.finish(
                    &key,
                    Ack::delivered("m", result["sessionId"].as_str().map(str::to_owned)),
                );
            }
        });
        assert!(wait_control_result(receiver, Duration::from_secs(50)).await.is_none());
        let Claim::Waiting(receiver) = ledger.claim("sender", &message, true) else {
            panic!("redelivery must join the running operation");
        };
        let ack = wait_control_result(receiver, Duration::from_secs(50)).await.unwrap();
        assert_eq!(ack.state, AckState::Delivered);
        assert_eq!(ack.detail.as_deref(), Some("stable-id"));
        target.await.unwrap();
        worker.await.unwrap();
        assert!(matches!(ledger.claim("sender", &message, true), Claim::Done(_)));
    }

    #[tokio::test]
    async fn a_lost_rpc_response_is_indeterminate_not_refused() {
        let (tx, mut requests) = mpsc::channel(1);
        let (replies, mut rx) = mpsc::channel(1);
        let target = tokio::spawn(async move {
            requests.recv().await.unwrap();
            // The handler may have executed before the connection dropped.
            drop(replies);
        });
        let result = rpc_call(&tx, &mut rx, 1, crate::rpc::method::SESSION_NEW, json!({})).await;
        assert!(matches!(result, Err(ControlFailure::Unknown)));
        target.await.unwrap();
    }

    #[test]
    fn an_ack_detail_is_clipped_to_what_the_hub_takes() {
        let ack = clip(Ack::refused("é".repeat(5000)));
        assert_eq!(ack.detail.unwrap().chars().count(), MAX_DETAIL_CHARS);
        assert_eq!(clip(Ack::refused("short")).detail.as_deref(), Some("short"));
    }
}
