//! Sandboxed Runs that classic Cloud runs (`/api/runs`, hq#3367), where the cmux app opens no
//! chat for them:
//!
//! - an incognito send's Run (#39022 review at 946e940e, F1). A daemon Run is a Cloud chat the
//!   app opens in the machine's workspace, an ordinary one that shows the prompt and the reply
//!   outside the incognito window and keeps them in its chat history; classic Cloud runs the task
//!   on its own VM and answers only the receipt, as every sandboxed send did before the daemon ran
//!   Runs. An incognito create without the app's classic session is refused: it never falls back
//!   to a daemon Run.
//! - a Run a person made before the daemon ran Runs, drained to its end after an upgrade: the app
//!   keeps following it from its saved list, and a Run the daemon never made is classic Cloud's.

use std::time::Duration;

use reqwest::Method;
use serde_json::{Map, Value};

use super::http::{Auth, Http};
use super::{Failure, Request, optional_int, optional_text, text};

/// The server holds one wait this long at most.
const WAIT_LIMIT_MS: i64 = 10_000;

/// Whether `call` is an incognito send's create (`runs.create` with `incognito: true`), which
/// classic Cloud runs ([`drain`]), never the daemon.
pub fn is_incognito_create(call: &str, args: &Map<String, Value>) -> bool {
    call == "runs.create" && args.get("incognito").and_then(Value::as_bool) == Some(true)
}

/// An incognito send's `runs.create`, or `runs.wait` or `runs.cancel` for a Run the daemon does
/// not know, sent to classic Cloud: the app's classic API (`args.classicApi`) and team
/// (`args.classicTeam`, the Run's), with the Stack session the request carries (`credential` and
/// `refresh`). A request without them sends nothing: a wait or cancel finds no classic Run of the
/// app's there, and an incognito create is refused rather than started as an ordinary chat.
pub async fn drain(request: &Request) -> Result<Value, Failure> {
    let api = optional_text(&request.args, "classicApi").filter(|api| !api.is_empty());
    let (Some(api), Some(_)) = (api, request.refresh.as_deref().filter(|r| !r.is_empty())) else {
        if request.call == "runs.create" {
            return Err(Failure::http(
                409,
                Some("run_incognito_unavailable".into()),
                Some("an incognito Run needs the cmux app's Cloud session".into()),
            ));
        }
        return Err(Failure::http(
            404,
            Some("run_not_found".into()),
            Some("no such Run on this Mac".into()),
        ));
    };
    let team = optional_text(&request.args, "classicTeam").filter(|t| !t.is_empty());
    let http = Http::new(&Request {
        auth: Auth::Stack,
        api: api.to_owned(),
        team: team.map(str::to_owned),
        ..request.clone()
    })?;
    match request.call.as_str() {
        "runs.create" if is_incognito_create(&request.call, &request.args) => {
            create(&http, &request.args).await
        }
        "runs.wait" => wait(&http, &request.args).await,
        "runs.cancel" => cancel(&http, &request.args).await,
        other => Err(Failure::Transport(format!("{other} is never sent to classic Cloud"))),
    }
}

/// `POST /api/runs` (`environment: sandboxed`): the task on classic Cloud's own VM. The send's
/// idempotency key makes a retry after a lost answer return the same Run, never a second one.
async fn create(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let mut body = Map::new();
    body.insert("environment".into(), Value::from("sandboxed"));
    body.insert("task".into(), Value::from(text(args, "task")?));
    for name in ["agent", "image"] {
        if let Some(value) = optional_text(args, name).filter(|value| !value.is_empty()) {
            body.insert(name.into(), Value::from(value));
        }
    }
    if let Some(timeout) = optional_int(args, "timeoutMs") {
        body.insert("timeoutMs".into(), Value::from(timeout));
    }
    let key = optional_text(args, "idempotencyKey").filter(|key| !key.is_empty());
    let sent = (Some(Value::Object(body)), key);
    http.classic(Method::POST, &["api", "runs"], &[], sent, Duration::from_secs(20)).await
}

/// `GET /api/runs/:id/wait?timeoutMs=`: the snapshot once the Run is terminal or after the wait
/// (at most 10 s), with its receipt when it has one.
async fn wait(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "id")?;
    let held = optional_int(args, "timeoutMs").unwrap_or(WAIT_LIMIT_MS).clamp(0, WAIT_LIMIT_MS);
    let query = [("timeoutMs", held.to_string())];
    let bound = Duration::from_millis(u64::try_from(held).unwrap_or(0).saturating_add(10_000));
    http.classic(Method::GET, &["api", "runs", id, "wait"], &query, (None, None), bound).await
}

/// `POST /api/runs/:id/cancel`: the server destroys the Run's VM before it answers.
async fn cancel(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "id")?;
    let bound = Duration::from_secs(60);
    http.classic(Method::POST, &["api", "runs", id, "cancel"], &[], (None, None), bound).await
}
