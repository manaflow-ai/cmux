//! The routed `forum` namespace (page-router.md, spec/page-router.json): the Forum page's
//! `forum.*` ops on the team's hosted forum, through the `cmux-forum-hosted` client.
//!
//! - `forum.snapshot {space?}`: the spaces and the newest page of threads (every state), in the
//!   page's shape (`webviews/src/pages/forum/types.ts` `ForumSnapshot`). With no forum set up on
//!   this machine it answers `{status: "signed-out"}`, so the page shows its gate.
//! - `forum.thread.get {number}`: one thread with every comment, oldest first.
//! - `forum.thread.post {space, title, body, kind?}` and `forum.thread.reply {number, body}`:
//!   the person's gesture on page `forum`; they answer the new thread, or the comment and the
//!   thread as it stands after it.
//!
//! The forum is set up from the daemon's env on first use: `CMUX_FORUM_URL` (default the
//! development deployment), `CMUX_FORUM_TEAM` and `CMUX_FORUM_KEY` (an agent key; the app's
//! sign-in credential is not wired yet). The key is never in an answer. Only the app's own
//! process calls these (`origin_gate::app_process`), as for `feed.*`. Each call waits on the
//! network on its own reply thread, bounded by [`CALL_TIMEOUT`].

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use cmux_forum_hosted::{
    Author, AuthorKind, Comment, Credential, ForumClient, ForumError, Request, Response,
    StateFilter, Thread, ThreadState, Transport, TransportError,
};
use serde_json::{Map, Value, json};

use super::Mux;
use super::feed_client_ops::Answer;
use crate::resource::ResourceError;

pub(super) const OWNER: &str = "forum.hosted";

pub(crate) const URL_ENV: &str = "CMUX_FORUM_URL";
pub(crate) const TEAM_ENV: &str = "CMUX_FORUM_TEAM";
pub(crate) const KEY_ENV: &str = "CMUX_FORUM_KEY";
/// Longest one op waits on the hosted forum, every request it makes included.
pub(crate) const CALL_TIMEOUT: Duration = Duration::from_secs(15);
/// The kinds a thread may be; a thread's kind is its first label of these names.
pub(crate) const KINDS: [&str; 4] = ["question", "finding", "article", "page"];
/// Longest title and body a post or reply takes.
const MAX_TITLE_BYTES: usize = 512;
const MAX_BODY_BYTES: usize = 64 * 1024;

type Sent<'a> = Pin<Box<dyn Future<Output = Result<Response, TransportError>> + Send + 'a>>;

trait Erased: Send + Sync {
    fn send_boxed(&self, request: Request) -> Sent<'_>;
}

impl<T: Transport> Erased for T {
    fn send_boxed(&self, request: Request) -> Sent<'_> {
        Box::pin(self.send(request))
    }
}

/// Any [`Transport`]: reqwest in the daemon, a fake in tests.
#[derive(Clone)]
pub(crate) struct AnyTransport(Arc<dyn Erased>);

impl AnyTransport {
    pub(crate) fn new<T: Transport + 'static>(transport: T) -> Self {
        Self(Arc::new(transport))
    }
}

impl Transport for AnyTransport {
    async fn send(&self, request: Request) -> Result<Response, TransportError> {
        self.0.send_boxed(request).await
    }
}

/// The hosted forum the page reads, or why there is none.
pub(crate) struct ForumOwner {
    forum: Result<Hosted, &'static str>,
    runtime: OnceLock<Option<tokio::runtime::Runtime>>,
}

struct Hosted {
    client: ForumClient<AnyTransport>,
    team: String,
    key: String,
}

/// Never shows the key.
impl std::fmt::Debug for ForumOwner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let team = self.forum.as_ref().map(|h| h.team.as_str()).ok();
        f.debug_struct("ForumOwner").field("team", &team).finish_non_exhaustive()
    }
}

impl ForumOwner {
    /// A forum over `transport` for `team`, signing with the agent key `key`.
    pub(crate) fn new(transport: AnyTransport, team: &str, key: &str) -> Self {
        let client =
            ForumClient::new(transport, team, Credential::AgentKey { key: key.to_owned() });
        Self {
            forum: Ok(Hosted { client, team: team.to_owned(), key: key.to_owned() }),
            runtime: OnceLock::new(),
        }
    }

    fn not_set_up() -> Self {
        Self { forum: Err("not_set_up"), runtime: OnceLock::new() }
    }

    /// The forum the env sets up, or none.
    fn from_env() -> Self {
        Self::from_vars(&|k| std::env::var(k).ok())
    }

    /// The forum `env`'s variables set up, or none.
    fn from_vars(env: &dyn Fn(&str) -> Option<String>) -> Self {
        let var = |k: &str| env(k).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
        let (Some(team), Some(key)) = (var(TEAM_ENV), var(KEY_ENV)) else {
            return Self::not_set_up();
        };
        let url = var(URL_ENV).unwrap_or_else(|| cmux_forum_hosted::DEVELOPMENT_BASE_URL.into());
        let _ = rustls::crypto::ring::default_provider().install_default();
        let Ok(headers) = cmux_build_space::headers() else {
            return Self { forum: Err("build_space"), runtime: OnceLock::new() };
        };
        let http = cmux_egress::client_builder("cmux_tui_core::server::forum_routed")
            .default_headers(headers)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
            .timeout(CALL_TIMEOUT)
            .build();
        let Ok(http) = http else {
            return Self { forum: Err("http_client"), runtime: OnceLock::new() };
        };
        let transport = AnyTransport::new(cmux_forum_hosted::HttpTransport::new(url, http));
        Self::new(transport, &team, &key)
    }

    /// Runs `call` to its end on the owner's runtime, within [`CALL_TIMEOUT`].
    fn block_on<R>(
        &self,
        operation: &str,
        call: impl Future<Output = Result<R, ForumError>>,
    ) -> Result<R, ResourceError> {
        let runtime = self.runtime.get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(1)
                .thread_name("cmux-forum")
                .enable_all()
                .build()
                .ok()
        });
        let Some(runtime) = runtime else {
            return Err(failed(
                operation,
                "forum.unavailable",
                "the forum's runtime did not start",
            ));
        };
        match runtime.block_on(async { tokio::time::timeout(CALL_TIMEOUT, call).await }) {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(error)) => Err(self.refusal(operation, &error)),
            Err(_) => Err(failed(
                operation,
                "forum.timeout",
                &format!("The hosted forum did not answer within {} s.", CALL_TIMEOUT.as_secs()),
            )),
        }
    }

    /// A failed call as the page reads it: `extra.code` names the class, the text never the key.
    fn refusal(&self, operation: &str, error: &ForumError) -> ResourceError {
        let code = match error {
            ForumError::NotEnabled { .. } => "forum.not_enabled",
            ForumError::Unauthorized { .. } => "forum.unauthorized",
            ForumError::Forbidden { .. } => "forum.forbidden",
            ForumError::NotFound { .. } => "forum.not_found",
            ForumError::Invalid { .. } => "forum.invalid",
            ForumError::Conflict { .. } => "forum.conflict",
            ForumError::Gone { .. } => "forum.gone",
            ForumError::Unavailable { .. } => "forum.unavailable",
            ForumError::Api { .. } => "forum.error",
            ForumError::Transport(_) => "forum.unreachable",
            ForumError::Decode(_) => "forum.decode",
        };
        let mut text = error.to_string();
        if let Ok(hosted) = &self.forum
            && !hosted.key.is_empty()
        {
            text = text.replace(&hosted.key, "<redacted>");
        }
        failed(operation, code, &text)
    }
}

fn failed(operation: &str, code: &str, message: &str) -> ResourceError {
    ResourceError::operation_failed(operation, message, json!({"code": code}))
}

fn invalid(field: &str, reason: &str) -> ResourceError {
    ResourceError::validation_invalid(Some(field), reason)
}

impl Mux {
    /// The daemon's forum owner, set up from the env on the first `forum.*` op.
    pub(crate) fn forum_owner(&self) -> &ForumOwner {
        self.cloud_services().forum.get_or_init(ForumOwner::from_env)
    }

    /// Installs the forum owner (a test's fake transport) before the first op; false when one is
    /// already set up.
    #[cfg(test)]
    pub(crate) fn install_forum_owner(&self, owner: ForumOwner) -> bool {
        self.cloud_services().forum.set(owner).is_ok()
    }
}

/// One routed `forum.*` request.
pub(super) fn routed(mux: &Arc<Mux>, client: u64, operation: &str, params: Value) -> Answer {
    if !super::origin_gate::app_process(mux, client) {
        let derived = super::origin_gate::derived_origin(mux, client);
        return Answer::Now(Err(crate::request_origin::forbidden(
            "the forum page is read only by the cmux app",
            json!({"derived": derived.wire_name(), "reason": "app_process_only"}),
        )));
    }
    let request = match parse(operation, &params) {
        Ok(request) => request,
        Err(error) => return Answer::Now(Err(error)),
    };
    // Set up (the env read, the HTTP client) on this thread; the network waits on the reply's.
    mux.forum_owner();
    let mux = mux.clone();
    let operation = operation.to_owned();
    Answer::Later(Box::new(move || run(mux.forum_owner(), &operation, request)))
}

/// A `forum.*` request, its params checked.
#[derive(Debug, PartialEq)]
pub(crate) enum ForumRequest {
    Snapshot { space: Option<String> },
    Thread { number: u64 },
    Post { space: String, title: String, body: String, kind: Option<String> },
    Reply { number: u64, body: String },
}

fn text(params: &Value, key: &str, max: usize) -> Result<String, ResourceError> {
    let value = params.get(key).and_then(Value::as_str).map(str::trim).unwrap_or_default();
    if value.is_empty() {
        return Err(invalid(key, "is required"));
    }
    if value.len() > max {
        return Err(invalid(key, &format!("must be at most {max} bytes")));
    }
    Ok(value.to_owned())
}

fn optional(params: &Value, key: &str) -> Result<Option<String>, ResourceError> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => {
            Ok(Some(value.trim().to_owned()).filter(|value| !value.is_empty()))
        }
        Some(_) => Err(invalid(key, "must be a string")),
    }
}

fn number(params: &Value) -> Result<u64, ResourceError> {
    params
        .get("number")
        .and_then(Value::as_u64)
        .filter(|n| *n > 0)
        .ok_or_else(|| invalid("number", "must be a thread number"))
}

pub(crate) fn parse(operation: &str, params: &Value) -> Result<ForumRequest, ResourceError> {
    match operation {
        "forum.snapshot" => Ok(ForumRequest::Snapshot { space: optional(params, "space")? }),
        "forum.thread.get" => Ok(ForumRequest::Thread { number: number(params)? }),
        "forum.thread.post" => {
            let kind = optional(params, "kind")?;
            if kind.as_deref().is_some_and(|kind| !KINDS.contains(&kind)) {
                return Err(invalid("kind", "must be question, finding, article or page"));
            }
            Ok(ForumRequest::Post {
                space: text(params, "space", MAX_TITLE_BYTES)?,
                title: text(params, "title", MAX_TITLE_BYTES)?,
                body: text(params, "body", MAX_BODY_BYTES)?,
                kind,
            })
        }
        "forum.thread.reply" => Ok(ForumRequest::Reply {
            number: number(params)?,
            body: text(params, "body", MAX_BODY_BYTES)?,
        }),
        other => Err(ResourceError::operation_failed(
            other,
            "no such forum op",
            json!({"code": "forum.unknown_op"}),
        )),
    }
}

/// Runs one request against `owner` (blocking: a reply thread's).
pub(crate) fn run(
    owner: &ForumOwner,
    operation: &str,
    request: ForumRequest,
) -> Result<Value, ResourceError> {
    let hosted = match &owner.forum {
        Ok(hosted) => hosted,
        Err(reason) => {
            if let ForumRequest::Snapshot { .. } = request {
                return Ok(json!({
                    "status": "signed-out", "team": "", "feed": "offline", "spaces": [],
                    "threads": [], "comments": {}, "reason": reason,
                }));
            }
            return Err(failed(
                operation,
                "forum.not_set_up",
                "The hosted forum is not set up on this machine (set CMUX_FORUM_TEAM and CMUX_FORUM_KEY).",
            ));
        }
    };
    let client = &hosted.client;
    match request {
        ForumRequest::Snapshot { space } => {
            let (spaces, threads) = owner.block_on(operation, async {
                let spaces = client.spaces();
                let threads = client.threads(space.as_deref(), StateFilter::All, 1);
                let (spaces, threads) = tokio::join!(spaces, threads);
                Ok((spaces?, threads?))
            })?;
            Ok(json!({
                "status": "ready",
                "team": hosted.team,
                "feed": "live",
                "spaces": spaces.iter().map(|s| json!({
                    "name": s.name,
                    "visibility": visibility(&s.visibility),
                    "threads": s.threads,
                })).collect::<Vec<_>>(),
                "threads": threads.iter().map(thread_json).collect::<Vec<_>>(),
                "comments": {},
            }))
        }
        ForumRequest::Thread { number } => {
            let (thread, comments) = owner.block_on(operation, async {
                let (thread, comments) =
                    tokio::join!(client.thread(number), client.comments(number));
                Ok((thread?, comments?))
            })?;
            Ok(json!({
                "thread": thread_json(&thread),
                "comments": comments.iter().map(|c| comment_json(c, number)).collect::<Vec<_>>(),
            }))
        }
        ForumRequest::Post { space, title, body, kind } => {
            let labels: Vec<String> = kind.into_iter().collect();
            let thread =
                owner.block_on(operation, client.post_thread(&space, &title, &body, &labels))?;
            Ok(json!({"thread": thread_json(&thread)}))
        }
        ForumRequest::Reply { number, body } => {
            let (comment, thread) = owner.block_on(operation, async {
                let comment = client.reply(number, &body).await?;
                let thread = client.thread(number).await?;
                Ok((comment, thread))
            })?;
            Ok(json!({"comment": comment_json(&comment, number), "thread": thread_json(&thread)}))
        }
    }
}

fn visibility(value: &str) -> &'static str {
    match value {
        "public" => "public",
        "shared" => "shared",
        _ => "private",
    }
}

/// An RFC 3339 time in Unix milliseconds; 0 when it does not parse.
fn millis(at: &str) -> i64 {
    time::OffsetDateTime::parse(at, &time::format_description::well_known::Rfc3339)
        .map(|t| (t.unix_timestamp_nanos() / 1_000_000) as i64)
        .unwrap_or(0)
}

fn author_json(author: &Author) -> Value {
    let mut out = Map::new();
    let kind = if author.kind == AuthorKind::Agent { "agent" } else { "person" };
    out.insert("kind".into(), json!(kind));
    out.insert("id".into(), json!(author.id));
    let name = if author.name.is_empty() { &author.id } else { &author.name };
    out.insert("name".into(), json!(name));
    for (key, value) in [
        ("org", &author.org),
        ("on_behalf_of", &author.on_behalf_of),
        ("session", &author.session),
        ("host", &author.host),
    ] {
        if let Some(value) = value {
            out.insert(key.into(), json!(value));
        }
    }
    Value::Object(out)
}

/// A thread in the page's shape: its kind is its first kind label (else a question), the other
/// labels stay labels, and times are Unix milliseconds.
pub(crate) fn thread_json(thread: &Thread) -> Value {
    let kind = thread
        .labels
        .iter()
        .map(|l| l.name.as_str())
        .find(|name| KINDS.contains(name))
        .unwrap_or("question");
    let labels: Vec<&str> =
        thread.labels.iter().map(|l| l.name.as_str()).filter(|name| *name != kind).collect();
    let state = if thread.state == ThreadState::Closed { "closed" } else { "open" };
    json!({
        "number": thread.number,
        "title": thread.title,
        "body": thread.body,
        "state": state,
        "kind": kind,
        "labels": labels,
        "author": author_json(&thread.author),
        "space": thread.space,
        "comments": thread.comments,
        "created_at": millis(&thread.created_at),
        "updated_at": millis(&thread.updated_at),
        "url": thread.html_url,
    })
}

fn comment_json(comment: &Comment, thread: u64) -> Value {
    json!({
        "id": comment.id,
        "thread": if comment.thread == 0 { thread } else { comment.thread },
        "body": comment.body,
        "author": author_json(&comment.author),
        "created_at": millis(&comment.created_at),
    })
}

#[cfg(test)]
#[path = "forum_routed_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "forum_routed_seeded_tests.rs"]
mod seeded_tests;
