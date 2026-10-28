//! Where a call that names no place acts: the caller's own place for
//! `current` and `focused` ([`super::caller_scope`]), and beside the
//! caller's chat for a new terminal or link ([`crate::cli::beside`]).

use std::borrow::Cow;

use serde_json::{Map, Value, json};

use super::transport::{self, CallFailure};
use super::{
    Backend, Server, caller_scope, envelope, failure_result, success, tool_error, v2_tools,
};

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
        let Some(placement) = self
            .backend
            .identity()
            .ok()
            .flatten()
            .and_then(|identity| crate::cli::beside::placement(&identity))
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
            params["idempotency_key"] = json!(key);
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
        let caller = if caller_scope::wants_caller(params) {
            match self.backend.identity() {
                // The app answers an agent session it has no chat for
                // with `found: false` and no workspace.
                Ok(Some(identity)) => {
                    let caller = identity.get("caller").cloned().unwrap_or(Value::Null);
                    if !caller_scope::is_placed(&caller) {
                        return Err(caller_scope::unresolved("the app does not know this chat"));
                    }
                    Some(caller)
                }
                Ok(None) => None,
                Err(failure) => {
                    let message = failure.error["message"].as_str().unwrap_or("no answer");
                    return Err(caller_scope::unresolved(message));
                }
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
}
