//! The data-plane side of a provider: typed op handlers and event sources,
//! offline token checks, and the first-frame `auth` handshake.
//!
//! A page or native peer connects straight to the provider (the router is
//! not on this path), sends `{"t":"auth","token":...}` as its first frame
//! within [`AUTH_DEADLINE`], and then calls ops. A refusal is
//! `{"t":"err","id":0,"code":"cmux.protocol.auth_refused",...}` before any
//! other message, then a close (code 4001 on WebSocket). Every call is
//! checked against the token's namespaces and scopes, then its params are
//! decoded into the op's type, which rejects anything the schema rejects.
//! Ops and events that were not declared are refused.

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::envelope::{AUTH_REPLY_ID, Envelope, Role};
use crate::error::{self, AUTH_REFUSED_CLOSE_CODE, ErrorBody};
use crate::frame::Message;
use crate::op::{Event, Op};
use crate::rpc::{CallFuture, Handler, Peer, SubscribeResult};
use crate::token::{Claims, Verifier};
use crate::transport::Transport;

/// Events queued per subscription before the provider drops and marks a gap.
pub const EVENT_QUEUE: usize = 256;

/// A connection that has not authenticated by then is closed.
pub const AUTH_DEADLINE: Duration = Duration::from_secs(2);

type Route = Box<dyn Fn(Arc<Claims>, Value) -> CallFuture + Send + Sync>;
type Source = Box<dyn Fn(Arc<Claims>, Option<Value>) -> SubscribeResult + Send + Sync>;

struct Entry<T> {
    scope: &'static str,
    run: T,
}

/// A provider's op and event table.
pub struct Provider {
    app_id: String,
    routes: HashMap<&'static str, Entry<Route>>,
    sources: HashMap<&'static str, Entry<Source>>,
}

/// Read the first frame and check it is a valid `auth`. On refusal, send
/// the `err` id 0 and a close, and return the refusal.
pub async fn authenticate<T>(
    transport: &mut Transport,
    verify: impl FnOnce(&str) -> Result<T, String>,
    welcome: impl FnOnce(&T) -> Value,
) -> Result<T, ErrorBody> {
    let first = tokio::time::timeout(AUTH_DEADLINE, transport.rx.recv()).await;
    let outcome = match first {
        Err(_) => Err(("timeout", "no auth frame within 2 s".to_owned())),
        Ok(None | Some(Message::Close(..))) => Err(("closed", "closed before auth".to_owned())),
        Ok(Some(Message::Text(text))) => match Envelope::decode(&text) {
            Ok(Envelope::Auth { token }) => {
                verify(&token).map_err(|reason| ("invalid_token", reason))
            }
            _ => Err(("missing_token", "the first frame must be auth".to_owned())),
        },
        Ok(Some(Message::Binary(_))) => {
            Err(("missing_token", "the first frame must be auth".to_owned()))
        }
    };
    match outcome {
        Ok(claims) => {
            let ok = Envelope::Ok { id: AUTH_REPLY_ID, value: welcome(&claims) };
            if transport.tx.send(Message::Text(ok.encode())).await.is_err() {
                return Err(ErrorBody::new(error::CLOSED, "closed during auth").retryable());
            }
            Ok(claims)
        }
        Err((reason, message)) => {
            let body = ErrorBody::new(error::AUTH_REFUSED, message)
                .with_details(json!({ "reason": reason }));
            let _ = transport
                .tx
                .send(Message::Text(Envelope::error(AUTH_REPLY_ID, body.clone()).encode()))
                .await;
            let _ = transport
                .tx
                .send(Message::Close(AUTH_REFUSED_CLOSE_CODE, "auth refused".into()))
                .await;
            Err(body)
        }
    }
}

/// Canonicalize `path` (resolving `..` and symlinks) and require it inside
/// one of `roots` (decision 20). Returns the canonical path, which the
/// handler then uses. No roots allows no path.
/// The filesystem calls run on tokio's blocking pool, not the async thread.
pub async fn confine(roots: &[String], path: &str) -> Result<String, ErrorBody> {
    let forbidden = |why: &str| ErrorBody::new(error::FORBIDDEN, format!("path {path:?} {why}"));
    if roots.is_empty() {
        return Err(forbidden("is refused: the token names no roots"));
    }
    let requested = std::path::Path::new(path);
    if !requested.is_absolute() {
        return Err(forbidden("is not absolute"));
    }
    let canonical =
        tokio::fs::canonicalize(requested).await.map_err(|_| forbidden("does not resolve"))?;
    let mut inside = false;
    for root in roots {
        let root = tokio::fs::canonicalize(root).await.unwrap_or_else(|_| root.into());
        if canonical.starts_with(root) {
            inside = true;
            break;
        }
    }
    if !inside {
        return Err(forbidden("is outside the token's roots"));
    }
    canonical.into_os_string().into_string().map_err(|_| forbidden("is not UTF-8"))
}

/// Replace each string path param with its confined canonical form.
async fn confine_params(
    roots: &[String],
    names: &[&str],
    mut params: Value,
) -> Result<Value, ErrorBody> {
    for name in names {
        if let Some(slot) = params.get_mut(*name)
            && let Some(path) = slot.as_str()
        {
            *slot = Value::String(confine(roots, path).await?);
        }
    }
    Ok(params)
}

fn refuse(code: &str, message: String) -> CallFuture {
    let body = ErrorBody::new(code, message);
    Box::pin(async move { Err(body) })
}

impl Provider {
    pub fn new(app_id: impl Into<String>) -> Self {
        Self { app_id: app_id.into(), routes: HashMap::new(), sources: HashMap::new() }
    }

    pub fn app_id(&self) -> &str {
        &self.app_id
    }

    /// Serve op `O` with `handler`.
    pub fn handle<O, F, Fut>(&mut self, handler: F)
    where
        O: Op,
        F: Fn(Arc<Claims>, O::Params) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<O::Result, ErrorBody>> + Send + 'static,
    {
        let handler = Arc::new(handler);
        let run: Route = Box::new(move |claims, params| {
            let handler = handler.clone();
            Box::pin(async move {
                let invalid = |e: serde_json::Error| {
                    ErrorBody::new(error::INVALID_PARAMS, format!("params of {}: {e}", O::NAME))
                };
                // Shape first, so a malformed call is invalid_params, not forbidden.
                serde_json::from_value::<O::Params>(params.clone()).map_err(invalid)?;
                let params = confine_params(&claims.roots, O::PATH_PARAMS, params).await?;
                let params: O::Params = serde_json::from_value(params).map_err(invalid)?;
                let result = handler(claims, params).await?;
                serde_json::to_value(result)
                    .map_err(|e| ErrorBody::new(error::INVALID_RESULT, e.to_string()))
            })
        });
        self.routes.insert(O::NAME, Entry { scope: O::SCOPE, run });
    }

    /// Serve event stream `E`: `source` returns a receiver of event data
    /// for one subscription; the subscription ends when it closes.
    pub fn source<E, F>(&mut self, source: F)
    where
        E: Event,
        F: Fn(Arc<Claims>) -> mpsc::Receiver<E::Data> + Send + Sync + 'static,
    {
        let run: Source = Box::new(move |claims, _filter| {
            let mut typed = source(claims);
            let (tx, rx) = mpsc::channel(1);
            tokio::spawn(async move {
                while let Some(data) = typed.recv().await {
                    let Ok(value) = serde_json::to_value(data) else { return };
                    if tx.send(value).await.is_err() {
                        return;
                    }
                }
            });
            Ok(crate::rpc::bounded_events(rx, EVENT_QUEUE))
        });
        self.sources.insert(E::NAME, Entry { scope: E::SCOPE, run });
    }

    /// The ops this provider serves, sorted (sent in hello).
    pub fn op_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.routes.keys().map(|name| (*name).to_owned()).collect();
        names.sort();
        names
    }

    /// Authorize and run one call.
    pub fn dispatch(&self, claims: &Arc<Claims>, op: &str, params: Value) -> CallFuture {
        let Some(entry) = self.routes.get(op) else {
            return refuse(error::UNKNOWN_OP, format!("no handler for {op}"));
        };
        if !claims.allows(op, entry.scope) {
            return refuse(
                error::FORBIDDEN,
                format!("token does not grant {op} (scope {})", entry.scope),
            );
        }
        (entry.run)(claims.clone(), params)
    }

    fn subscribe(
        &self,
        claims: &Arc<Claims>,
        stream: &str,
        filter: Option<Value>,
    ) -> SubscribeResult {
        let Some(entry) = self.sources.get(stream) else {
            return Err(ErrorBody::new(
                error::UNKNOWN_STREAM,
                format!("no event source for {stream}"),
            ));
        };
        if !claims.allows(stream, entry.scope) {
            return Err(ErrorBody::new(error::FORBIDDEN, format!("token does not grant {stream}")));
        }
        (entry.run)(claims.clone(), filter)
    }

    /// Run the auth handshake on `transport` (an accepted connection), then
    /// serve it until it closes. `origin` is the connection's normalized
    /// `Origin` header (`None` for a native peer).
    pub async fn serve(
        self: Arc<Self>,
        mut transport: Transport,
        verifier: &Verifier,
        origin: Option<String>,
    ) -> Result<Claims, ErrorBody> {
        let provider_id = self.app_id.clone();
        let claims = authenticate(
            &mut transport,
            |token| verifier.verify(token, crate::token::now(), origin.as_deref()).map_err(|problem| problem.to_string()),
            |claims: &Claims| json!({ "sub": claims.sub, "app": claims.app, "exp": claims.exp, "provider": provider_id }),
        )
        .await?;
        let handler = Arc::new(Authorized { provider: self, claims: Arc::new(claims.clone()) });
        let (_peer, task) = Peer::start(transport, Role::Accepting, handler);
        let _ = task.await;
        Ok(claims)
    }
}

struct Authorized {
    provider: Arc<Provider>,
    claims: Arc<Claims>,
}

impl Authorized {
    fn expired(&self) -> Option<ErrorBody> {
        (self.claims.exp <= crate::token::now()).then(|| {
            ErrorBody::new(error::TOKEN_EXPIRED, "token expired; refresh it and reconnect")
                .retryable()
        })
    }
}

impl Handler for Authorized {
    fn call(&self, op: String, params: Value) -> CallFuture {
        if let Some(expired) = self.expired() {
            return Box::pin(async move { Err(expired) });
        }
        self.provider.dispatch(&self.claims, &op, params)
    }

    fn subscribe(&self, stream: String, filter: Option<Value>) -> SubscribeResult {
        if let Some(expired) = self.expired() {
            return Err(expired);
        }
        self.provider.subscribe(&self.claims, &stream, filter)
    }
}
