//! `cmux server pair`: the server side of pairing (server.md 6.2 steps 1,
//! 2 and 5; keys 6.1 and 6.5).
//!
//! 1. Load or make the install identity ([`identity`]).
//! 2. `POST /v1/pair/begin` with a proof of possession ([`api`]), or reuse
//!    an unexpired pending pairing of the same key, so a second `pair`
//!    (for example `pair` then `pair --wait`) shows the same code.
//! 3. Show the code, the QR payload and the four words.
//! 4. With `--wait`: one WebSocket to `/v1/pair/wait` ([`wait`]) until the
//!    pushed result, then store it in `credentials.json` (0600).
//!
//! Every file lives in `<state>/pairing/` (0700). One run at a time holds
//! `<state>/pairing/.lock`.

pub mod api;
pub mod identity;
pub mod info;
mod private;
pub mod wait;

use std::fs::{File, TryLockError};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_server_core::layout::Layout;
use cmux_server_core::pairing::{PairingCode, fingerprint_words, qr_payload};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{Error, Result};
use crate::fsx;

pub use api::HostInfo;
pub use identity::InstallIdentity;

pub const PAIRING_DIR: &str = "pairing";
pub const PENDING_FILE: &str = "pending.json";
pub const CREDENTIALS_FILE: &str = "credentials.json";

/// The production API Worker and its `ENVIRONMENT`.
pub const PRODUCTION_API: &str = "https://cloud-api.cmux.dev";
pub const PRODUCTION_ENV: &str = "production";

/// Where pairing talks to, and the environment name the begin proof binds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApiTarget {
    pub base: String,
    pub environment: String,
    /// `http://` and `ws://` (tests only).
    pub allow_http: bool,
}

impl ApiTarget {
    pub fn production() -> ApiTarget {
        ApiTarget {
            base: PRODUCTION_API.to_owned(),
            environment: PRODUCTION_ENV.to_owned(),
            allow_http: false,
        }
    }

    /// Production, except in a debug build where `CMUX_SERVER_API_URL` and
    /// `CMUX_SERVER_API_ENV` (both) name a development or test Worker. A
    /// release build never sends its key proof to another origin.
    pub fn from_env() -> ApiTarget {
        let var = |n: &str| std::env::var(n).ok().filter(|v| !v.is_empty());
        match (cfg!(debug_assertions), var("CMUX_SERVER_API_URL"), var("CMUX_SERVER_API_ENV")) {
            (true, Some(base), Some(environment)) => {
                let allow_http = base.starts_with("http://");
                ApiTarget { base, environment, allow_http }
            }
            _ => ApiTarget::production(),
        }
    }

    /// `(tls, host, port)` of the base URL.
    pub fn endpoint(&self) -> Result<(bool, String, u16)> {
        let (tls, rest) = match self.base.split_once("://") {
            Some(("https", rest)) => (true, rest),
            Some(("http", rest)) if self.allow_http => (false, rest),
            _ => return Err(Error::rejected(format!("refusing API base {}", self.base))),
        };
        let authority = rest.split('/').next().unwrap_or("");
        if authority.is_empty() || authority.contains(['@', '?', '#']) {
            return Err(Error::rejected(format!("refusing API base {}", self.base)));
        }
        let (host, port) = match authority.rsplit_once(':') {
            Some((h, p)) if !h.ends_with(']') || h.starts_with('[') => (
                h.trim_matches(['[', ']']).to_owned(),
                p.parse().map_err(|_| Error::usage(format!("bad port in {}", self.base)))?,
            ),
            _ => (authority.to_owned(), if tls { 443 } else { 80 }),
        };
        Ok((tls, host, port))
    }

    pub fn url(&self, path: &str) -> Result<String> {
        self.endpoint()?;
        Ok(format!("{}{path}", self.base.trim_end_matches('/')))
    }

    pub fn ws_url(&self, path: &str) -> Result<String> {
        let (tls, _, _) = self.endpoint()?;
        let rest = self.base.split_once("://").map_or("", |(_, r)| r).trim_end_matches('/');
        Ok(format!("{}://{rest}{path}", if tls { "wss" } else { "ws" }))
    }
}

/// `<state>/pairing`.
pub fn pairing_dir(layout: &Layout) -> PathBuf {
    fsx::local(&layout.state).join(PAIRING_DIR)
}

/// One pairing run: inputs.
pub struct PairRequest<'a> {
    pub layout: &'a Layout,
    pub api: &'a ApiTarget,
    pub info: HostInfo,
    pub wait: bool,
    /// The wait deadline; `None` waits until the code expires.
    pub timeout: Option<Duration>,
    pub now_ms: u64,
}

/// What the person reads or scans.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Started {
    /// `7KQ4-M2XD`.
    pub code: String,
    pub expires_at: u64,
    pub words: [String; 4],
    pub qr_payload: String,
    /// True when an earlier run's unexpired code was reused.
    #[serde(skip)]
    pub resumed: bool,
}

/// The stored result of a finished pairing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Paired {
    pub host: String,
    pub team: String,
}

#[derive(Debug)]
pub enum PairOutcome {
    /// Without `--wait`: the code is shown; approval is collected later.
    Pending(Started),
    Paired(Paired),
    /// `credentials.json` already holds a pairing; nothing was sent.
    AlreadyPaired(Paired),
}

#[derive(Serialize, Deserialize)]
struct Pending {
    code: String,
    collect_secret: String,
    expires_at: u64,
    thumbprint: String,
    api: String,
    /// The Worker `ENVIRONMENT` the begin proof was signed for.
    #[serde(default)]
    environment: String,
}

/// A code is never trusted to live longer than this after `now` (the
/// backend's TTL is 10 minutes), whatever `expires_at` says.
const MAX_CODE_LIFE: Duration = Duration::from_secs(10 * 60);
/// Slack after expiry for the Worker's 4408 to arrive.
const EXPIRY_MARGIN: Duration = Duration::from_secs(30);

/// An exclusive lock on the pairing folder, released on drop.
struct PairLock {
    _file: File,
}

fn lock(dir: &Path) -> Result<PairLock> {
    let path = dir.join(".lock");
    let file = private::open_lock(&path)?;
    match file.try_lock() {
        Ok(()) => Ok(PairLock { _file: file }),
        Err(TryLockError::WouldBlock) => {
            Err(Error::unreachable("another `cmux server pair` is running on this machine"))
        }
        Err(TryLockError::Error(e)) => Err(Error::io(path.display(), e)),
    }
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<Option<T>> {
    match private::read(path)? {
        Some(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| Error::internal(format!("{}: {e}", path.display()))),
        None => Ok(None),
    }
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut bytes = serde_json::to_vec_pretty(value).map_err(|e| Error::internal(e.to_string()))?;
    bytes.push(b'\n');
    fsx::atomic_write(path, &bytes, 0o600)
}

fn remove_if_present(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(Error::io(path.display(), e)),
    }
}

/// Server-sent text for a terminal: no control characters, bounded.
fn printable(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(200).collect()
}

fn field<'a>(record: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    record.get(key).and_then(Value::as_str)
}

fn paired_from(record: &Map<String, Value>) -> Option<Paired> {
    Some(Paired {
        host: printable(field(record, "host")?),
        team: printable(field(record, "team")?),
    })
}

/// Runs one pairing. `on_started` gets each code before its wait begins.
pub fn run(req: &PairRequest<'_>, on_started: &mut dyn FnMut(&Started)) -> Result<PairOutcome> {
    fsx::ensure_dir(&fsx::local(&req.layout.state), 0o700)?;
    private::check_dir(&req.layout.state)?;
    let dir = pairing_dir(req.layout);
    fsx::ensure_dir(&dir, 0o700)?;
    private::check_dir(&req.layout.state.join(PAIRING_DIR))?;
    let _lock = lock(&dir)?;
    let identity = InstallIdentity::load_or_create(&dir)?;
    let thumbprint_b64u = identity.thumbprint_b64u();
    if let Some(record) = read_json::<Map<String, Value>>(&dir.join(CREDENTIALS_FILE))? {
        let paired = paired_from(&record)
            .ok_or_else(|| Error::internal(format!("{CREDENTIALS_FILE} has no host or team")))?;
        if field(&record, "thumbprint") != Some(thumbprint_b64u.as_str())
            || field(&record, "api") != Some(req.api.base.as_str())
        {
            return Err(Error::rejected(format!(
                "this server is paired as host {} through {}, with another install key or API than this run ({}); unpair it first",
                paired.host,
                printable(field(&record, "api").unwrap_or("an unknown API")),
                req.api.base
            )));
        }
        return Ok(PairOutcome::AlreadyPaired(paired));
    }
    let pending_path = dir.join(PENDING_FILE);
    let start = Instant::now();
    let now = || req.now_ms + start.elapsed().as_millis() as u64;
    // A stored code of this key, API and environment is used until it
    // really expires: it may be approved already, and a new begin would
    // lose that result and make a second install on a second approval.
    let mut pending = read_json::<Pending>(&pending_path)?.filter(|p| {
        p.thumbprint == thumbprint_b64u
            && p.api == req.api.base
            && p.environment == req.api.environment
            && p.expires_at > now()
            && api::valid_collect_secret(&p.collect_secret)
    });
    let fixed_deadline = req.timeout.map(|t| start + t);
    let mut fresh = false;
    loop {
        let (p, resumed) = match pending.take() {
            Some(p) => (p, true),
            None => {
                let begun = api::begin(req.api, &identity, &req.info, now())?;
                let p = Pending {
                    code: begun.code.as_str().to_owned(),
                    collect_secret: begun.collect_secret,
                    expires_at: begun.expires_at,
                    thumbprint: thumbprint_b64u.clone(),
                    api: req.api.base.clone(),
                    environment: req.api.environment.clone(),
                };
                write_json(&pending_path, &p)?;
                fresh = true;
                (p, false)
            }
        };
        let code = PairingCode::normalize(&p.code)
            .map_err(|_| Error::internal(format!("{}: invalid code", pending_path.display())))?;
        let thumbprint = identity.thumbprint();
        let started = Started {
            code: code.display(),
            expires_at: p.expires_at,
            words: fingerprint_words(&thumbprint).map(str::to_owned),
            qr_payload: qr_payload(&code, &thumbprint),
            resumed,
        };
        on_started(&started);
        if !req.wait {
            return Ok(PairOutcome::Pending(started));
        }
        let life = Duration::from_millis(p.expires_at.saturating_sub(now())).min(MAX_CODE_LIFE);
        let deadline = fixed_deadline.unwrap_or_else(|| Instant::now() + life + EXPIRY_MARGIN);
        // A timeout (the `?`) keeps the code for the next `pair --wait`.
        match wait::wait(req.api, code.as_str(), &p.collect_secret, deadline)? {
            wait::End::Paired(record) => return store(req, &dir, &thumbprint_b64u, record),
            wait::End::Refused => {
                remove_if_present(&pending_path)?;
                return Err(Error::rejected("the pairing was refused"));
            }
            wait::End::Expired => {
                remove_if_present(&pending_path)?;
                // A stored code ran out: begin once more. A fresh code
                // that runs out ends the run.
                if fresh {
                    return Err(Error::unreachable(
                        "the pairing code expired; run `cmux server pair` again",
                    ));
                }
            }
        }
    }
}

fn store(
    req: &PairRequest<'_>,
    dir: &Path,
    thumbprint_b64u: &str,
    record: Map<String, Value>,
) -> Result<PairOutcome> {
    let paired = paired_from(&record)
        .ok_or_else(|| Error::internal("the pairing result has no host or team"))?;
    let mut stored = record;
    stored.insert("api".to_owned(), Value::String(req.api.base.clone()));
    stored.insert("environment".to_owned(), Value::String(req.api.environment.clone()));
    stored.insert("thumbprint".to_owned(), Value::String(thumbprint_b64u.to_owned()));
    stored.insert("paired_at".to_owned(), Value::from(crate::host::now_ms()));
    write_json(&dir.join(CREDENTIALS_FILE), &stored)?;
    remove_if_present(&dir.join(PENDING_FILE))?;
    Ok(PairOutcome::Paired(paired))
}
