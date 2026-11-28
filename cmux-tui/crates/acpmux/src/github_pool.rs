//! The pool budget on the Mac that lends its login (`github_broker.rs`): one agent
//! session reading in a loop cannot spend the hourly pool every other machine's agents, and the
//! person's own `gh`, draw from.
//!
//! The rules are the fleet's (`gh-quota.json`, `tools/gh_quota.py` in leo-workspace), moved into
//! the product so the broker that runs the call is the one that budgets it:
//!
//! - Only reads are charged. Actions that land work (`token`, issue, comment, draft pull request)
//!   are never refused here: a push that waits on a quota is the outage the budget exists to
//!   prevent.
//! - The pools are the Mac's keyring login's, read with `gh api rate_limit` (which GitHub does not
//!   charge) at most once a `READING_TTL`: `core` (REST) and `graphql` (`gh pr view --json` and
//!   `gh repo view --json` spend GraphQL points, not REST calls). Each read is judged against the
//!   pool it spends ([`Pool`], [`pool_of`]). GitHub's Actions endpoints answer from a REST counter
//!   of their own that `rate_limit` does not list; it is read from their answers' headers
//!   ([`Budget::set_pool_reading`]) and, until one is seen, an Actions read is held to `core`.
//!   An App installation token has a pool of its own per repository, so a read that runs with one
//!   is not judged against the keyring's.
//! - The floor is `FLOOR_SHARE` of the limit scaled by how much of the hour is left before the
//!   reset, never under `FLOOR_MIN_SHARE` of it; under `HARD_RESERVE` remaining, no read runs.
//! - A caller (the lane peer and its session) gets `CALLER_READS_PER_HOUR` reads in a rolling hour,
//!   counted always and enforced while the pool is under its floor or has no fresh reading.
//! - Reads from every caller together start at most `PACE_PER_MINUTE` a minute.
//! - A refusal is `-32044` and names who is over (the caller or the pool), the reading, and when
//!   to ask again, spread over `RETRY_SPREAD` by caller so refused lanes do not all come back in
//!   the same second.

use std::collections::{HashMap, VecDeque};
use std::sync::{LazyLock, Mutex};

use serde_json::{Value, json};

use crate::rpc::RpcError;

pub const CALLER_READS_PER_HOUR: usize = 600;
pub const PACE_PER_MINUTE: usize = 170;
pub const HARD_RESERVE: u64 = 500;
pub const FLOOR_SHARE: f64 = 0.15;
pub const FLOOR_MIN_SHARE: f64 = 0.02;
pub const READING_TTL_MS: u64 = 60_000;
pub const RETRY_SPREAD_MS: u64 = 120_000;
const HOUR_MS: u64 = 3_600_000;
const MINUTE_MS: u64 = 60_000;
/// How many callers' windows are kept; past that the least recently seen goes.
const CALLERS_MAX: usize = 4096;

/// Which of the login's pools a read spends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Pool {
    /// REST (`resources.core`).
    Core,
    /// GraphQL points (`resources.graphql`).
    Graphql,
    /// The REST counter GitHub's Actions endpoints answer from (runs, jobs, logs).
    Actions,
}

impl Pool {
    pub const ALL: [Pool; 3] = [Pool::Core, Pool::Graphql, Pool::Actions];

    pub fn name(self) -> &'static str {
        match self {
            Pool::Core => "core",
            Pool::Graphql => "graphql",
            Pool::Actions => "actions",
        }
    }
}

/// The pool `gh ARGS` spends: `gh api graphql` and the `--json` views (`gh` answers them with
/// GraphQL) spend GraphQL points; `gh run`, `gh workflow` and `gh api .../actions/...` the Actions
/// counter; every other `gh api` call REST.
pub fn pool_of<S: AsRef<str>>(args: &[S]) -> Pool {
    let words: Vec<&str> = args.iter().map(AsRef::as_ref).collect();
    match words.first().copied() {
        Some("api") => {
            let path = api_path(words.get(1..).unwrap_or_default());
            let path = path.trim_start_matches('/');
            if path == "graphql" {
                Pool::Graphql
            } else if path.split(['/', '?']).any(|seg| seg == "actions") {
                Pool::Actions
            } else {
                Pool::Core
            }
        }
        Some("run" | "workflow" | "cache") => Pool::Actions,
        Some(_) if words.iter().any(|w| *w == "--json" || w.starts_with("--json=")) => {
            Pool::Graphql
        }
        _ => Pool::Core,
    }
}

/// `gh api`'s endpoint: its first word that is neither a flag nor a flag's value.
fn api_path<'a>(words: &[&'a str]) -> &'a str {
    // `gh api`'s flags that take a value as the next word.
    const VALUED: [&str; 14] = [
        "-X",
        "--method",
        "-H",
        "--header",
        "-f",
        "--raw-field",
        "-F",
        "--field",
        "-q",
        "--jq",
        "-t",
        "--template",
        "--input",
        "--hostname",
    ];
    let mut it = words.iter();
    while let Some(w) = it.next() {
        if VALUED.contains(w) {
            it.next();
        } else if !w.starts_with('-') {
            return w;
        }
    }
    ""
}

/// One pool as `gh api rate_limit` (or an Actions answer's headers) last said it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reading {
    pub limit: u64,
    pub remaining: u64,
    /// When the pool resets, ms since the epoch.
    pub reset_ms: u64,
    /// When it was read, ms since the epoch.
    pub read_ms: u64,
}

impl Reading {
    fn fresh(&self, now_ms: u64) -> bool {
        now_ms.saturating_sub(self.read_ms) <= READING_TTL_MS
    }

    /// The floor under which each caller's own cap holds.
    pub fn floor(&self, now_ms: u64) -> u64 {
        let left = self.reset_ms.saturating_sub(now_ms).min(HOUR_MS) as f64 / HOUR_MS as f64;
        let limit = self.limit as f64;
        (limit * FLOOR_SHARE * left).max(limit * FLOOR_MIN_SHARE) as u64
    }

    fn to_json(self) -> Value {
        json!({"limit": self.limit, "remaining": self.remaining, "resetAt": self.reset_ms, "readAt": self.read_ms})
    }
}

/// Every pool `gh api rate_limit` lists that a read spends, from one call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Readings {
    pub core: Reading,
    pub graphql: Option<Reading>,
}

/// Every caller's reads in the last hour and every read in the last minute.
#[derive(Default)]
pub struct Budget {
    callers: HashMap<String, VecDeque<u64>>,
    minute: VecDeque<u64>,
    readings: HashMap<Pool, Reading>,
}

impl Budget {
    /// One `rate_limit` answer: `core` and, when it lists it, `graphql`. The Actions counter keeps
    /// its own reading (`rate_limit` does not list it).
    pub fn set_readings(&mut self, readings: Readings) {
        self.readings.insert(Pool::Core, readings.core);
        if let Some(g) = readings.graphql {
            self.readings.insert(Pool::Graphql, g);
        }
    }

    /// A reading of one pool, e.g. the Actions counter from an Actions answer's headers.
    pub fn set_pool_reading(&mut self, pool: Pool, reading: Reading) {
        self.readings.insert(pool, reading);
    }

    pub fn reading(&self, pool: Pool) -> Option<Reading> {
        self.readings.get(&pool).copied()
    }

    /// The fresh reading a read from `pool` is held to: its own, and for the Actions counter
    /// with none yet, core's (the counter it was before GitHub split it).
    fn held_to(&self, pool: Pool, now_ms: u64) -> Option<(Pool, Reading)> {
        let own = self.readings.get(&pool).filter(|r| r.fresh(now_ms)).map(|r| (pool, *r));
        match (own, pool) {
            (Some(o), _) => Some(o),
            (None, Pool::Actions) => self.held_to(Pool::Core, now_ms),
            (None, _) => None,
        }
    }

    /// Whether `caller` may start a read from `pool` now (`pooled`: it runs with the login the
    /// readings are of); a read let in is counted against that pool.
    pub fn admit_read(
        &mut self,
        caller: &str,
        pool: Pool,
        pooled: bool,
        now_ms: u64,
    ) -> Result<(), RpcError> {
        while self.minute.front().is_some_and(|t| now_ms.saturating_sub(*t) >= MINUTE_MS) {
            self.minute.pop_front();
        }
        let held = if pooled { self.held_to(pool, now_ms) } else { None };
        let reading = held.map(|(_, r)| r);
        let on = held.map_or(pool, |(p, _)| p);
        if let Some(r) = reading
            && r.remaining <= HARD_RESERVE
        {
            return Err(refusal("pool", on, caller, Some(r), r.reset_ms.max(now_ms), now_ms));
        }
        if self.minute.len() >= PACE_PER_MINUTE {
            let next = self.minute.front().map_or(now_ms, |t| t + MINUTE_MS);
            return Err(refusal("pace", on, caller, reading, next, now_ms));
        }
        let near_floor = match reading {
            Some(r) => r.remaining < r.floor(now_ms),
            // No fresh reading of the pool this read draws from: hold every caller to its cap.
            None => true,
        };
        if !self.callers.contains_key(caller) && self.callers.len() >= CALLERS_MAX {
            let oldest = self
                .callers
                .iter()
                .min_by_key(|(_, w)| w.back().copied().unwrap_or(0))
                .map(|(k, _)| k.clone());
            if let Some(k) = oldest {
                self.callers.remove(&k);
            }
        }
        let window = self.callers.entry(caller.to_owned()).or_default();
        while window.front().is_some_and(|t| now_ms.saturating_sub(*t) >= HOUR_MS) {
            window.pop_front();
        }
        if near_floor && window.len() >= CALLER_READS_PER_HOUR {
            let next = window.front().map_or(now_ms, |t| t + HOUR_MS);
            return Err(refusal("caller", on, caller, reading, next, now_ms));
        }
        window.push_back(now_ms);
        self.minute.push_back(now_ms);
        // A read spends one from its pool: until the next reading, count it down.
        if let Some(r) = held.and_then(|(p, _)| self.readings.get_mut(&p)) {
            r.remaining = r.remaining.saturating_sub(1);
        }
        Ok(())
    }
}

/// A caller's share of `RETRY_SPREAD_MS`, the same every time for one caller.
fn spread(caller: &str) -> u64 {
    let h = caller
        .bytes()
        .fold(0xcbf2_9ce4_8422_2325_u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3));
    h % RETRY_SPREAD_MS
}

/// `-32044`: `over` is `caller`, `pace` or `pool`. Only a `caller` refusal stays on this caller:
/// another Mac's pool may still serve a `pool` or `pace` one (`server/github_lane.rs`; the lane's own per-session cap on running actions is `github_budget.rs`).
fn refusal(
    over: &str,
    pool: Pool,
    caller: &str,
    reading: Option<Reading>,
    until_ms: u64,
    now_ms: u64,
) -> RpcError {
    let retry_ms = until_ms.saturating_sub(now_ms) + spread(caller);
    let message = match over {
        "caller" => format!(
            "this session used its {CALLER_READS_PER_HOUR} GitHub reads for the hour while the Mac's pool is low; ask again in {}s",
            retry_ms / 1000
        ),
        "pace" => format!(
            "the Mac started {PACE_PER_MINUTE} GitHub reads this minute; ask again in {}s",
            retry_ms / 1000
        ),
        _ => format!(
            "the Mac's GitHub {} pool is down to its last {HARD_RESERVE} calls, kept for pushes and merges; ask again in {}s",
            pool.name(),
            retry_ms / 1000
        ),
    };
    RpcError::new(-32044, message).with_data(json!({
        "reason": format!("github.budget.{over}"),
        "caller": caller,
        "pool": pool.name(),
        "retryAfterMs": retry_ms,
        "retryable": true,
        "reading": reading.map(Reading::to_json),
    }))
}

static BUDGET: LazyLock<Mutex<Budget>> = LazyLock::new(Default::default);
/// One `gh api rate_limit` at a time.
static READER: LazyLock<tokio::sync::Mutex<()>> = LazyLock::new(Default::default);

/// The Mac's gate for one read by `caller` (`peer/session`) from `pool` that runs with `login`.
pub async fn admit(
    caller: &str,
    pool: Pool,
    login: &crate::github_app_token::Source,
) -> Result<(), RpcError> {
    let pooled = login.token().is_none();
    if pooled {
        refresh().await;
    }
    BUDGET.lock().unwrap_or_else(|e| e.into_inner()).admit_read(
        caller,
        pool,
        pooled,
        crate::store::now_ms(),
    )
}

/// The keyring login's pool, read again once the last reading is past `READING_TTL_MS`. A
/// failed read leaves the old one (it goes stale, and every caller is then held to its cap).
async fn refresh() {
    let stale = |now| {
        let b = BUDGET.lock().unwrap_or_else(|e| e.into_inner());
        !b.readings.get(&Pool::Core).is_some_and(|r| r.fresh(now))
    };
    if !stale(crate::store::now_ms()) {
        return;
    }
    let _one = READER.lock().await;
    if !stale(crate::store::now_ms()) {
        return;
    }
    if let Some(r) = read_pool().await {
        BUDGET.lock().unwrap_or_else(|e| e.into_inner()).set_readings(r);
    }
}

async fn read_pool() -> Option<Readings> {
    let mut gh = tokio::process::Command::new("gh");
    gh.args(["api", "rate_limit"]);
    crate::github_broker::login_env(gh.as_std_mut(), None);
    gh.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let out =
        tokio::time::timeout(std::time::Duration::from_secs(10), gh.output()).await.ok()?.ok()?;
    if !out.status.success() {
        return None;
    }
    parse_reading(&out.stdout, crate::store::now_ms())
}

/// `gh api rate_limit`'s answer: the core pool (required) and the GraphQL one (when listed).
pub fn parse_reading(body: &[u8], now_ms: u64) -> Option<Readings> {
    let v: Value = serde_json::from_slice(body).ok()?;
    let resources = v.get("resources")?;
    let one = |r: &Value| -> Option<Reading> {
        Some(Reading {
            limit: r.get("limit")?.as_u64()?,
            remaining: r.get("remaining")?.as_u64()?,
            reset_ms: r.get("reset")?.as_u64()? * 1000,
            read_ms: now_ms,
        })
    };
    Some(Readings {
        core: one(resources.get("core")?)?,
        graphql: resources.get("graphql").and_then(one),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000_000;

    fn reading(remaining: u64) -> Reading {
        Reading { limit: 5000, remaining, reset_ms: NOW + HOUR_MS, read_ms: NOW }
    }

    #[test]
    fn a_caller_over_its_cap_is_refused_only_while_the_pool_is_low() {
        let mut b = Budget::default();
        b.set_pool_reading(Pool::Core, reading(4000));
        // 170 a minute pace: spread the reads over the hour.
        for i in 0..CALLER_READS_PER_HOUR as u64 + 10 {
            let mut fresh = reading(4000);
            fresh.read_ms = NOW + i * 5000;
            b.set_pool_reading(Pool::Core, fresh);
            assert!(
                b.admit_read("lane/a", Pool::Core, true, NOW + i * 5000).is_ok(),
                "pool high: no cap"
            );
        }
        let t = NOW + 3_100_000;
        // Over the reserve but under the floor (15% of the limit with the hour still ahead).
        b.set_pool_reading(
            Pool::Core,
            Reading { limit: 5000, remaining: 600, reset_ms: t + HOUR_MS, read_ms: t },
        );
        let e = b.admit_read("lane/a", Pool::Core, true, t).unwrap_err();
        assert_eq!(e.code, -32044);
        let data = e.data.unwrap();
        assert_eq!(data["reason"], "github.budget.caller");
        assert_eq!(data["caller"], "lane/a");
        assert!(data["retryAfterMs"].as_u64().unwrap() > 0);
        assert!(b.admit_read("lane/b", Pool::Core, true, t).is_ok(), "another caller still reads");
    }

    #[test]
    fn the_hard_reserve_refuses_every_read() {
        let mut b = Budget::default();
        b.set_pool_reading(Pool::Core, reading(HARD_RESERVE));
        let e = b.admit_read("lane/a", Pool::Core, true, NOW).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.budget.pool");
        // An App token's read draws from another pool.
        assert!(b.admit_read("lane/a", Pool::Core, false, NOW).is_ok());
    }

    #[test]
    fn reads_are_paced_across_callers() {
        let mut b = Budget::default();
        b.set_pool_reading(Pool::Core, reading(5000));
        for i in 0..PACE_PER_MINUTE {
            assert!(b.admit_read(&format!("lane/{i}"), Pool::Core, true, NOW).is_ok());
        }
        let e = b.admit_read("lane/x", Pool::Core, true, NOW + 1).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.budget.pace");
        assert!(b.admit_read("lane/x", Pool::Core, true, NOW + MINUTE_MS).is_ok());
    }

    #[test]
    fn no_reading_holds_every_caller_to_its_cap() {
        let mut b = Budget::default();
        for i in 0..CALLER_READS_PER_HOUR as u64 {
            assert!(b.admit_read("lane/a", Pool::Core, true, NOW + i * 1000).is_ok());
        }
        let e = b.admit_read("lane/a", Pool::Core, true, NOW + 700_000).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.budget.caller");
    }

    #[test]
    fn the_floor_shrinks_toward_the_reset() {
        let r = reading(1000);
        assert_eq!(r.floor(NOW), 750);
        assert_eq!(r.floor(NOW + HOUR_MS - 60_000), 100, "never under 2% of the limit");
    }

    #[test]
    fn rate_limit_answer_parses() {
        let body = br#"{"resources":{"core":{"limit":5000,"remaining":4321,"reset":1800003600},"graphql":{"limit":5000,"remaining":120,"reset":1800001800}}}"#;
        let r = parse_reading(body, NOW).unwrap();
        assert_eq!(
            (r.core.limit, r.core.remaining, r.core.reset_ms),
            (5000, 4321, 1_800_003_600_000)
        );
        let g = r.graphql.unwrap();
        assert_eq!((g.remaining, g.reset_ms), (120, 1_800_001_800_000));
        let core_only =
            br#"{"resources":{"core":{"limit":5000,"remaining":1,"reset":1800003600}}}"#;
        assert!(parse_reading(core_only, NOW).unwrap().graphql.is_none());
        assert!(parse_reading(b"{}", NOW).is_none());
    }

    #[test]
    fn each_read_is_judged_against_the_pool_it_spends() {
        let mut b = Budget::default();
        b.set_readings(Readings { core: reading(4000), graphql: Some(reading(HARD_RESERVE - 1)) });
        // GraphQL spent: a `--json` view is refused, naming the pool; a REST read still runs.
        let e = b.admit_read("lane/a", Pool::Graphql, true, NOW).unwrap_err();
        let data = e.data.unwrap();
        assert_eq!(data["reason"], "github.budget.pool");
        assert_eq!(data["pool"], "graphql");
        assert!(e.message.contains("graphql pool"), "{}", e.message);
        assert!(b.admit_read("lane/a", Pool::Core, true, NOW).is_ok());
        // Only the pool a read spends is counted down.
        assert_eq!(b.reading(Pool::Core).unwrap().remaining, 3999);
        assert_eq!(b.reading(Pool::Graphql).unwrap().remaining, HARD_RESERVE - 1);
    }

    #[test]
    fn the_actions_counter_is_held_to_core_until_its_own_reading() {
        let mut b = Budget::default();
        b.set_readings(Readings { core: reading(HARD_RESERVE), graphql: Some(reading(5000)) });
        let e = b.admit_read("lane/a", Pool::Actions, true, NOW).unwrap_err();
        assert_eq!(e.data.unwrap()["pool"], "core", "no Actions reading yet: core's");
        b.set_pool_reading(Pool::Actions, reading(3000));
        assert!(b.admit_read("lane/a", Pool::Actions, true, NOW).is_ok());
        assert_eq!(b.reading(Pool::Actions).unwrap().remaining, 2999);
        assert_eq!(b.reading(Pool::Core).unwrap().remaining, HARD_RESERVE);
    }

    #[test]
    fn a_stale_graphql_reading_holds_callers_to_their_cap_not_core() {
        let mut b = Budget::default();
        let mut old = reading(5000);
        old.read_ms = NOW - READING_TTL_MS - 1;
        b.set_readings(Readings { core: reading(5000), graphql: Some(old) });
        for i in 0..CALLER_READS_PER_HOUR as u64 {
            assert!(b.admit_read("lane/a", Pool::Graphql, true, NOW + i * 400).is_ok());
        }
        let e = b.admit_read("lane/a", Pool::Graphql, true, NOW + 300_000).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.budget.caller");
    }

    #[test]
    fn gh_commands_map_to_the_pool_they_spend() {
        let cases: &[(&[&str], Pool)] = &[
            (&["pr", "view", "1", "--json=number,title", "--repo=o/r"], Pool::Graphql),
            (&["repo", "view", "o/r", "--json=url"], Pool::Graphql),
            (&["pr", "list", "--json", "number"], Pool::Graphql),
            (&["api", "graphql", "-f", "query=x"], Pool::Graphql),
            (&["api", "/graphql"], Pool::Graphql),
            (&["api", "repos/o/r/actions/runs/1/jobs"], Pool::Actions),
            (&["api", "-X", "GET", "repos/o/r/actions/runs?per_page=5"], Pool::Actions),
            (&["run", "view", "1", "--log-failed"], Pool::Actions),
            (&["workflow", "list"], Pool::Actions),
            (&["api", "repos/o/r/pulls/1"], Pool::Core),
            (&["api", "repos/o/actions-tools/pulls"], Pool::Core),
            (&["pr", "diff", "1"], Pool::Core),
        ];
        for (args, pool) in cases {
            assert_eq!(pool_of(args), *pool, "{args:?}");
        }
    }
}
