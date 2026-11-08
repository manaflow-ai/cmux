#![allow(dead_code)] // Red stub: no pane move yet; the fix adds the `tab.move` composite.
//! `cmux pane <pane> move`: move a whole pane to another place.

use serde_json::{Value, json};

use super::command::RequestPlan;
use super::{GlobalArgs, UsageError, wire};

/// Where `pane move` puts the pane.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Destination {
    /// The end of this pane, or a new pane split off it in `split`'s direction.
    Pane { pane: String, split: Option<String> },
    /// The pane that shows this tab, after the tab.
    Tab(String),
    /// A new screen in this workspace; `None` is the pane's own workspace.
    NewScreen { workspace: Option<String> },
}

/// `pane <pane> move`, parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct MoveRequest {
    pub pane: String,
    pub destination: Destination,
    /// The new screen's name (`--to-workspace`, `--new-screen`).
    pub name: Option<String>,
    /// `--focus`: focus the destination pane instead of keeping the focus.
    pub focus: bool,
    /// `--idempotency-key`: the command's key, from which each step's key
    /// derives; `None` makes a new random one.
    pub idempotency_key: Option<String>,
    /// The caller's own terminal (`CMUX_TUI_TERMINAL_ID`), which `current`
    /// and `caller` selectors name; `None` outside cmux or when routed.
    pub caller_terminal: Option<String>,
}

/// The flags of `pane <pane> move`, as `command.rs` read them.
#[derive(Debug, Default)]
pub(super) struct MoveFlags {
    pub to_pane: Option<String>,
    pub to_tab: Option<String>,
    pub to_workspace: Option<String>,
    pub split: Option<String>,
    pub name: Option<String>,
    pub new_screen: bool,
    pub focus: bool,
    pub idempotency_key: Option<String>,
}

const USAGE: &str = "pane move takes one of --to-pane <pane> [--split right|down|left|up], \
                     --to-tab <tab>, --to-workspace <ws> or --new-screen (--new-tab), and \
                     --name <screen name> and --focus";

/// Checks `flags` for `pane <target> move` and makes the request.
pub(super) fn request(target: &str, flags: MoveFlags) -> Result<MoveRequest, UsageError> {
    let MoveFlags {
        to_pane,
        to_tab,
        to_workspace,
        split,
        name,
        new_screen,
        focus,
        idempotency_key,
    } = flags;
    for (flag, value) in [
        ("--to-pane", &to_pane),
        ("--to-tab", &to_tab),
        ("--to-workspace", &to_workspace),
        ("--split", &split),
        ("--name", &name),
    ] {
        if value.as_deref() == Some("") {
            return Err(UsageError::new(format!("{flag} needs a value")));
        }
    }
    if let Some(direction) = &split
        && !matches!(direction.as_str(), "right" | "down" | "left" | "up")
    {
        return Err(UsageError::new(format!(
            "--split takes right, down, left or up, not {direction:?}"
        )));
    }
    let chosen = [to_pane.is_some(), to_tab.is_some(), to_workspace.is_some(), new_screen];
    if chosen.iter().filter(|chosen| **chosen).count() != 1 {
        return Err(UsageError::new(format!("{USAGE}: give exactly one destination")));
    }
    if split.is_some() && to_pane.is_none() {
        return Err(UsageError::new("--split goes with --to-pane <pane>"));
    }
    let destination = match (to_pane, to_tab) {
        (Some(pane), _) => Destination::Pane { pane, split },
        (_, Some(tab)) => Destination::Tab(tab),
        _ => Destination::NewScreen { workspace: to_workspace },
    };
    if name.is_some() && !matches!(destination, Destination::NewScreen { .. }) {
        return Err(UsageError::new(
            "--name names a new screen: it goes with --to-workspace or --new-screen",
        ));
    }
    if let Some(key) = &idempotency_key {
        cmux_tui_core::resource::validate_idempotency_key(key)
            .map_err(|error| UsageError::new(error.message))?;
    }
    Ok(MoveRequest {
        pane: target.to_owned(),
        destination,
        name,
        focus,
        idempotency_key,
        caller_terminal: None,
    })
}

pub(super) fn run(global: GlobalArgs, mut request: MoveRequest) -> i32 {
    // A routed command (--socket, --session, --machine) runs in another
    // session, where the caller's terminal does not exist.
    if global.socket.is_none() && global.session.is_none() && global.machine.is_none() {
        request.caller_terminal = std::env::var("CMUX_TUI_TERMINAL_ID").ok();
    }
    let key = match request.idempotency_key.clone() {
        Some(key) => key,
        None => match wire::random_idempotency_key() {
            Ok(key) => key,
            Err(error) => {
                let failure = StepFailure::usage(error.0);
                return wire::print_local_error(&failure.error, global.output, failure.exit);
            }
        },
    };
    match move_pane(&Cli(&global), &request, &key) {
        Ok(result) => wire::print_local_success(&result, global.output),
        Err(failure) => wire::print_local_error(&failure.error, global.output, failure.exit),
    }
}

/// Sends one step to the daemon: the result, or the error as JSON.
pub(super) trait Daemon {
    fn request(&self, plan: RequestPlan) -> Result<Value, Value>;
}

/// The daemon this CLI talks to.
struct Cli<'a>(&'a GlobalArgs);

impl Daemon for Cli<'_> {
    fn request(&self, plan: RequestPlan) -> Result<Value, Value> {
        wire::fetch(self.0, plan)
    }
}

/// A failed step, and the exit code the CLI gives it.
#[derive(Debug)]
pub(super) struct StepFailure {
    pub error: Value,
    pub exit: i32,
}

impl StepFailure {
    fn usage(message: impl Into<String>) -> Self {
        Self {
            error: json!({"code": "usage.invalid", "message": message.into(), "details": {},
                          "retryable": false}),
            exit: 2,
        }
    }
}

/// Runs `pane <pane> move`.
pub(super) fn move_pane<B: Daemon + ?Sized>(
    backend: &B,
    request: &MoveRequest,
    command_key: &str,
) -> Result<Value, StepFailure> {
    let _ = (backend, request, command_key);
    Err(StepFailure::usage("pane move is not supported"))
}

#[cfg(test)]
#[path = "pane_move_tests.rs"]
mod tests;
