//! Where a call that names no place acts: the caller's own place for
//! `current` and `focused` ([`super::caller_scope`]) and for a creation
//! with no place ([`crate::cli::beside`]: beside the caller's chat for a new
//! terminal, profile browser tab or link).

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
    let caller = crate::cli::beside::Caller::of_process();
    if !caller.is_known() {
        return Ok(None);
    }
    // A Chief turn's place is the Home chat of the app that owns this
    // server's daemon. A Cloud Chief turn reaches the person's Mac app over a
    // relay while its daemon is the VM's, where the Mac's Home ids name
    // nothing: there it has no place, and its calls keep the daemon's own
    // `current` (https://github.com/manaflow-ai/cmux/issues/25590).
    if caller.home_chat {
        let owned =
            crate::cli::wire::resolve_socket_with_origin(global).ok().is_some_and(|(socket, _)| {
                crate::cli::frontend_browser::owning_app_socket(global, &socket).is_some()
            });
        if !owned {
            return Ok(None);
        }
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
    /// A creation that names no place acts in the caller's own
    /// ([`crate::cli::beside`]), never in the daemon's active workspace,
    /// which follows the person's focus. A terminal tab, a profile browser
    /// tab or a web link goes beside the caller's chat: the column right of
    /// the chat takes it, and with none a split makes one (that split's
    /// answer is the `Err`, the call's result). A pane, a screen and any tab
    /// the app does not place go to the caller's own workspace, screen and
    /// pane when the request is sent. A client with no caller keeps the
    /// daemon's default.
    pub(super) fn place_beside<'a>(
        &self,
        tool: &v2_tools::V2Tool,
        arguments: &'a Map<String, Value>,
    ) -> Result<Cow<'a, Map<String, Value>>, Value> {
        use crate::cli::beside::{self, Kind, Placement};
        use cmux_tui_core::resource::ResourceOperation;

        if beside::creation_scopes(tool.operation).is_none() {
            return Ok(Cow::Borrowed(arguments));
        }
        let terminal = tool.operation == ResourceOperation::TabCreateTerminal;
        let open_url = tool.operation == ResourceOperation::WorkspaceOpenUrl;
        let profile = tool.operation == ResourceOperation::BrowserProfileOpen;
        // `pane: "current"` would put the terminal over this chat's own pane; models write
        // it by reflex for "on my right" (tests/tool-evals r13a: GPT 6 Astra and 6.1 Sol in
        // 8 samples, after the sheet said no pane). It goes beside the chat like no pane;
        // the chat's own pane by its id still works.
        // `workspace: "current"` too, which models write beside it; any other parent stays.
        let current = |key: &str| arguments.get(key).and_then(Value::as_str) == Some("current");
        let own_pane = terminal
            && current("pane")
            && beside::PARENTS.iter().all(|key| {
                *key == "pane"
                    || !arguments.contains_key(*key)
                    || (*key == "workspace" && current(key))
            });
        let unplaced = if own_pane {
            let mut without = arguments.clone();
            without.remove("pane");
            without.remove("workspace");
            Cow::Owned(without)
        } else {
            Cow::Borrowed(arguments)
        };
        if arguments.contains_key("session") || !beside::names_no_place(&unplaced) {
            return Ok(Cow::Borrowed(arguments));
        }
        if terminal || open_url || profile {
            let answer = match self.backend.identity() {
                Ok(identity) => identity,
                // No app: a terminal still goes beside the chat, from the
                // daemon's own layout.
                Err(_) if terminal => self.daemon_identity(),
                Err(_) => None,
            };
            // An MCP client is an agent, in a chat or in a terminal: its tab
            // goes beside it whatever the app's version.
            let kind = if terminal { Kind::Terminal } else { Kind::Browser };
            match answer.and_then(|identity| beside::placement_of(&identity, kind)) {
                // The app's `browser.open_split` places a link beside the chat.
                Some(_) if open_url => return Err(self.open_beside(&unplaced)),
                Some(Placement::Pane { workspace, pane }) => {
                    let mut with_place = Map::clone(&unplaced);
                    with_place.insert("workspace".into(), json!(workspace));
                    with_place.insert("pane".into(), json!(pane));
                    return Ok(Cow::Owned(with_place));
                }
                Some(Placement::NewColumn { workspace, chat_pane }) => {
                    let split = beside::split_params(&unplaced, &workspace, &chat_pane);
                    return Err(self.split_for(tool, &unplaced, &workspace, split));
                }
                Some(Placement::SplitBelow { workspace, pane }) => {
                    let split = beside::split_below_params(&unplaced, &workspace, &pane);
                    return Err(self.split_for(tool, &unplaced, &workspace, split));
                }
                None => {}
            }
        }
        // Every other creation, and a tab the app does not place, gets the
        // caller's own workspace, screen and pane on the request's own
        // connection, as the CLI's does (transport.rs, resolve.rs
        // `place_creation`). A browser tab an app renders is placed by the
        // caller its run names (frontend_browser.rs).
        Ok(Cow::Borrowed(arguments))
    }

    /// The place of the workspace an agent chat's environment names
    /// (`CMUX_WORKSPACE_ID`), when this session has it: the workspace and,
    /// while it has them, its active screen, pane and tab.
    fn workspace_key_place(&self) -> Option<Map<String, Value>> {
        let key = self.backend.caller_workspace_key()?;
        let ask = |tool: &str, arguments: Map<String, Value>| {
            let call = v2_tools::find(tool)?.plan(&arguments).ok()?;
            let answer = self.backend.resource(None, call.plan, &call.prefixes).ok()?;
            Some(answer.get("value").cloned().unwrap_or(answer))
        };
        let workspaces = ask("workspace_list", Map::new())?;
        let workspace = crate::cli::beside::workspace_of_key(&workspaces, &key)?;
        let mut path = Map::new();
        let mut selector = Map::new();
        selector.insert("workspace".into(), json!(workspace));
        path.insert("workspace".into(), json!(workspace));
        for (tool, scope) in [("screen_get", "screen"), ("pane_get", "pane"), ("tab_get", "tab")] {
            selector.insert(scope.into(), json!("current"));
            let Some(id) = ask(tool, selector.clone())
                .and_then(|record| record.get("id").and_then(Value::as_str).map(str::to_owned))
            else {
                break;
            };
            selector.insert(scope.into(), json!(id));
            path.insert(scope.into(), json!(id));
        }
        Some(path)
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

    /// The tab a creation asked for, in the new pane `split` makes (a new
    /// column right of the chat, or a pane below the column's lone pane of
    /// another kind). A terminal is the split's own tab, then given its
    /// name. A profile browser tab opens in the new pane, whose shell tab
    /// then ends, which leaves the pane to the browser.
    fn split_for(
        &self,
        tool: &v2_tools::V2Tool,
        arguments: &Map<String, Value>,
        workspace: &str,
        mut split: Map<String, Value>,
    ) -> Value {
        let key = arguments.get("idempotency_key").and_then(Value::as_str);
        if let Some(key) = key {
            split.insert("idempotency_key".into(), json!(format!("{key}-beside")));
        }
        let Some(pane_split) = v2_tools::find("pane_split") else {
            return tool_error(envelope(
                v2_tools::invalid("pane_split is unavailable"),
                "not_run",
                None,
            ));
        };
        let result = self.call_v2(pane_split, &split);
        if result["isError"] == true {
            return result;
        }
        // A change answers `{revision, value}`; `value` is the created path.
        let answer = &result["structuredContent"];
        let created = if answer["value"].is_object() { &answer["value"] } else { answer };
        if tool.operation == cmux_tui_core::resource::ResourceOperation::BrowserProfileOpen {
            return self.open_in_new_pane(tool, arguments, workspace, created);
        }
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

    /// Opens `tool`'s browser tab in the pane a split `created`, then ends
    /// that pane's shell. A failed open ends the shell too, and with it the
    /// new pane.
    fn open_in_new_pane(
        &self,
        tool: &v2_tools::V2Tool,
        arguments: &Map<String, Value>,
        workspace: &str,
        created: &Value,
    ) -> Value {
        let text = |field: &str| created.get(field).and_then(Value::as_str);
        let (Some(pane), Some(shell)) = (text("pane_id"), text("terminal_id")) else {
            return tool_error(envelope(
                v2_tools::invalid("the split made no pane for the browser tab"),
                "in_progress",
                None,
            ));
        };
        let mut open = arguments.clone();
        open.insert("workspace".into(), json!(workspace));
        open.insert("pane".into(), json!(pane));
        let opened = self.call_v2(tool, &open);
        if let Some(close) = v2_tools::find("terminal_close") {
            let mut end = Map::new();
            end.insert("terminal".into(), json!(shell));
            if let Some(key) = arguments.get("idempotency_key").and_then(Value::as_str) {
                end.insert("idempotency_key".into(), json!(format!("{key}-shell")));
            }
            // The browser tab is open either way; a shell that stays is closed by hand.
            let _ = self.call_v2(close, &end);
        }
        opened
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
                // with `found: false` and no workspace: the workspace the
                // chat's environment names stands in, when this session has it.
                Ok(Some(identity)) => {
                    let caller = identity.get("caller").cloned().unwrap_or(Value::Null);
                    if !caller_scope::is_placed(&caller) {
                        match self.workspace_key_place() {
                            Some(place) => Some(Value::Object(place)),
                            None => {
                                return Err(caller_scope::unresolved(
                                    "the app does not know this chat",
                                ));
                            }
                        }
                    } else {
                        if browser {
                            crate::cli::caller_browser::apply(params, &identity)?;
                        }
                        Some(caller)
                    }
                }
                Ok(None) => None,
                // No app (a cmux TUI or Cloud session): the daemon knows the
                // caller's terminal, as it does for the CLI (resolve.rs
                // `caller_path_of`), and an agent chat's workspace by its key.
                Err(failure) => match self
                    .daemon_caller()
                    .or_else(|| self.workspace_key_place().map(Value::Object))
                {
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

    /// A `tab_move` that names its destination pane but not that pane's screen and
    /// workspace, or no index, gets them: a pane is in one screen of one workspace, and a
    /// moved tab goes last (the daemon clamps an index past the end). Agents looked the
    /// move up in the docs and then the pane's parents before every move (tests/tool-evals
    /// r13d: 2 to 3 steps). Only the destination workspace named: its active screen and
    /// pane (`current` under a named workspace is its active child, not the caller's).
    pub(super) fn tab_move_destination<'a>(
        &self,
        tool: &v2_tools::V2Tool,
        arguments: &'a Map<String, Value>,
    ) -> Result<Cow<'a, Map<String, Value>>, Value> {
        let keys = ["destination_workspace", "destination_screen", "destination_pane", "index"];
        if tool.wire != "tab.move" || keys.iter().all(|key| arguments.contains_key(*key)) {
            return Ok(Cow::Borrowed(arguments));
        }
        let mut filled = arguments.clone();
        filled.entry("index").or_insert(json!(u32::MAX));
        if !filled.contains_key("destination_pane") {
            if let Some(workspace) = filled.get("destination_workspace").cloned() {
                // A workspace made with no content has no pane to take the tab: say so,
                // where the daemon answered "no current screen" (tests/tool-evals r14a:
                // GPT 6 Astra spent 3 steps after it).
                let mut list = Map::new();
                if let Some(session) = arguments.get("session") {
                    list.insert("session".into(), session.clone());
                }
                list.insert("workspace".into(), workspace);
                list.insert("limit".into(), json!(1));
                let panes = self.read(v2_tools::find("pane_list"), &list)?;
                if panes.get("items").and_then(Value::as_array).is_some_and(Vec::is_empty) {
                    return Err(tool_error(envelope(
                        v2_tools::invalid(
                            "tab_move: that workspace has no pane to take the tab (it was \
                             made empty); pane_create {workspace} makes one, then pass its \
                             destination_pane",
                        ),
                        "not_run",
                        None,
                    )));
                }
                filled.entry("destination_screen").or_insert(json!("current"));
                filled.insert("destination_pane".into(), json!("current"));
            }
            return Ok(Cow::Owned(filled));
        }
        if filled.contains_key("destination_screen") && filled.contains_key("destination_workspace")
        {
            return Ok(Cow::Owned(filled));
        }
        // The lookups run in the move's session: the call's, else the one the tab names.
        let session = arguments.get("session").cloned().or_else(|| {
            let tab = arguments.get("tab").and_then(Value::as_str)?;
            Some(json!(tab.rsplit_once(':')?.0))
        });
        let scope = |id: &str, value: &Value| {
            let mut lookup = Map::new();
            if let Some(session) = &session {
                lookup.insert("session".into(), session.clone());
            }
            lookup.insert(id.into(), value.clone());
            lookup
        };
        let pane = filled.get("destination_pane").cloned().unwrap_or(Value::Null);
        let record = self.read(v2_tools::find("pane_get"), &scope("pane", &pane))?;
        let (Some(id), Some(screen)) =
            (record.get("id").cloned(), record.get("screen_id").cloned())
        else {
            return Ok(Cow::Borrowed(arguments));
        };
        // The pane's own id: a destination field is sent as written, so `current`, a
        // prefix or `<session>:` would reach the daemon unresolved.
        filled.insert("destination_pane".into(), id);
        if !filled.contains_key("destination_workspace") {
            let record = self.read(v2_tools::find("screen_get"), &scope("screen", &screen))?;
            let Some(workspace) = record.get("workspace_id").cloned() else {
                return Ok(Cow::Borrowed(arguments));
            };
            filled.insert("destination_workspace".into(), workspace);
        }
        filled.entry("destination_screen").or_insert(screen);
        Ok(Cow::Owned(filled))
    }

    /// One read through the same path as a direct call (`current`, prefixes and the
    /// `<session>:` qualifier resolve as there): its record, or the failed call's answer.
    pub(super) fn read(
        &self,
        tool: Option<&v2_tools::V2Tool>,
        arguments: &Map<String, Value>,
    ) -> Result<Value, Value> {
        let Some(tool) = tool else {
            return Err(tool_error(envelope(
                v2_tools::invalid("a lookup tool is unavailable"),
                "not_run",
                None,
            )));
        };
        let answer = self.call_v2(tool, arguments);
        if answer.get("isError").and_then(Value::as_bool) == Some(true) {
            return Err(answer);
        }
        let record = answer.get("structuredContent").cloned().unwrap_or(Value::Null);
        Ok(record.get("value").cloned().unwrap_or(record))
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
