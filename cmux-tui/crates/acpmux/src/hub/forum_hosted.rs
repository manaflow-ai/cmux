//! The team's hosted forum from a chat: `cmux-forum`'s `post`, `reply` and `search` tools
//! (`forum_mcp.rs`) reach it through `_acpmux/forum/{post,reply,search}` (`server/forum.rs`).
//!
//! - Set up from the daemon's env on first use: `CMUX_FORUM_URL` (default the development
//!   deployment), `CMUX_FORUM_TEAM` and `CMUX_FORUM_KEY` (an agent key). Without a team or key
//!   every call answers [`NOT_SET_UP`]. The key is never logged and never in an error's text.
//! - Each calling session gets its own client, reporting its session id and this machine's name
//!   beside its posts (display only), and keeping its exchanged token between calls.
//! - Every call runs in its own request task, bounded by [`CALL_TIMEOUT`].
//! - The answer is the one JSON object the chat's card reads (`thread_json`, the module tests).

use super::*;
use cmux_forum_hosted::{
    Credential, ForumClient, ForumError, Request, Response, Thread, ThreadState, Transport,
    TransportError,
};
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

pub const URL_ENV: &str = "CMUX_FORUM_URL";
pub const TEAM_ENV: &str = "CMUX_FORUM_TEAM";
pub const KEY_ENV: &str = "CMUX_FORUM_KEY";
/// What every call answers on a machine with no team or key.
pub const NOT_SET_UP: &str =
    "The hosted forum is not set up on this machine (set CMUX_FORUM_TEAM and CMUX_FORUM_KEY).";
/// Longest one tool call waits on the hosted forum, every request it makes included.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(15);
/// Most hits a search answers.
pub const MAX_HITS: usize = 10;
/// Most per-session clients kept; past it the cache starts over (each only holds a token).
const MAX_CLIENTS: usize = 64;
/// The kinds a post may name; each is sent as a label of that name.
pub const KINDS: [&str; 4] = ["question", "finding", "article", "page"];

type Sent<'a> = Pin<Box<dyn Future<Output = Result<Response, TransportError>> + Send + 'a>>;

trait Erased: Send + Sync {
    fn send_boxed(&self, request: Request) -> Sent<'_>;
}

impl<T: Transport> Erased for T {
    fn send_boxed(&self, request: Request) -> Sent<'_> {
        Box::pin(self.send(request))
    }
}

/// Any [`Transport`], shared by every session's client: reqwest in the daemon, a fake in tests.
#[derive(Clone)]
pub struct AnyTransport(Arc<dyn Erased>);

impl AnyTransport {
    pub fn new<T: Transport + 'static>(transport: T) -> Self {
        Self(Arc::new(transport))
    }
}

impl Transport for AnyTransport {
    async fn send(&self, request: Request) -> Result<Response, TransportError> {
        self.0.send_boxed(request).await
    }
}

/// The hosted forum this daemon posts to, for one team with one agent key.
pub struct HostedForum {
    transport: AnyTransport,
    team: String,
    key: String,
    host: String,
    clients: StdMutex<HashMap<String, Arc<ForumClient<AnyTransport>>>>,
}

/// Never shows the key.
impl std::fmt::Debug for HostedForum {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostedForum")
            .field("team", &self.team)
            .field("key", &"<redacted>")
            .field("host", &self.host)
            .finish_non_exhaustive()
    }
}

/// What the hub holds: the forum, or the message every call answers instead.
pub type Slot = Result<Arc<HostedForum>, String>;

impl HostedForum {
    /// A forum over `transport` for `team`, signing with the agent key `key`.
    pub fn new(transport: AnyTransport, team: impl Into<String>, key: impl Into<String>) -> Self {
        Self {
            transport,
            team: team.into(),
            key: key.into(),
            host: crate::hand::pair::hostname(),
            clients: StdMutex::default(),
        }
    }

    /// The forum the env sets up, or the message calls answer without one.
    fn from_env() -> Slot {
        let var = |k: &str| std::env::var(k).ok().map(|v| v.trim().to_owned());
        let team = var(TEAM_ENV).filter(|v| !v.is_empty());
        let key = var(KEY_ENV).filter(|v| !v.is_empty());
        let (Some(team), Some(key)) = (team, key) else {
            return Err(NOT_SET_UP.to_owned());
        };
        let url = var(URL_ENV)
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| cmux_forum_hosted::DEVELOPMENT_BASE_URL.to_owned());
        Self::at(url, team, key)
    }

    /// The forum at `url` for `team`, signed in with the agent `key`.
    fn at(url: String, team: String, key: String) -> Slot {
        // reqwest is built without a default TLS provider (as `github_status.rs` does).
        let _ = rustls::crypto::ring::default_provider().install_default();
        let headers = cmux_build_space::headers()
            .map_err(|_| "The hosted forum is off: this build's space is unusable.".to_owned())?;
        let http = cmux_egress::client_builder("acpmux::hub::forum_hosted")
            .default_headers(headers)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
            .timeout(CALL_TIMEOUT)
            .build()
            .map_err(|e| format!("The hosted forum's HTTP client did not start: {e}"))?;
        let transport = AnyTransport::new(cmux_forum_hosted::HttpTransport::new(url, http));
        Ok(Arc::new(Self::new(transport, team, key)))
    }

    /// The client that reports `session` beside its posts.
    fn client(&self, session: &str) -> Arc<ForumClient<AnyTransport>> {
        let mut clients = self.clients.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(client) = clients.get(session) {
            return client.clone();
        }
        if clients.len() >= MAX_CLIENTS {
            clients.clear();
        }
        let client = Arc::new(
            ForumClient::new(
                self.transport.clone(),
                self.team.clone(),
                Credential::AgentKey { key: self.key.clone() },
            )
            .with_reported(session, self.host.clone()),
        );
        clients.insert(session.to_owned(), client.clone());
        client
    }

    /// `text` with the key, should anything have echoed it, blanked.
    fn redact(&self, text: String) -> String {
        if self.key.is_empty() { text } else { text.replace(&self.key, "<redacted>") }
    }

    /// A failed call as the agent reads it.
    fn refusal(&self, e: &ForumError) -> RpcError {
        let (reason, text) = match e {
            ForumError::NotEnabled { .. } => {
                ("forum.not_enabled", "The hosted forum is not on for this team.".to_owned())
            }
            ForumError::Unauthorized { .. } => (
                "forum.unauthorized",
                format!(
                    "The hosted forum refused this machine's agent key ({KEY_ENV}): it is invalid, revoked or expired."
                ),
            ),
            ForumError::Forbidden { code, message } => (
                "forum.forbidden",
                format!("The hosted forum refused this agent ({code}): {message}"),
            ),
            ForumError::NotFound { message } => {
                ("forum.not_found", format!("No such thread or space: {message}"))
            }
            ForumError::Invalid { code, message } => (
                "forum.invalid",
                format!("The hosted forum refused the request ({code}): {message}"),
            ),
            ForumError::Conflict { message } => {
                ("forum.conflict", format!("The hosted forum refused a conflict: {message}"))
            }
            ForumError::Gone { message } => ("forum.gone", format!("Gone: {message}")),
            ForumError::Unavailable { status, .. } => (
                "forum.unavailable",
                format!("The hosted forum is unavailable ({status}); try again."),
            ),
            ForumError::Api { status, code, message } => {
                ("forum.error", format!("The hosted forum answered {status} ({code}): {message}"))
            }
            ForumError::Transport(m) => {
                ("forum.unreachable", format!("The hosted forum could not be reached: {m}"))
            }
            ForumError::Decode(m) => {
                ("forum.decode", format!("The hosted forum's answer did not parse: {m}"))
            }
        };
        RpcError::internal(self.redact(text)).with_data(json!({"reason": reason}))
    }

    /// `call` within [`CALL_TIMEOUT`], its failure as the agent reads it.
    async fn bounded<R>(
        &self,
        call: impl Future<Output = Result<R, ForumError>>,
    ) -> Result<R, RpcError> {
        match tokio::time::timeout(CALL_TIMEOUT, call).await {
            Ok(Ok(r)) => Ok(r),
            Ok(Err(e)) => Err(self.refusal(&e)),
            Err(_) => Err(RpcError::internal(format!(
                "The hosted forum did not answer within {} s; try again.",
                CALL_TIMEOUT.as_secs()
            ))
            .with_data(json!({"reason": "forum.timeout"}))),
        }
    }
}

fn state_text(state: ThreadState) -> &'static str {
    match state {
        ThreadState::Open => "open",
        ThreadState::Closed => "closed",
        ThreadState::Unknown => "unknown",
    }
}

/// A thread as the chat's card reads it.
pub fn thread_json(t: &Thread) -> Value {
    json!({
        "number": t.number,
        "title": t.title,
        "space": t.space,
        "state": state_text(t.state),
        "comments": t.comments,
        "url": t.html_url,
    })
}

/// What a `post` asks for.
pub struct PostRequest {
    pub space: String,
    pub title: String,
    pub body: String,
    pub kind: Option<String>,
    pub labels: Vec<String>,
}

fn invalid(message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message.into()).with_data(json!({"reason": "forum.invalid_params"}))
}

fn required(name: &str, value: &str) -> Result<(), RpcError> {
    if value.trim().is_empty() { Err(invalid(format!("{name} is required"))) } else { Ok(()) }
}

impl Hub {
    /// The hosted forum, set up from the env the first time it is asked for.
    fn forum_hosted(&self) -> Result<Arc<HostedForum>, RpcError> {
        self.forum_hosted.get_or_init(HostedForum::from_env).clone().map_err(|message| {
            RpcError::invalid_params(message).with_data(json!({"reason": "forum.not_set_up"}))
        })
    }

    /// Sets the hosted forum (a test's fake transport), or none, before the first call.
    /// False when a call already set it up.
    pub fn set_forum_hosted(&self, forum: Option<HostedForum>) -> bool {
        let slot = forum.map(Arc::new).ok_or_else(|| NOT_SET_UP.to_owned());
        self.forum_hosted.set(slot).is_ok()
    }

    /// `_acpmux/forum/post`: a new thread by `session`.
    pub async fn forum_post(&self, session: &Session, req: PostRequest) -> Result<Value, RpcError> {
        required("space", &req.space)?;
        required("title", &req.title)?;
        required("body", &req.body)?;
        let mut labels = req.labels;
        if let Some(kind) = req.kind.as_deref().map(str::trim).filter(|k| !k.is_empty()) {
            if !KINDS.contains(&kind) {
                return Err(invalid(format!("kind must be one of {}", KINDS.join(", "))));
            }
            if !labels.iter().any(|l| l == kind) {
                labels.insert(0, kind.to_owned());
            }
        }
        let forum = self.forum_hosted()?;
        let client = forum.client(&session.id);
        let thread = forum
            .bounded(client.post_thread(req.space.trim(), &req.title, &req.body, &labels))
            .await?;
        Ok(json!({"forum": "post", "thread": thread_json(&thread)}))
    }

    /// `_acpmux/forum/reply`: a comment by `session`, with the thread as it stands after it.
    pub async fn forum_reply(
        &self,
        session: &Session,
        thread: u64,
        body: &str,
    ) -> Result<Value, RpcError> {
        required("body", body)?;
        let forum = self.forum_hosted()?;
        let client = forum.client(&session.id);
        let (comment, after) = forum
            .bounded(async {
                let comment = client.reply(thread, body).await?;
                let after = client.thread(thread).await?;
                Ok((comment, after))
            })
            .await?;
        Ok(json!({"forum": "reply", "thread": thread_json(&after), "comment": {"id": comment.id}}))
    }

    /// `_acpmux/forum/search`: at most [`MAX_HITS`] threads, each with its comment count.
    pub async fn forum_search(
        &self,
        session: &Session,
        query: &str,
        space: Option<&str>,
    ) -> Result<Value, RpcError> {
        required("query", query)?;
        let forum = self.forum_hosted()?;
        let client = forum.client(&session.id);
        let space = space.map(str::trim).filter(|s| !s.is_empty());
        let hits = forum
            .bounded(async {
                let mut hits = client.search(query, space).await?;
                hits.truncate(MAX_HITS);
                // A hit carries no comment count: each thread's, read together; a failed read is 0.
                let threads =
                    futures::future::join_all(hits.iter().map(|h| client.thread(h.number))).await;
                Ok(hits
                    .iter()
                    .zip(threads)
                    .map(|(h, t)| {
                        json!({
                            "number": h.number,
                            "title": h.title,
                            "space": h.space,
                            "state": state_text(h.state),
                            "comments": t.map_or(0, |t| t.comments),
                            "snippet": h.snippet,
                        })
                    })
                    .collect::<Vec<_>>())
            })
            .await?;
        Ok(json!({"forum": "search", "query": query, "hits": hits}))
    }
}

/// Longest a digest read waits: it may page through a long feed.
pub const DIGEST_TIMEOUT: Duration = Duration::from_secs(60);
/// Longest rendered digest a caller may ask for, in characters.
pub const MAX_DIGEST_BUDGET: usize = 20_000;

/// What a `digest` asks for.
pub struct DigestRequest {
    pub space: String,
    /// Move the person's cursor past this digest.
    pub ack: bool,
    /// The read-back counts records at or after this (ms since the epoch).
    pub since: u64,
    /// Areas the person owns, as globs over paths or labels.
    pub areas: Vec<String>,
    pub budget: Option<usize>,
    /// The person the digest is for (the proven app's account, else the OS user).
    pub person: String,
}

/// What a `digest_act` asks for.
pub struct DigestActRequest {
    pub space: String,
    pub item: String,
    pub action: String,
    pub person: String,
}

fn store_refusal(forum: &HostedForum, e: &acpmux_team_space::StoreError) -> RpcError {
    use acpmux_team_space::StoreError;
    let (reason, text) = match e {
        StoreError::Forbidden { space } => {
            ("forum.forbidden", format!("This agent is not admitted to space {space}."))
        }
        StoreError::NotFound { space } => ("forum.not_found", format!("No such space: {space}")),
        StoreError::Unavailable(why) => ("forum.unavailable", format!("The digest failed: {why}")),
    };
    RpcError::internal(forum.redact(text)).with_data(json!({"reason": reason}))
}

impl Hub {
    /// The log of each person's digests, actions and cursors: a file beside the forum log, or
    /// memory when the daemon keeps no store on disk or the file cannot open.
    fn digest_log(&self) -> Arc<acpmux_team_space::log::JsonlLog> {
        self.digest_log
            .get_or_init(|| {
                let log = self.forum_root.get().and_then(|root| {
                    acpmux_team_space::log::JsonlLog::open_with(
                        root.join("digest.jsonl"),
                        crate::forum::append_private,
                    )
                    .inspect_err(|e| {
                        tracing::warn!("digest log unavailable, keeping it in memory: {e}");
                    })
                    .ok()
                });
                Arc::new(log.unwrap_or_else(acpmux_team_space::log::JsonlLog::in_memory))
            })
            .clone()
    }

    /// `_acpmux/forum/digest`: the person's digest of `space` after their stored cursor, the
    /// raised items, the summarized remainder, and the read-back counts since `req.since`. The
    /// cursor moves only when `req.ack` is set.
    pub async fn forum_digest(
        &self,
        session: &Session,
        req: DigestRequest,
    ) -> Result<Value, RpcError> {
        use acpmux_team_space::digest::{DigestOptions, Person};
        use acpmux_team_space::hosted::HostedStore;
        use acpmux_team_space::service::{Ask, Counts, DEFAULT_BUDGET, run};
        required("space", &req.space)?;
        let forum = self.forum_hosted()?;
        let client = forum.client(&session.id);
        let log = self.digest_log();
        let (handle, name) =
            session.read_meta(|m| (m.spoken_handle().into_owned(), m.name.clone()));
        let mut agents = vec![session.id.clone(), handle];
        agents.extend(Some(name).filter(|n| !n.trim().is_empty()));
        let person = Person {
            id: req.person.clone(),
            handle: req.person.clone(),
            agents,
            areas: req.areas.clone(),
        };
        let space = req.space.trim().to_owned();
        let budget = req.budget.unwrap_or(DEFAULT_BUDGET).clamp(200, MAX_DIGEST_BUDGET);
        let (ack, since) = (req.ack, req.since);
        let runtime = tokio::runtime::Handle::current();
        let job = tokio::task::spawn_blocking(move || {
            let store = HostedStore::new(client, runtime, log.clone());
            let options = DigestOptions::default();
            run(
                &store,
                &*log,
                &Ask {
                    person: &person,
                    space: &space,
                    options: &options,
                    budget,
                    ack,
                    now: crate::store::now_ms(),
                    since,
                },
            )
        });
        let got = match tokio::time::timeout(DIGEST_TIMEOUT, job).await {
            Ok(Ok(Ok(got))) => got,
            Ok(Ok(Err(e))) => return Err(store_refusal(&forum, &e)),
            Ok(Err(e)) => {
                return Err(RpcError::internal(format!("The digest did not finish: {e}")));
            }
            Err(_) => {
                return Err(RpcError::internal(format!(
                    "The digest did not finish within {} s; try again.",
                    DIGEST_TIMEOUT.as_secs()
                ))
                .with_data(json!({"reason": "forum.timeout"})));
            }
        };
        let d = &got.digest;
        let summarized: Vec<Value> = d
            .rest
            .iter()
            .map(|g| json!({"kind": g.kind.as_str(), "posts": g.posts, "items": g.items.len()}))
            .collect();
        Ok(json!({
            "forum": "digest",
            "space": d.space,
            "text": got.rendered.text,
            "fromSeq": d.from_seq,
            "toSeq": d.to_seq,
            "head": d.head,
            "behind": d.behind,
            "postsRead": d.posts_seen,
            "duplicatesFolded": d.duplicates_folded,
            "needsYou": d.needs_you,
            "affectsYou": d.affects_you,
            "summarized": summarized,
            "shown": got.rendered.shown,
            "cut": got.rendered.cut,
            "acked": got.acked,
            "cursor": got.cursor,
            "counts": Counts::new(&got.stats, since),
        }))
    }

    /// `_acpmux/forum/digest_act`: the person opened, answered or dismissed digest item `item`.
    pub async fn forum_digest_act(
        &self,
        session: &Session,
        req: DigestActRequest,
    ) -> Result<Value, RpcError> {
        use acpmux_team_space::Action;
        use acpmux_team_space::hosted::HostedStore;
        use acpmux_team_space::service::{ActError, act};
        required("space", &req.space)?;
        required("item", &req.item)?;
        let action = match req.action.trim() {
            "opened" => Action::Opened,
            "answered" => Action::Answered,
            "dismissed" => Action::Dismissed,
            _ => return Err(invalid("action must be one of opened, answered, dismissed")),
        };
        let forum = self.forum_hosted()?;
        let store = HostedStore::new(
            forum.client(&session.id),
            tokio::runtime::Handle::current(),
            self.digest_log(),
        );
        let (person, space, item) = (req.person, req.space.trim().to_owned(), req.item);
        let record = tokio::task::spawn_blocking(move || {
            act(&store, &person, &space, item.trim(), action, crate::store::now_ms())
        })
        .await
        .map_err(|e| RpcError::internal(format!("The record did not finish: {e}")))?
        .map_err(|e| match e {
            ActError::UnknownItem(_) => invalid(e.to_string()),
            ActError::Store(e) => store_refusal(&forum, &e),
        })?;
        Ok(json!({
            "forum": "digest_act",
            "item": record.item,
            "action": record.action.as_str(),
            "at": record.at,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_never_shows_the_key() {
        struct Never;
        impl Transport for Never {
            async fn send(&self, _: Request) -> Result<Response, TransportError> {
                Err(TransportError::new("never"))
            }
        }
        let forum = HostedForum::new(AnyTransport::new(Never), "team-a", "cfk_secret_value");
        let shown = format!("{forum:?}");
        assert!(!shown.contains("cfk_secret_value"), "{shown}");
        assert!(shown.contains("team-a"), "{shown}");
        let err = forum.refusal(&ForumError::Transport("echo cfk_secret_value".into()));
        assert!(!err.message.contains("cfk_secret_value"), "{}", err.message);
        assert!(!format!("{err:?}").contains("cfk_secret_value"));
    }

    /// Seeded secrets on the wire (cmux_egress::capture): the agent key rides only in the token
    /// exchange's `Authorization`, the team only in `x-cmux-team`, and the post's text only in
    /// bodies. tests/egress_seeded.json names this test for `acpmux::hub::forum_hosted`.
    #[tokio::test]
    async fn seeded_secrets_ride_only_where_the_forum_needs_them() {
        cmux_egress::capture::install().unwrap();
        let key = "cfk_SEEDforumHostedKey-4b1e";
        let team = "SEEDforumTeam-91ac";
        let forum = HostedForum::at(
            cmux_forum_hosted::DEVELOPMENT_BASE_URL.to_owned(),
            team.to_owned(),
            key.to_owned(),
        )
        .unwrap();
        let client = forum.client("seeded-session");
        // The capture server answers `200 {}`: the exchange decodes no token and the call ends.
        let _ = client.spaces().await;
        let host = "cmux-platform-development.debussy.workers.dev";
        let sent = cmux_egress::capture::requests_to(host);
        assert!(!sent.is_empty(), "the exchange reached the capture server");
        let places = cmux_egress::capture::leaks(key);
        assert!(!places.is_empty(), "{sent:?}");
        assert!(
            places.iter().all(|p| p.ends_with(" /v1/forum/token: header authorization")),
            "{places:?}"
        );
        let places = cmux_egress::capture::leaks(team);
        assert!(places.iter().all(|p| p.ends_with(": header x-cmux-team")), "{places:?}");
    }
}
