//! The carrier's grant keyset, kept fresh by the Cloud role itself: one
//! thread beside the worker fetches `GET /v1/cloud/keyset` and, when the
//! keyset changed, rewrites `carrier.json` (temp file, then rename). The
//! supervisor's watch then rewrites the session host's
//! `carrier-grant.json` the same way, and the session host's verifier
//! re-reads it at the first grant signed by a kid it does not hold.
//!
//! When to fetch is cmux-link's [`KeysetRefresh`]: once when the machine
//! binds (or the agent restarts bound), then once a day at a time of day
//! jittered by the machine id, and on a grant with an unknown kid at most
//! once per 60 s. A 429 holds every fetch until its `retry-after`. The
//! session host's verifier reports an unknown kid on the agent socket
//! (`{"carrier_keyset": {"kid": "…"}}`, [`check_ask`]).
//!
//! Nothing here depends on the native receiver. A machine with no
//! `carrier.json` fetches nothing. The thread stops when the worker drops
//! its [`Refresher`] (the channel closes); a fetch in flight is bounded by
//! [`FETCH_BUDGET`].

use std::path::Path;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
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
use crate::carrier_entry::{CARRIER_FILE, with_keyset};
use crate::config::Paths;

/// The agent socket line's key.
pub const REQUEST_KEY: &str = "carrier_keyset";

/// The keyset route (no bearer: the keyset is public).
pub const PATH: &str = "/v1/cloud/keyset";

/// One fetch's whole budget.
pub const FETCH_BUDGET: Duration = Duration::from_secs(20);

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

/// The keyset kept in `carrier.json`'s text, when it has a valid one.
pub fn held(carrier: Option<&str>) -> Option<Keyset> {
    let file = crate::carrier_entry::parse_file(carrier).ok().flatten()?;
    read_keyset(&file.keyset).ok()
}

/// One fetch at `now`: the answer goes into `schedule`, and when it is a
/// new keyset for this machine's issuer, `carrier.json`'s new text.
pub fn fetch<H: Http>(
    client: &CloudClient<H>,
    schedule: &mut KeysetRefresh,
    carrier: Option<&str>,
    now: Instant,
) -> Option<String> {
    let read = RequestDeadline::after(FETCH_BUDGET)
        .ok_or_else(|| "no deadline".to_owned())
        .and_then(|deadline| client.request_until(PATH, None, None, &deadline))
        .map_or(Err(KeysetRefused::Unavailable), |(status, bytes)| {
            read_answer(status, &[], &bytes)
        });
    schedule.apply(read.clone(), now);
    let keys = read.ok()?;
    with_keyset(carrier, &client.bound().env.grant_issuer(), &keyset_json(&keys))
}

enum Msg<H: Http> {
    Bound(Box<CloudClient<H>>),
    UnknownKid(String),
}

/// The worker's handle on the refresher thread. Dropping it stops the
/// thread (after a fetch in flight, at most [`FETCH_BUDGET`]).
pub struct Refresher<H: Http> {
    tx: Option<Sender<Msg<H>>>,
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
        let thread = std::thread::Builder::new()
            .name("cmux-host-keyset".to_owned())
            .spawn(move || run(&rx, &paths, log))?;
        Ok(Refresher { tx: Some(tx), thread: Some(thread) })
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

fn run<H: Http>(rx: &Receiver<Msg<H>>, paths: &Paths, log: fn(&str)) {
    let mut state: Option<(Box<CloudClient<H>>, KeysetRefresh)> = None;
    loop {
        let msg = match &state {
            Some((_, schedule)) => {
                rx.recv_timeout(schedule.next_wakeup().saturating_duration_since(Instant::now()))
            }
            None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        let now = Instant::now();
        let due = match msg {
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {
                state.as_mut().is_some_and(|(_, schedule)| schedule.on_daily_deadline(now))
            }
            Ok(Msg::UnknownKid(kid)) => {
                state.as_mut().is_some_and(|(_, schedule)| schedule.on_unknown_kid(&kid, now))
            }
            Ok(Msg::Bound(client)) => {
                // A machine without a carrier keeps no keyset and fetches none.
                state = held(read_carrier(paths).as_deref()).map(|keys| {
                    let jitter = daily_jitter(&client.bound().machine);
                    (client, KeysetRefresh::at_bind(keys, now, jitter))
                });
                state.is_some()
            }
        };
        if let (true, Some((client, schedule))) = (due, state.as_mut()) {
            let carrier = read_carrier(paths);
            if let Some(text) = fetch(client, schedule, carrier.as_deref(), now) {
                write(&paths.at(CARRIER_FILE), &text, log);
            }
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
