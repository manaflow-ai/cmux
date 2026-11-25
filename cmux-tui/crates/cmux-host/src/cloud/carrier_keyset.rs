//! The carrier's grant keyset, kept fresh by the Cloud role itself: one
//! thread beside the worker fetches `GET /v1/cloud/keyset` and, when the
//! keyset changed, rewrites `carrier.json` (temp file, then rename). The
//! supervisor's watch then rewrites the session host's
//! `carrier-grant.json` the same way, and the session host's verifier
//! re-reads it when it changed.
//!
//! When to fetch is cmux-link's [`KeysetRefresh`]: once when the machine
//! binds (or the agent restarts bound), then once a day at a time of day
//! jittered by the machine id, and on a grant with an unknown kid at most
//! once per 60 s. A 429 holds every fetch until its `Retry-After`, at most
//! [`MAX_RETRY_AFTER`]. The session host's verifier reports an unknown kid
//! on the agent socket (`{"carrier_keyset": {"kid": "…"}}`, [`check_ask`]).
//!
//! The write is a compare-and-swap: under the lock the bind's own
//! carrier.json write holds ([`Refresher::carrier_lock`]), carrier.json is
//! read again after the fetch and rewritten only when it still names the
//! route the fetch was for ([`swap_text`]). A route change or a removal
//! during the fetch drops the result.
//!
//! Nothing here depends on the native receiver. A machine with no
//! `carrier.json`, or one whose file went away, holds no schedule and
//! fetches nothing until a bind brings a carrier back ([`Keeper::on`]).
//! The thread stops when the worker drops its [`Refresher`] (the channel
//! closes); a fetch in flight is bounded by [`FETCH_BUDGET`].

use std::path::Path;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_link::keyset::{
    Keyset, KeysetRefresh, KeysetRefused, daily_jitter, read_answer, read_keyset,
};
use cmux_server::cloud_http::RequestDeadline;
use serde_json::{Map, Value, json};

use super::client::{CloudClient, Http};
use crate::carrier_entry::{CARRIER_FILE, CarrierRoute, parse_file, with_keyset};
use crate::config::Paths;

/// The agent socket line's key.
pub const REQUEST_KEY: &str = "carrier_keyset";

/// The keyset route (no bearer: the keyset is public).
pub const PATH: &str = "/v1/cloud/keyset";

/// One fetch's whole budget.
pub const FETCH_BUDGET: Duration = Duration::from_secs(20);

/// The longest 429 hold a `Retry-After` may ask for.
pub const MAX_RETRY_AFTER: Duration = Duration::from_secs(60 * 60);

/// The kid of a `carrier_keyset` ask: `{"kid": "<1 to 64 of A-Z a-z 0-9 . _ ->"}`.
pub fn check_ask(value: &Value) -> Result<String, String> {
    let refused = || "carrier_keyset takes exactly {\"kid\": \"<kid>\"}".to_owned();
    let Value::Object(fields) = value else { return Err(refused()) };
    if fields.len() != 1 {
        return Err(refused());
    }
    let kid = fields.get("kid").and_then(Value::as_str).ok_or_else(refused)?;
    let valid = (1..=64).contains(&kid.len())
        && kid.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b));
    if !valid {
        return Err(refused());
    }
    Ok(kid.to_owned())
}

/// A checked keyset as its JSON (`{version, keys: {kid: JWK}}`).
pub fn keyset_json(keys: &Keyset) -> Value {
    let version = keys.version.clone();
    let keys: Map<String, Value> = keys
        .keys
        .iter()
        .map(|(kid, key)| {
            let jwk = json!({"kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid,
                "x": URL_SAFE_NO_PAD.encode(key)});
            (kid.clone(), jwk)
        })
        .collect();
    json!({"version": version, "keys": keys})
}

/// The keyset answer of one fetch: a 429's `Retry-After` is honoured up to
/// [`MAX_RETRY_AFTER`]; a transport failure is `Unavailable`.
pub fn read_fetch(
    response: Result<cmux_server::cloud_http::Response, String>,
) -> Result<Keyset, KeysetRefused> {
    let response = response.map_err(|_| KeysetRefused::Unavailable)?;
    let headers: Vec<(String, String)> =
        response.retry_after.into_iter().map(|value| ("retry-after".to_owned(), value)).collect();
    read_answer(response.status, &headers, &response.bytes).map_err(|refused| match refused {
        KeysetRefused::RateLimited { retry_after } => {
            KeysetRefused::RateLimited { retry_after: retry_after.min(MAX_RETRY_AFTER) }
        }
        other => other,
    })
}

/// carrier.json's new text after a fetch for `route` brought `keys`: only
/// when the file (read again, `current`) still exists and names the same
/// relay, machine and slot, and its keyset differs. `None` drops the
/// result.
pub fn swap_text(
    current: Option<&str>,
    route: &CarrierRoute,
    issuer: &str,
    keys: &Keyset,
) -> Option<String> {
    let file = parse_file(current).ok().flatten()?;
    if file.route != *route {
        return None;
    }
    with_keyset(current, issuer, &keyset_json(keys))
}

/// What wakes the keeper.
pub enum Event<H: Http> {
    /// The machine is bound (again), with its client.
    Bound(Box<CloudClient<H>>),
    /// The session host's verifier saw a grant signed by this kid.
    UnknownKid(String),
    /// [`Keeper::next_wakeup`] passed.
    Deadline,
}

struct Held<H: Http> {
    client: Box<CloudClient<H>>,
    schedule: KeysetRefresh,
    /// The route of the carrier.json the schedule is for.
    route: CarrierRoute,
}

/// A fetch's result, for [`swap_text`].
pub struct Fetched {
    pub route: CarrierRoute,
    pub issuer: String,
    pub keys: Keyset,
}

/// The schedule and client of a machine with a carrier (sans I/O but the
/// fetch itself): the thread's state, driven by [`Keeper::on`].
pub struct Keeper<H: Http> {
    held: Option<Held<H>>,
}

impl<H: Http> Default for Keeper<H> {
    fn default() -> Self {
        Keeper { held: None }
    }
}

impl<H: Http> Keeper<H> {
    /// Whether a carrier is held (a schedule runs).
    pub fn is_active(&self) -> bool {
        self.held.is_some()
    }

    /// When the schedule wants waking, or `None` (wait for a message only).
    pub fn next_wakeup(&self) -> Option<Instant> {
        self.held.as_ref().map(|held| held.schedule.next_wakeup())
    }

    /// One event at `now`, with carrier.json's text as it is now: true to
    /// fetch. A missing or refused carrier.json clears everything, so no
    /// fetch happens until a bind brings a carrier back.
    pub fn on(&mut self, event: Event<H>, carrier: Option<&str>, now: Instant) -> bool {
        let file = parse_file(carrier).ok().flatten();
        let Some(file) = file else {
            self.held = None;
            return false;
        };
        match event {
            Event::Bound(client) => {
                self.held = read_keyset(&file.keyset).ok().map(|keys| {
                    let jitter = daily_jitter(&client.bound().machine);
                    Held {
                        client,
                        schedule: KeysetRefresh::at_bind(keys, now, jitter),
                        route: file.route,
                    }
                });
                self.held.is_some()
            }
            Event::UnknownKid(kid) => {
                self.held.as_mut().is_some_and(|held| held.schedule.on_unknown_kid(&kid, now))
            }
            Event::Deadline => {
                self.held.as_mut().is_some_and(|held| held.schedule.on_daily_deadline(now))
            }
        }
    }

    /// One bounded fetch; the answer goes into the schedule. A new keyset
    /// comes back for [`swap_text`].
    pub fn fetch(&mut self) -> Option<Fetched> {
        let held = self.held.as_mut()?;
        let response = RequestDeadline::after(FETCH_BUDGET)
            .ok_or_else(|| "no deadline".to_owned())
            .and_then(|deadline| held.client.request_with_headers(PATH, &deadline));
        let read = read_fetch(response);
        held.schedule.apply(read.clone(), Instant::now());
        Some(Fetched {
            route: held.route.clone(),
            issuer: held.client.bound().env.grant_issuer(),
            keys: read.ok()?,
        })
    }
}

enum Msg<H: Http> {
    Bound(Box<CloudClient<H>>),
    UnknownKid(String),
}

/// The worker's handle on the refresher thread. Dropping it stops the
/// thread (after a fetch in flight, at most [`FETCH_BUDGET`]).
pub struct Refresher<H: Http> {
    tx: Option<Sender<Msg<H>>>,
    lock: Arc<Mutex<()>>,
    thread: Option<JoinHandle<()>>,
}

impl<H: Http> Drop for Refresher<H> {
    fn drop(&mut self) {
        self.tx = None;
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl<H: Http + Send + 'static> Refresher<H> {
    pub fn spawn(paths: Paths, log: fn(&str)) -> std::io::Result<Refresher<H>> {
        let (tx, rx) = mpsc::channel();
        let lock = Arc::new(Mutex::new(()));
        let held = Arc::clone(&lock);
        let thread = std::thread::Builder::new()
            .name("cmux-host-keyset".to_owned())
            .spawn(move || run(&rx, &paths, &held, log))?;
        Ok(Refresher { tx: Some(tx), lock, thread: Some(thread) })
    }

    /// The lock every carrier.json writer of this process holds: the bind
    /// holds it around its write, the refresher around its re-read and
    /// write.
    pub fn carrier_lock(&self) -> Arc<Mutex<()>> {
        Arc::clone(&self.lock)
    }

    /// The machine is bound (again): fetch now, then on the schedule.
    pub fn bound(&self, client: CloudClient<H>) {
        self.send(Msg::Bound(Box::new(client)));
    }

    /// The session host's verifier saw a grant signed by `kid`.
    pub fn unknown_kid(&self, kid: String) {
        self.send(Msg::UnknownKid(kid));
    }

    fn send(&self, msg: Msg<H>) {
        if let Some(tx) = self.tx.as_ref() {
            let _ = tx.send(msg);
        }
    }
}

fn read_carrier(paths: &Paths) -> Option<String> {
    std::fs::read_to_string(paths.at(CARRIER_FILE)).ok()
}

fn run<H: Http>(rx: &Receiver<Msg<H>>, paths: &Paths, lock: &Mutex<()>, log: fn(&str)) {
    let mut keeper = Keeper::<H>::default();
    loop {
        let msg = match keeper.next_wakeup() {
            Some(at) => rx.recv_timeout(at.saturating_duration_since(Instant::now())),
            None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        let event = match msg {
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => Event::Deadline,
            Ok(Msg::Bound(client)) => Event::Bound(client),
            Ok(Msg::UnknownKid(kid)) => Event::UnknownKid(kid),
        };
        let was_active = keeper.is_active();
        let due = keeper.on(event, read_carrier(paths).as_deref(), Instant::now());
        if was_active && !keeper.is_active() {
            log("carrier: carrier.json is gone; keyset refresh stopped");
        }
        if !due {
            continue;
        }
        let Some(fetched) = keeper.fetch() else { continue };
        let _held = lock.lock().unwrap_or_else(PoisonError::into_inner);
        let current = read_carrier(paths);
        if let Some(text) =
            swap_text(current.as_deref(), &fetched.route, &fetched.issuer, &fetched.keys)
        {
            write(&paths.at(CARRIER_FILE), &text, log);
        }
    }
}

fn write(file: &Path, text: &str, log: fn(&str)) {
    match write_atomic(file, text.as_bytes()) {
        Ok(()) => log("carrier: kept the refreshed keyset"),
        Err(e) => log(&format!("carrier.json keyset write: {e}")),
    }
}

/// `file` (0600) through a temp file beside it, then a rename.
fn write_atomic(file: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let dir = file.parent().ok_or_else(|| std::io::Error::other("no parent"))?;
    let name = file.file_name().ok_or_else(|| std::io::Error::other("no file name"))?;
    let tmp = dir.join(format!(".{}.keyset-{}", name.to_string_lossy(), std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)
        .and_then(|mut out| out.write_all(bytes).and_then(|()| out.sync_all()))
        .and_then(|()| std::fs::rename(&tmp, file));
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

#[cfg(test)]
#[path = "carrier_keyset_tests.rs"]
mod tests;
