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
    tokio::spawn(serve(server, socket, machine, Budget::shared()));
    Ok(client)
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
            got.extend_from_slice(&chunk[..n]);
            if chunk[..n].contains(&b'\n') || got.len() >= FIRST_LINE_MAX {
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
    let end = first.iter().position(|b| *b == b'\n').unwrap_or(first.len());
    let Classified { cost, lane } = classify(&first[..end]);
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
mod tests {
    use super::*;

    fn book() -> Vec<(String, String)> {
        vec![
            ("a".repeat(44), "gcp-agent-lane-10".to_owned()),
            ("b".repeat(44), "twice".to_owned()),
            ("b".repeat(44), "twice-again".to_owned()),
            ("c".repeat(44), "../etc".to_owned()),
        ]
    }

    #[test]
    fn a_listed_machine_reaches_its_own_socket_beside_the_brokers() {
        let got = admit(Some("/srv/broker/broker.sock"), &book(), &"a".repeat(44)).unwrap();
        assert_eq!(got, PathBuf::from("/srv/broker/client-gcp-agent-lane-10.sock"));
    }

    #[test]
    fn no_configured_broker_is_off() {
        let refused = admit(None, &book(), &"a".repeat(44)).unwrap_err();
        assert_eq!(refused.reason, "service.off");
    }

    #[test]
    fn an_unlisted_twice_listed_or_odd_name_is_refused() {
        for from in ["z".repeat(44), "b".repeat(44), "c".repeat(44)] {
            let refused = admit(Some("/srv/broker.sock"), &book(), &from).unwrap_err();
            assert_eq!(refused.reason, "service.unknown_machine", "{from}");
        }
    }

    #[test]
    fn a_relative_broker_socket_is_misconfigured() {
        let refused = admit(Some("broker.sock"), &book(), &"a".repeat(44)).unwrap_err();
        assert_eq!(refused.reason, "service.misconfigured");
    }

    // ---- the per-caller budget ----

    fn small() -> Limits {
        Limits {
            cheap_slots: 4,
            bulk_slots: 2,
            caller_cheap_inflight: 4,
            caller_bulk_inflight: 2,
            caller_cheap_per_min: 100,
            caller_bulk_per_min: 100,
        }
    }

    #[test]
    fn pings_and_reads_are_cheap_and_everything_else_is_bulk() {
        let cheap = [
            r#"{"op":"ping","check_push":false}"#,
            r#"{"op":"call","tool":"get","repo":"a/b","lane":"x","args":{}}"#,
            r#"{"op":"call","tool":"ci_status","lane":"x"}"#,
            r#"{"op":"call","tool":"ci_wait","lane":"x"}"#,
        ];
        for line in cheap {
            assert_eq!(classify(line.as_bytes()).cost, Cost::Cheap, "{line}");
        }
        let bulk = [
            r#"{"op":"call","tool":"push","lane":"x"}"#,
            r#"{"op":"call","tool":"ci","lane":"x"}"#,
            r#"{"op":"call","tool":"land","lane":"x"}"#,
            r#"{"op":"call","tool":"never_heard_of_it","lane":"x"}"#,
            r#"{"op":"fetch"}"#,
            r#"{"op":"call"}"#,
            "not json",
            "",
        ];
        for line in bulk {
            assert_eq!(classify(line.as_bytes()).cost, Cost::Bulk, "{line}");
        }
    }

    #[test]
    fn the_caller_key_is_the_lane_field_and_empty_when_absent() {
        assert_eq!(classify(br#"{"op":"ping","lane":"lane-7"}"#).lane, "lane-7");
        assert_eq!(classify(br#"{"op":"ping"}"#).lane, "");
        assert_eq!(classify(br#"{"op":"ping","lane":5}"#).lane, "");
    }

    #[test]
    fn one_lane_cannot_take_more_than_its_share_of_a_machines_bulk_slots() {
        let budget = Budget::new(small());
        let now = Instant::now();
        let a1 = budget.admit("m", "a", Cost::Bulk, now).unwrap();
        let _a2 = budget.admit("m", "a", Cost::Bulk, now).unwrap();
        let refused = budget.admit("m", "a", Cost::Bulk, now).unwrap_err();
        assert_eq!(refused.why, Refused::CallerInflight);
        // Lane b still gets a slot of the machine's two... until they are all held.
        let _b = budget.admit("m", "b", Cost::Bulk, now);
        assert_eq!(budget.admit("m", "c", Cost::Bulk, now).unwrap_err().why, Refused::MachineSlots);
        // Another machine has slots of its own.
        assert!(budget.admit("other", "a", Cost::Bulk, now).is_ok());
        drop(a1);
        assert!(budget.admit("m", "a", Cost::Bulk, now).is_ok());
    }

    #[test]
    fn a_caller_over_its_minute_waits_for_its_oldest_call_to_age_out() {
        let budget = Budget::new(Limits { caller_bulk_per_min: 2, ..small() });
        let t0 = Instant::now();
        drop(budget.admit("m", "a", Cost::Bulk, t0).unwrap());
        drop(budget.admit("m", "a", Cost::Bulk, t0 + Duration::from_secs(10)).unwrap());
        let busy = budget.admit("m", "a", Cost::Bulk, t0 + Duration::from_secs(20)).unwrap_err();
        assert_eq!(busy.why, Refused::CallerRate);
        assert_eq!(busy.retry_after_s, 40);
        // Another lane is not spent, and the first call ages out of the window at 60 s.
        assert!(budget.admit("m", "b", Cost::Bulk, t0 + Duration::from_secs(20)).is_ok());
        assert!(budget.admit("m", "a", Cost::Bulk, t0 + Duration::from_secs(61)).is_ok());
    }

    #[test]
    fn cheap_calls_have_slots_bulk_calls_cannot_take() {
        let budget = Budget::new(small());
        let now = Instant::now();
        let _held: Vec<_> =
            (0..2).map(|i| budget.admit("m", &format!("l{i}"), Cost::Bulk, now).unwrap()).collect();
        assert!(budget.admit("m", "l2", Cost::Bulk, now).is_err());
        for _ in 0..4 {
            std::mem::forget(budget.admit("m", "l2", Cost::Cheap, now).unwrap());
        }
    }

    #[test]
    fn the_refusal_is_the_busy_line_lane_gh_asks_again_on() {
        let line = Busy { why: Refused::MachineSlots, retry_after_s: 2 }.line(Cost::Bulk);
        assert!(line.ends_with('\n'));
        let v: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(v["ok"], false);
        let error = v["error"].as_str().unwrap();
        assert!(error.starts_with("busy:") && error.contains("nothing was started"), "{error}");
        assert!(error.contains("retry after 2s"));
        assert_eq!(v["retry_after"], 2);
    }

    #[cfg(unix)]
    mod stream {
        use super::*;
        use tokio::io::{AsyncBufReadExt, BufReader};
        use tokio::net::UnixListener;
        use tokio::sync::{Semaphore, watch};

        /// A broker stand-in with `workers` threads' worth of capacity, as the real one has: a
        /// connection takes a worker before it reads its line, a `push` holds it until
        /// `release`, and every request is answered `{"ok":true,"echo":<line>}`.
        fn fake_broker(
            dir: &Path,
            workers: usize,
        ) -> (PathBuf, watch::Sender<bool>, tokio::task::JoinHandle<()>) {
            let socket = dir.join("client-m.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let (release, released) = watch::channel(false);
            let pool = Arc::new(Semaphore::new(workers));
            let task = tokio::spawn(async move {
                loop {
                    let Ok((conn, _)) = listener.accept().await else { return };
                    let pool = pool.clone();
                    let mut released = released.clone();
                    tokio::spawn(async move {
                        let _worker = pool.acquire_owned().await.unwrap();
                        let (read, mut write) = conn.into_split();
                        let mut line = String::new();
                        if BufReader::new(read).read_line(&mut line).await.unwrap_or(0) == 0 {
                            return;
                        }
                        if line.contains(r#""tool":"push""#) {
                            let _ = released.wait_for(|r| *r).await;
                        }
                        let echo = serde_json::json!({"ok": true, "echo": line.trim_end()});
                        let _ = write.write_all(format!("{echo}\n").as_bytes()).await;
                    });
                }
            });
            (socket, release, task)
        }

        /// One request through the budget: the answer line and how long it took.
        async fn ask(
            socket: &Path,
            budget: &Arc<Budget>,
            line: &str,
        ) -> (serde_json::Value, Duration) {
            let began = Instant::now();
            let (mut client, server) = tokio::io::duplex(PIPE_BYTES);
            tokio::spawn(serve(server, socket.to_path_buf(), "m".into(), budget.clone()));
            client.write_all(format!("{line}\n").as_bytes()).await.unwrap();
            let mut answer = String::new();
            BufReader::new(client).read_line(&mut answer).await.unwrap();
            (serde_json::from_str(&answer).unwrap(), began.elapsed())
        }

        fn push(lane: &str) -> String {
            format!(r#"{{"op":"call","tool":"push","repo":"a/b","lane":"{lane}","args":{{}}}}"#)
        }

        const PING: &str = r#"{"op":"ping","check_push":false}"#;

        #[tokio::test(flavor = "multi_thread")]
        async fn the_first_line_reaches_the_broker_whole_and_its_answer_comes_back() {
            let dir = tempfile::tempdir().unwrap();
            let (socket, _release, _broker) = fake_broker(dir.path(), 4);
            let budget = Budget::new(small());
            let (answer, _) = ask(&socket, &budget, PING).await;
            assert_eq!(answer["ok"], true);
            assert_eq!(answer["echo"], PING);
        }

        /// Durability 4.6: hold every bulk slot, and a cheap ping still answers; a further bulk
        /// call is answered busy at once instead of waiting behind the held ones.
        #[tokio::test(flavor = "multi_thread")]
        async fn a_ping_answers_while_every_bulk_slot_is_held() {
            let dir = tempfile::tempdir().unwrap();
            let (socket, release, _broker) = fake_broker(dir.path(), 3);
            let budget = Budget::new(Limits { bulk_slots: 2, ..small() });
            let held: Vec<_> = (0..2)
                .map(|i| {
                    let (socket, budget) = (socket.clone(), budget.clone());
                    tokio::spawn(
                        async move { ask(&socket, &budget, &push(&format!("l{i}"))).await },
                    )
                })
                .collect();
            // Both bulk slots are taken once the broker's workers are.
            tokio::time::timeout(Duration::from_secs(5), async {
                while budget.table.lock().unwrap().machines.get("m").map_or(0, |m| m.bulk) < 2 {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .unwrap();

            let (ping, took) = ask(&socket, &budget, PING).await;
            assert_eq!(ping["ok"], true);
            assert!(took < Duration::from_secs(1), "ping took {took:?}");
            let (third, refused_in) = ask(&socket, &budget, &push("l2")).await;
            assert_eq!(third["ok"], false);
            assert!(third["error"].as_str().unwrap().starts_with("busy:"));
            assert!(refused_in < Duration::from_secs(1), "refusal took {refused_in:?}");

            release.send(true).unwrap();
            for held in held {
                assert_eq!(held.await.unwrap().0["ok"], true);
            }
            // The slots came back.
            assert_eq!(ask(&socket, &budget, &push("l2")).await.0["ok"], true);
        }

        /// The number for the PR: a broker with 3 workers and bulk calls that hold them for
        /// 500 ms. Before (no cap on bulk streams) the ping waits behind them; after, bulk is
        /// held to 2 of the 3 workers, so the ping has one. Run with `--nocapture` to see it.
        #[tokio::test(flavor = "multi_thread")]
        async fn ping_latency_with_the_bulk_slots_held_before_and_after() {
            async fn trial(limits: Limits) -> Duration {
                let dir = tempfile::tempdir().unwrap();
                let (socket, release, _broker) = fake_broker(dir.path(), 3);
                let budget = Budget::new(limits);
                for i in 0..8 {
                    let (socket, budget) = (socket.clone(), budget.clone());
                    tokio::spawn(
                        async move { ask(&socket, &budget, &push(&format!("l{i}"))).await },
                    );
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
                let freed = tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    let _ = release.send(true);
                });
                let (ping, took) = ask(&socket, &budget, PING).await;
                assert_eq!(ping["ok"], true);
                freed.abort();
                took
            }
            let unbudgeted = Limits {
                bulk_slots: usize::MAX,
                caller_bulk_inflight: usize::MAX,
                caller_bulk_per_min: usize::MAX,
                ..small()
            };
            let before = trial(unbudgeted).await;
            let after = trial(Limits { bulk_slots: 2, caller_bulk_inflight: 2, ..small() }).await;
            println!("ping with all bulk held: before {before:?}, after {after:?}");
            assert!(before >= Duration::from_millis(300), "before {before:?}");
            assert!(after < Duration::from_millis(250), "after {after:?}");
        }
    }
}
