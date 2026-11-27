//! One GitHub poller per machine for the state of a chat's pull request: the daemon side of
//! `_acpmux/github/pr_state` and `_acpmux/github/pr_wait` (`server/github_prs.rs`), which the
//! `acpmux` MCP server's `pr_state` and `pr_wait` tools ask (`acpmux_mcp_pr.rs`). Design:
//! cmuxterm-hq `docs/design/daemon-github-poller.md`, move 4 of `glaeda-into-cmux.md`.
//!
//! Before this, every chat's MCP server ran its own `gh pr view` for every look, so N chats
//! watching one pull request cost N GitHub calls a look. Here the daemon keeps one entry per
//! pull request, and every chat on the machine reads through it:
//!
//! - **One fetch per pull request at a time.** An entry is locked while it refreshes; a caller
//!   that waited on the lock finds the fresh answer and makes no call of its own.
//! - **A fresh answer is shared.** `status` answers from the entry when it is younger than
//!   [`FRESH`]; `wait` polls no more often than [`Config::interval`], and every waiter on one
//!   pull request reads the same refresh, so N waiters cost one poll an interval.
//! - **Conditional requests.** A refresh is REST reads (the pull request, its head's check runs
//!   and commit status, its comments), each sent with the ETag of its last answer. A 304 costs
//!   no GitHub rate limit and is not charged to the budget; the kept body is used.
//! - **One budget per machine.** A token bucket ([`Config::capacity`], refilled at
//!   [`Config::refill_per_hour`]) is charged one per answer GitHub counts (a 200, or the
//!   `gh pr view` fallback). When GitHub's own `x-ratelimit-remaining` falls under
//!   [`Config::rate_floor`], nothing is fetched until its reset. With the budget spent a caller
//!   gets the kept answer marked stale, or a refusal with when to ask again; never a call.
//! - **Waits slow down as the budget drains**: the interval doubles under half the bucket and
//!   quadruples under a quarter.
//!
//! A refresh whose REST read fails for any reason (a `gh` that takes no `--include`, a broker
//! chain) falls back to one `gh pr view`, charged the same. Both answers have the shape
//! `gh pr view --json` gives, so `pr_state`'s parse (`acpmux_mcp_pr.rs`) reads either.
//! `gh` runs with this daemon's own login, every GitHub token removed from its env
//! (`github_broker::login_env`); a chat whose own `gh` sees more falls back to it in the tool.
//!
//! **Any repository read, too** (`get`, `_acpmux/github/read`, `acpmux gh-read`): one GET of a
//! `repos/OWNER/REPO/...` path (a run, its jobs, an issue, a file's contents) gets the same
//! entry, lock, ETag, budget and stale-while-spent answer a pull request gets, keyed by its path.
//! Before, the fleet's `gh_quota.py` shim kept that cache in Python per host; this is the
//! product's, so the shim's cache can go (leo-workspace `tools/gh_quota.py`, group 3).

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::time::Instant;

/// How old a kept answer may be and still answer a `status`.
pub const FRESH: Duration = Duration::from_secs(15);
/// The longest one wait may be asked to run.
pub const MAX_WAIT: Duration = Duration::from_secs(3600);
/// The most pull requests kept at once; past it the least recently read idle one goes.
pub const MAX_ENTRIES: usize = 256;
/// The longest a [`Poller::get`] caller may let its kept answer be; more is held to this.
pub const READ_MAX_FRESH: Duration = Duration::from_secs(3600);
/// The longest path a [`Poller::get`] takes.
const READ_PATH_MAX: usize = 1024;
/// Pages of check runs read (100 a page).
const CHECK_PAGES: u32 = 3;
/// The `gh pr view` fields, as `pr_state` reads them.
pub const VIEW_FIELDS: &str = "number,url,state,headRefOid,baseRefName,mergeable,mergedAt,\
mergeCommit,labels,body,comments,statusCheckRollup";

/// The poller's limits.
#[derive(Clone, Debug)]
pub struct Config {
    /// How often a wait reads its pull request again, with a full budget.
    pub interval: Duration,
    /// Charged reads the bucket holds.
    pub capacity: f64,
    /// Charged reads it gains an hour.
    pub refill_per_hour: f64,
    /// GitHub's remaining rate limit under which nothing is fetched until its reset.
    pub rate_floor: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            interval: Duration::from_secs(30),
            capacity: 60.0,
            refill_per_hour: 600.0,
            rate_floor: 200,
        }
    }
}

/// One HTTP answer of `gh api --include`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Reply {
    pub status: u16,
    pub etag: Option<String>,
    pub body: Vec<u8>,
    /// `x-ratelimit-remaining` and `x-ratelimit-reset` (Unix seconds).
    pub remaining: Option<u64>,
    pub reset: Option<u64>,
    /// The `rel="last"` page of a `Link` header.
    pub last_page: Option<u32>,
}

pub type Fut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// How the poller reaches GitHub: [`GhFetch`] in the daemon, a counting fake in tests.
pub trait Fetch: Send + Sync {
    /// One GET of `path`, with `If-None-Match: etag` when there is one.
    fn get<'a>(&'a self, path: &'a str, etag: Option<&'a str>) -> Fut<'a, Result<Reply, String>>;
    /// One `gh pr view NUMBER -R REPO --json VIEW_FIELDS`.
    fn view<'a>(&'a self, repo: &'a str, number: u64) -> Fut<'a, Result<Value, String>>;
}

/// A pull request: `OWNER/REPO` (lowercase) and its number.
#[derive(Clone, Debug, Hash, PartialEq, Eq)]
pub struct Key {
    pub repo: String,
    pub number: u64,
}

impl Key {
    pub fn new(repo: &str, number: u64) -> Self {
        Self { repo: repo.to_ascii_lowercase(), number }
    }
}

/// Where an answer came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// Kept from an earlier refresh, younger than asked.
    Cache,
    /// Read from GitHub for this call (or one it waited on).
    Fetched,
    /// Kept, older than asked: the budget is spent or the refresh failed.
    Stale,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Cache => "cache",
            Source::Fetched => "fetched",
            Source::Stale => "stale",
        }
    }
}

/// A pull request's state (`gh pr view --json` shape) and how it was had.
#[derive(Clone, Debug)]
pub struct Answer {
    pub pr: Value,
    pub source: Source,
    pub age: Duration,
    /// Why a stale answer was not refreshed.
    pub note: Option<String>,
}

/// Why there is no answer: the text, and when asking again may help.
#[derive(Clone, Debug, PartialEq)]
pub struct Refusal {
    pub message: String,
    pub retry_after: Option<Duration>,
}

/// What the poller has done since the daemon started.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counters {
    /// GitHub requests sent (`gh api` and `gh pr view` runs).
    pub requests: u64,
    /// Of those, answers GitHub counts against the rate limit.
    pub charged: u64,
    /// Of those, 304s.
    pub not_modified: u64,
    /// Refreshes of an entry.
    pub refreshes: u64,
    /// Calls answered from an entry with no request.
    pub cache_hits: u64,
}

/// When a wait is over.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Until {
    /// Nothing pending: checks done (green or red), or merged or closed.
    Settled,
    /// The summary line differs from the one the wait started with.
    Change,
}

struct Kept {
    etag: String,
    body: Value,
    last_page: Option<u32>,
}

#[derive(Default)]
struct Entry {
    pr: Option<Value>,
    at: Option<Instant>,
    pages: HashMap<String, Kept>,
}

struct Budget {
    tokens: f64,
    at: Instant,
    /// GitHub's floor: no fetch before this.
    held_until: Option<Instant>,
}

struct Slot {
    entry: Arc<tokio::sync::Mutex<Entry>>,
    used: Instant,
}

/// The machine's poller.
pub struct Poller<F> {
    fetch: F,
    cfg: Config,
    entries: Mutex<HashMap<Key, Slot>>,
    /// [`Poller::get`]'s entries, keyed by path; the body is kept in `Entry::pr`.
    reads: Mutex<HashMap<String, Slot>>,
    budget: Mutex<Budget>,
    counters: Mutex<Counters>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

enum ReadError {
    Http(u16),
    Other(String),
}

impl ReadError {
    fn text(&self) -> String {
        match self {
            ReadError::Http(s) => format!("GitHub answered HTTP {s}"),
            ReadError::Other(e) => e.clone(),
        }
    }
}

impl<F: Fetch> Poller<F> {
    pub fn new(fetch: F, cfg: Config) -> Self {
        let budget = Budget { tokens: cfg.capacity, at: Instant::now(), held_until: None };
        Self {
            fetch,
            cfg,
            entries: Mutex::new(HashMap::new()),
            reads: Mutex::new(HashMap::new()),
            budget: Mutex::new(budget),
            counters: Mutex::new(Counters::default()),
        }
    }

    pub fn counters(&self) -> Counters {
        *lock(&self.counters)
    }

    /// `{tokens, capacity, refillPerHour, heldForSecs?, watched}` for a reply.
    pub fn budget_json(&self) -> Value {
        let mut b = lock(&self.budget);
        self.refill(&mut b);
        let held = b.held_until.map(|h| h.saturating_duration_since(Instant::now()).as_secs());
        json!({
            "tokens": b.tokens.floor(),
            "capacity": self.cfg.capacity,
            "refillPerHour": self.cfg.refill_per_hour,
            "heldForSecs": held.filter(|s| *s > 0),
            "watched": lock(&self.entries).len(),
            "readsKept": lock(&self.reads).len(),
        })
    }

    fn refill(&self, b: &mut Budget) {
        let now = Instant::now();
        let gained =
            now.saturating_duration_since(b.at).as_secs_f64() * self.cfg.refill_per_hour / 3600.0;
        b.tokens = (b.tokens + gained).min(self.cfg.capacity);
        b.at = now;
        if b.held_until.is_some_and(|h| h <= now) {
            b.held_until = None;
        }
    }

    /// Whether a refresh may start now; else how long until it may.
    fn admit(&self) -> Result<(), Duration> {
        let mut b = lock(&self.budget);
        self.refill(&mut b);
        if let Some(h) = b.held_until {
            return Err(h.saturating_duration_since(Instant::now()));
        }
        if b.tokens >= 1.0 {
            return Ok(());
        }
        let per_sec = self.cfg.refill_per_hour / 3600.0;
        let secs = if per_sec > 0.0 { ((1.0 - b.tokens) / per_sec).ceil() } else { 3600.0 };
        Err(Duration::from_secs_f64(secs.max(1.0)))
    }

    fn charge(&self) {
        let mut b = lock(&self.budget);
        self.refill(&mut b);
        b.tokens -= 1.0;
    }

    fn note_rate(&self, reply: &Reply) {
        let (Some(remaining), Some(reset)) = (reply.remaining, reply.reset) else { return };
        if remaining >= self.cfg.rate_floor {
            return;
        }
        let now_unix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let wait = Duration::from_secs(reset.saturating_sub(now_unix).clamp(1, 3600));
        lock(&self.budget).held_until = Some(Instant::now() + wait);
    }

    /// The interval a wait polls at now: longer as the bucket drains.
    pub fn interval(&self) -> Duration {
        let mut b = lock(&self.budget);
        self.refill(&mut b);
        let share = if self.cfg.capacity > 0.0 { b.tokens / self.cfg.capacity } else { 0.0 };
        let times = if share < 0.25 {
            4
        } else if share < 0.5 {
            2
        } else {
            1
        };
        self.cfg.interval.saturating_mul(times)
    }

    fn entry(&self, key: &Key) -> Arc<tokio::sync::Mutex<Entry>> {
        slot_in(&self.entries, key)
    }

    /// The pull request's state, no older than `fresh` when the budget allows.
    pub async fn status(&self, key: &Key, fresh: Duration) -> Result<Answer, Refusal> {
        let entry = self.entry(key);
        let mut e = entry.lock().await;
        if let (Some(pr), Some(at)) = (&e.pr, e.at)
            && at.elapsed() < fresh
        {
            lock(&self.counters).cache_hits += 1;
            return Ok(Answer {
                pr: pr.clone(),
                source: Source::Cache,
                age: at.elapsed(),
                note: None,
            });
        }
        if let Err(after) = self.admit() {
            let note = format!(
                "this machine's GitHub budget is spent; the next read in {}s",
                after.as_secs()
            );
            return match (&e.pr, e.at) {
                (Some(pr), Some(at)) => {
                    lock(&self.counters).cache_hits += 1;
                    Ok(Answer {
                        pr: pr.clone(),
                        source: Source::Stale,
                        age: at.elapsed(),
                        note: Some(note),
                    })
                }
                _ => Err(Refusal { message: note, retry_after: Some(after) }),
            };
        }
        lock(&self.counters).refreshes += 1;
        match self.refresh(key, &mut e).await {
            Ok(pr) => {
                e.pr = Some(pr.clone());
                e.at = Some(Instant::now());
                Ok(Answer { pr, source: Source::Fetched, age: Duration::ZERO, note: None })
            }
            Err(why) => match (&e.pr, e.at) {
                (Some(pr), Some(at)) => Ok(Answer {
                    pr: pr.clone(),
                    source: Source::Stale,
                    age: at.elapsed(),
                    note: Some(why),
                }),
                _ => Err(Refusal { message: why, retry_after: None }),
            },
        }
    }

    /// One GET of a `repos/OWNER/REPO/...` path (`read_path` says which it takes), no older than
    /// `fresh` (at most [`READ_MAX_FRESH`]) when the budget allows: the kept body when it is
    /// young enough, a conditional read otherwise (a 304 is not charged), the kept body marked
    /// stale when the budget is spent or GitHub failed. A 4xx is GitHub's answer, not a failure
    /// to read: the kept body goes and the caller gets the refusal, with no retry time.
    pub async fn get(&self, path: &str, fresh: Duration) -> Result<Answer, Refusal> {
        let path = read_path(path).map_err(|message| Refusal { message, retry_after: None })?;
        let fresh = fresh.min(READ_MAX_FRESH);
        let entry = slot_in(&self.reads, &path);
        let mut e = entry.lock().await;
        if let (Some(body), Some(at)) = (&e.pr, e.at)
            && at.elapsed() < fresh
        {
            lock(&self.counters).cache_hits += 1;
            return Ok(Answer {
                pr: body.clone(),
                source: Source::Cache,
                age: at.elapsed(),
                note: None,
            });
        }
        if let Err(after) = self.admit() {
            let note = format!(
                "this machine's GitHub budget is spent; the next read in {}s",
                after.as_secs()
            );
            return match (&e.pr, e.at) {
                (Some(body), Some(at)) => {
                    lock(&self.counters).cache_hits += 1;
                    Ok(Answer {
                        pr: body.clone(),
                        source: Source::Stale,
                        age: at.elapsed(),
                        note: Some(note),
                    })
                }
                _ => Err(Refusal { message: note, retry_after: Some(after) }),
            };
        }
        lock(&self.counters).refreshes += 1;
        let mut used = Vec::new();
        match self.read(&mut e, &mut used, path.clone()).await {
            Ok((body, _)) => {
                e.pr = Some(body.clone());
                e.at = Some(Instant::now());
                Ok(Answer { pr: body, source: Source::Fetched, age: Duration::ZERO, note: None })
            }
            Err(ReadError::Http(status)) if (400..500).contains(&status) && status != 429 => {
                e.pr = None;
                e.at = None;
                e.pages.clear();
                Err(Refusal {
                    message: format!("GitHub answered HTTP {status} for {path}"),
                    retry_after: None,
                })
            }
            Err(why) => match (&e.pr, e.at) {
                (Some(body), Some(at)) => Ok(Answer {
                    pr: body.clone(),
                    source: Source::Stale,
                    age: at.elapsed(),
                    note: Some(why.text()),
                }),
                _ => Err(Refusal { message: why.text(), retry_after: None }),
            },
        }
    }

    /// Reads until the pull request is settled or changed (`until`), or `deadline`. Every
    /// waiter on one pull request shares the refreshes. The answer and whether it timed out.
    pub async fn wait(
        &self,
        key: &Key,
        until: Until,
        deadline: Instant,
    ) -> Result<(Answer, bool), Refusal> {
        let mut answer = self.status(key, FRESH).await?;
        let start = summary(&answer.pr);
        loop {
            let done = match until {
                Until::Settled => settled(&answer.pr),
                Until::Change => summary(&answer.pr) != start,
            };
            if done {
                return Ok((answer, false));
            }
            let interval = self.interval();
            let next = Instant::now() + interval;
            if next >= deadline {
                tokio::time::sleep_until(deadline).await;
                return Ok((answer, true));
            }
            tokio::time::sleep_until(next).await;
            // A tenth of the interval of slack, so waiters that woke near together share one read.
            answer = self.status(key, interval.saturating_sub(interval / 10)).await?;
        }
    }

    async fn refresh(&self, key: &Key, e: &mut Entry) -> Result<Value, String> {
        let mut used = Vec::new();
        let rest = self.rest(key, e, &mut used).await;
        e.pages.retain(|path, _| used.contains(path));
        match rest {
            Ok(pr) => Ok(pr),
            Err(rest_err) => {
                lock(&self.counters).requests += 1;
                let viewed = self.fetch.view(&key.repo, key.number).await;
                match viewed {
                    Ok(pr) => {
                        lock(&self.counters).charged += 1;
                        self.charge();
                        Ok(pr)
                    }
                    Err(view_err) => Err(format!(
                        "GitHub REST read failed ({}), and gh pr view failed ({view_err})",
                        rest_err.text()
                    )),
                }
            }
        }
    }

    /// One conditional GET: the body, from GitHub or kept on a 304, and its last page.
    async fn read(
        &self,
        e: &mut Entry,
        used: &mut Vec<String>,
        path: String,
    ) -> Result<(Value, Option<u32>), ReadError> {
        let etag = e.pages.get(&path).map(|k| k.etag.clone());
        lock(&self.counters).requests += 1;
        let reply = self.fetch.get(&path, etag.as_deref()).await.map_err(ReadError::Other)?;
        self.note_rate(&reply);
        used.push(path.clone());
        if reply.status == 304
            && let Some(kept) = e.pages.get(&path)
        {
            lock(&self.counters).not_modified += 1;
            return Ok((kept.body.clone(), kept.last_page));
        }
        lock(&self.counters).charged += 1;
        self.charge();
        if !(200..300).contains(&reply.status) {
            return Err(ReadError::Http(reply.status));
        }
        let body: Value = serde_json::from_slice(&reply.body)
            .map_err(|err| ReadError::Other(format!("GitHub gave no JSON for {path}: {err}")))?;
        if let Some(etag) = reply.etag {
            e.pages.insert(path, Kept { etag, body: body.clone(), last_page: reply.last_page });
        }
        Ok((body, reply.last_page))
    }

    async fn rest(
        &self,
        key: &Key,
        e: &mut Entry,
        used: &mut Vec<String>,
    ) -> Result<Value, ReadError> {
        let (repo, n) = (&key.repo, key.number);
        let (pull, _) = self.read(e, used, format!("repos/{repo}/pulls/{n}")).await?;
        let sha = pull.pointer("/head/sha").and_then(Value::as_str).unwrap_or_default().to_owned();
        let mut rollup = Vec::new();
        if !sha.is_empty() {
            let mut page = 1;
            loop {
                let path =
                    format!("repos/{repo}/commits/{sha}/check-runs?per_page=100&page={page}");
                let (runs, last) = self.read(e, used, path).await?;
                for r in runs.get("check_runs").and_then(Value::as_array).into_iter().flatten() {
                    let up = |k: &str| {
                        r.get(k).and_then(Value::as_str).unwrap_or_default().to_ascii_uppercase()
                    };
                    rollup.push(json!({
                        "__typename": "CheckRun",
                        "name": r.get("name").cloned().unwrap_or(Value::Null),
                        "status": up("status"),
                        "conclusion": up("conclusion"),
                        // What `pr_state` orders runs of one name by (`newest_runs`).
                        "databaseId": r.get("id").cloned().unwrap_or(Value::Null),
                        "startedAt": r.get("started_at").cloned().unwrap_or(Value::Null),
                    }));
                }
                if page >= last.unwrap_or(1).min(CHECK_PAGES) {
                    break;
                }
                page += 1;
            }
            let (status, _) = self
                .read(e, used, format!("repos/{repo}/commits/{sha}/status?per_page=100"))
                .await?;
            for s in status.get("statuses").and_then(Value::as_array).into_iter().flatten() {
                rollup.push(json!({
                    "__typename": "StatusContext",
                    "context": s.get("context").cloned().unwrap_or(Value::Null),
                    "state": s.get("state").and_then(Value::as_str).unwrap_or_default().to_ascii_uppercase(),
                }));
            }
        }
        // The first page names the last; the newest comments (the receipts) are on it.
        let first = format!("repos/{repo}/issues/{n}/comments?per_page=100");
        let (mut raw, last) = self.read(e, used, first.clone()).await?;
        // With no Link header (the broker's answers), the pull's own comment count says it.
        let counted = pull.get("comments").and_then(Value::as_u64).map(|c| c.div_ceil(100));
        let last = last.or_else(|| counted.and_then(|c| u32::try_from(c).ok()));
        if let Some(last) = last.filter(|l| *l > 1) {
            let (tail, _) = self.read(e, used, format!("{first}&page={last}")).await?;
            raw = tail;
        }
        let comments: Vec<Value> = raw
            .as_array()
            .into_iter()
            .flatten()
            .map(|c| {
                json!({
                    "body": c.get("body").cloned().unwrap_or(Value::Null),
                    "author": {"login": c.pointer("/user/login").cloned().unwrap_or(Value::Null)},
                })
            })
            .collect();
        Ok(view_shape(&pull, rollup, comments))
    }
}

/// `map`'s entry for `key`, made when there is none; past [`MAX_ENTRIES`] the least recently
/// read idle one goes.
fn slot_in<K: Clone + Eq + std::hash::Hash>(
    map: &Mutex<HashMap<K, Slot>>,
    key: &K,
) -> Arc<tokio::sync::Mutex<Entry>> {
    let mut entries = lock(map);
    let now = Instant::now();
    if let Some(slot) = entries.get_mut(key) {
        slot.used = now;
        return slot.entry.clone();
    }
    if entries.len() >= MAX_ENTRIES {
        let idle = entries
            .iter()
            .filter(|(_, s)| Arc::strong_count(&s.entry) == 1)
            .min_by_key(|(_, s)| s.used)
            .map(|(k, _)| k.clone());
        if let Some(k) = idle {
            entries.remove(&k);
        }
    }
    let entry = Arc::new(tokio::sync::Mutex::new(Entry::default()));
    entries.insert(key.clone(), Slot { entry: entry.clone(), used: now });
    entry
}

/// The path a [`Poller::get`] reads: `repos/OWNER/REPO/REST[?QUERY]`, a leading `/` or
/// `https://api.github.com/` dropped, OWNER and REPO lowercased (the cache key: GitHub matches
/// them either way). Only repository paths: the broker a lane VM reads through takes no other,
/// and a path that is not a read of one repository (`search/`, `graphql`, `user`) is not one
/// this cache can share.
pub fn read_path(path: &str) -> Result<String, String> {
    let path = path.trim();
    let path = path.strip_prefix("https://api.github.com/").unwrap_or(path);
    let path = path.trim_start_matches('/');
    let refuse = |why: &str| Err(format!("{why}: give a repos/OWNER/REPO/... path, not {path:?}"));
    if path.is_empty() || path.len() > READ_PATH_MAX {
        return refuse("the path is empty or too long");
    }
    if path.bytes().any(|b| b.is_ascii_whitespace() || b.is_ascii_control() || b == b'#') {
        return refuse("the path has a space, a control character or a #");
    }
    let (route, query) = path.split_once('?').map_or((path, None), |(r, q)| (r, Some(q)));
    let mut parts = route.splitn(4, '/');
    let (Some("repos"), Some(owner), Some(repo), Some(rest)) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return refuse("not a repository read");
    };
    let name = |p: &str| {
        !p.is_empty()
            && p != "."
            && p != ".."
            && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    };
    if !name(owner) || !name(repo) || rest.is_empty() || rest.split('/').any(|s| s == "..") {
        return refuse("not a repository read");
    }
    let mut out =
        format!("repos/{}/{}/{rest}", owner.to_ascii_lowercase(), repo.to_ascii_lowercase());
    if let Some(q) = query.filter(|q| !q.is_empty()) {
        out.push('?');
        out.push_str(q);
    }
    Ok(out)
}

/// A REST pull request, its rollup and comments, in `gh pr view --json VIEW_FIELDS` shape.
pub fn view_shape(pull: &Value, rollup: Vec<Value>, comments: Vec<Value>) -> Value {
    let s = |p: &str| pull.pointer(p).cloned().unwrap_or(Value::Null);
    let merged = pull.get("merged").and_then(Value::as_bool).unwrap_or(false)
        || pull.get("merged_at").is_some_and(|m| !m.is_null());
    let state = match (merged, pull.get("state").and_then(Value::as_str)) {
        (true, _) => "MERGED",
        (false, Some("closed")) => "CLOSED",
        _ => "OPEN",
    };
    let mergeable = match pull.get("mergeable").and_then(Value::as_bool) {
        Some(true) => "MERGEABLE",
        Some(false) => "CONFLICTING",
        None => "UNKNOWN",
    };
    let labels: Vec<Value> = pull
        .get("labels")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|l| json!({"name": l.get("name").cloned().unwrap_or(Value::Null)}))
        .collect();
    json!({
        "number": s("/number"),
        "url": s("/html_url"),
        "state": state,
        "headRefOid": s("/head/sha"),
        "baseRefName": s("/base/ref"),
        "mergeable": mergeable,
        "mergedAt": s("/merged_at"),
        "mergeCommit": if merged { json!({"oid": s("/merge_commit_sha")}) } else { Value::Null },
        "labels": labels,
        "body": s("/body"),
        "comments": comments,
        "statusCheckRollup": rollup,
    })
}

/// `pr_state`'s first line for a pull request.
pub fn summary(pr: &Value) -> String {
    crate::acpmux_mcp::pr_state(pr)
        .1
        .get("summary")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// Whether nothing is pending: `pr_state`'s status is not `running`.
pub fn settled(pr: &Value) -> bool {
    crate::acpmux_mcp::pr_state(pr).1.get("status").and_then(Value::as_str) != Some("running")
}

/// `gh api --include` output as a [`Reply`].
pub fn parse_include(output: &[u8]) -> Option<Reply> {
    let split =
        find(output, b"\r\n\r\n").map(|a| (a, 4)).or_else(|| find(output, b"\n\n").map(|a| (a, 2)));
    let (head, body) = match split {
        Some((at, len)) => (output.get(..at)?, output.get(at + len..).unwrap_or_default()),
        None => (output, &[][..]),
    };
    let head = String::from_utf8_lossy(head);
    let mut lines = head.lines();
    let first = lines.next()?;
    if !first.starts_with("HTTP/") {
        return None;
    }
    let status = first.split_whitespace().nth(1)?.parse().ok()?;
    let mut reply = Reply { status, body: body.to_vec(), ..Reply::default() };
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        let value = value.trim();
        match name.trim().to_ascii_lowercase().as_str() {
            "etag" => reply.etag = Some(value.to_owned()),
            "x-ratelimit-remaining" => reply.remaining = value.parse().ok(),
            "x-ratelimit-reset" => reply.reset = value.parse().ok(),
            "link" => reply.last_page = last_page(value),
            _ => {}
        }
    }
    Some(reply)
}

/// The `page=` of a Link header's `rel="last"`.
fn last_page(link: &str) -> Option<u32> {
    link.split(',').find(|part| part.contains("rel=\"last\"")).and_then(|part| {
        let url = part.split(['<', '>']).nth(1)?;
        url.split(['?', '&']).find_map(|kv| kv.strip_prefix("page=")).and_then(|p| p.parse().ok())
    })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// The real fetcher: this machine's `gh`, with the daemon's own login. A lane VM's `gh` has no
/// login: its GitHub reads go through the broker on the controller (`lane-gh call get`), so once
/// `gh` says it has none, every read goes there. Before, `pr_state` failed every call on a lane VM
/// ("gh auth login"; 76 of 76 in 48 h, cmuxterm-hq
/// docs/findings/2026-11-23-mcp-tool-error-census.md).
pub struct GhFetch {
    /// `lane-gh`, once `gh` said it has no login here.
    broker: std::sync::OnceLock<std::path::PathBuf>,
}

impl GhFetch {
    pub const fn new() -> Self {
        Self { broker: std::sync::OnceLock::new() }
    }

    /// `path` through the broker when `gh` has no login here (`said`) and `lane-gh` is found;
    /// else `said`.
    async fn or_broker(&self, path: &str, said: String) -> Result<Reply, String> {
        if !no_login(&said) {
            return Err(said);
        }
        let Ok(program) = crate::cli::send_relay::find_relay_program(BROKER) else {
            return Err(said);
        };
        let program = self.broker.get_or_init(|| program);
        broker_get(program, path).await.map_err(|e| format!("{said}; through the broker: {e}"))
    }
}

impl Default for GhFetch {
    fn default() -> Self {
        Self::new()
    }
}

/// The lane VM broker's client, in `~/.local/bin` (`cli/send_relay.rs` finds it off PATH).
const BROKER: &str = "lane-gh";

/// `gh`'s answer when it has no login here (or is not here at all).
fn no_login(said: &str) -> bool {
    said.contains("gh auth login") || said.contains("gh is not installed")
}

/// `repos/OWNER/REPO/REST?QUERY` as the broker's `OWNER/REPO`, `REST` and query map.
fn broker_path(path: &str) -> Option<(String, String, std::collections::BTreeMap<String, String>)> {
    let (path, query) = path.split_once('?').unwrap_or((path, ""));
    let mut parts = path.strip_prefix("repos/")?.splitn(3, '/');
    let (owner, repo, rest) = (parts.next()?, parts.next()?, parts.next()?);
    let query = query
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect();
    Some((format!("{owner}/{repo}"), rest.to_owned(), query))
}

/// One GET through the broker: `program call get OWNER/REPO {"path","query"}`, whose answer is
/// `{"status", "data"}` (no headers: a list's last page is read from its `total_count`).
async fn broker_get(program: &std::path::Path, path: &str) -> Result<Reply, String> {
    let (repo, rest, query) =
        broker_path(path).ok_or_else(|| format!("{path} is not a repos/OWNER/REPO/ path"))?;
    let ask = json!({"path": rest, "query": query}).to_string();
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(["call", "get", &repo, &ask])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let out = match tokio::time::timeout(GH_TIMEOUT, cmd.output()).await {
        Err(_) => return Err(format!("{BROKER} did not answer in {}s", GH_TIMEOUT.as_secs())),
        Ok(Err(e)) => return Err(format!("{BROKER} could not run: {e}")),
        Ok(Ok(out)) => out,
    };
    let stderr = String::from_utf8_lossy(&out.stderr);
    let answer: Value = serde_json::from_slice(&out.stdout)
        .map_err(|_| format!("{BROKER} call get gave no JSON: {}", stderr.trim()))?;
    let status = answer.get("status").and_then(Value::as_u64).and_then(|s| u16::try_from(s).ok());
    let Some(status) = status else {
        let why = answer.get("error").and_then(Value::as_str).unwrap_or(stderr.trim());
        return Err(format!("{BROKER} call get: {why}"));
    };
    let data = answer.get("data").cloned().unwrap_or(Value::Null);
    let per_page = query.get("per_page").and_then(|p| p.parse::<u64>().ok()).unwrap_or(30).max(1);
    let last_page = data
        .get("total_count")
        .and_then(Value::as_u64)
        .map(|total| u32::try_from(total.div_ceil(per_page).max(1)).unwrap_or(u32::MAX));
    let body = serde_json::to_vec(&data).map_err(|e| e.to_string())?;
    Ok(Reply { status, body, last_page, ..Reply::default() })
}

/// How long one `gh` may run.
const GH_TIMEOUT: Duration = Duration::from_secs(30);
/// The most bytes of one answer read.
const GH_MAX_OUTPUT: usize = 8 * 1024 * 1024;

async fn run_gh(args: Vec<String>) -> Result<(bool, Vec<u8>, String), String> {
    let mut std_cmd = std::process::Command::new("gh");
    std_cmd.args(&args);
    crate::github_broker::login_env(&mut std_cmd, None);
    let mut cmd = tokio::process::Command::from(std_cmd);
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let out = match tokio::time::timeout(GH_TIMEOUT, cmd.output()).await {
        Err(_) => return Err(format!("gh did not answer in {}s", GH_TIMEOUT.as_secs())),
        Ok(Err(e)) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err("gh is not installed or not on the daemon's PATH".to_owned());
        }
        Ok(Err(e)) => return Err(format!("gh could not run: {e}")),
        Ok(Ok(out)) => out,
    };
    if out.stdout.len() > GH_MAX_OUTPUT {
        return Err("gh answered more than the poller reads".to_owned());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    let skip = stderr.chars().count().saturating_sub(400);
    Ok((out.status.success(), out.stdout, stderr.chars().skip(skip).collect()))
}

impl Fetch for GhFetch {
    fn get<'a>(&'a self, path: &'a str, etag: Option<&'a str>) -> Fut<'a, Result<Reply, String>> {
        Box::pin(async move {
            let mut args: Vec<String> =
                ["api", "--include", "-H", "Accept: application/vnd.github+json"]
                    .map(str::to_owned)
                    .into();
            if let Some(broker) = self.broker.get() {
                return broker_get(broker, path).await;
            }
            if let Some(etag) = etag {
                args.extend(["-H".to_owned(), format!("If-None-Match: {etag}")]);
            }
            args.push(path.to_owned());
            // `gh api` exits 1 on a 304 and on HTTP errors: the status line says which.
            let (_, stdout, stderr) = match run_gh(args).await {
                Ok(ran) => ran,
                Err(e) => return self.or_broker(path, e).await,
            };
            match parse_include(&stdout) {
                Some(reply) => Ok(reply),
                None => {
                    let said = format!("gh api gave no HTTP answer: {}", stderr.trim());
                    self.or_broker(path, said).await
                }
            }
        })
    }

    fn view<'a>(&'a self, repo: &'a str, number: u64) -> Fut<'a, Result<Value, String>> {
        Box::pin(async move {
            let args = ["pr", "view", &number.to_string(), "-R", repo, "--json", VIEW_FIELDS]
                .map(str::to_owned)
                .into();
            let (ok, stdout, stderr) = run_gh(args).await?;
            if !ok {
                return Err(format!("gh pr view failed: {}", stderr.trim()));
            }
            serde_json::from_slice(&stdout).map_err(|e| format!("gh pr view gave no JSON: {e}"))
        })
    }
}

/// This daemon's poller: one per machine.
pub fn machine() -> &'static Poller<GhFetch> {
    static POLLER: std::sync::LazyLock<Poller<GhFetch>> =
        std::sync::LazyLock::new(|| Poller::new(GhFetch::new(), Config::default()));
    &POLLER
}

#[cfg(test)]
#[path = "pr_poller_tests.rs"]
mod tests;
