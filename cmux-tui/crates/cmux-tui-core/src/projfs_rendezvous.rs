//! `projfs-v1`: the rendezvous that carries a projected folder's bytes from the person's Mac to
//! the mount helper on this Cloud machine (`cmux-tui projfs mount`, crate `cmux-projfs`).
//!
//! No new socket and no new network path: the Mac already holds the link to this daemon and
//! sends it requests (`fs-v1`), and requests on the link only go Mac -> machine. So the helper
//! leaves the wants of a read here and waits; the Mac long-polls for them and answers. The
//! daemon is only a queue: it never opens, reads or checks a path (the Mac checks every path
//! against its own manifest and skip rules), and keeps everything in memory.
//!
//! - `projfs.fetch {mount, wants:[{path, size, mtime_ns, ctime_ns, offset, len}], wait_ms}`:
//!   the helper, on a trusted local connection only (never a remote client; the link's gate
//!   does not admit it). Answers `{results:[…]}`, one per want in order, when the Mac answered
//!   them all, or when `wait_ms` passed: a want no Mac took by then answers `{status:"away"}`.
//!   A want a Mac took is waited for until that Mac answers or its lease ends.
//! - `projfs.next {mount, wait_ms}`: the Mac, over the link. Answers at once when wants are
//!   queued, else when some arrive or `wait_ms` passes (`{batch:null}`):
//!   `{batch:{id, wants:[…]}}`. The batch is leased to that poll for [`LEASE`]; a batch not
//!   answered by then goes back to the front of the queue for the next poll.
//! - `projfs.answer {mount, batch, results:[…]}`: the Mac, over the link; `batch` is the id
//!   `projfs.next` handed out (not `id`, which is the request line's own), and one result per
//!   want of the batch, in order: `{status:"bytes", data_b64}`, `{status:"changed", size,
//!   mtime_ns, ctime_ns, mode}`, `{status:"gone"}`, `{status:"withheld"}`,
//!   `{status:"failed", reason?}` or `{status:"away"}`. Answers `{answered: N}`. An unknown or
//!   expired batch is refused (`projfs.unknown_batch`) and its bytes are dropped.
//! - `projfs.status {mount?}`: `{mounts:[{mount, queued, batches_out, polling, fetching,
//!   bytes_answered, last_answer_age_ms}]}`.
//! - `projfs.mount` and `projfs.unmount`: the Mac, over the link: start and stop the mount
//!   helper itself ([`crate::projfs_mount`]).
//!
//! Served exactly where `fs-v1` is (Cloud hosts). Waits use one condition variable, never a
//! sleep. A waiting op holds only its own connection's reader: every connection has a reader
//! thread of its own (server/line_connection.rs), so other connections go on meanwhile.

use std::collections::{HashMap, VecDeque};
use std::sync::{Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

/// The capability that carries the `projfs.*` ops.
pub const PROJFS_CAPABILITY: &str = "projfs-v1";

/// The ops of `projfs-v1`, exactly: the rendezvous's four, and the two that start and stop the
/// mount helper (`projfs.mount|unmount`, served by [`crate::projfs_mount`]).
pub const PROJFS_COMMANDS: [&str; 6] = [
    "projfs.fetch",
    "projfs.next",
    "projfs.answer",
    "projfs.status",
    "projfs.mount",
    "projfs.unmount",
];

/// The ops the link's remote gate admits beside the `fs-v1` ops: the Mac's side. Never
/// `projfs.fetch`, which only the mount helper on this machine sends.
pub const PROJFS_REMOTE_COMMANDS: [&str; 5] =
    ["projfs.next", "projfs.answer", "projfs.status", "projfs.mount", "projfs.unmount"];

/// Mounts one daemon keeps queues for; past it an idle mount is forgotten, else refused.
pub const MAX_MOUNTS: usize = 64;
/// Wants queued for one mount (taken or not, until answered).
pub const MAX_QUEUED_WANTS: usize = 4096;
/// Wants in one `projfs.fetch`, and in one batch handed to the Mac (the helper's own limit).
pub const MAX_WANTS: usize = 512;
/// The largest `len` of one want: one chunk of the helper's cache (`cmux_projfs::cache::CHUNK`).
pub const MAX_WANT_LEN: u64 = 4 << 20;
/// The most bytes one fetch asks for, and one batch carries: the Mac answers a batch in one
/// request line, and 8 MiB in base64 (10.7 MiB) stays under the daemon's 16 MiB line limit
/// (`REMOTE_CLIENT_MESSAGE_MAX_BYTES`), as `fs.write`'s 12 MiB does.
pub const MAX_BATCH_BYTES: u64 = 8 << 20;
/// The longest path in a want.
pub const MAX_PATH_BYTES: usize = 4096;
/// The longest mount id (letters, digits, `.`, `_`, `-`).
pub const MAX_MOUNT_ID: usize = 64;
/// The longest `reason` of a failed result.
pub const MAX_REASON_BYTES: usize = 1000;
/// The longest a `projfs.fetch` or `projfs.next` waits (`wait_ms` is capped at this): under
/// the link's idle limits, so a quiet long poll is never cut.
pub const MAX_WAIT: Duration = Duration::from_secs(25);
/// How long a batch handed to a poll is that poll's: a Mac that took it and went away gives
/// it back after this.
pub const LEASE: Duration = Duration::from_secs(30);

static SERVICE: OnceLock<Rendezvous> = OnceLock::new();

/// The rendezvous, when this daemon serves `fs-v1` (a Cloud host).
#[must_use]
pub fn installed() -> Option<&'static Rendezvous> {
    crate::fs_ops::installed()?;
    Some(SERVICE.get_or_init(Rendezvous::new))
}

/// The capability to advertise in `identify`, when served.
#[must_use]
pub fn advertised() -> Option<&'static str> {
    crate::fs_ops::installed().map(|_| PROJFS_CAPABILITY)
}

/// The `cmd` of `line` when it is one of [`PROJFS_COMMANDS`], exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    let value: Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    // A frame with `protocol` goes to the resource router, never here.
    if object.contains_key("protocol") {
        return None;
    }
    let cmd = object.get("cmd")?.as_str()?;
    PROJFS_COMMANDS.iter().copied().find(|known| *known == cmd)
}

/// The `cmd` of `line` when it is one of [`PROJFS_REMOTE_COMMANDS`] (what the remote gate
/// admits).
#[must_use]
pub fn remote_frame_command(line: &str) -> Option<&'static str> {
    frame_command(line).filter(|cmd| PROJFS_REMOTE_COMMANDS.contains(cmd))
}

/// Who sent a frame, as the connection says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Caller {
    /// A trusted local (Unix socket) connection that is not a remote client: the mount helper.
    Local,
    /// A remote client with a principal checked for this frame: the Mac over the link.
    Remote,
    /// Anything else (a WebSocket, a remote client without a principal): refused.
    Denied,
}

/// A refused request: its wire code and display text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl Refusal {
    fn bad(message: impl Into<String>) -> Self {
        Self { code: "projfs.bad_request", message: message.into() }
    }

    fn limit(message: impl Into<String>) -> Self {
        Self { code: "projfs.limit", message: message.into() }
    }

    fn denied() -> Self {
        Self { code: "projfs.permission_denied", message: "permission denied".into() }
    }
}

/// The answer to one `projfs.*` request line, in the daemon's envelope. `service` is `None` on
/// a host that is not a Cloud host.
#[must_use]
pub fn answer_line(service: Option<&Rendezvous>, caller: Caller, line: &str) -> Value {
    let Ok(Value::Object(mut request)) = serde_json::from_str::<Value>(line) else {
        return envelope(&Value::Null, Err(Refusal::bad("not a JSON object")));
    };
    let id = request.remove("id").unwrap_or(Value::Null);
    let Some(cmd) = frame_command(line) else {
        return envelope(&id, Err(Refusal::bad("unknown projfs op")));
    };
    if crate::projfs_mount::frame_command(line).is_some() {
        // The helper's start and stop, with the helper's own default socket.
        return crate::projfs_mount::answer_line(
            crate::projfs_mount::installed(),
            caller,
            None,
            line,
        );
    }
    request.remove("cmd");
    // The helper's op from this machine only; the Mac's ops from the link (or from here, which
    // a local test or tool may use to read the status).
    let allowed = match cmd {
        "projfs.fetch" => caller == Caller::Local,
        "projfs.status" => caller != Caller::Denied,
        _ => caller == Caller::Remote,
    };
    if !allowed {
        return envelope(&id, Err(Refusal::denied()));
    }
    let Some(service) = service else {
        return envelope(
            &id,
            Err(Refusal {
                code: "projfs.unavailable",
                message: "projected folders are served only on cmux Cloud hosts".into(),
            }),
        );
    };
    let result = match cmd {
        "projfs.fetch" => service.fetch(request),
        "projfs.next" => service.next(request),
        "projfs.answer" => service.answer(request),
        _ => service.status(&request),
    };
    envelope(&id, result)
}

/// The daemon's envelope around one answer: `{id, ok:true, data}` or `{id, ok:false, error,
/// error_code}`.
pub(crate) fn envelope(id: &Value, result: Result<Value, Refusal>) -> Value {
    match result {
        Ok(data) => json!({ "id": id, "ok": true, "data": data }),
        Err(refusal) => json!({
            "id": id,
            "ok": false,
            "error": refusal.message,
            "error_code": refusal.code,
        }),
    }
}

/// How long the waits and the lease are (tests shorten them).
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub max_wait: Duration,
    pub lease: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self { max_wait: MAX_WAIT, lease: LEASE }
    }
}

/// Every mount's queue, behind one lock, with one condition variable for every waiter.
pub struct Rendezvous {
    state: Mutex<State>,
    changed: Condvar,
    limits: Limits,
}

#[derive(Default)]
struct State {
    next_fetch: u64,
    next_batch: u64,
    mounts: HashMap<String, MountQueue>,
}

/// One mount's wants, batches and counters.
struct MountQueue {
    /// Wants no Mac holds, oldest first.
    queue: VecDeque<Slot>,
    /// Waiting fetches by their number.
    fetches: HashMap<u64, Fetch>,
    /// Batches handed out, by id.
    batches: HashMap<String, Batch>,
    polling: usize,
    bytes_answered: u64,
    last_answer: Option<Instant>,
    last_used: Instant,
}

/// One want of one fetch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Slot {
    fetch: u64,
    index: usize,
}

struct Fetch {
    wants: Vec<Want>,
    results: Vec<Option<Value>>,
    open: usize,
}

/// A want as checked (the wire object) and its length.
struct Want {
    wire: Value,
    len: u64,
}

struct Batch {
    slots: Vec<Slot>,
    leased_until: Instant,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// `at + by`, or `at` when that is past what an `Instant` holds.
fn later(at: Instant, by: Duration) -> Instant {
    at.checked_add(by).unwrap_or(at)
}

/// A fetch or a poll lost its own record (never expected: such records go only with their op).
fn lost() -> Refusal {
    Refusal { code: "projfs.internal", message: "the request's own record was lost".into() }
}

fn unknown_batch() -> Refusal {
    Refusal {
        code: "projfs.unknown_batch",
        message: "no such batch: it was answered, or its lease ended and it was handed out \
                  again; the answer is dropped"
            .into(),
    }
}

impl Fetch {
    /// Sets want `index`'s result unless it has one.
    fn fill(&mut self, index: usize, result: Value) {
        if let Some(slot) = self.results.get_mut(index)
            && slot.is_none()
        {
            *slot = Some(result);
            self.open = self.open.saturating_sub(1);
        }
    }

    fn is_open(&self, index: usize) -> bool {
        self.results.get(index).is_some_and(Option::is_none)
    }
}

impl Default for Rendezvous {
    fn default() -> Self {
        Self::new()
    }
}

impl Rendezvous {
    #[must_use]
    pub fn new() -> Self {
        Self::with_limits(Limits::default())
    }

    #[must_use]
    pub fn with_limits(limits: Limits) -> Self {
        Self { state: Mutex::new(State::default()), changed: Condvar::new(), limits }
    }

    fn wait_for(&self, params: &Map<String, Value>) -> Result<Duration, Refusal> {
        let ms = match params.get("wait_ms") {
            None => 0,
            Some(value) => value.as_u64().ok_or_else(|| Refusal::bad("wait_ms is a number"))?,
        };
        Ok(Duration::from_millis(ms).min(self.limits.max_wait))
    }

    /// Waits on the condition variable until `until` at the latest.
    fn wait_until<'a>(
        &self,
        state: MutexGuard<'a, State>,
        until: Instant,
    ) -> MutexGuard<'a, State> {
        let left = until.saturating_duration_since(Instant::now());
        self.changed.wait_timeout(state, left).unwrap_or_else(PoisonError::into_inner).0
    }

    /// `projfs.fetch`: queues the wants and waits for their answers.
    pub fn fetch(&self, mut params: Map<String, Value>) -> Result<Value, Refusal> {
        only(&params, &["mount", "wants", "wait_ms"])?;
        let mount = mount_id(&params)?;
        let wait = self.wait_for(&params)?;
        let wants = match params.remove("wants") {
            Some(Value::Array(wants)) => checked_wants(wants)?,
            _ => return Err(Refusal::bad("wants is an array")),
        };
        if wants.is_empty() {
            return Ok(json!({ "results": [] }));
        }
        let now = Instant::now();
        let deadline = later(now, wait);
        let mut state = lock(&self.state);
        let number = state.next_fetch;
        state.next_fetch = number.wrapping_add(1);
        let queue = state.mount(&mount, now)?;
        if queue.queued_wants().saturating_add(wants.len()) > MAX_QUEUED_WANTS {
            return Err(Refusal::limit("too many wants are waiting for this mount"));
        }
        let count = wants.len();
        queue.queue.extend((0..count).map(|index| Slot { fetch: number, index }));
        queue.fetches.insert(number, Fetch { results: vec![None; count], open: count, wants });
        self.changed.notify_all();
        loop {
            let now = Instant::now();
            // A mount with a waiting fetch is never forgotten, and only this call removes it.
            let Some(queue) = state.mounts.get_mut(&mount) else { return Err(lost()) };
            if queue.expire(now) {
                self.changed.notify_all();
            }
            if now >= deadline {
                queue.give_up(number);
            }
            let Some(fetch) = queue.fetches.get(&number) else { return Err(lost()) };
            if fetch.open == 0 {
                let results: Vec<Value> = queue
                    .fetches
                    .remove(&number)
                    .map(|fetch| fetch.results.into_iter().flatten().collect())
                    .unwrap_or_default();
                self.changed.notify_all();
                return Ok(json!({ "results": results }));
            }
            let wake = if now < deadline {
                queue.next_expiry().map_or(deadline, |at| at.min(deadline))
            } else {
                // Only wants a Mac holds are left: they end with its answer or its lease.
                queue.next_expiry_of(number).unwrap_or_else(|| later(now, self.limits.lease))
            };
            state = self.wait_until(state, wake);
        }
    }

    /// `projfs.next`: a batch of queued wants, waiting for some when there are none.
    pub fn next(&self, params: Map<String, Value>) -> Result<Value, Refusal> {
        only(&params, &["mount", "wait_ms"])?;
        let mount = mount_id(&params)?;
        let wait = self.wait_for(&params)?;
        let deadline = later(Instant::now(), wait);
        let mut state = lock(&self.state);
        let queue = state.mount(&mount, Instant::now())?;
        queue.polling = queue.polling.saturating_add(1);
        self.changed.notify_all();
        let lease = self.limits.lease;
        let answer = loop {
            let now = Instant::now();
            let id = state.next_batch;
            // A polled mount is never forgotten.
            let Some(queue) = state.mounts.get_mut(&mount) else { return Err(lost()) };
            if queue.expire(now) {
                self.changed.notify_all();
            }
            if let Some(batch) = queue.take_batch(format!("b{id}"), later(now, lease)) {
                state.next_batch = id.wrapping_add(1);
                break json!({ "batch": batch });
            }
            if now >= deadline {
                break json!({ "batch": null });
            }
            let wake = queue.next_expiry().map_or(deadline, |at| at.min(deadline));
            state = self.wait_until(state, wake);
        };
        if let Some(queue) = state.mounts.get_mut(&mount) {
            queue.polling = queue.polling.saturating_sub(1);
            queue.last_used = Instant::now();
        }
        Ok(answer)
    }

    /// `projfs.answer`: completes a batch's wants and wakes their fetches.
    pub fn answer(&self, mut params: Map<String, Value>) -> Result<Value, Refusal> {
        only(&params, &["mount", "batch", "results"])?;
        let mount = mount_id(&params)?;
        let id = params.get("batch").and_then(Value::as_str).map(str::to_owned);
        let id = id.ok_or_else(|| Refusal::bad("batch is the id of the batch answered"))?;
        let Some(Value::Array(results)) = params.remove("results") else {
            return Err(Refusal::bad("results is an array"));
        };
        let now = Instant::now();
        let mut state = lock(&self.state);
        let queue = state.mounts.get_mut(&mount).ok_or_else(unknown_batch)?;
        if queue.expire(now) {
            self.changed.notify_all();
        }
        let batch = queue.batches.get(&id).ok_or_else(unknown_batch)?;
        if results.len() != batch.slots.len() {
            return Err(Refusal::bad("results has one result per want of the batch"));
        }
        let mut checked = Vec::with_capacity(results.len());
        for (slot, result) in batch.slots.iter().zip(results) {
            checked.push(checked_result(result, queue.want_len(*slot))?);
        }
        let Some(batch) = queue.batches.remove(&id) else { return Err(unknown_batch()) };
        let answered = checked.len();
        for (slot, (result, len)) in batch.slots.into_iter().zip(checked) {
            queue.bytes_answered = queue.bytes_answered.saturating_add(len);
            if let Some(fetch) = queue.fetches.get_mut(&slot.fetch) {
                fetch.fill(slot.index, result);
            }
        }
        queue.last_answer = Some(now);
        queue.last_used = now;
        self.changed.notify_all();
        Ok(json!({ "answered": answered }))
    }

    /// Tests: waits (on the condition variable, at most `timeout`) until `done` holds for the
    /// status of `mount`; whether it did.
    #[cfg(test)]
    pub(crate) fn settle(
        &self,
        mount: &str,
        timeout: Duration,
        done: impl Fn(&Value) -> bool,
    ) -> bool {
        let deadline = later(Instant::now(), timeout);
        let mut state = lock(&self.state);
        loop {
            let counts = state.mounts.get(mount).map_or(Value::Null, |queue| {
                json!({ "queued": queue.queue.len(), "batches_out": queue.batches.len(),
                        "polling": queue.polling, "fetching": queue.fetches.len() })
            });
            if done(&counts) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            state = self.wait_until(state, deadline);
        }
    }

    /// `projfs.status`: the counts of one mount, or of every mount.
    pub fn status(&self, params: &Map<String, Value>) -> Result<Value, Refusal> {
        only(params, &["mount"])?;
        let wanted = match params.get("mount") {
            None => None,
            Some(_) => Some(mount_id(params)?),
        };
        let now = Instant::now();
        let mut state = lock(&self.state);
        let mut mounts: Vec<(String, Value)> = Vec::new();
        for (name, queue) in &mut state.mounts {
            if wanted.as_ref().is_some_and(|w| w != name) {
                continue;
            }
            if queue.expire(now) {
                self.changed.notify_all();
            }
            let counts = json!({
                "mount": name,
                "queued": queue.queue.len(),
                "batches_out": queue.batches.len(),
                "polling": queue.polling,
                "fetching": queue.fetches.len(),
                "bytes_answered": queue.bytes_answered,
                "last_answer_age_ms": queue.last_answer.map(|at| {
                    u64::try_from(now.duration_since(at).as_millis()).unwrap_or(u64::MAX)
                }),
            });
            mounts.push((name.clone(), counts));
        }
        mounts.sort_by(|a, b| a.0.cmp(&b.0));
        let mounts: Vec<Value> = mounts.into_iter().map(|(_, counts)| counts).collect();
        Ok(json!({ "mounts": mounts }))
    }
}

impl State {
    /// The queue of `mount`, made when new. Past [`MAX_MOUNTS`] the idle mount used least
    /// recently is forgotten (its counters with it); with none idle the request is refused.
    fn mount(&mut self, mount: &str, now: Instant) -> Result<&mut MountQueue, Refusal> {
        if !self.mounts.contains_key(mount) && self.mounts.len() >= MAX_MOUNTS {
            let idle = self
                .mounts
                .iter()
                .filter(|(_, queue)| queue.idle())
                .min_by_key(|(_, queue)| queue.last_used)
                .map(|(name, _)| name.clone())
                .ok_or_else(|| Refusal::limit("too many projected folders are in use"))?;
            self.mounts.remove(&idle);
        }
        let queue = self.mounts.entry(mount.to_owned()).or_insert_with(|| MountQueue::new(now));
        queue.last_used = now;
        Ok(queue)
    }
}

impl MountQueue {
    fn new(now: Instant) -> Self {
        Self {
            queue: VecDeque::new(),
            fetches: HashMap::new(),
            batches: HashMap::new(),
            polling: 0,
            bytes_answered: 0,
            last_answer: None,
            last_used: now,
        }
    }

    fn idle(&self) -> bool {
        self.queue.is_empty()
            && self.fetches.is_empty()
            && self.batches.is_empty()
            && self.polling == 0
    }

    /// Wants waiting, queued or handed out.
    fn queued_wants(&self) -> usize {
        self.fetches.values().map(|fetch| fetch.open).sum()
    }

    /// Puts the wants of every batch whose lease ended back at the front of the queue, in
    /// their order (those of a fetch that is gone, or already answered, are dropped). Whether
    /// any batch ended.
    fn expire(&mut self, now: Instant) -> bool {
        let ended: Vec<String> = self
            .batches
            .iter()
            .filter(|(_, batch)| batch.leased_until <= now)
            .map(|(id, _)| id.clone())
            .collect();
        let mut ended: Vec<Batch> = ended.iter().filter_map(|id| self.batches.remove(id)).collect();
        // The batch handed out first goes back first.
        ended.sort_by_key(|batch| std::cmp::Reverse(batch.leased_until));
        for batch in &ended {
            for slot in batch.slots.iter().rev() {
                if self.fetches.get(&slot.fetch).is_some_and(|fetch| fetch.is_open(slot.index)) {
                    self.queue.push_front(*slot);
                }
            }
        }
        !ended.is_empty()
    }

    /// The `len` of the want at `slot` (the most a result may carry): the bound when its fetch
    /// is gone.
    fn want_len(&self, slot: Slot) -> u64 {
        self.fetches
            .get(&slot.fetch)
            .and_then(|fetch| fetch.wants.get(slot.index))
            .map_or(MAX_WANT_LEN, |want| want.len)
    }

    /// The soonest lease end of any batch.
    fn next_expiry(&self) -> Option<Instant> {
        self.batches.values().map(|batch| batch.leased_until).min()
    }

    /// The soonest lease end of a batch holding a want of fetch `number`.
    fn next_expiry_of(&self, number: u64) -> Option<Instant> {
        self.batches
            .values()
            .filter(|batch| batch.slots.iter().any(|slot| slot.fetch == number))
            .map(|batch| batch.leased_until)
            .min()
    }

    /// Fetch `number`'s time is up: its wants no Mac holds answer `away`.
    fn give_up(&mut self, number: u64) {
        let Some(fetch) = self.fetches.get_mut(&number) else { return };
        self.queue.retain(|slot| {
            if slot.fetch != number {
                return true;
            }
            fetch.fill(slot.index, json!({ "status": "away" }));
            false
        });
    }

    /// Takes the oldest queued wants, as many as fit one batch, leased until `until`.
    fn take_batch(&mut self, id: String, until: Instant) -> Option<Value> {
        let mut slots = Vec::new();
        let mut wire = Vec::new();
        let mut bytes: u64 = 0;
        while let Some(slot) = self.queue.front().copied() {
            let want = self.fetches.get(&slot.fetch).and_then(|f| f.wants.get(slot.index));
            let Some(want) = want else {
                self.queue.pop_front();
                continue;
            };
            let full = slots.len() >= MAX_WANTS || bytes.saturating_add(want.len) > MAX_BATCH_BYTES;
            if !slots.is_empty() && full {
                break;
            }
            bytes = bytes.saturating_add(want.len);
            wire.push(want.wire.clone());
            slots.push(slot);
            self.queue.pop_front();
        }
        if slots.is_empty() {
            return None;
        }
        self.batches.insert(id.clone(), Batch { slots, leased_until: until });
        Some(json!({ "id": id, "wants": wire }))
    }
}

/// Refuses a param outside `allowed`.
pub(crate) fn only(params: &Map<String, Value>, allowed: &[&str]) -> Result<(), Refusal> {
    match params.keys().find(|key| !allowed.contains(&key.as_str())) {
        Some(key) => Err(Refusal::bad(format!("unknown param {key:?}"))),
        None => Ok(()),
    }
}

/// `mount`: 1 to [`MAX_MOUNT_ID`] letters, digits, `.`, `_` or `-`.
pub(crate) fn mount_id(params: &Map<String, Value>) -> Result<String, Refusal> {
    params
        .get("mount")
        .and_then(Value::as_str)
        .filter(|id| (1..=MAX_MOUNT_ID).contains(&id.len()))
        .filter(|id| {
            id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        })
        .map(str::to_owned)
        .ok_or_else(|| Refusal::bad("mount is 1 to 64 letters, digits, '.', '_' or '-'"))
}

/// The wants of a fetch, checked against the bounds (the paths are never interpreted).
fn checked_wants(wants: Vec<Value>) -> Result<Vec<Want>, Refusal> {
    if wants.len() > MAX_WANTS {
        return Err(Refusal::limit(format!("at most {MAX_WANTS} wants per fetch")));
    }
    let mut total = 0;
    let mut out = Vec::with_capacity(wants.len());
    for want in wants {
        let Value::Object(want) = want else { return Err(Refusal::bad("a want is an object")) };
        only(&want, &["path", "size", "mtime_ns", "ctime_ns", "offset", "len"])?;
        let path = want
            .get("path")
            .and_then(Value::as_str)
            .filter(|p| !p.is_empty() && p.len() <= MAX_PATH_BYTES && !p.contains('\0'))
            .ok_or_else(|| Refusal::bad("a want's path is 1 to 4096 bytes"))?;
        let unsigned = |key: &str| want.get(key).and_then(Value::as_u64);
        let signed = |key: &str| want.get(key).and_then(Value::as_i64);
        let (Some(size), Some(offset), Some(len), Some(mtime), Some(ctime)) = (
            unsigned("size"),
            unsigned("offset"),
            unsigned("len"),
            signed("mtime_ns"),
            signed("ctime_ns"),
        ) else {
            return Err(Refusal::bad("a want has size, mtime_ns, ctime_ns, offset and len"));
        };
        if len == 0 || len > MAX_WANT_LEN {
            return Err(Refusal::bad(format!("a want's len is 1 to {MAX_WANT_LEN}")));
        }
        total = len.saturating_add(total);
        if total > MAX_BATCH_BYTES {
            return Err(Refusal::limit(format!("at most {MAX_BATCH_BYTES} bytes per fetch")));
        }
        let wire = json!({
            "path": path, "size": size, "mtime_ns": mtime, "ctime_ns": ctime,
            "offset": offset, "len": len,
        });
        out.push(Want { wire, len });
    }
    Ok(out)
}

/// One result of an answer, checked, and the bytes it carries. A `bytes` result may carry at
/// most `len` bytes (its want's).
fn checked_result(result: Value, len: u64) -> Result<(Value, u64), Refusal> {
    let Value::Object(mut result) = result else {
        return Err(Refusal::bad("a result is an object"));
    };
    let status = result.get("status").and_then(Value::as_str).unwrap_or_default().to_owned();
    match status.as_str() {
        "bytes" => {
            only(&result, &["status", "data_b64"])?;
            let Some(Value::String(data)) = result.remove("data_b64") else {
                return Err(Refusal::bad("a bytes result has data_b64"));
            };
            let decoded = base64_len(&data).ok_or_else(|| Refusal::bad("data_b64 is base64"))?;
            if decoded > len {
                return Err(Refusal::bad("a bytes result is longer than its want"));
            }
            Ok((json!({ "status": "bytes", "data_b64": data }), decoded))
        }
        "changed" => {
            only(&result, &["status", "size", "mtime_ns", "ctime_ns", "mode"])?;
            let unsigned = |key: &str| result.get(key).and_then(Value::as_u64);
            let signed = |key: &str| result.get(key).and_then(Value::as_i64);
            match (unsigned("size"), signed("mtime_ns"), signed("ctime_ns"), unsigned("mode")) {
                (Some(size), Some(mtime), Some(ctime), Some(mode)) => Ok((
                    json!({ "status": "changed", "size": size, "mtime_ns": mtime,
                            "ctime_ns": ctime, "mode": mode }),
                    0,
                )),
                _ => Err(Refusal::bad("a changed result has size, mtime_ns, ctime_ns and mode")),
            }
        }
        "failed" => {
            only(&result, &["status", "reason"])?;
            let reason = match result.get("reason") {
                None => "the Mac could not read it",
                Some(reason) => reason
                    .as_str()
                    .filter(|r| r.len() <= MAX_REASON_BYTES)
                    .ok_or_else(|| Refusal::bad("a failed result's reason is a short text"))?,
            };
            Ok((json!({ "status": "failed", "reason": reason }), 0))
        }
        "gone" | "withheld" | "away" => {
            only(&result, &["status"])?;
            Ok((json!({ "status": status }), 0))
        }
        _ => {
            Err(Refusal::bad("a result's status is bytes, changed, gone, withheld, failed or away"))
        }
    }
}

/// The decoded length of standard, padded base64 text, when it is that.
fn base64_len(text: &str) -> Option<u64> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let padding = bytes.iter().rev().take_while(|b| **b == b'=').count();
    let body = bytes.get(..bytes.len().checked_sub(padding)?)?;
    let plain = |b: &u8| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/');
    if padding > 2 || !body.iter().all(plain) {
        return None;
    }
    let decoded = (bytes.len() / 4).checked_mul(3)?.checked_sub(padding)?;
    u64::try_from(decoded).ok()
}

#[cfg(test)]
#[path = "projfs_rendezvous_tests.rs"]
mod tests;
