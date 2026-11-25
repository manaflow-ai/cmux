//! Opt-in team usage sharing for acpmux: one record per agent turn, uploaded to the person's team
//! on cmux-platform (`POST /v1/usage/records`), which serves the team spend audit
//! (`GET /v1/usage/audit`: by person, repository, model, harness, machine and day).
//!
//! Off by default. Nothing is recorded and nothing is sent until the person turns on
//! `diagnostics.usageSharing` (`CMUX_USAGE_SHARING=on|off` overrides the setting). While on, each
//! finished turn appends one `turn` record (and a session's first, one `session` record) to
//! `<ACPMUX_HOME>/usage-share/YYYY-MM-DD.jsonl`, and the daemon uploads the unsent lines every
//! [`UPLOAD_EVERY`].
//!
//! What a record holds: counts, times, a harness and model name (tokens only), the turn's outcome,
//! and ids hashed with a salt that never leaves the machine (session, repository from the git
//! origin URL, machine from the host name). Never prompt or reply text, tool input or output,
//! file paths, the working folder, branch names or titles. The wire format is cmux-platform's
//! `src/server/usage/Validate.ts`, which refuses a whole batch on any field it does not list.
//!
//! Cost stays constant: off is one cached setting read (reread at most every
//! [`GATE_REREAD`], only when a turn ends or the uploader wakes); on is one small append per
//! turn. The spool keeps [`spool::KEEP_DAYS`] days.

pub mod ids;
pub mod record;
pub mod spool;
pub mod upload;

use ids::Identity;
use record::{Event, Outcome, Record, SRC, SessionEvent, TurnEvent};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The setting that turns sharing on (a toggle, default off).
pub const SETTING_KEY: &str = "diagnostics.usageSharing";
/// `CMUX_USAGE_SHARING=on|off` overrides the setting.
pub const ENV_OVERRIDE: &str = "CMUX_USAGE_SHARING";
/// The spool's folder under the acpmux home.
pub const DIR_NAME: &str = "usage-share";
/// How often the daemon uploads while sharing is on.
pub const UPLOAD_EVERY: Duration = Duration::from_secs(10 * 60);
/// The first upload after the daemon starts.
pub const FIRST_UPLOAD_AFTER: Duration = Duration::from_secs(30);
/// The longest a cached setting read is used.
pub const GATE_REREAD: Duration = Duration::from_secs(5);
/// Distinct sessions and working folders one daemon remembers (each a few bytes); past it the
/// memory starts over, which at worst writes a session's `session` record again.
const MAX_REMEMBERED: usize = 4096;

/// Whether sharing is on: `CMUX_USAGE_SHARING` when set, else `diagnostics.usageSharing` in the
/// settings file at `config` (nested or as one dotted key) is `true`. A missing or unreadable
/// file is off.
pub fn setting_enabled(config: &Path) -> bool {
    if let Some(forced) = env_override() {
        return forced;
    }
    let Some(root) =
        std::fs::read_to_string(config).ok().and_then(|text| cmux_config::jsonc::parse(&text).ok())
    else {
        return false;
    };
    let nested = cmux_config::value::value_at(&root, &["diagnostics", "usageSharing"]);
    let flat = root.get(SETTING_KEY);
    nested.or(flat).and_then(serde_json::Value::as_bool) == Some(true)
}

fn env_override() -> Option<bool> {
    let value = std::env::var(ENV_OVERRIDE).ok()?;
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "on" | "true" | "yes" => Some(true),
        "0" | "off" | "false" | "no" => Some(false),
        _ => None,
    }
}

/// A finished turn as acpmux knows it; [`Sharer::record_turn`] hashes and trims it.
#[derive(Debug, Clone, Default)]
pub struct TurnFacts<'a> {
    pub session_id: &'a str,
    pub harness: &'a str,
    pub model: Option<&'a str>,
    /// The session's working folder: only its git origin's hash is kept.
    pub cwd: Option<&'a Path>,
    pub ms: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub tool_calls: u32,
    pub cost_usd: Option<f64>,
    pub outcome: Option<Outcome>,
}

/// The last upload round, for a status surface.
#[derive(Debug, Clone, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// Unix ms of the last round's end (0: none yet).
    pub at: u64,
    pub round: Option<upload::Round>,
}

/// One process's sharing: the spool folder, the settings file it is gated by, and what it
/// remembers between turns.
pub struct Sharer {
    dir: PathBuf,
    config: PathBuf,
    gate: Mutex<Option<(Instant, bool)>>,
    identity: OnceLock<Option<Identity>>,
    seen: Mutex<HashSet<String>>,
    repos: Mutex<HashMap<PathBuf, Option<String>>>,
    status: Mutex<Status>,
    host: Option<String>,
}

impl Sharer {
    /// A sharer spooling in `dir`, gated by the settings file at `config`, on the machine named
    /// `host` (only its hash is recorded).
    pub fn new(dir: PathBuf, config: PathBuf, host: Option<String>) -> Self {
        Self {
            dir,
            config,
            gate: Mutex::new(None),
            identity: OnceLock::new(),
            seen: Mutex::new(HashSet::new()),
            repos: Mutex::new(HashMap::new()),
            status: Mutex::new(Status::default()),
            host: host.map(|h| h.trim().to_ascii_lowercase()).filter(|h| !h.is_empty()),
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Whether sharing is on now (the setting, reread at most every [`GATE_REREAD`]).
    pub fn enabled(&self) -> bool {
        let mut gate = self.gate.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((read, on)) = *gate
            && read.elapsed() < GATE_REREAD
        {
            return on;
        }
        let on = setting_enabled(&self.config);
        *gate = Some((Instant::now(), on));
        on
    }

    /// This install's salt and id, made on first use.
    pub fn identity(&self) -> Option<&Identity> {
        self.identity.get_or_init(|| Identity::load_or_create(&self.dir)).as_ref()
    }

    /// The machine as records name it: the host name hashed, else `local`.
    fn machine(&self, identity: &Identity) -> String {
        self.host
            .as_ref()
            .map_or_else(|| "local".to_owned(), |h| identity.hash(&format!("host:{h}")))
    }

    fn repo(&self, identity: &Identity, cwd: &Path) -> Option<String> {
        let mut repos = self.repos.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(known) = repos.get(cwd) {
            return known.clone();
        }
        let hashed = ids::origin_url(cwd)
            .and_then(|url| ids::normalize_remote(&url))
            .map(|remote| identity.hash(&format!("repo:{remote}")));
        if repos.len() >= MAX_REMEMBERED {
            repos.clear();
        }
        repos.insert(cwd.to_path_buf(), hashed.clone());
        hashed
    }

    /// Spools one finished turn (and the session's first `session` record) when sharing is on.
    /// Returns whether it wrote.
    pub fn record_turn(&self, facts: &TurnFacts<'_>) -> bool {
        if !self.enabled() {
            return false;
        }
        self.record_turn_at(facts, now_ms())
    }

    /// [`Self::record_turn`] at `at` with the gate already passed (tests).
    pub fn record_turn_at(&self, facts: &TurnFacts<'_>, at: u64) -> bool {
        let Some(identity) = self.identity() else { return false };
        let session = identity.hash(&format!("session:{}", facts.session_id));
        let harness = record::harness_token(facts.harness);
        let machine = self.machine(identity);
        let first = {
            let mut seen = self.seen.lock().unwrap_or_else(|e| e.into_inner());
            if seen.len() >= MAX_REMEMBERED {
                seen.clear();
            }
            seen.insert(session.clone())
        };
        if first {
            let ev = Event::Session(SessionEvent {
                session: session.clone(),
                harness: harness.clone(),
                machine: machine.clone(),
            });
            if spool::append(&self.dir, &Record { at, src: SRC.into(), ev }).is_err() {
                return false;
            }
        }
        let turn = TurnEvent {
            session,
            harness,
            model: facts.model.and_then(record::token),
            ms: facts.ms,
            input_tokens: facts.input_tokens,
            output_tokens: facts.output_tokens,
            cache_read_tokens: facts.cache_read_tokens,
            cache_write_tokens: facts.cache_write_tokens,
            tool_calls: facts.tool_calls,
            subagents: 0,
            repo: facts.cwd.and_then(|cwd| self.repo(identity, cwd)),
            machine: Some(machine),
            cost_usd: facts.cost_usd,
            outcome: facts.outcome,
        }
        .clamped();
        spool::append(&self.dir, &Record { at, src: SRC.into(), ev: Event::Turn(turn) }).is_ok()
    }

    /// One upload round with `sender` when sharing is on; prunes old spool files first. None when
    /// off or there is no identity.
    pub async fn upload_round<S: upload::Sender>(&self, sender: &S) -> Option<upload::Round> {
        if !self.enabled() {
            return None;
        }
        let install = self.identity()?.install.clone();
        spool::prune(&self.dir, now_ms());
        let round = upload::upload(&self.dir, &install, sender).await;
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) =
            Status { at: now_ms(), round: Some(round.clone()) };
        Some(round)
    }

    /// The last round.
    pub fn status(&self) -> Status {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

static GLOBAL: OnceLock<Sharer> = OnceLock::new();

/// Installs this process's sharer, spooling in `<home>/usage-share` and gated by the cmux
/// settings file, on the machine named `host` (once; later calls return the first).
pub fn install(home: &Path, host: Option<String>) -> &'static Sharer {
    GLOBAL.get_or_init(|| Sharer::new(home.join(DIR_NAME), cmux_config::config_path(), host))
}

/// This process's sharer, when [`install`] ran.
pub fn global() -> Option<&'static Sharer> {
    GLOBAL.get()
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod tests;
