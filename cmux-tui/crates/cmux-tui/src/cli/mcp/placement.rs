//! Where a call that names no place acts: the caller's own place for
//! `current` and `focused` ([`super::caller_scope`]), and beside the
//! caller's chat for a new terminal or link ([`crate::cli::beside`]).

use std::borrow::Cow;

use serde_json::{Map, Value, json};

use super::transport::{self, CallFailure};
use super::{
    Backend, Server, caller_scope, envelope, failure_result, success, tool_error, v2_tools,
};
use cmux_json::JsonSet as _;

/// The app's `system.identify` answer, whose `caller` names the chat's
/// workspace, screen, pane and tab and whose `beside` names the column
/// right of it; `None` when the environment names no caller (a client
/// outside a cmux chat or terminal).
pub(super) fn app_identity(global: &crate::cli::GlobalArgs) -> Result<Option<Value>, CallFailure> {
    if crate::cli::app::caller_from(|key| std::env::var(key).ok()).is_none() {
        return Ok(None);
    }
    let timeout = crate::cli::app::READ_TIMEOUT;
    transport::app_method(global, "system.identify", json!({}), timeout, None, false).map(Some)
}

/// What the person looks at: the app's focus from `snapshot.get` (its
/// window, workspace, pane and tab ids).
pub(super) fn app_focus(global: &crate::cli::GlobalArgs) -> Result<Option<Value>, CallFailure> {
    let timeout = crate::cli::app::READ_TIMEOUT;
    let snapshot = transport::app_method(global, "snapshot.get", json!({}), timeout, None, false)?;
    Ok(snapshot.get("topology").and_then(|topology| topology.get("focus")).cloned())
}

impl<B: Backend> Server<B> {
    /// A terminal tab or web link that names no place goes beside the
    /// caller's chat, in its own workspace ([`super::beside`]): the column
    /// right of the chat takes it, and with none a split makes one (that
    /// split's answer is the `Err`, the call's result). A client the app
    /// does not place keeps the daemon's default.
    pub(super) fn place_beside<'a>(
        &self,
        tool: &v2_tools::V2Tool,
        arguments: &'a Map<String, Value>,
    ) -> Result<Cow<'a, Map<String, Value>>, Value> {
        let terminal = tool.wire == "tab.create_terminal";
        let open_url = tool.wire == "workspace.open_url";
        if !(terminal || open_url)
            || arguments.contains_key("session")
            || !crate::cli::beside::names_no_place(arguments)
        {
            return Ok(Cow::Borrowed(arguments));
        }
        let identity = match self.backend.identity() {
            Ok(identity) => identity,
            // No app: a terminal still goes beside the chat, from the
            // daemon's own layout. A link keeps the daemon's
            // `workspace.open_url`, since `browser.open_split` needs the app.
            Err(_) if terminal => self.daemon_identity(),
            Err(_) => None,
        };
        let Some(placement) =
            identity.and_then(|identity| crate::cli::beside::placement(&identity))
        else {
            return Ok(Cow::Borrowed(arguments));
        };
        if open_url {
            return Err(self.open_beside(arguments));
        }
        let mut with_place = arguments.clone();
        match placement {
            crate::cli::beside::Placement::Pane { workspace, pane } => {
                with_place.insert("workspace".into(), json!(workspace));
                with_place.insert("pane".into(), json!(pane));
            }
            crate::cli::beside::Placement::NewColumn { workspace, chat_pane } => {
                return Err(self.new_column(arguments, &workspace, &chat_pane));
            }
        }
        Ok(Cow::Owned(with_place))
    }

    /// A link an agent opens with no workspace: the app's `browser.open_split`
    /// (the path `cmux open URL` takes), whose `beside_caller` rule puts the
    /// page in the column right of the chat, or a new column there. The
    /// daemon's `workspace.open_url` would open it in Home, or, with the
    /// workspace named, in the chat's own pane when the chat is not docked.
    fn open_beside(&self, arguments: &Map<String, Value>) -> Value {
        let key = arguments.get("idempotency_key").and_then(Value::as_str);
        let mut params =
            json!({"url": arguments.get("url").cloned().unwrap_or(Value::Null), "focus": false});
        if let Some(key) = key {
            params.set("idempotency_key", json!(key));
        }
        let timeout = crate::cli::app::waiting_run_timeout("openBrowser");
        match self.backend.app("browser.open_split", params, timeout, key, true) {
            Ok(value) => success(value, true),
            Err(failure) => failure_result(failure),
        }
    }

    /// The terminal a `tab_create_terminal` asked for, opened as a new
    /// column right of the chat, then given its name.
    fn new_column(
        &self,
        arguments: &Map<String, Value>,
        workspace: &str,
        chat_pane: &str,
    ) -> Value {
        let key = arguments.get("idempotency_key").and_then(Value::as_str);
        let mut split = crate::cli::beside::split_params(arguments, workspace, chat_pane);
        if let Some(key) = key {
            split.insert("idempotency_key".into(), json!(format!("{key}-beside")));
        }
        let Some(tool) = v2_tools::find("pane_split") else {
            return tool_error(envelope(
                v2_tools::invalid("pane_split is unavailable"),
                "not_run",
                None,
            ));
        };
        let result = self.call_v2(tool, &split);
        if result["isError"] == true {
            return result;
        }
        // A change answers `{revision, value}`; `value` is the created path.
        let answer = &result["structuredContent"];
        let created = if answer["value"].is_object() { &answer["value"] } else { answer };
        if let Some(mut rename) = crate::cli::beside::rename_params(arguments, workspace, created) {
            rename.remove("machine");
            if let Some(key) = key {
                rename.insert("idempotency_key".into(), json!(format!("{key}-name")));
            }
            // The terminal exists either way; a missing rename tool leaves it unnamed.
            if let Some(tool) = v2_tools::find("tab_rename") {
                let renamed = self.call_v2(tool, &rename);
                if renamed["isError"] == true {
                    return renamed;
                }
            }
        }
        result
    }

    /// Puts the caller's own ids in place of `current` selectors and the
    /// app's focus in place of `focused` ([`caller_scope`]). A call to
    /// another session than the server's has neither there.
    pub(super) fn place_caller(&self, call: &mut v2_tools::CallPlan) -> Result<(), Value> {
        let Some(params) = call.plan.params.as_object_mut() else { return Ok(()) };
        if call.session.is_some() {
            return Ok(());
        }
        // A `current` browser is the one nearest the caller (#26648). A bare
        // `browser: current` that the app cannot place keeps the daemon's chain,
        // as before; a `current` level still needs the caller.
        let browser = crate::cli::caller_browser::wants(params);
        if browser
            && !caller_scope::wants_caller(params)
            && let Ok(Some(identity)) = self.backend.identity()
            && identity.get("caller").is_some_and(caller_scope::is_placed)
        {
            crate::cli::caller_browser::apply(params, &identity)?;
        }
        let caller = if caller_scope::wants_caller(params) {
            match self.backend.identity() {
                // The app answers an agent session it has no chat for
                // with `found: false` and no workspace.
                Ok(Some(identity)) => {
                    let caller = identity.get("caller").cloned().unwrap_or(Value::Null);
                    if !caller_scope::is_placed(&caller) {
                        return Err(caller_scope::unresolved("the app does not know this chat"));
                    }
                    if browser {
                        crate::cli::caller_browser::apply(params, &identity)?;
                    }
                    Some(caller)
                }
                Ok(None) => None,
                // No app (a cmux TUI or Cloud session): the daemon knows the
                // caller's terminal, as it does for the CLI (resolve.rs
                // `caller_path_of`).
                Err(failure) => match self.daemon_caller() {
                    Some(caller) => Some(caller),
                    None => {
                        let message = failure
                            .error
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("no answer");
                        return Err(caller_scope::unresolved(message));
                    }
                },
            }
        } else {
            None
        };
        // An app that cannot say what is in front leaves the daemon's
        // `current`, its active object.
        let focus = caller_scope::wants_focus(params)
            .then(|| self.backend.focus().ok().flatten())
            .flatten();
        caller_scope::apply(params, caller.as_ref(), focus.as_ref());
        Ok(())
    }

    /// The app's `system.identify` answer built from the session daemon
    /// alone, for a session no app owns: the caller ([`Self::daemon_caller`])
    /// and, as `beside`, the pane right of the caller's. A terminal with no
    /// place then goes beside the chat, as with the app, not into the chat's
    /// own pane.
    fn daemon_identity(&self) -> Option<Value> {
        let caller = self.daemon_caller()?;
        let pane = caller.get("pane")?.as_str()?;
        let tool = v2_tools::find("pane_neighbor_get")?;
        let mut arguments = Map::new();
        arguments.insert("pane".into(), json!(pane));
        arguments.insert("direction".into(), json!("right"));
        let call = tool.plan(&arguments).ok()?;
        let answer = self.backend.resource(None, call.plan, &call.prefixes).ok()?;
        let right = answer
            .get("value")
            .unwrap_or(&answer)
            .pointer("/pane/id")
            .and_then(Value::as_str)
            .map(str::to_owned);
        Some(match right {
            Some(right) => json!({"caller": caller, "beside": {"pane": right}}),
            None => json!({"caller": caller}),
        })
    }

    /// The caller's place from the session daemon alone: the terminal in
    /// `CMUX_TUI_TERMINAL_ID` and the tab, pane, screen and workspace that
    /// hold it. `None` without that terminal or when the daemon does not
    /// place it. Without this, every `current` over MCP failed in a session
    /// no app owns, while the same CLI call worked (tests/tool-evals
    /// `no-app-current`, 2026-10-27).
    fn daemon_caller(&self) -> Option<Value> {
        let terminal = self.backend.caller_terminal()?;
        let mut caller = Map::new();
        caller.insert("terminal_id".into(), json!(terminal));
        let mut id = terminal;
        for (tool, selector, parent, level) in [
            ("terminal_get", "terminal", "tab_id", "tab"),
            ("tab_get", "tab", "pane_id", "pane"),
            ("pane_get", "pane", "screen_id", "screen"),
            ("screen_get", "screen", "workspace_id", "workspace"),
        ] {
            let tool = v2_tools::find(tool)?;
            let mut arguments = Map::new();
            arguments.insert(selector.into(), json!(id));
            let call = tool.plan(&arguments).ok()?;
            let answer = self.backend.resource(None, call.plan, &call.prefixes).ok()?;
            let record = answer.get("value").unwrap_or(&answer);
            id = record.get(parent)?.as_str()?.to_owned();
            caller.insert(level.into(), json!(id));
        }
        Some(Value::Object(caller))
    }
}
