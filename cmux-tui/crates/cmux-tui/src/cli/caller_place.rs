//! `current` in a CLI command means the caller's own place, as it does in
//! an MCP call ([`super::caller_scope`]): an agent that ran `cmux pane
//! current split` or `cmux tab create terminal` split or opened a tab in the
//! workspace the person looked at, because the daemon reads `current` as
//! its active object (https://github.com/manaflow-ai/cmux/issues/25590).
//!
//! The caller is found from its environment, on the request's own
//! connection before the request is sent:
//! - an agent chat (`CMUX_AGENT_SESSION`, or a Chief turn's
//!   `CMUX_CALLER_HOME_CHAT`): the app's `system.identify` answer, which
//!   fails closed when the app cannot place the chat;
//! - a terminal (`CMUX_TUI_TERMINAL_ID`): the tab, pane, screen and
//!   workspace that hold it, read from the daemon.
//!
//! `focused` is the object the person looks at, from the app's focus;
//! without an app it is the daemon's active object. A command routed to
//! another session (`--socket`, `--session`) keeps the daemon's meaning.

use std::io::BufReader;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::GlobalArgs;
use super::caller_scope;
use super::command::{RequestPlan, WireOperation};
use super::resolve::{Failure, SocketRoute};

type Reader = BufReader<Box<dyn transport::Stream>>;

/// What the CLI's environment says about who runs it.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Caller {
    /// An agent chat or Chief turn the app places.
    pub(super) agent: bool,
    /// The caller's own terminal.
    pub(super) terminal: Option<String>,
}

impl Caller {
    pub(super) fn from_env(env: impl Fn(&str) -> Option<String>) -> Self {
        let set = |key: &str| env(key).filter(|value| !value.is_empty());
        Self {
            agent: set("CMUX_AGENT_SESSION").is_some()
                || set("CMUX_CALLER_HOME_CHAT").as_deref() == Some("1"),
            terminal: set("CMUX_TUI_TERMINAL_ID"),
        }
    }
}

/// Which part of [`apply`] runs. The CLI rewrites the selectors once,
/// before any request leaves; a browser tab no app opened gets its place
/// after the app path, and only that, because the first pass's `current`
/// already means the daemon's active object there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Pass {
    /// `current` and `focused`, and a terminal tab with no place.
    Selectors,
    /// A browser tab with no place that no app opened.
    DaemonBrowser,
}

/// The parent selectors a creation with no place gets from a terminal
/// caller in `pass`, so the new tab opens in the caller's pane rather than
/// the daemon's active one. An agent chat's creations go beside its chat
/// instead (beside.rs, the app's `openBrowser`), and a browser tab in a
/// session an app owns opens next to the caller's tab through the app
/// (frontend_browser.rs).
pub(super) fn no_place_parents(operation: &WireOperation, pass: Pass) -> &'static [&'static str] {
    match (operation, pass) {
        (WireOperation::Typed(ResourceOperation::TabCreateTerminal), Pass::Selectors)
        | (WireOperation::Typed(ResourceOperation::TabCreateBrowser), Pass::DaemonBrowser) => {
            &["workspace", "screen", "pane"]
        }
        _ => &[],
    }
}

/// Fills `current` for each of `parents` when `params` names no place, so
/// [`caller_scope::apply`] puts the caller's ids there; whether it did.
pub(super) fn fill_no_place(params: &mut Map<String, Value>, parents: &[&str]) -> bool {
    if parents.is_empty() || !super::beside::names_no_place(params) {
        return false;
    }
    for parent in parents {
        params.insert((*parent).into(), json!("current"));
    }
    true
}

/// Rewrites the `current` and `focused` selectors of `plan` and fills the
/// place of a terminal caller's creation that names none, as `pass` says.
/// `Ok(true)` when the params changed and the request must be encoded
/// again.
pub(super) fn apply(
    global: &GlobalArgs,
    plan: &mut RequestPlan,
    reader: &mut Reader,
    caller_route: bool,
    socket: &SocketRoute<'_>,
    pass: Pass,
) -> Result<bool, Failure> {
    let caller = Caller::from_env(|key| std::env::var(key).ok());
    let parents = no_place_parents(&plan.operation, pass);
    let Some(params) = plan.params.as_object_mut() else { return Ok(false) };
    let caller_route = caller_route && machine_is_local(params);
    let app = app_owns(global, socket);
    let terminal_caller = caller_route && !caller.agent && caller.terminal.is_some();
    if pass == Pass::DaemonBrowser {
        if !terminal_caller || !fill_no_place(params, parents) {
            return Ok(false);
        }
        // A terminal the daemon no longer shows keeps the daemon's default.
        let place = caller_place(reader, socket, &caller, params, app.then_some(global)).ok().flatten();
        caller_scope::apply(params, place.as_ref(), None);
        return Ok(true);
    }
    if !caller_route {
        // Another session: neither the caller nor the app's focus is there.
        if !caller_scope::wants_focus(params) {
            return Ok(false);
        }
        caller_scope::apply(params, None, None);
        return Ok(true);
    }
    // A place the command did not name: a caller the daemon no longer shows
    // (a script that outlived its tab) keeps the daemon's default, as before.
    let filled = terminal_caller && fill_no_place(params, parents);
    let wants_caller = caller_scope::wants_caller(params);
    let wants_focus = caller_scope::wants_focus(params);
    if !wants_caller && !wants_focus {
        return Ok(false);
    }
    let place = match outermost(params) {
        // `current` at the top is the caller's place: no answer, no guess.
        Some(CURRENT) if !filled => caller_place(reader, socket, &caller, params, app.then_some(global))?,
        // Below `focused` every level is the person's.
        Some(FOCUSED) => None,
        // Under an id, `current` is the caller's only inside its own
        // place; a caller that cannot be found keeps the daemon's.
        Some(_) if wants_caller => {
            caller_place(reader, socket, &caller, params, app.then_some(global)).ok().flatten()
        }
        _ => None,
    };
    let focus = if wants_focus && app { app_focus(global) } else { None };
    caller_scope::apply(params, place.as_ref(), focus.as_ref());
    Ok(true)
}

const CURRENT: &str = "current";
const FOCUSED: &str = "focused";

/// Whether the request goes to this machine's daemon: another machine's
/// knows neither the caller's terminal nor the app's ids.
pub(super) fn machine_is_local(params: &Map<String, Value>) -> bool {
    params.get("machine").is_none_or(|machine| machine.as_str() == Some(CURRENT))
}

/// Whether the app this CLI reaches owns the request's daemon, so its
/// `system.identify` and focus name that daemon's objects. A Cloud Chief
/// turn reaches the person's Mac app through a relay while its daemon is
/// the VM's: the Mac's ids mean nothing there.
pub(super) fn app_owns(global: &GlobalArgs, socket: &SocketRoute<'_>) -> bool {
    global.app_socket.is_some() || super::frontend_browser::app_daemon_is(socket.path)
}

/// The outermost structural selector `params` names.
fn outermost(params: &Map<String, Value>) -> Option<&str> {
    ["workspace", "screen", "pane", "tab"]
        .into_iter()
        .find_map(|level| params.get(level).and_then(Value::as_str))
}

/// The caller's own workspace, screen, pane and tab; `None` when the
/// environment names no caller (a shell outside cmux), which keeps the
/// daemon's `current`. `app` is the CLI's globals when the app it reaches
/// owns the daemon ([`app_owns`]); an agent chat is placed only by that app.
fn caller_place(
    reader: &mut Reader,
    socket: &SocketRoute<'_>,
    caller: &Caller,
    params: &Map<String, Value>,
    app: Option<&GlobalArgs>,
) -> Result<Option<Value>, Failure> {
    if caller.agent
        && let Some(global) = app
    {
        match app_identity(global) {
            Ok(identity) => {
                let place = identity.get("caller").cloned().unwrap_or(Value::Null);
                if caller_scope::is_placed(&place) {
                    return Ok(Some(place));
                }
                // An agent in a terminal the app does not know as a chat.
                if caller.terminal.is_none() {
                    return Err(Failure::Resource(caller_scope::unresolved(
                        "the app does not know this chat",
                    )));
                }
            }
            Err(message) if caller.terminal.is_none() => {
                return Err(Failure::Resource(caller_scope::unresolved(&message)));
            }
            Err(_) => {}
        }
    }
    let Some(terminal) = caller.terminal.as_deref() else { return Ok(None) };
    let route = super::resolve::route(params);
    super::resolve::registered_caller_place(reader, &route, terminal, socket)
        .map(|place| Some(Value::Object(place)))
}

/// The app's `system.identify` answer for this caller (the request carries
/// the caller from the environment, app.rs `with_caller`).
fn app_identity(global: &GlobalArgs) -> Result<Value, String> {
    let socket = super::app::socket_path(global)?;
    let mut app = super::app::connect(&socket)?;
    super::app::request(&mut app, "system.identify", json!({}), super::app::READ_TIMEOUT)?
        .map_err(|error| error["message"].as_str().unwrap_or("no answer").to_owned())
}

/// What the person looks at: the app's focus from `snapshot.get`; `None`
/// without an app, which leaves the daemon's active object.
fn app_focus(global: &GlobalArgs) -> Option<Value> {
    let socket = super::app::socket_path(global).ok()?;
    let mut app = super::app::connect(&socket).ok()?;
    let snapshot =
        super::app::request(&mut app, "snapshot.get", json!({}), super::app::READ_TIMEOUT)
            .ok()?
            .ok()?;
    snapshot.get("topology").and_then(|topology| topology.get("focus")).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_environment_names_the_caller() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |key: &str| {
                pairs.iter().find(|(name, _)| *name == key).map(|(_, value)| (*value).to_owned())
            }
        };
        assert_eq!(Caller::from_env(env(&[])), Caller::default());
        assert_eq!(
            Caller::from_env(env(&[("CMUX_TUI_TERMINAL_ID", "term_a")])),
            Caller { agent: false, terminal: Some("term_a".into()) }
        );
        assert!(Caller::from_env(env(&[("CMUX_AGENT_SESSION", "s")])).agent);
        assert!(Caller::from_env(env(&[("CMUX_CALLER_HOME_CHAT", "1")])).agent);
        assert!(!Caller::from_env(env(&[("CMUX_AGENT_SESSION", "")])).agent);
    }

    #[test]
    fn a_creation_with_no_place_gets_current_parents_and_a_named_one_keeps_its_own() {
        let terminal = WireOperation::Typed(ResourceOperation::TabCreateTerminal);
        let mut params = json!({"machine": "current", "session": "current"})
            .as_object()
            .cloned()
            .unwrap_or_default();
        assert!(fill_no_place(&mut params, no_place_parents(&terminal, Pass::Selectors)));
        assert_eq!(params["workspace"], "current");
        assert_eq!(params["pane"], "current");

        let mut named = json!({"pane": "pane_x"}).as_object().cloned().unwrap_or_default();
        assert!(!fill_no_place(&mut named, no_place_parents(&terminal, Pass::Selectors)));
        assert!(named.get("workspace").is_none());

        let browser = WireOperation::Typed(ResourceOperation::TabCreateBrowser);
        assert!(no_place_parents(&browser, Pass::Selectors).is_empty());
        assert_eq!(no_place_parents(&browser, Pass::DaemonBrowser).len(), 3);
        assert!(no_place_parents(&terminal, Pass::DaemonBrowser).is_empty());
        let split = WireOperation::Typed(ResourceOperation::PaneSplit);
        assert!(no_place_parents(&split, Pass::Selectors).is_empty());
    }
}
