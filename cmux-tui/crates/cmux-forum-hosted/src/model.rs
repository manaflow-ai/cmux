//! Wire types for `/v1/forum/*`. Missing fields default and unknown fields are ignored, so a newer
//! server does not break an older client.

use serde::{Deserialize, Deserializer, Serialize};

/// Who wrote a thread or comment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuthorKind {
    #[default]
    Person,
    Agent,
    Anonymous,
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Author {
    pub kind: AuthorKind,
    pub id: String,
    pub name: String,
    /// The author's team.
    pub org: Option<String>,
    /// An agent's person.
    pub on_behalf_of: Option<String>,
    /// Reported by the agent, display only.
    pub session: Option<String>,
    /// Reported by the agent, display only.
    pub host: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Label {
    pub name: String,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadState {
    #[default]
    Open,
    Closed,
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Space {
    pub name: String,
    /// `private`, `public` or `shared`.
    pub visibility: String,
    pub threads: u64,
    /// Shown to a guest only: the host and the orgs active in a shared space.
    pub orgs: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Thread {
    pub number: u64,
    pub title: String,
    pub body: String,
    pub state: ThreadState,
    pub labels: Vec<Label>,
    pub author: Author,
    pub space: String,
    /// Comment count.
    pub comments: u64,
    pub created_at: String,
    pub updated_at: String,
    pub closed_at: Option<String>,
    pub html_url: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Comment {
    pub id: i64,
    pub body: String,
    pub author: Author,
    pub thread: u64,
    pub created_at: String,
    pub updated_at: String,
    pub html_url: String,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum EventKind {
    #[serde(rename = "thread.created")]
    ThreadCreated,
    #[serde(rename = "thread.updated")]
    ThreadUpdated,
    #[serde(rename = "thread.closed")]
    ThreadClosed,
    #[serde(rename = "thread.reopened")]
    ThreadReopened,
    #[serde(rename = "comment.created")]
    CommentCreated,
    #[serde(rename = "thread.imported")]
    ThreadImported,
    #[default]
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct EventActor {
    pub kind: String,
    pub id: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct EventCommentAuthor {
    pub kind: String,
    pub name: String,
}

/// The comment a `comment.created` event carries, cut to one line.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct EventComment {
    pub id: i64,
    pub author: EventCommentAuthor,
    /// One line, at most 280 characters.
    pub excerpt: String,
    pub cut: bool,
    pub length: u64,
}

/// One entry of the feed log. `title` and `state` are the thread's as of this event.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct FeedEvent {
    pub seq: u64,
    pub kind: EventKind,
    pub at: String,
    pub space: String,
    pub thread: u64,
    pub title: String,
    pub state: ThreadState,
    pub actor: EventActor,
    /// The bridge that wrote it; `None` for a direct write.
    pub origin: Option<String>,
    pub comment: Option<EventComment>,
}

/// `GET /feed`: events after the cursor, oldest first. `next == head` means caught up.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct FeedPage {
    pub events: Vec<FeedEvent>,
    pub next: u64,
    pub head: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SearchHit {
    pub number: u64,
    pub title: String,
    pub snippet: String,
    pub state: ThreadState,
    pub space: String,
    pub labels: Vec<Label>,
    pub updated_at: String,
    /// Relevance; the server may send a non-finite score as a string.
    #[serde(deserialize_with = "lenient_f64")]
    pub score: f64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub(crate) struct SearchResult {
    pub hits: Vec<SearchHit>,
}

/// `POST /token`'s answer.
#[derive(Clone, Default, Deserialize)]
#[serde(default)]
pub(crate) struct TokenGrant {
    pub token: String,
    pub expires_in: u64,
}

/// A refusal's body: `{code, message}` from the front, `{error}` from the store.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub(crate) struct ApiErrorBody {
    pub code: Option<String>,
    pub message: Option<String>,
    pub error: Option<String>,
}

fn lenient_f64<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Num {
        F(f64),
        S(String),
        Null(()),
    }
    Ok(match Num::deserialize(d)? {
        Num::F(f) => f,
        Num::S(s) => match s.as_str() {
            "Infinity" => f64::INFINITY,
            "-Infinity" => f64::NEG_INFINITY,
            other => other.parse().unwrap_or(f64::NAN),
        },
        Num::Null(()) => 0.0,
    })
}
