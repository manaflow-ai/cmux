//! One feed item as the owner sends it (plans/cmux-next/feed.md 3.1; the
//! `FeedDO` wire JSON: snake_case, times in Unix ms). Port of Swift
//! `FeedItem` and `FeedWireDecode.item`: the decode is lenient, so one odd
//! item never hides the rest of the feed. The fields the client reads are
//! typed; the kind-specific parts (`prompt`, the answer and cancel records,
//! attachments, actions, context) stay JSON and pass through unchanged, and
//! every member the client does not know (`type`, `answer_schema`, `open`,
//! `mail`, ...) is kept in `extra` and written back as it came.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value, json};

/// Lifecycle (feed.md 3.6). Answered, cancelled and expired are final.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum State {
    Open,
    Answered,
    Cancelled,
    Expired,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Open => "open",
            State::Answered => "answered",
            State::Cancelled => "cancelled",
            State::Expired => "expired",
        }
    }

    /// An unknown state reads as open, as the Swift decode does.
    pub fn parse(value: &str) -> Self {
        match value {
            "answered" => State::Answered,
            "cancelled" => State::Cancelled,
            "expired" => State::Expired,
            _ => State::Open,
        }
    }

    pub fn is_closed(self) -> bool {
        self != State::Open
    }
}

/// `low` < `normal` < `high` < `urgent`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Priority {
    Low,
    Normal,
    High,
    Urgent,
}

impl Priority {
    pub fn as_str(self) -> &'static str {
        match self {
            Priority::Low => "low",
            Priority::Normal => "normal",
            Priority::High => "high",
            Priority::Urgent => "urgent",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "low" => Some(Priority::Low),
            "normal" => Some(Priority::Normal),
            "high" => Some(Priority::High),
            "urgent" => Some(Priority::Urgent),
            _ => None,
        }
    }

    /// Higher sorts first.
    pub fn rank(self) -> i8 {
        self as i8
    }

    /// A kind's default priority (feed.md 3.4): notices, reviews and custom
    /// kinds are normal, every other built-in request is high.
    pub fn default_for(kind: &str) -> Self {
        match kind {
            "question" | "choice" | "approve" | "confirm" | "sign-in" | "passkey" | "input"
            | "file" | "handoff" => Priority::High,
            _ => Priority::Normal,
        }
    }
}

/// Who posted the item (feed.md 3.2). `label` and `harness` are what the
/// poster declared; `scope` is its authenticated poster scope.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Poster {
    /// `agent`, `harness`, `app`, `server`, `vm`, `automation`,
    /// `integration`, `system` or `user`; an unknown kind reads as `agent`.
    pub kind: String,
    pub label: String,
    pub harness: Option<String>,
    pub scope: Option<String>,
    /// Members the client does not read, written back unchanged.
    pub extra: Map<String, Value>,
}

const POSTER_KINDS: [&str; 9] =
    ["agent", "harness", "app", "server", "vm", "automation", "integration", "system", "user"];

impl Poster {
    pub fn new(kind: &str, label: &str) -> Self {
        Self { kind: kind.to_owned(), label: label.to_owned(), ..Self::default() }
    }

    fn from_object(object: &Map<String, Value>) -> Self {
        let mut extra = object.clone();
        let mut take = |key: &str| extra.remove(key);
        let kind = take("kind").and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default();
        let kind = if POSTER_KINDS.contains(&kind.as_str()) { kind } else { "agent".to_owned() };
        let label = take("label").and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default();
        let harness = take("harness").and_then(|v| v.as_str().map(str::to_owned));
        let scope = take("scope").and_then(|v| v.as_str().map(str::to_owned));
        Self { kind, label, harness, scope, extra }
    }

    fn to_value(&self) -> Value {
        let mut object = self.extra.clone();
        object.insert("kind".into(), json!(self.kind));
        object.insert("label".into(), json!(self.label));
        if let Some(harness) = &self.harness {
            object.insert("harness".into(), json!(harness));
        }
        if let Some(scope) = &self.scope {
            object.insert("scope".into(), json!(scope));
        }
        Value::Object(object)
    }

    /// "Claude Code · api-server", or the label alone.
    pub fn display_label(&self) -> String {
        match self.harness.as_deref().filter(|harness| !harness.is_empty()) {
            None => self.label.clone(),
            Some(harness) if self.label.is_empty() => harness.to_owned(),
            Some(harness) => format!("{harness} · {}", self.label),
        }
    }
}

/// One feed item.
#[derive(Clone, Debug, PartialEq)]
pub struct FeedItem {
    /// `fi_` + 20, stable across a home transfer.
    pub id: String,
    /// `cloud` or `local:<install>`.
    pub home: String,
    /// `notice`, or the request's registry kind.
    pub kind: String,
    pub title: String,
    /// Markdown, at most 4096 characters.
    pub body: String,
    /// The kind-specific prompt object (`{}` for a notice).
    pub prompt: Value,
    pub priority: Priority,
    pub dedupe_key: Option<String>,
    pub thread: Option<String>,
    /// `{host, workspace, tab, terminal, browser_tab, acp_session, task, url}`.
    pub context: Map<String, Value>,
    pub attachments: Vec<Value>,
    pub actions: Vec<Value>,
    pub expires_at: Option<i64>,
    pub poster: Poster,
    pub state: State,
    /// `{value, by, device, at}`.
    pub answer: Option<Value>,
    /// `{reason, by, at, note?}`.
    pub cancel: Option<Value>,
    pub read_at: Option<i64>,
    pub seen_at: Option<i64>,
    pub archived_at: Option<i64>,
    pub snoozed_until: Option<i64>,
    /// How many posts the dedupe key coalesced.
    pub count: i64,
    pub revision: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub closed_at: Option<i64>,
    /// Members the client does not read, written back unchanged.
    pub extra: Map<String, Value>,
}

/// A JSON number as Unix ms (fractions round down, as the Swift `Date` did
/// not keep them either once shown).
pub(crate) fn ms(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value.as_i64().or_else(|| value.as_f64().and_then(whole_ms))
}

fn string(value: Option<Value>) -> Option<String> {
    match value {
        Some(Value::String(text)) => Some(text),
        _ => None,
    }
}

fn opt(value: Option<i64>) -> Value {
    value.map_or(Value::Null, |n| json!(n))
}

impl FeedItem {
    /// A notice with the owner's defaults (tests, integration posts).
    pub fn notice(id: &str, title: &str, poster: Poster, created_at: i64) -> Self {
        Self {
            id: id.to_owned(),
            home: "cloud".to_owned(),
            kind: "notice".to_owned(),
            title: title.to_owned(),
            body: String::new(),
            prompt: Value::Object(Map::new()),
            priority: Priority::Normal,
            dedupe_key: None,
            thread: None,
            context: Map::new(),
            attachments: Vec::new(),
            actions: Vec::new(),
            expires_at: None,
            poster,
            state: State::Open,
            answer: None,
            cancel: None,
            read_at: None,
            seen_at: None,
            archived_at: None,
            snoozed_until: None,
            count: 1,
            revision: 1,
            created_at,
            updated_at: created_at,
            closed_at: None,
            extra: Map::new(),
        }
    }

    /// The item of the owner's JSON, or `None` without an `id`, a `title`,
    /// a `poster` object or a numeric `created_at` (Swift
    /// `FeedWireDecode.item`). Every other part falls back to its default.
    pub fn from_value(value: &Value) -> Option<Self> {
        let mut object = value.as_object()?.clone();
        let mut take = |key: &str| object.remove(key);
        let id = string(take("id"))?;
        let title = string(take("title"))?;
        let poster = match take("poster") {
            Some(Value::Object(poster)) => Poster::from_object(&poster),
            _ => return None,
        };
        let created_at = ms(take("created_at").as_ref())?;
        let kind = string(take("kind")).unwrap_or_else(|| "notice".to_owned());
        let prompt = match take("prompt") {
            Some(Value::Object(prompt)) => Value::Object(prompt),
            _ => Value::Object(Map::new()),
        };
        let priority = string(take("priority"))
            .and_then(|p| Priority::parse(&p))
            .unwrap_or_else(|| Priority::default_for(&kind));
        let objects = |value: Option<Value>| match value {
            Some(Value::Array(rows)) => rows
                .into_iter()
                .filter(|row| row.get("id").is_some_and(Value::is_string))
                .filter(|row| row.get("name").or(row.get("label")).is_some_and(Value::is_string))
                .collect(),
            _ => Vec::new(),
        };
        let attachments = objects(take("attachments"));
        let actions = objects(take("actions"));
        let context = match take("context") {
            Some(Value::Object(context)) => context,
            _ => Map::new(),
        };
        let record = |value: Option<Value>| {
            value.filter(|record| record.is_object() && ms(record.get("at")).is_some())
        };
        let answer = record(take("answer"));
        let cancel = record(take("cancel")).filter(|record| {
            record.get("reason").and_then(Value::as_str).is_some_and(|reason| {
                matches!(
                    reason,
                    "poster" | "declined" | "answered_elsewhere" | "superseded" | "poster_gone"
                )
            })
        });
        let updated_at = ms(take("updated_at").as_ref()).unwrap_or(created_at);
        let item = Self {
            id,
            home: string(take("home")).unwrap_or_else(|| "cloud".to_owned()),
            title,
            body: string(take("body")).unwrap_or_default(),
            prompt,
            priority,
            dedupe_key: string(take("dedupe_key")),
            thread: string(take("thread")),
            context,
            attachments,
            actions,
            expires_at: ms(take("expires_at").as_ref()),
            poster,
            state: string(take("state")).map_or(State::Open, |s| State::parse(&s)),
            answer,
            cancel,
            read_at: ms(take("read_at").as_ref()),
            seen_at: ms(take("seen_at").as_ref()),
            archived_at: ms(take("archived_at").as_ref()),
            snoozed_until: ms(take("snoozed_until").as_ref()),
            count: take("count").and_then(|v| v.as_i64()).unwrap_or(1),
            revision: take("revision").and_then(|v| v.as_i64()).unwrap_or(1),
            created_at,
            updated_at,
            closed_at: ms(take("closed_at").as_ref()),
            kind,
            extra: Map::new(),
        };
        // `type` is derived from the kind on the way out.
        object.remove("type");
        Some(Self { extra: object, ..item })
    }

    /// The owner's JSON: every member, absent optional ones as `null`.
    pub fn to_value(&self) -> Value {
        let mut object = self.extra.clone();
        let mut put = |key: &str, value: Value| {
            object.insert(key.to_owned(), value);
        };
        put("id", json!(self.id));
        put("home", json!(self.home));
        put("type", json!(if self.is_request() { "request" } else { "notice" }));
        put("kind", json!(self.kind));
        put("title", json!(self.title));
        put("body", json!(self.body));
        put("prompt", self.prompt.clone());
        put("priority", json!(self.priority.as_str()));
        put("dedupe_key", self.dedupe_key.as_ref().map_or(Value::Null, |key| json!(key)));
        put("thread", self.thread.as_ref().map_or(Value::Null, |thread| json!(thread)));
        put("context", Value::Object(self.context.clone()));
        put("attachments", Value::Array(self.attachments.clone()));
        put("actions", Value::Array(self.actions.clone()));
        put("expires_at", opt(self.expires_at));
        put("poster", self.poster.to_value());
        put("state", json!(self.state.as_str()));
        put("answer", self.answer.clone().unwrap_or(Value::Null));
        put("cancel", self.cancel.clone().unwrap_or(Value::Null));
        put("read_at", opt(self.read_at));
        put("seen_at", opt(self.seen_at));
        put("archived_at", opt(self.archived_at));
        put("snoozed_until", opt(self.snoozed_until));
        put("count", json!(self.count));
        put("revision", json!(self.revision));
        put("created_at", json!(self.created_at));
        put("updated_at", json!(self.updated_at));
        put("closed_at", opt(self.closed_at));
        Value::Object(object)
    }

    pub fn is_request(&self) -> bool {
        self.kind != "notice"
    }

    /// A request still waiting for its answer.
    pub fn is_open_request(&self) -> bool {
        self.is_request() && self.state == State::Open
    }

    pub fn is_unread(&self) -> bool {
        self.read_at.is_none()
    }

    pub fn is_archived(&self) -> bool {
        self.archived_at.is_some()
    }

    /// Snoozed until a moment after `now`: out of the active lists.
    pub fn is_snoozed(&self, now: i64) -> bool {
        self.snoozed_until.is_some_and(|until| until > now)
    }

    /// In the active lists: not archived, not snoozed.
    pub fn is_active(&self, now: i64) -> bool {
        !self.is_archived() && !self.is_snoozed(now)
    }

    /// Items of a local owner carry a "this Mac only" badge.
    pub fn is_local(&self) -> bool {
        self.home.starts_with("local:")
    }

    /// A string member of the context (`url`, `tab`, `terminal`, ...).
    pub fn context_str(&self, key: &str) -> Option<&str> {
        self.context.get(key).and_then(Value::as_str)
    }
}

impl Serialize for FeedItem {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.to_value().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for FeedItem {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(deserializer)?;
        Self::from_value(&value).ok_or_else(|| {
            serde::de::Error::custom(
                "a feed item needs an id, a title, a poster object and a numeric created_at",
            )
        })
    }
}

/// A finite JSON number of milliseconds, rounded down, when it fits an `i64`.
pub(crate) fn whole_ms(value: f64) -> Option<i64> {
    let floor = value.floor();
    // i64::MIN is exactly representable; i64::MAX is not, so the upper bound is exclusive.
    (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&floor).then(|| {
        #[allow(
            clippy::cast_possible_truncation,
            reason = "checked above: finite, whole and inside i64's range"
        )]
        let whole = floor as i64;
        whole
    })
}
