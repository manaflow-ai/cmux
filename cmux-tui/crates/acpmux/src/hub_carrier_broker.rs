//! The lane-gh broker as a carrier service (RFD 0127 cut 2, decided move 3 of
//! fleet-dogfoods-remote): a lane machine's `lane-gh` reaches the broker on its owner machine as
//! a stream on the pair's held carrier link, where until now the broker host held one
//! `ssh -N -R` forward per machine, which flapped and took minutes to come back after a link loss.
//!
//! - Serving side (the broker host): a stream that names [`CircuitService::LaneGhBroker`] (hello
//!   `{"service":"lane-gh-broker"}`) reaches the broker's own unix socket for the dialing machine,
//!   `client-<machine>.sock` beside the broker's socket, the socket the broker made for that
//!   machine's `ssh -R` forward. The broker takes a call's scope from which socket it came in on
//!   (its `client_socket`), so the machine name must be the dialer's, never the dialer's say: it
//!   is the name the hub's address book lists for the key the Noise handshake proved, and only a
//!   key the book lists under exactly one name gets one. Off unless the owner names the broker's
//!   socket (`laneGhBroker`, `acpmux config --set lane_gh_broker=PATH`).
//! - Dialing side (the lane machine): `_acpmux/remote.pipe` `{machine, service: "lane-gh-broker"}`
//!   on this daemon's unix socket (`cmux_tui_service.rs`), the way `tools/carrier-pipe` opens an
//!   ssh pipe, and `acpmux machine broker-forward OWNER --socket PATH` listens on a unix socket
//!   and opens one such pipe per connection, so `LANE_GH_SOCKET=PATH lane-gh ...` uses it.
//!
//! Opt-in on both ends: the forward keeps working, and nothing here changes which one `lane-gh`
//! uses by default (RFD 0127: each route default flips per surface, after its numbers).
//!
//! [`CircuitService::LaneGhBroker`]: super::CircuitService::LaneGhBroker

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::Instant;

use async_trait::async_trait;

use super::ServiceRefusal;

/// Whether this machine serves its lane-gh broker to the person's other machines, and which
/// socket a machine reaches.
#[async_trait]
pub trait LaneGhBrokerGate: Send + Sync + 'static {
    /// The broker's socket for the machine whose hub `daemonId` is `from` (as the Noise
    /// handshake proved it), or why it may not reach one.
    async fn admit(&self, from: &str) -> Result<PathBuf, ServiceRefusal>;
}

/// This machine's end of a broker stream from `from`: a stream whose first request line is
/// budgeted (see [`Budget`]) and then relayed to the broker's socket.
#[cfg(unix)]
pub(super) async fn open(
    gate: Option<Arc<dyn LaneGhBrokerGate>>,
    from: Option<String>,
) -> Result<tokio::io::DuplexStream, ServiceRefusal> {
    let (socket, machine) = match (gate, from) {
        (Some(gate), Some(from)) => (gate.admit(&from).await?, from),
        (None, _) => return Err(off()),
        (Some(_), None) => {
            return Err(ServiceRefusal::new(
                "service.unknown_machine",
                "the circuit's machine key is not one this machine admitted",
            ));
        }
    };
    let (client, server) = tokio::io::duplex(PIPE_BYTES);
    scope().spawn_named("lane-gh broker stream", serve(server, socket, machine, Budget::shared()));
    Ok(client)
}

/// The owner of every broker stream's relay task. Each ends on its own, when either end of the
/// stream closes or the budget refuses its first line.
#[cfg(unix)]
fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: OnceLock<cmux_scope::Scope> = OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("lane-gh broker streams"))
}

// ---------------------------------------------------------------------------------------------
// The per-caller budget (fleet-dogfoods-remote move 3: "Give broker calls cost lanes and a
// per-caller budget"; durability 4.6: "Cheap reads get their own queue and connection slot").
//
// The Python broker already admits per authenticated VM with pools of its own (hq
// `parts/59-caller-admission.py`: work, waits, creates, reads, fetches, each with a bounded line
// that answers `busy: ... retry after Ns`). Its key is the socket, so over the carrier all of a
// machine's lanes are one caller, and every stream is a connection and a broker thread before the
// broker can say no. This edge is the same idea one step earlier and one key finer: it keeps its
// limits looser than the broker's pools (the broker stays the authority on what it can run) and
// only bounds how many connections one machine, and one `lane` on it, may have open per cost
// lane, so a flood of bulk calls never takes the slots a ping or a read needs.
// ---------------------------------------------------------------------------------------------

/// Bytes the in-process pipe between the carrier stream and the budget task buffers each way.
const PIPE_BYTES: usize = 64 * 1024;

/// The longest first request line read before the call is classified. A line past this is
/// forwarded as it stands (a bulk call whose caller key is the empty lane).
const FIRST_LINE_MAX: usize = 4 * 1024 * 1024;

/// How long a stream may take to send its first line before it is closed without holding a slot
/// (a slot is only taken once the line is read, so an idle stream costs no budget).
const FIRST_LINE_WAIT: Duration = Duration::from_secs(60);

/// The longest a `lane` field is kept as a budget key (longer is cut), so the table's keys stay
/// small whatever a machine sends.
const LANE_KEY_MAX: usize = 128;

/// The most caller rows (in-flight or in a rate window) kept before idle ones are dropped.
const CALLER_ROWS_PRUNE_AT: usize = 1024;

/// What the broker's lane-gh clients wait out: the broker's own busy answers read
/// `busy: ... nothing was started, retry after Ns` with a `retry_after` field, and lane-gh's
/// `busy_answer` asks again (jittered, bounded) on exactly that shape.
const BUSY_RETRY_AFTER_S: u64 = 2;

/// Tools that only read (or wait for a read): a call to one is [`Cost::Cheap`]. Everything else,
/// including an unknown tool, a push, a fetch, a ci dispatch and a land, is [`Cost::Bulk`].
const CHEAP_TOOLS: &[&str] = &[
    "get",
    "search_issues",
    "graphql",
    "ci_status",
    "ci_wait",
    "ci_run_status",
    "ci_receipt",
    "ci_log_read",
    "lease_check",
    "lease_metrics",
    "backlog",
    "land_outcomes",
    "rest_breakdown",
    "slack_read",
];

/// A call's cost lane. Each lane has slots of its own on a machine, so one never waits on the
/// other.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Cost {
    /// A ping or a read.
    Cheap,
    /// A write, a git fetch or push, a ci run, a land, and anything not known to be cheap.
    Bulk,
}

impl Cost {
    fn name(self) -> &'static str {
        match self {
            Cost::Cheap => "cheap",
            Cost::Bulk => "bulk",
        }
    }
}

/// The knobs of the budget. [`Limits::default`] is what a daemon runs; tests build smaller ones.
#[derive(Clone, Debug)]
pub struct Limits {
    /// Cheap streams one machine may have open at once, over all its lanes. Reads wait seconds
    /// (a `ci_wait` up to 540 s), so this is generous.
    pub cheap_slots: usize,
    /// Bulk streams one machine may have open at once. Kept at or under the broker's own work and
    /// fetch pools, which stay the authority on what runs.
    pub bulk_slots: usize,
    /// Cheap streams one `(machine, lane)` may have open at once.
    pub caller_cheap_inflight: usize,
    /// Bulk streams one `(machine, lane)` may have open at once, so one lane's burst of pushes
    /// leaves the machine's other lanes their share of `bulk_slots`.
    pub caller_bulk_inflight: usize,
    /// Cheap calls one `(machine, lane)` may start in a minute.
    pub caller_cheap_per_min: usize,
    /// Bulk calls one `(machine, lane)` may start in a minute.
    pub caller_bulk_per_min: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            cheap_slots: 64,
            bulk_slots: 8,
            caller_cheap_inflight: 16,
            caller_bulk_inflight: 3,
            caller_cheap_per_min: 1200,
            caller_bulk_per_min: 120,
        }
    }
}

/// How long a rate window is.
const WINDOW: Duration = Duration::from_secs(60);

/// Why a call was not admitted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refused {
    /// The machine's slots for this cost lane are all held.
    MachineSlots,
    /// This caller already has its share of the lane's slots open.
    CallerInflight,
    /// This caller started its minute's calls.
    CallerRate,
}

/// A refusal and when to ask again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Busy {
    pub why: Refused,
    pub retry_after_s: u64,
}

impl Busy {
    /// The one answer line, in the shape lane-gh's `busy_answer` retries: `ok` false, an error
    /// that starts `busy:` and says nothing was started, and `retry_after`.
    pub fn line(&self, cost: Cost) -> String {
        let what = match self.why {
            Refused::MachineSlots => {
                format!("all of this machine's {} slots are held", cost.name())
            }
            Refused::CallerInflight => {
                format!("this lane already has its share of {} calls running", cost.name())
            }
            Refused::CallerRate => {
                format!("this lane's {} calls this minute are spent", cost.name())
            }
        };
        busy_line(&what, self.retry_after_s)
    }
}

/// A busy answer line for `what`, retry after `retry_after_s`.
fn busy_line(what: &str, retry_after_s: u64) -> String {
    let mut line = serde_json::json!({
        "ok": false,
        "error": format!("busy: {what}; nothing was started, retry after {retry_after_s}s"),
        "retry_after": retry_after_s,
    })
    .to_string();
    line.push('\n');
    line
}

#[derive(Default)]
struct Machine {
    cheap: usize,
    bulk: usize,
}

#[derive(Default)]
struct Row {
    inflight: usize,
    started: VecDeque<Instant>,
}

#[derive(Default)]
struct Table {
    machines: HashMap<String, Machine>,
    callers: HashMap<(String, String, Cost), Row>,
}

/// The per-caller budget: per-machine slots for each cost lane, and per `(machine, lane)` an
/// in-flight cap and a per-minute call count.
pub struct Budget {
    limits: Limits,
    table: Mutex<Table>,
}

/// A held admission: the slots go back when it drops.
pub struct Admitted {
    budget: Arc<Budget>,
    machine: String,
    lane: String,
    cost: Cost,
}

impl std::fmt::Debug for Admitted {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Admitted({} {} {})", self.machine, self.lane, self.cost.name())
    }
}

impl Drop for Admitted {
    fn drop(&mut self) {
        let mut table = self.budget.table.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(m) = table.machines.get_mut(&self.machine) {
            let n = match self.cost {
                Cost::Cheap => &mut m.cheap,
                Cost::Bulk => &mut m.bulk,
            };
            *n = n.saturating_sub(1);
            if m.cheap == 0 && m.bulk == 0 {
                table.machines.remove(&self.machine);
            }
        }
        let key = (self.machine.clone(), self.lane.clone(), self.cost);
        if let Some(row) = table.callers.get_mut(&key) {
            row.inflight = row.inflight.saturating_sub(1);
        }
    }
}

impl Budget {
    pub fn new(limits: Limits) -> Arc<Self> {
        Arc::new(Self { limits, table: Mutex::new(Table::default()) })
    }

    /// The daemon's one budget, with the default limits.
    fn shared() -> Arc<Self> {
        static SHARED: OnceLock<Arc<Budget>> = OnceLock::new();
        SHARED.get_or_init(|| Budget::new(Limits::default())).clone()
    }

    /// Admit one call of `cost` from `lane` on `machine` at `now`, or say when to ask again. A
    /// cheap call never looks at the bulk slots, nor a bulk call at the cheap ones.
    pub fn admit(
        self: &Arc<Self>,
        machine: &str,
        lane: &str,
        cost: Cost,
        now: Instant,
    ) -> Result<Admitted, Busy> {
        let l = &self.limits;
        let (slots, inflight_cap, per_min) = match cost {
            Cost::Cheap => (l.cheap_slots, l.caller_cheap_inflight, l.caller_cheap_per_min),
            Cost::Bulk => (l.bulk_slots, l.caller_bulk_inflight, l.caller_bulk_per_min),
        };
        let lane: String = lane.chars().take(LANE_KEY_MAX).collect();
        let mut table = self.table.lock().unwrap_or_else(|e| e.into_inner());
        if table.callers.len() >= CALLER_ROWS_PRUNE_AT {
            table.callers.retain(|_, row| {
                while row.started.front().is_some_and(|t| now.duration_since(*t) >= WINDOW) {
                    row.started.pop_front();
                }
                row.inflight > 0 || !row.started.is_empty()
            });
        }
        let held = table.machines.get(machine).map_or(0, |m| match cost {
            Cost::Cheap => m.cheap,
            Cost::Bulk => m.bulk,
        });
        let key = (machine.to_owned(), lane.clone(), cost);
        let row = table.callers.entry(key.clone()).or_default();
        while row.started.front().is_some_and(|t| now.duration_since(*t) >= WINDOW) {
            row.started.pop_front();
        }
        let refuse = if row.started.len() >= per_min {
            let oldest = row.started.front().copied().unwrap_or(now);
            let wait = WINDOW.saturating_sub(now.duration_since(oldest)).as_secs_f64().ceil();
            Some(Busy { why: Refused::CallerRate, retry_after_s: (wait as u64).max(1) })
        } else if row.inflight >= inflight_cap {
            Some(Busy { why: Refused::CallerInflight, retry_after_s: BUSY_RETRY_AFTER_S })
        } else if held >= slots {
            Some(Busy { why: Refused::MachineSlots, retry_after_s: BUSY_RETRY_AFTER_S })
        } else {
            None
        };
        if let Some(busy) = refuse {
            if row.inflight == 0 && row.started.is_empty() {
                table.callers.remove(&key);
            }
            return Err(busy);
        }
        row.inflight += 1;
        row.started.push_back(now);
        let m = table.machines.entry(machine.to_owned()).or_default();
        match cost {
            Cost::Cheap => m.cheap += 1,
            Cost::Bulk => m.bulk += 1,
        }
        drop(table);
        Ok(Admitted { budget: self.clone(), machine: machine.to_owned(), lane, cost })
    }
}

/// A request's cost lane and caller key, from its first line.
#[derive(Debug, PartialEq, Eq)]
pub struct Classified {
    pub cost: Cost,
    pub lane: String,
}

/// Classify a first request line: `{"op":"ping"}` and a `call` of a [`CHEAP_TOOLS`] tool are
/// cheap; every other op, tool or line that does not parse is bulk.
pub fn classify(first: &[u8]) -> Classified {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(first) else {
        return Classified { cost: Cost::Bulk, lane: String::new() };
    };
    let lane = v.get("lane").and_then(|l| l.as_str()).unwrap_or_default().to_owned();
    let cheap = match v.get("op").and_then(|o| o.as_str()) {
        Some("ping") => true,
        Some("call") => {
            v.get("tool").and_then(|t| t.as_str()).is_some_and(|t| CHEAP_TOOLS.contains(&t))
        }
        _ => false,
    };
    Classified { cost: if cheap { Cost::Cheap } else { Cost::Bulk }, lane }
}

/// Read the stream until its first newline (the bytes read, including any past it), or `None`
/// when it closed or stalled before sending any.
async fn read_first_line<R: AsyncRead + Unpin>(client: &mut R) -> Option<Vec<u8>> {
    let read = async {
        let mut got = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            let n = client.read(&mut chunk).await.ok()?;
            if n == 0 {
                return (!got.is_empty()).then_some(got);
            }
            let fresh = chunk.get(..n).unwrap_or_default();
            got.extend_from_slice(fresh);
            if fresh.contains(&b'\n') || got.len() >= FIRST_LINE_MAX {
                return Some(got);
            }
        }
    };
    tokio::time::timeout(FIRST_LINE_WAIT, read).await.ok().flatten()
}

#[cfg(unix)]
/// One carrier stream's life: read its first line, take a slot of its cost lane (or answer busy
/// and close), connect to the broker's socket, replay the bytes read, and relay both ways until
/// either side ends. The slot is held for the whole stream.
async fn serve<C>(mut client: C, socket: PathBuf, machine: String, budget: Arc<Budget>)
where
    C: AsyncRead + AsyncWrite + Unpin,
{
    let Some(first) = read_first_line(&mut client).await else { return };
    let line = first.split(|b| *b == b'\n').next().unwrap_or_default();
    let Classified { cost, lane } = classify(line);
    let _admitted = match budget.admit(&machine, &lane, cost, Instant::now()) {
        Ok(admitted) => admitted,
        Err(busy) => {
            tracing::warn!(
                machine = %machine.get(..8).unwrap_or(&machine),
                lane = %lane,
                cost = cost.name(),
                why = ?busy.why,
                retry_after_s = busy.retry_after_s,
                "lane-gh broker: a call was refused over its caller budget"
            );
            let _ = client.write_all(busy.line(cost).as_bytes()).await;
            let _ = client.shutdown().await;
            return;
        }
    };
    let mut broker = match tokio::net::UnixStream::connect(&socket).await {
        Ok(broker) => broker,
        Err(e) => {
            // A broker restarting: lane-gh waits that out on the busy shape, nothing was sent.
            let line = busy_line(
                &format!("the broker at {} is not listening ({e})", socket.display()),
                BUSY_RETRY_AFTER_S,
            );
            let _ = client.write_all(line.as_bytes()).await;
            let _ = client.shutdown().await;
            return;
        }
    };
    if broker.write_all(&first).await.is_err() {
        return;
    }
    let _ = tokio::io::copy_bidirectional(&mut client, &mut broker).await;
}

/// No unix sockets: no broker to reach.
#[cfg(not(unix))]
pub(super) async fn open(
    _gate: Option<Arc<dyn LaneGhBrokerGate>>,
    _from: Option<String>,
) -> Result<tokio::io::DuplexStream, ServiceRefusal> {
    Err(off())
}

fn off() -> ServiceRefusal {
    ServiceRefusal::new(
        "service.off",
        "this machine serves no lane-gh broker to its other machines; its owner sets one with \
         `acpmux config --set lane_gh_broker=PATH` (the broker's socket)",
    )
}

/// The serving gate of a daemon: its config's `laneGhBroker` and its hub address book.
pub struct ConfiguredBrokerGate {
    hub: Weak<crate::hub::Hub>,
}

impl ConfiguredBrokerGate {
    pub fn new(hub: &Arc<crate::hub::Hub>) -> Self {
        Self { hub: Arc::downgrade(hub) }
    }
}

#[async_trait]
impl LaneGhBrokerGate for ConfiguredBrokerGate {
    async fn admit(&self, from: &str) -> Result<PathBuf, ServiceRefusal> {
        let hub =
            self.hub.upgrade().ok_or_else(|| ServiceRefusal::new("service.off", "stopping"))?;
        let configured = hub.config.read().await.lane_gh_broker.clone();
        let socket = admit(configured.as_deref(), &hub.mesh_book_machines(), from)?;
        // The broker makes a machine's socket only for a machine in its config; none is a
        // machine it does not serve, said as such rather than as a failed connect.
        let exists = {
            let socket = socket.clone();
            tokio::task::spawn_blocking(move || socket.exists()).await.unwrap_or(false)
        };
        if !exists {
            return Err(ServiceRefusal::new(
                "broker.no_client",
                format!(
                    "this machine's lane-gh broker has no socket for that machine ({})",
                    socket.display()
                ),
            ));
        }
        Ok(socket)
    }
}

/// The broker socket the machine whose `daemonId` is `from` reaches, given the configured broker
/// socket and the hub address book's `(daemonId, host)` rows: `client-<host>.sock` beside it.
/// Refused unless the book lists `from` under exactly one plain name.
pub fn admit(
    configured: Option<&str>,
    machines: &[(String, String)],
    from: &str,
) -> Result<PathBuf, ServiceRefusal> {
    let configured = configured.ok_or_else(off)?;
    let broker = broker_socket(configured)?;
    let mut names = machines.iter().filter(|(key, _)| key == from).map(|(_, host)| host);
    let (Some(host), None) = (names.next(), names.next()) else {
        return Err(ServiceRefusal::new(
            "service.unknown_machine",
            "the hub's address book does not name the dialing machine once",
        ));
    };
    if !plain_name(host) {
        return Err(ServiceRefusal::new(
            "service.unknown_machine",
            "the dialing machine's name is not one a broker socket can have",
        ));
    }
    Ok(broker.with_file_name(format!("client-{host}.sock")))
}

/// `configured` as an absolute path (`~/` is this user's home).
fn broker_socket(configured: &str) -> Result<PathBuf, ServiceRefusal> {
    let bad = || {
        ServiceRefusal::new(
            "service.misconfigured",
            format!(
                "laneGhBroker must be an absolute path to the broker's socket, not `{configured}`"
            ),
        )
    };
    let path = match configured.strip_prefix("~/") {
        Some(rest) => {
            Path::new(&std::env::var_os("HOME").filter(|h| !h.is_empty()).ok_or_else(bad)?)
                .join(rest)
        }
        None => PathBuf::from(configured),
    };
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(bad());
    }
    Ok(path)
}

/// A machine name the broker's socket names may hold: letters, digits, `.`, `_` and `-`, not
/// starting with `.`, so it never leaves the broker's directory.
fn plain_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && !name.starts_with('.')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

#[cfg(test)]
#[path = "hub_carrier_broker_tests.rs"]
mod tests;
