//! `cmux browser right <verb> …`: page commands for the browser in the column
//! right of the Home chat, the one every Chief, local or cloud, shows and
//! drives pages in (plans/cmux-next/chief-browser-use-DESIGN.md). The app
//! picks the tab (`browser.page.right`: the agent's own tab there, else the
//! shown browser tab, else a new one there, never in the dock or with focus,
//! and never a tab another agent holds); the verb then runs on that tab like
//! `cmux browser <tab_…> <verb>`. The CLI names the verb, because only reads
//! may run on the person's shown tab; `--take` (only when the person handed
//! that tab over) lets a write run there too
//! (plans/cmux-next/agent-browser-passkey-DESIGN.md). `cmux browser right
//! release` gives the agent's tabs back.

use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::page::{agent_from_env, parse_page, take_agent};
use super::{AppCommand, GlobalArgs, READ_TIMEOUT, Ran, UsageError, call};

/// The app gives an open of a new tab 20 s; the CLI waits that plus a margin.
const RIGHT_TIMEOUT: Duration = Duration::from_secs(25);

pub(super) fn parse(args: &[String]) -> Result<AppCommand, UsageError> {
    let usage = || UsageError::new(crate::localization::catalog().app_control.browser_page_usage);
    let take = args.iter().any(|arg| arg == "--take");
    let args: Vec<String> = args.iter().filter(|arg| *arg != "--take").cloned().collect();
    let args = args.as_slice();
    let (words, agent) = take_agent(args).ok_or_else(usage)?;
    let agent = agent.or_else(|| agent_from_env(|key| std::env::var(key).ok()));
    let mut params = Map::new();
    if let Some(agent) = &agent {
        params.insert("agent".into(), json!(agent));
    }
    if words.len() == 1 && words[0] == "release" {
        params.insert("release".into(), json!(true));
        return Ok(AppCommand::Call {
            method: "browser.page.right",
            params: Value::Object(params),
            timeout: Some(READ_TIMEOUT),
            pick: None,
        });
    }
    // The verb as on the focused tab (`page`); run() names the tab.
    let then = parse_page("page", args)?;
    let verb = match &then {
        AppCommand::Call { method, .. } => Some(*method),
        AppCommand::Screenshot { .. } => Some("browser.page.screenshot"),
        _ => None,
    };
    if let Some(verb) = verb {
        params.insert("verb".into(), json!(verb));
    }
    if take {
        params.insert("take".into(), json!(true));
    }
    if let AppCommand::Call { method: "browser.page.navigate", params: inner, .. } = &then
        && let Some(url) = inner.get("url")
    {
        params.insert("url".into(), url.clone());
    }
    Ok(AppCommand::Right { params: Value::Object(params), then: Box::new(then) })
}

/// Asks the app for the tab, then runs `then` on it. A navigation the app
/// already made (a new tab opened with the URL) is not loaded twice.
pub(super) fn run(
    global: &GlobalArgs,
    stream: &mut UnixStream,
    params: Value,
    then: AppCommand,
) -> Ran {
    let response = match super::wait::request(
        global,
        stream,
        "browser.page.right",
        &params,
        Some(RIGHT_TIMEOUT),
    ) {
        Ok(response) => response,
        Err(error) => {
            return Ran::Done(super::super::wire::print_local_error(&error, global.output, 3));
        }
    };
    let resolved = match response {
        Ok(resolved) => resolved,
        Err(error) => {
            return Ran::Done(super::super::wire::print_local_error(&error, global.output, 1));
        }
    };
    let Some(tab) = resolved.get("tab").and_then(Value::as_str).map(str::to_owned) else {
        return Ran::Done(super::super::wire::print_local_success(&resolved, global.output));
    };
    let navigated = resolved.get("navigated") == Some(&Value::Bool(true));
    let mut then = then;
    match &mut then {
        AppCommand::Call { method: "browser.page.navigate", .. } if navigated => {
            return Ran::Done(super::super::wire::print_local_success(&resolved, global.output));
        }
        AppCommand::Call { params, .. } | AppCommand::Screenshot { params, .. } => {
            if let Some(params) = params.as_object_mut() {
                params.insert("tab".into(), json!(tab));
            }
        }
        _ => {}
    }
    call(global, stream, then)
}
