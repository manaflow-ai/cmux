//! The daemon requests `agent start`, `agent resume`, `terminal <t> resume`,
//! `terminal <t> wait --until ready` and the agent-name rewrite send.
//!
//! [`Daemon`] is the one seam: the CLI sends each request over the session
//! socket ([`CliDaemon`], `wire::fetch`), and tests answer with a fake.

use serde_json::{Value, json};

use super::super::command::RequestPlan;
use super::super::{GlobalArgs, wire};
use super::{Failure, plan};

/// A daemon request that failed: the daemon's (or the transport's) error.
#[derive(Debug)]
pub(in crate::cli) struct CallFailure {
    pub error: Value,
}

/// Sends one request and returns its result.
pub(in crate::cli) trait Daemon {
    /// Sends `plan`. `session` is reserved for a request to another session
    /// than the command's own; the flows here always pass `None`.
    fn request(&self, session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure>;
}

/// The daemon of the command's own route (`--socket`, `--session`, the
/// caller's session).
pub(in crate::cli) struct CliDaemon {
    pub global: GlobalArgs,
}

impl Daemon for CliDaemon {
    fn request(&self, _session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        wire::fetch(&self.global, plan).map_err(|error| CallFailure { error })
    }
}

/// The session's `session.snapshot`.
pub(in crate::cli) fn snapshot<D: Daemon + ?Sized>(daemon: &D) -> Result<Value, Failure> {
    Ok(daemon.request(None, plan(&["session", "current", "snapshot"])?)?)
}

/// The terminal id that `current` or `focused` names, from the daemon (its
/// selector rules say what `current` means); any other selector as it is.
pub(in crate::cli) fn terminal_keyword<D: Daemon + ?Sized>(
    daemon: &D,
    selector: &str,
) -> Result<String, Failure> {
    if !matches!(selector, "current" | "focused") {
        return Ok(selector.to_owned());
    }
    let terminal = daemon.request(None, plan(&["terminal", selector, "show"])?)?;
    terminal["id"].as_str().map(str::to_owned).ok_or_else(|| {
        Failure::local(
            "selector.not_found",
            format!("no terminal is {selector:?}"),
            json!({"target": selector}),
            1,
        )
    })
}

/// The terminal record `target` names: a `term_` id or unique prefix, a
/// `tab_` id it shows in, an exact title, or (when no title matches) an
/// agent name or unique tab name (agent_names.rs). `current` and `focused`
/// go through [`terminal_keyword`] first.
pub(in crate::cli) fn find_terminal<'a>(
    snapshot: &'a Value,
    target: &str,
) -> Result<&'a Value, Failure> {
    use super::super::agent_names::{Found, resolve};
    let terminals = snapshot["terminals"].as_array().map(Vec::as_slice).unwrap_or_default();
    let target = target.strip_prefix("name:").unwrap_or(target);
    let exact = terminals.iter().find(|terminal| {
        terminal["id"] == target
            || terminal["tab_id"] == target
            || terminal["tab_ids"].as_array().is_some_and(|tabs| tabs.iter().any(|t| t == target))
    });
    if let Some(found) = exact {
        return Ok(found);
    }
    let matches: Vec<&Value> = if target.starts_with("term_") {
        terminals
            .iter()
            .filter(|terminal| terminal["id"].as_str().is_some_and(|id| id.starts_with(target)))
            .collect()
    } else {
        terminals.iter().filter(|terminal| terminal["title"] == target).collect()
    };
    // An agent name (or a unique tab name) only where no title matches, so a
    // title that selected a terminal before still selects it.
    if matches.is_empty() && !target.starts_with("term_") {
        match resolve(snapshot, target) {
            Found::One(place) => {
                if let Some(found) =
                    terminals.iter().find(|terminal| terminal["id"] == place.terminal)
                {
                    return Ok(found);
                }
            }
            Found::Ambiguous(tabs) => {
                return Err(Failure::local(
                    "selector.ambiguous",
                    format!("{} tabs are named {target:?}; name one by its id", tabs.len()),
                    json!({"target": target, "candidates": tabs}),
                    1,
                ));
            }
            Found::Missing => {}
        }
    }
    match matches.as_slice() {
        [one] => Ok(one),
        [] => Err(Failure::local(
            "selector.not_found",
            format!("no terminal is {target:?}"),
            json!({"target": target}),
            1,
        )),
        many => Err(Failure::local(
            "selector.ambiguous",
            format!("{} terminals match {target:?}; name one by its term_ id", many.len()),
            json!({"target": target, "terminals": many.iter().map(|t| &t["id"]).collect::<Vec<_>>()}),
            1,
        )),
    }
}
