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
//! - The floor is the merge reserve ([`Class`], [`class_of`]): under it a plain read stops, while a
//!   merge-critical one (a single `gh pr view N`, the read a landing makes before it merges) still
//!   runs down to `HARD_RESERVE`.
//! - A caller (the lane peer and its session) gets `CALLER_READS_PER_HOUR` reads in a rolling hour,
//!   counted always and enforced while the pool has no fresh reading or (for merge-critical reads,
//!   with `MERGE_CRITICAL_EXTRA_PER_HOUR` more) is under its floor: a loop of `gh pr view N` is
//!   still a loop.
//! - Every read is kept in a per-pool ledger ([`Budget::ledger`]): who spent how much of each pool
//!   in the last hour. A `pool` or `floor` refusal names the biggest spender of that pool.
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
pub const MERGE_CRITICAL_EXTRA_PER_HOUR: usize = 60;
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

/// How much of a pool a read may spend: a plain read stops at the floor (the merge reserve); a
/// merge-critical one runs down to `HARD_RESERVE`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Class {
    Reader,
    MergeCritical,
}

/// The class of `gh ARGS`: a single `gh pr view N` (what a landing reads before `gh pr merge`)
/// is merge-critical; every other read is a reader.
pub fn class_of<S: AsRef<str>>(args: &[S]) -> Class {
    let words: Vec<&str> = args.iter().map(AsRef::as_ref).collect();
    match words.as_slice() {
        ["pr", "view", n, ..] if !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => {
            Class::MergeCritical
        }
        _ => Class::Reader,
    }
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

/// One pool's last hour on this Mac: its limit (from the last reading, if any), the reads it let
/// in, and who spent them, most first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PoolLedger {
    pub pool: Pool,
    pub limit: Option<u64>,
    pub spent: usize,
    pub consumers: Vec<(String, usize)>,
}

impl PoolLedger {
    pub fn to_json(&self) -> Value {
        let consumers: Vec<Value> =
            self.consumers.iter().map(|(c, n)| json!({"caller": c, "calls": n})).collect();
        json!({"pool": self.pool.name(), "limit": self.limit, "spent": self.spent, "consumers": consumers})
    }

    /// The biggest spender, as `(caller, calls)`.
    pub fn top(&self) -> Option<(&str, usize)> {
        self.consumers.first().map(|(c, n)| (c.as_str(), *n))
    }
}

/// Every caller's reads in the last hour (when, and which pool each spent) and every read in the
/// last minute.
#[derive(Default)]
pub struct Budget {
    callers: HashMap<String, VecDeque<(u64, Pool)>>,
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

    /// Each pool's last hour: what every caller spent of it, most first (ties by name).
    pub fn ledger(&self, now_ms: u64) -> Vec<PoolLedger> {
        Pool::ALL
            .iter()
            .map(|&pool| {
                let mut consumers: Vec<(String, usize)> = self
                    .callers
                    .iter()
                    .map(|(c, w)| {
                        let n = w
                            .iter()
                            .filter(|(t, p)| *p == pool && now_ms.saturating_sub(*t) < HOUR_MS)
                            .count();
                        (c.clone(), n)
                    })
                    .filter(|(_, n)| *n > 0)
                    .collect();
                consumers.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
                PoolLedger {
                    pool,
                    limit: self.readings.get(&pool).map(|r| r.limit),
                    spent: consumers.iter().map(|(_, n)| n).sum(),
                    consumers,
                }
            })
            .collect()
    }

    fn pool_ledger(&self, pool: Pool, now_ms: u64) -> PoolLedger {
        self.ledger(now_ms).into_iter().find(|l| l.pool == pool).expect("every pool has a row")
    }

    /// Whether `caller` may start a read of `class` from `pool` now (`pooled`: it runs with the
    /// login the readings are of); a read let in is counted against that pool.
    pub fn admit_read(
        &mut self,
        caller: &str,
        pool: Pool,
        class: Class,
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
            let top = self.pool_ledger(on, now_ms);
            return Err(
                refusal("pool", on, caller, Some(r), r.reset_ms.max(now_ms), now_ms).with_top(&top)
            );
        }
        if self.minute.len() >= PACE_PER_MINUTE {
            let next = self.minute.front().map_or(now_ms, |t| t + MINUTE_MS);
            return Err(refusal("pace", on, caller, reading, next, now_ms));
        }
        let under_floor = reading.is_some_and(|r| r.remaining < r.floor(now_ms));
        // Under the floor (the merge reserve) a plain read stops; a merge-critical one runs on.
        if under_floor
            && class == Class::Reader
            && let Some(r) = reading
        {
            let top = self.pool_ledger(on, now_ms);
            return Err(refusal("floor", on, caller, Some(r), r.reset_ms.max(now_ms), now_ms)
                .with_top(&top));
        }
        // No fresh reading of the pool this read draws from: hold every caller to its cap.
        let capped = under_floor || reading.is_none();
        let cap = match class {
            Class::Reader => CALLER_READS_PER_HOUR,
            Class::MergeCritical => CALLER_READS_PER_HOUR + MERGE_CRITICAL_EXTRA_PER_HOUR,
        };
        if !self.callers.contains_key(caller) && self.callers.len() >= CALLERS_MAX {
            let oldest = self
                .callers
                .iter()
                .min_by_key(|(_, w)| w.back().map_or(0, |(t, _)| *t))
                .map(|(k, _)| k.clone());
            if let Some(k) = oldest {
                self.callers.remove(&k);
            }
        }
        let window = self.callers.entry(caller.to_owned()).or_default();
        while window.front().is_some_and(|(t, _)| now_ms.saturating_sub(*t) >= HOUR_MS) {
            window.pop_front();
        }
        if capped && window.len() >= cap {
            let next = window.front().map_or(now_ms, |(t, _)| t + HOUR_MS);
            return Err(refusal("caller", on, caller, reading, next, now_ms));
        }
        window.push_back((now_ms, pool));
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

/// `-32044`: `over` is `caller`, `pace`, `floor` or `pool`. Only a `caller` refusal stays on this caller:
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
        "floor" => format!(
            "the Mac's GitHub {} pool is under its floor, kept for merges (a single `gh pr view N` still runs); ask again in {}s",
            pool.name(),
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

trait WithTop {
    fn with_top(self, ledger: &PoolLedger) -> Self;
}

impl WithTop for RpcError {
    /// A `pool` or `floor` refusal names who spent the pool: "; the biggest spender of it on this
    /// Mac in the last hour: CALLER, N of M calls (P%)".
    fn with_top(mut self, ledger: &PoolLedger) -> Self {
        let Some((caller, calls)) = ledger.top() else { return self };
        let of = ledger.spent.max(1);
        self.message.push_str(&format!(
            "; the biggest spender of it on this Mac in the last hour: {caller}, {calls} of {of} calls ({}%)",
            calls * 100 / of
        ));
        if let Some(Value::Object(data)) = self.data.as_mut() {
            data.insert("topSpender".into(), json!({"caller": caller, "calls": calls, "of": of}));
        }
        self
    }
}

static BUDGET: LazyLock<Mutex<Budget>> = LazyLock::new(Default::default);
/// One `gh api rate_limit` at a time.
static READER: LazyLock<tokio::sync::Mutex<()>> = LazyLock::new(Default::default);

/// This Mac's per-pool ledger now ([`Budget::ledger`]).
pub fn ledger() -> Vec<PoolLedger> {
    BUDGET.lock().unwrap_or_else(|e| e.into_inner()).ledger(crate::store::now_ms())
}

/// The Mac's gate for one read of `class` by `caller` (`peer/session`) from `pool` that runs with
/// `login`.
pub async fn admit(
    caller: &str,
    pool: Pool,
    class: Class,
    login: &crate::github_app_token::Source,
) -> Result<(), RpcError> {
    let pooled = login.token().is_none();
    if pooled {
        refresh().await;
    }
    BUDGET.lock().unwrap_or_else(|e| e.into_inner()).admit_read(
        caller,
        pool,
        class,
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
        // 170 a minute pace: spread the reads over the hour.
        for i in 0..CALLER_READS_PER_HOUR as u64 + 10 {
            let mut fresh = reading(4000);
            fresh.read_ms = NOW + i * 5000;
            b.set_pool_reading(Pool::Core, fresh);
            assert!(
                b.admit_read("lane/a", Pool::Core, Class::Reader, true, NOW + i * 5000).is_ok(),
                "pool high: no cap"
            );
        }
        let t = NOW + 3_100_000;
        // Over the reserve but under the floor (15% of the limit with the hour still ahead): a
        // merge-critical read runs on to its cap and `MERGE_CRITICAL_EXTRA_PER_HOUR` past it.
        b.set_pool_reading(
            Pool::Core,
            Reading { limit: 5000, remaining: 700, reset_ms: t + HOUR_MS, read_ms: t },
        );
        let room =
            CALLER_READS_PER_HOUR + MERGE_CRITICAL_EXTRA_PER_HOUR - (CALLER_READS_PER_HOUR + 10);
        for _ in 0..room {
            assert!(b.admit_read("lane/a", Pool::Core, Class::MergeCritical, true, t).is_ok());
        }
        let e = b.admit_read("lane/a", Pool::Core, Class::MergeCritical, true, t).unwrap_err();
        assert_eq!(e.code, -32044);
        let data = e.data.unwrap();
        assert_eq!(data["reason"], "github.budget.caller");
        assert_eq!(data["caller"], "lane/a");
        assert!(data["retryAfterMs"].as_u64().unwrap() > 0);
        assert!(
            b.admit_read("lane/b", Pool::Core, Class::MergeCritical, true, t).is_ok(),
            "another caller still reads"
        );
    }

    #[test]
    fn under_the_floor_only_merge_critical_reads_run() {
        let mut b = Budget::default();
        b.set_pool_reading(Pool::Core, reading(4000));
        for _ in 0..30 {
            assert!(b.admit_read("lane/loop", Pool::Core, Class::Reader, true, NOW).is_ok());
        }
        assert!(b.admit_read("lane/other", Pool::Core, Class::Reader, true, NOW).is_ok());
        // 600 left: over the 500 reserve, under the 750 floor.
        b.set_pool_reading(Pool::Core, reading(600));
        let e = b.admit_read("lane/new", Pool::Core, Class::Reader, true, NOW).unwrap_err();
        let data = e.data.clone().unwrap();
        assert_eq!(data["reason"], "github.budget.floor");
        assert_eq!(data["pool"], "core");
        assert_eq!(data["topSpender"], json!({"caller": "lane/loop", "calls": 30, "of": 31}));
        assert!(e.message.contains("kept for merges"), "{}", e.message);
        assert!(e.message.contains("lane/loop, 30 of 31 calls (96%)"), "{}", e.message);
        assert!(b.admit_read("lane/new", Pool::Core, Class::MergeCritical, true, NOW).is_ok());
        assert_eq!(b.reading(Pool::Core).unwrap().remaining, 599);
        // The floor is the keyring's: an App token's read is not held to it.
        assert!(b.admit_read("lane/new", Pool::Core, Class::Reader, false, NOW).is_ok());
        // And the hard reserve holds merge-critical reads too.
        b.set_pool_reading(Pool::Core, reading(HARD_RESERVE));
        let e = b.admit_read("lane/new", Pool::Core, Class::MergeCritical, true, NOW).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.budget.pool");
        assert!(e.message.contains("biggest spender of it on this Mac"), "{}", e.message);
    }

    #[test]
    fn the_ledger_counts_each_pool_by_caller_for_the_hour() {
        let mut b = Budget::default();
        b.set_readings(Readings { core: reading(5000), graphql: Some(reading(5000)) });
        for _ in 0..3 {
            b.admit_read("lane/a", Pool::Graphql, Class::Reader, true, NOW).unwrap();
        }
        b.admit_read("lane/b", Pool::Graphql, Class::Reader, true, NOW).unwrap();
        b.admit_read("lane/b", Pool::Core, Class::Reader, true, NOW).unwrap();
        b.admit_read("lane/c", Pool::Graphql, Class::Reader, true, NOW).unwrap();
        let rows = b.ledger(NOW + 1);
        let graphql = rows.iter().find(|r| r.pool == Pool::Graphql).unwrap();
        assert_eq!(graphql.spent, 5);
        assert_eq!(graphql.limit, Some(5000));
        assert_eq!(
            graphql.consumers,
            vec![("lane/a".into(), 3), ("lane/b".into(), 1), ("lane/c".into(), 1)]
        );
        let core = rows.iter().find(|r| r.pool == Pool::Core).unwrap();
        assert_eq!(core.consumers, vec![("lane/b".into(), 1)]);
        let actions = rows.iter().find(|r| r.pool == Pool::Actions).unwrap();
        assert_eq!((actions.spent, actions.limit, actions.top()), (0, None, None));
        assert_eq!(core.to_json()["consumers"][0], json!({"caller": "lane/b", "calls": 1}));
        // An hour on, it is empty again.
        assert!(b.ledger(NOW + HOUR_MS).iter().all(|r| r.spent == 0));
    }

    #[test]
    fn a_single_pr_view_is_merge_critical() {
        let cases: &[(&[&str], Class)] = &[
            (&["pr", "view", "12", "--json=number,title", "--repo=o/r"], Class::MergeCritical),
            (&["pr", "view", "12"], Class::MergeCritical),
            (&["pr", "view", "--json=number"], Class::Reader),
            (&["pr", "view", "lane/x"], Class::Reader),
            (&["pr", "list", "--json", "number"], Class::Reader),
            (&["repo", "view", "o/r", "--json=url"], Class::Reader),
            (&["api", "repos/o/r/pulls/1"], Class::Reader),
        ];
        for (args, class) in cases {
            assert_eq!(class_of(args), *class, "{args:?}");
        }
    }

    #[test]
    fn the_hard_reserve_refuses_every_read() {
        let mut b = Budget::default();
        b.set_pool_reading(Pool::Core, reading(HARD_RESERVE));
        let e = b.admit_read("lane/a", Pool::Core, Class::Reader, true, NOW).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.budget.pool");
        // An App token's read draws from another pool.
        assert!(b.admit_read("lane/a", Pool::Core, Class::Reader, false, NOW).is_ok());
    }

    #[test]
    fn reads_are_paced_across_callers() {
        let mut b = Budget::default();
        b.set_pool_reading(Pool::Core, reading(5000));
        for i in 0..PACE_PER_MINUTE {
            assert!(
                b.admit_read(&format!("lane/{i}"), Pool::Core, Class::Reader, true, NOW).is_ok()
            );
        }
        let e = b.admit_read("lane/x", Pool::Core, Class::Reader, true, NOW + 1).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.budget.pace");
        assert!(b.admit_read("lane/x", Pool::Core, Class::Reader, true, NOW + MINUTE_MS).is_ok());
    }

    #[test]
    fn no_reading_holds_every_caller_to_its_cap() {
        let mut b = Budget::default();
        for i in 0..CALLER_READS_PER_HOUR as u64 {
            assert!(
                b.admit_read("lane/a", Pool::Core, Class::Reader, true, NOW + i * 1000).is_ok()
            );
        }
        let e = b.admit_read("lane/a", Pool::Core, Class::Reader, true, NOW + 700_000).unwrap_err();
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
        let e = b.admit_read("lane/a", Pool::Graphql, Class::Reader, true, NOW).unwrap_err();
        let data = e.data.unwrap();
        assert_eq!(data["reason"], "github.budget.pool");
        assert_eq!(data["pool"], "graphql");
        assert!(e.message.contains("graphql pool"), "{}", e.message);
        assert!(b.admit_read("lane/a", Pool::Core, Class::Reader, true, NOW).is_ok());
        // Only the pool a read spends is counted down.
        assert_eq!(b.reading(Pool::Core).unwrap().remaining, 3999);
        assert_eq!(b.reading(Pool::Graphql).unwrap().remaining, HARD_RESERVE - 1);
    }

    #[test]
    fn the_actions_counter_is_held_to_core_until_its_own_reading() {
        let mut b = Budget::default();
        b.set_readings(Readings { core: reading(HARD_RESERVE), graphql: Some(reading(5000)) });
        let e = b.admit_read("lane/a", Pool::Actions, Class::Reader, true, NOW).unwrap_err();
        assert_eq!(e.data.unwrap()["pool"], "core", "no Actions reading yet: core's");
        b.set_pool_reading(Pool::Actions, reading(3000));
        assert!(b.admit_read("lane/a", Pool::Actions, Class::Reader, true, NOW).is_ok());
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
            assert!(
                b.admit_read("lane/a", Pool::Graphql, Class::Reader, true, NOW + i * 400).is_ok()
            );
        }
        let e =
            b.admit_read("lane/a", Pool::Graphql, Class::Reader, true, NOW + 300_000).unwrap_err();
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
