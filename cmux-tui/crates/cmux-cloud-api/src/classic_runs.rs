//! The classic sandboxed Runs a person made before the daemon ran Runs (`/api/runs`, hq#3367),
//! drained to their end after an upgrade: the app keeps following them from its saved list, and
//! a Run the daemon never made is classic Cloud's. Only a wait and a cancel, never a create: a
//! new Run is the daemon's own ([`crate::sandbox`]).

use std::time::Duration;

use reqwest::Method;
use serde_json::{Map, Value};

use super::http::{Auth, Http};
use super::{Failure, Request, optional_int, optional_text, text};

/// The server holds one wait this long at most.
const WAIT_LIMIT_MS: i64 = 10_000;

/// `runs.wait` or `runs.cancel` for a Run the daemon does not know, sent to classic Cloud: the
/// app's classic API (`args.classicApi`) and team (`args.classicTeam`, the Run's), with the Stack
/// session the request carries (`credential` and `refresh`). A request without them sends
/// nothing: no classic Run is the app's to drain there.
pub async fn drain(request: &Request) -> Result<Value, Failure> {
    let api = optional_text(&request.args, "classicApi").filter(|api| !api.is_empty());
    let (Some(api), Some(_)) = (api, request.refresh.as_deref().filter(|r| !r.is_empty())) else {
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
        "runs.wait" => wait(&http, &request.args).await,
        "runs.cancel" => cancel(&http, &request.args).await,
        other => Err(Failure::Transport(format!("{other} is never sent to classic Cloud"))),
    }
}

/// `GET /api/runs/:id/wait?timeoutMs=`: the snapshot once the Run is terminal or after the wait
/// (at most 10 s), with its receipt when it has one.
async fn wait(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "id")?;
    let held = optional_int(args, "timeoutMs").unwrap_or(WAIT_LIMIT_MS).clamp(0, WAIT_LIMIT_MS);
    let query = [("timeoutMs", held.to_string())];
    let bound = Duration::from_millis(u64::try_from(held).unwrap_or(0).saturating_add(10_000));
    http.classic(Method::GET, &["api", "runs", id, "wait"], &query, bound).await
}

/// `POST /api/runs/:id/cancel`: the server destroys the Run's VM before it answers.
async fn cancel(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "id")?;
    http.classic(Method::POST, &["api", "runs", id, "cancel"], &[], Duration::from_secs(60)).await
}
