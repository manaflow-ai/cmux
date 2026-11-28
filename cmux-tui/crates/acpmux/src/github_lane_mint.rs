//! The asker `cmux github` (git's credential helper, the `gh` shim) and `acpmux github-mcp` use
//! on a machine the person added from their Mac (remote-integrations slice 2,
//! `cmux_host::github_cli_lane`): one `token` action (`github_broker.rs`) over this agent
//! session's acpmux socket, proved by the session's caller token; the daemon asks the Mac that
//! lends this machine GitHub (`server/github_lane.rs`).
//!
//! The token lives in this process's memory only: never written, never logged, never in argv.

use std::time::Duration;

use cmux_host::cloud::github::TokenAsk;
use cmux_host::github_cli::{Minted, Refused, refused};
use serde_json::Value;

use crate::github_broker::{GithubAction, GithubActionParams, LANE_WAIT, installation_token};
use crate::rpc::RpcError;

/// The hidden argument that runs `cmux github` in acpmux (`cli/entry.rs`).
pub const CLI_ARG: &str = "__github";

/// How long the ask waits for the daemon: the lane's own wait for the Mac, and a few seconds to
/// connect.
const WAIT: Duration = Duration::from_secs(LANE_WAIT.as_secs() + 10);

/// The request one ask becomes.
pub fn request_for(ask: &TokenAsk) -> GithubActionParams {
    GithubActionParams {
        session_id: None,
        action: GithubAction::Token,
        repo: ask.repo.clone(),
        branch: None,
        base: None,
        issue: None,
        title: None,
        body: None,
        permissions: Some(ask.permissions.clone()),
        deadline_ms: None,
    }
}

/// [`cmux_host::github_cli_lane::LaneSource`]: None outside an acpmux agent session (no caller
/// token, or no daemon socket), so the ask keeps its `vm.agent_unreachable`.
pub fn ask(ask: &TokenAsk) -> Option<Result<Minted, Refused>> {
    let in_session =
        std::env::var_os(crate::person_tokens::CALLER_TOKEN_ENV).is_some_and(|v| !v.is_empty());
    let socket = crate::config::socket_path();
    if !in_session || !socket.exists() {
        return None;
    }
    let request = request_for(ask);
    if let Err(e) = crate::github_broker::validate(&request) {
        return Some(Err(refused("github.invalid", e.message)));
    }
    let params = serde_json::to_value(&request).ok()?;
    // Its own (scoped) thread and runtime: the callers are sync, and one (GitHub MCP) runs on a
    // blocking thread of a runtime, where another runtime cannot start. The timeout is inside, so
    // the scope joins within WAIT.
    let reply = std::thread::scope(|s| {
        s.spawn(move || -> Option<anyhow::Result<Value>> {
            let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                Ok(runtime) => runtime,
                Err(e) => return Some(Err(e.into())),
            };
            runtime.block_on(async move {
                tokio::time::timeout(WAIT, async move {
                    let client = crate::client::Client::connect(&socket).await?;
                    client.request(crate::rpc::method::MUX_GITHUB_ACTION, params).await
                })
                .await
                .ok()
            })
        })
        .join()
    });
    let Ok(Some(reply)) = reply else {
        return Some(Err(refused(
            "vm.agent_unreachable",
            format!("this machine's acpmux did not answer within {}s", WAIT.as_secs()),
        )));
    };
    Some(match reply {
        Ok(v) => minted(&v),
        Err(e) => match e.downcast_ref::<crate::client::DaemonError>() {
            Some(daemon) => Err(refusal(&daemon.0)),
            None => Err(refused("vm.agent_unreachable", "this machine's acpmux is not running")),
        },
    })
}

/// The token of the daemon's answer, when it is an App installation token.
pub fn minted(reply: &Value) -> Result<Minted, Refused> {
    match reply.get("token").and_then(Value::as_str) {
        Some(token) if installation_token(token) => Ok(Minted { token: token.to_owned() }),
        _ => Err(refused("vm.agent_bad_answer", "no GitHub App token in the answer")),
    }
}

/// The codes `cmux github` explains (`github_cli::Refused::explain`) for the daemon's error:
/// cmux Cloud's code when the Mac's mint failed on one, else the broker's reason. Only these
/// fixed words go on, with every token cut out of the message.
pub fn refusal(e: &RpcError) -> Refused {
    let data = e.data.as_ref();
    let field = |k: &str| data.and_then(|d| d.get(k)).and_then(Value::as_str);
    let code = match (field("code"), field("reason")) {
        (
            Some(c @ ("integration.not_found" | "needs_reauth" | "policy.denied" | "rate_limited")),
            _,
        ) => c,
        (Some("unreachable"), _) => "integration.unavailable",
        (_, Some("github.not_connected")) => "github.not_connected",
        (_, Some("github.busy")) => "busy",
        (_, Some(r @ ("github.no_owner" | "github.denied" | "github.expired"))) => r,
        (Some(c @ ("build_space" | "invalid_reply" | "lease_changed")), _) => c,
        _ => "github.app_token",
    };
    refused(code, crate::github_broker::redact_github_tokens(&e.message))
}

#[cfg(test)]
#[path = "github_lane_mint_tests.rs"]
mod tests;
