//! The GitHub poster (Swift `GitHubFeedSource`, `GitHubCLIClient`,
//! `GitHubNotification`, `GitHubReviewRequest`, `GitHubFeedDetail`), pure:
//! the `gh api` queries and their arguments, the parse of `gh api
//! --include` output, the mapping of GitHub rows to feed items, and the
//! poller's state (ETags, the held pull requests, the live details). The
//! daemon runs the `gh` processes; nothing here does I/O. Item lifecycle,
//! dedupe and triage stay with the feed owner; PR and issue text stays in
//! the details, never in the owner's items.

use std::collections::{HashMap, HashSet, VecDeque};

use serde::Serialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::item::{FeedItem, Poster, Priority};

/// The poll interval when none is configured.
pub const DEFAULT_INTERVAL_S: u64 = 120;
/// The shortest and longest interval `feed.github.configure` takes.
pub const MIN_INTERVAL_S: u64 = 30;
pub const MAX_INTERVAL_S: u64 = 3600;
/// Notification reasons the feed shows.
pub const SUPPORTED_REASONS: [&str; 4] = ["assign", "ci_activity", "mention", "review_requested"];
/// The user's own open pull requests held for their trial of a build.
pub const HELD_FOR_TRIAL_QUERY: &str = "is:pr is:open author:@me label:hold archived:false";
/// The most notice details kept: as many as the integration owner keeps items.
pub const MAX_DETAILS: usize = super::owner::MAX_INTEGRATION_ITEMS;
const WEEK_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// One `gh api` request.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Query {
    Notifications,
    ReviewRequests,
    FailingChecks,
    HeldForTrial,
    /// Find Work's assignments (not polled).
    AssignedWork,
}

impl Query {
    /// The poll's queries, in order.
    pub const POLLED: [Query; 4] =
        [Query::Notifications, Query::ReviewRequests, Query::FailingChecks, Query::HeldForTrial];

    fn path(self) -> &'static str {
        match self {
            Query::Notifications => "notifications",
            _ => "search/issues",
        }
    }

    fn fields(self) -> Vec<(&'static str, &'static str)> {
        match self {
            Query::Notifications => vec![("per_page", "100")],
            Query::ReviewRequests => {
                vec![("per_page", "100"), ("q", "is:pr is:open review-requested:@me")]
            }
            Query::FailingChecks => {
                vec![("per_page", "100"), ("q", "is:pr is:open author:@me status:failure")]
            }
            Query::HeldForTrial => vec![("per_page", "50"), ("q", HELD_FOR_TRIAL_QUERY)],
            Query::AssignedWork => {
                vec![("per_page", "50"), ("q", "is:open assignee:@me archived:false")]
            }
        }
    }

    /// `gh`'s arguments (after the program), with the conditional request.
    pub fn gh_args(self, etag: Option<&str>) -> Vec<String> {
        let mut args: Vec<String> =
            ["api", "--include", "-X", "GET", self.path()].map(str::to_owned).to_vec();
        for (key, value) in self.fields() {
            args.push("-f".to_owned());
            args.push(format!("{key}={value}"));
        }
        if let Some(etag) = etag {
            args.push("-H".to_owned());
            args.push(format!("If-None-Match: {etag}"));
        }
        args
    }
}

/// One HTTP answer of `gh api --include`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub etag: Option<String>,
    pub body: Vec<u8>,
}

/// Splits `gh api --include` output into status, ETag and body. Output
/// without headers is a 200 body.
pub fn parse_http(output: &[u8]) -> Response {
    let split = find(output, b"\r\n\r\n")
        .map(|at| (at, 4))
        .or_else(|| find(output, b"\n\n").map(|at| (at, 2)));
    let Some((at, len)) = split else {
        return Response { status: 200, etag: None, body: output.to_vec() };
    };
    let (head, rest) = output.split_at_checked(at).unwrap_or((output, &[]));
    let header = String::from_utf8_lossy(head);
    let mut lines = header.lines();
    let status = lines
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse().ok())
        .unwrap_or(200);
    let etag = header
        .lines()
        .filter_map(|line| line.split_once(':'))
        .filter(|(name, _)| name.trim().eq_ignore_ascii_case("etag"))
        .map(|(_, value)| value.trim().to_owned())
        .next_back();
    Response { status, etag, body: rest.get(len..).unwrap_or_default().to_vec() }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

/// `2026-11-06T10:00:00Z` as Unix ms.
pub fn parse_time(text: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(text).ok().map(|time| time.timestamp_millis())
}

fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

/// A GitHub notification (the subset the feed reads).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notification {
    pub id: String,
    pub reason: String,
    pub title: String,
    pub subject_url: Option<String>,
    pub subject_type: Option<String>,
    pub repository: String,
    pub repository_url: Option<String>,
    pub updated_at: i64,
}

impl Notification {
    fn from_value(value: &Value) -> Option<Self> {
        let subject = value.get("subject")?;
        let repository = value.get("repository")?;
        Some(Self {
            id: string(value, "id")?,
            reason: string(value, "reason")?,
            title: string(subject, "title")?,
            subject_url: string(subject, "url"),
            subject_type: string(subject, "type"),
            repository: string(repository, "full_name")?,
            repository_url: string(repository, "html_url"),
            updated_at: parse_time(value.get("updated_at")?.as_str()?)?,
        })
    }
}

/// An issue or pull request of GitHub's issue search.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Pull {
    pub id: i64,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub repo: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    /// The author's login.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    pub updated_at: i64,
}

impl Pull {
    fn from_value(value: &Value) -> Option<Self> {
        let repo = value
            .pointer("/repository/full_name")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                let url = value.get("repository_url")?.as_str()?;
                let parts: Vec<&str> = url.split('/').filter(|part| !part.is_empty()).collect();
                Some(parts.get(parts.len().saturating_sub(2)..).unwrap_or_default().join("/"))
            })
            .unwrap_or_default();
        Some(Self {
            id: value.get("id")?.as_i64()?,
            number: value.get("number")?.as_i64()?,
            title: string(value, "title")?,
            url: string(value, "html_url")?,
            repo,
            body: string(value, "body"),
            state: string(value, "state"),
            branch: value
                .pointer("/pull_request/head/ref")
                .and_then(Value::as_str)
                .map(str::to_owned),
            author: value.pointer("/user/login").and_then(Value::as_str).map(str::to_owned),
            updated_at: parse_time(value.get("updated_at")?.as_str()?)?,
        })
    }
}

/// The rows of a search answer (`{items: [...]}`); rows that do not decode
/// are skipped.
pub fn pulls(body: &[u8]) -> Result<Vec<Pull>, String> {
    let value: Value = serde_json::from_slice(body).map_err(|error| error.to_string())?;
    let items = value.get("items").and_then(Value::as_array).ok_or("a search answer has items")?;
    Ok(items.iter().filter_map(Pull::from_value).collect())
}

/// The rows of a notifications answer.
pub fn notifications(body: &[u8]) -> Result<Vec<Notification>, String> {
    let value: Value = serde_json::from_slice(body).map_err(|error| error.to_string())?;
    let rows = value.as_array().ok_or("a notifications answer is a list")?;
    Ok(rows.iter().filter_map(Notification::from_value).collect())
}

/// One check of a detail.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Check {
    pub name: String,
    pub conclusion: Option<String>,
}

/// Live GitHub content for one feed item, never sent to the owner.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Detail {
    pub repository: String,
    pub number: Option<i64>,
    pub url: Option<String>,
    pub title: String,
    pub body: Option<String>,
    pub state: Option<String>,
    pub branch: Option<String>,
    pub checks: Vec<Check>,
    pub updated_at: i64,
}

impl Detail {
    /// `github` of a view item (feed-page.md section 2).
    pub fn to_value(&self) -> Value {
        let mut value = json!({
            "title": self.title,
            "repo": self.repository,
            "number": self.number,
            "url": self.url,
            "checks": self.checks,
        });
        if let Some(object) = value.as_object_mut() {
            if let Some(body) = &self.body {
                object.insert("body".to_owned(), json!(body));
            }
            if let Some(branch) = &self.branch {
                object.insert("branch".to_owned(), json!(branch));
            }
        }
        value
    }
}

/// What a poll asks of the integration owner.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Post(Box<FeedItem>),
    /// The poster withdraws its open item with this dedupe key.
    Withdraw(String),
}

/// The poller's state across polls.
#[derive(Default)]
pub struct GitHubSync {
    etags: HashMap<Query, String>,
    /// Dedupe keys of the held pull requests the last fresh answer listed.
    held: HashSet<String>,
    details: HashMap<String, Detail>,
    /// Notice detail keys, least recently posted first.
    order: VecDeque<String>,
}

impl GitHubSync {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn etag(&self, query: Query) -> Option<&str> {
        self.etags.get(&query).map(String::as_str)
    }

    /// Drops the conditional validators and the details (the account changed).
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// The detail of an item: by its dedupe key, its id, or its URL.
    pub fn detail(&self, item: &FeedItem) -> Option<&Detail> {
        item.dedupe_key
            .as_ref()
            .and_then(|key| self.details.get(key))
            .or_else(|| self.details.get(&item.id))
            .or_else(|| {
                let url = item.context_str("url")?;
                self.details.values().find(|detail| detail.url.as_deref() == Some(url))
            })
    }

    /// One answer of a polled query: the owner effects (a 304 says nothing
    /// new; an error stops the poll, and nothing is withdrawn on it).
    pub fn apply(
        &mut self,
        query: Query,
        response: &Response,
        now: i64,
    ) -> Result<Vec<Effect>, String> {
        if let Some(etag) = &response.etag {
            self.etags.insert(query, etag.clone());
        }
        if response.status == 304 {
            return Ok(Vec::new());
        }
        if !(200..300).contains(&response.status) {
            return Err(format!(
                "gh api answered HTTP {}: {}",
                response.status,
                String::from_utf8_lossy(&response.body).chars().take(200).collect::<String>()
            ));
        }
        let mut effects = Vec::new();
        match query {
            Query::Notifications => {
                for row in notifications(&response.body)? {
                    if SUPPORTED_REASONS.contains(&row.reason.as_str()) {
                        let (item, detail) = notification_item(&row, now);
                        effects.push(self.post(item, detail));
                    }
                }
            }
            Query::ReviewRequests => {
                for pull in pulls(&response.body)? {
                    let (item, detail) = pull_item(&pull, PullKind::Review, now);
                    effects.push(self.post(item, detail));
                }
            }
            Query::FailingChecks => {
                for pull in pulls(&response.body)? {
                    let (item, detail) = pull_item(&pull, PullKind::Checks, now);
                    effects.push(self.post(item, detail));
                }
            }
            Query::HeldForTrial => {
                // Needs you: the user's own PRs held for their trial are open
                // requests until the PR lands, closes or loses the hold; a
                // fresh answer without it withdraws the request.
                let mut listed = HashSet::new();
                for pull in pulls(&response.body)? {
                    let (item, detail) = pull_item(&pull, PullKind::Held, now);
                    listed.insert(item.dedupe_key.clone().unwrap_or_else(|| item.id.clone()));
                    effects.push(self.post(item, detail));
                }
                let mut gone: Vec<String> = self.held.difference(&listed).cloned().collect();
                gone.sort();
                for key in gone {
                    self.details.remove(&key);
                    effects.push(Effect::Withdraw(key));
                }
                self.held = listed;
            }
            Query::AssignedWork => {}
        }
        Ok(effects)
    }

    fn post(&mut self, item: FeedItem, detail: Detail) -> Effect {
        let key = item.dedupe_key.clone().unwrap_or_else(|| item.id.clone());
        self.details.insert(key.clone(), detail);
        // A request's detail stays as long as the owner keeps the request; a
        // notice's details are bounded like the owner's items, oldest first.
        if !item.is_request() {
            self.order.retain(|old| *old != key);
            self.order.push_back(key);
            while self.order.len() > MAX_DETAILS {
                if let Some(stale) = self.order.pop_front() {
                    self.details.remove(&stale);
                }
            }
        }
        Effect::Post(Box::new(item))
    }
}

/// `fi_` and 20 hex digits of the key's SHA-256: the same item id for the
/// same GitHub thing on every poll.
pub fn stable_id(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    let hex: String = digest.iter().take(10).map(|byte| format!("{byte:02x}")).collect();
    format!("fi_{hex}")
}

fn base_item(
    dedupe: String,
    thread: String,
    body: String,
    url: Option<&str>,
    created: i64,
    now: i64,
) -> FeedItem {
    let mut item = FeedItem::notice(
        &stable_id(&dedupe),
        "GitHub",
        Poster::new("integration", "GitHub"),
        created,
    );
    item.home = "local:github".to_owned();
    item.body = body;
    item.dedupe_key = Some(dedupe);
    item.thread = Some(thread);
    if let Some(url) = url {
        item.context = Map::from_iter([("url".to_owned(), json!(url))]);
    }
    item.expires_at = Some(now.saturating_add(WEEK_MS));
    item.updated_at = now;
    item
}

fn review_prompt(item: &mut FeedItem, reference: &str) {
    item.kind = "review".to_owned();
    item.prompt = json!({"subject": "pr", "ref": reference});
}

fn reference(repository: &str, number: Option<i64>) -> String {
    number.map_or_else(|| repository.to_owned(), |number| format!("{repository}#{number}"))
}

fn number_of(url: Option<&str>) -> Option<i64> {
    url?.rsplit('/').next()?.parse().ok()
}

fn notification_item(row: &Notification, now: i64) -> (FeedItem, Detail) {
    let number = number_of(row.subject_url.as_deref());
    let url = match (&row.subject_url, number, &row.repository_url) {
        (None, _, base) => base.clone(),
        (Some(_), Some(number), Some(base)) => {
            let kind =
                if row.subject_type.as_deref().is_some_and(|t| t.to_lowercase().contains("pull")) {
                    "pull"
                } else {
                    "issues"
                };
            Some(format!("{}/{kind}/{number}", base.trim_matches('/')))
        }
        (Some(raw), _, _) => Some(raw.clone()),
    };
    let review = row.reason == "review_requested";
    let dedupe = match (review, number) {
        (true, Some(number)) => format!("github:review:{}:{number}", row.repository),
        _ => format!("github:notification:{}", row.id),
    };
    let mut item = base_item(
        dedupe,
        format!("github:{}", row.repository),
        reference(&row.repository, number),
        url.as_deref(),
        row.updated_at,
        now,
    );
    if review {
        review_prompt(&mut item, url.as_deref().unwrap_or(&row.title));
    }
    item.priority = if row.reason == "ci_activity" { Priority::High } else { Priority::Normal };
    let detail = Detail {
        repository: row.repository.clone(),
        number,
        url,
        title: row.title.clone(),
        body: None,
        state: Some("open".to_owned()),
        branch: None,
        checks: Vec::new(),
        updated_at: row.updated_at,
    };
    (item, detail)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PullKind {
    Review,
    Checks,
    Held,
}

fn pull_item(pull: &Pull, kind: PullKind, now: i64) -> (FeedItem, Detail) {
    let prefix = match kind {
        PullKind::Review => "review",
        PullKind::Checks => "checks",
        PullKind::Held => "held",
    };
    let mut item = base_item(
        format!("github:{prefix}:{}:{}", pull.repo, pull.number),
        format!("github:{}:pr:{}", pull.repo, pull.number),
        reference(&pull.repo, Some(pull.number)),
        Some(&pull.url),
        pull.updated_at,
        now,
    );
    let mut checks = Vec::new();
    if kind == PullKind::Checks {
        item.priority = Priority::High;
        checks.push(Check {
            name: "GitHub checks".to_owned(),
            conclusion: Some("failure".to_owned()),
        });
    } else {
        review_prompt(&mut item, &pull.url);
    }
    let detail = Detail {
        repository: pull.repo.clone(),
        number: Some(pull.number),
        url: Some(pull.url.clone()),
        title: pull.title.clone(),
        body: pull.body.clone(),
        state: pull.state.clone(),
        branch: pull.branch.clone(),
        checks,
        updated_at: pull.updated_at,
    };
    (item, detail)
}

/// Which GitHub actions an item offers (Swift `FeedGitHubActions.install`):
/// open and comment for a GitHub item with a detail URL, approve for a
/// review with a number, checkout when its branch is known too, and start an
/// agent. Request Changes is not offered: `gh pr review --request-changes`
/// needs a body the page does not ask for, and the Swift Feed never offered it.
pub fn actions(item: &FeedItem, detail: Option<&Detail>) -> Option<Vec<&'static str>> {
    let detail = detail?;
    if !item.dedupe_key.as_deref().is_some_and(|key| key.starts_with("github:"))
        || detail.url.is_none()
    {
        return None;
    }
    let mut actions = vec!["open"];
    let review = item.kind == "review" && detail.number.is_some();
    if review && detail.branch.is_some() {
        actions.push("checkout");
    }
    actions.push("start_agent");
    if review {
        actions.push("approve");
    }
    actions.push("comment");
    Some(actions)
}
