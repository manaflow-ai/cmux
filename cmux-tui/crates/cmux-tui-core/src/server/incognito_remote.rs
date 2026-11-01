//! Incognito workspaces stay off remote devices (#31210; design/spaces.md
//! "Incognito": nothing of the window shows outside it).
//!
//! A phone reaches this socket through a splice (the Mac app's daemon lane,
//! cmux-mobile-host), which marks its `set-client-info` `remote: true`
//! (`ClientRecord::remote_device`). For such a connection the daemon:
//!
//! - takes only the `cmux.protocol/2` operations both splices allow
//!   ([`REMOTE_RESOURCE_OPERATIONS`]), so no resource read lists an
//!   incognito workspace;
//! - refuses a request that names an object of an ephemeral workspace (the
//!   workspace, its key or name, a screen, pane, tab or terminal of it), or
//!   names a target by `current` or `name:` while one exists, with the answer
//!   an unknown object gets, so its existence is not revealed;
//! - refuses a command that names no target at all while the Mac's current
//!   workspace is incognito, unless the command never acts on the current
//!   workspace ([`NO_CURRENT_TARGET`]);
//! - leaves the rows that name such an object out of a reply, at any depth
//!   (`list-workspaces`, `ids`, `list-terminals`, `list-clients`, ...);
//! - drops the subscription events that name such an object.
//!
//! The Mac app's own connections are not remote devices and see everything.
//! Nothing here allows a command, operation or field: it only narrows what a
//! remote device is answered (remote-relay-authorization.md: deny by default).

use std::collections::HashSet;

use serde_json::Value;
use serde_json::json;

use crate::Mux;
use crate::panic_free::RecoverPoison;

/// The `cmux.protocol/2` operations a remote device may send: exactly the
/// ones the daemon-lane splice (`DaemonLanePolicy.allowedResourceOperations`)
/// and cmux-mobile-host (`policy.rs` `ALLOWED_RESOURCE_OPERATIONS`) forward.
/// None of them lists workspaces or their content.
const REMOTE_RESOURCE_OPERATIONS: [&str; 7] = [
    "notification.clear",
    "sidebar_layout.get",
    "sidebar_layout.update",
    "workspace_group.create",
    "workspace_group.update",
    "workspace_group.delete",
    "workspace.place",
];

/// Commands that never act on the Mac's current workspace when they name no
/// target: reads of the whole session, the connection's own settings, and
/// creating a new workspace or group. Any other command that names no target
/// is refused while the current workspace is incognito (fail closed).
const NO_CURRENT_TARGET: [&str; 36] = [
    "identify",
    "ping",
    "server-stats",
    "set-client-info",
    "list-clients",
    "list-workspaces",
    "list-workspace-groups",
    "list-tab-groups",
    "list-saved-tab-groups",
    "list-saved-screen-groups",
    "list-notifications",
    "list-personal",
    "list-agents",
    "list-terminals",
    "machine-usage",
    "machine-listening-tcp",
    "ids",
    "subscribe",
    "terminal-events",
    "get-cell-pixels",
    "set-cell-pixels",
    "get-host-size-policy",
    "set-host-size-policy",
    "create-workspace",
    "new-workspace",
    "create-workspace-group",
    "update-workspace-group",
    "delete-workspace-group",
    "move-workspace-group",
    "get-frontend-projection",
    "put-frontend-projection",
    "client-focus",
    "report-focus",
    "set-personal-workspace",
    "set-window-title",
    "clear-window-title",
];

/// The object families a field can name (`workspace`, `destination_pane`,
/// `surfaces`, `tab_resource_id`, `workspace_key`, `group`, `split`, ...).
const FAMILIES: [&str; 11] = [
    "workspace",
    "screen",
    "pane",
    "surface",
    "tab",
    "terminal",
    "target",
    "key",
    "resource",
    "group",
    "split",
];
const SUFFIXES: [&str; 6] = ["", "s", "_id", "_ids", "_key", "_keys"];

/// Fields that name a split by its id, exactly as spelled: `set-row-heights`
/// takes its `column` and each height's `row`, `move-tab` its
/// `after_column`. Never widened by suffix or prefix: `rows` and `cols` are
/// terminal sizes.
const SPLIT_KEYS: [&str; 3] = ["column", "row", "after_column"];

/// Reply lists of bare surface ids under a key no family names
/// (`list-clients`' `attached`): their hidden ids are left out.
const SURFACE_LIST_KEYS: [&str; 1] = ["attached"];

/// The kinds an object names by its `value` (a sidebar item's `ref`) or,
/// in an `ids` row, its `id` and `short_id`.
const REF_KINDS: [&str; 6] = ["workspace", "screen", "pane", "surface", "tab", "terminal"];

/// The family field `key` names an object of: a family, with an optional
/// suffix and an optional `<anything>_` prefix. `workspace_revision`,
/// `terminal_revision` and other counters name none.
fn key_family(key: &str) -> Option<&'static str> {
    if SPLIT_KEYS.contains(&key) {
        return Some("split");
    }
    FAMILIES.into_iter().find(|family| {
        SUFFIXES.iter().any(|suffix| {
            let tail = format!("{family}{suffix}");
            key == tail
                || key
                    .strip_suffix(tail.as_str())
                    .is_some_and(|prefix| !prefix.is_empty() && prefix.ends_with('_'))
        })
    })
}

fn is_target_key(key: &str) -> bool {
    key_family(key).is_some()
}

/// Split ids (`set-split-ratio`) of a screen's layout.
fn split_ids(node: &crate::model::Node, out: &mut Vec<u64>) {
    if let crate::model::Node::Split { id, a, b, .. } = node {
        out.push(*id);
        split_ids(a, out);
        split_ids(b, out);
    }
}

/// The objects of the live ephemeral workspaces, by every id a client can
/// name them with.
#[derive(Default)]
pub(super) struct Hidden {
    /// Workspace, screen, pane and tab (surface) slot ids: one id space.
    numbers: HashSet<u64>,
    /// Split ids, matched only in `split` fields.
    splits: HashSet<u64>,
    /// Public ids, workspace keys, short ids, terminal ids and tab and
    /// screen group ids.
    names: HashSet<String>,
    /// The hidden workspaces' names: a request naming one is refused (a
    /// bare-name selector), but a reply row is not judged by them.
    labels: HashSet<String>,
    /// Saved tab and screen groups saved from an incognito workspace's
    /// group (`store::incognito_saved`): their records keep its members'
    /// titles, directories and URLs, and reopening one recreates them.
    saved: HashSet<String>,
    /// Notifications of a hidden workspace or terminal, by public id (random,
    /// so matched in any field): a terminal-less one names its workspace
    /// only in state a reply row leaves out.
    notifications: HashSet<String>,
    /// The Mac's current workspace is incognito.
    current_hidden: bool,
    /// The registry could not say which workspaces are ephemeral: hide
    /// every workspace object (fail closed).
    all: bool,
}

/// Whether `client` is a remote device's connection.
pub(super) fn is_remote_device(mux: &Mux, client: u64) -> bool {
    let state = mux.control_clients.state.lock().recover_poison();
    state.clients.get(&client).is_some_and(|record| record.remote_device)
}

/// What `client` must not see, or None when it may see everything (it is
/// not a remote device, or no workspace is incognito).
fn for_client(mux: &Mux, client: u64) -> Option<Hidden> {
    if !is_remote_device(mux, client) {
        return None;
    }
    hidden(mux)
}

/// The objects of the live ephemeral workspaces, or None when there are none.
pub(super) fn hidden(mux: &Mux) -> Option<Hidden> {
    // The registry lock is released before the state lock is taken.
    let ephemeral: HashSet<String> =
        match mux.read_registry_state(crate::state::store::ephemeral_workspaces) {
            Ok(ephemeral) => ephemeral.into_iter().collect(),
            Err(error) => {
                eprintln!(
                    "cmux-tui: could not list incognito workspaces for a remote device: {error:#}"
                );
                return Some(Hidden { all: true, current_hidden: true, ..Hidden::default() });
            }
        };
    let saved = crate::state::store::incognito_saved();
    if ephemeral.is_empty() && saved.is_empty() {
        return None;
    }
    for workspace in &ephemeral {
        crate::state::store::note_ephemeral(workspace);
    }
    // Taken before the state lock, as `tree_decorations` does.
    let presentation = mux.presentation_snapshot();
    let mut hidden = Hidden::default();
    mux.with_state(|state| {
        let indexes = &state.resource_indexes;
        let mut numbers = Vec::new();
        for (index, workspace) in state.workspaces.iter().enumerate() {
            if !ephemeral.contains(workspace.public_id.as_str()) {
                continue;
            }
            hidden.current_hidden |= index == state.active_workspace;
            hidden.names.insert(workspace.public_id.as_str().to_string());
            hidden.names.insert(workspace.key.clone());
            hidden.labels.insert(workspace.name.clone());
            numbers.push(workspace.id);
            for run in crate::mux::workspace_screen_groups(workspace, &presentation.screens) {
                hidden.names.insert(run.group.id);
            }
            for screen in &workspace.screens {
                numbers.push(screen.id);
                let mut splits = Vec::new();
                split_ids(&screen.root, &mut splits);
                for split in splits {
                    if let Some(id) = indexes.split_ids.get(&split) {
                        hidden.names.insert(id.as_str().to_string());
                    }
                    hidden.splits.insert(split);
                }
                if let Some(id) = indexes.screen_ids.get(&screen.id) {
                    hidden.names.insert(id.as_str().to_string());
                }
                for pane in screen.root.pane_ids_vec() {
                    numbers.push(pane);
                    if let Some(id) = indexes.pane_ids.get(&pane) {
                        hidden.names.insert(id.as_str().to_string());
                    }
                    for run in crate::mux::pane_tab_groups(state, &presentation, pane) {
                        hidden.names.insert(run.group.id);
                    }
                    for surface in state.panes.get(&pane).into_iter().flat_map(|pane| &pane.tabs) {
                        numbers.push(*surface);
                        if let Some(id) = indexes.tab_ids.get(surface) {
                            hidden.names.insert(id.as_str().to_string());
                        }
                        if let Some(id) = indexes.content_ids.get(surface) {
                            hidden.names.insert(id.as_str().to_string());
                        }
                        let identity = state
                            .surfaces
                            .get(surface)
                            .and_then(|surface| surface.terminal_host_identity());
                        if let Some(identity) = identity {
                            hidden.names.insert(identity.terminal_id);
                        }
                    }
                }
            }
        }
        let short_ids = super::tree_json::tree_short_ids(state);
        for number in numbers {
            if let Some(short) = short_ids.get(&number) {
                hidden.names.insert(short.clone());
            }
            hidden.numbers.insert(number);
        }
    });
    // A live group of a hidden workspace: its saved record too (noted, so it
    // stays hidden once the workspace closes).
    let tab_groups = presentation.tab_groups.groups.values().map(|g| (&g.pane_id, &g.saved_id));
    let screen_groups =
        presentation.screens.groups.values().map(|g| (&g.workspace_key, &g.saved_id));
    for (owner, saved_id) in tab_groups.chain(screen_groups) {
        if let Some(saved_id) = saved_id.as_ref().filter(|_| hidden.names.contains(owner)) {
            crate::state::store::note_incognito_saved(saved_id);
            hidden.saved.insert(saved_id.clone());
        }
    }
    hidden.saved.extend(saved);
    for notification in mux.resource_notifications(256) {
        let workspace = notification.workspace_id.as_ref().map(|id| id.as_str());
        let terminal = notification.terminal_id.as_ref().map(|id| id.as_str());
        if workspace.into_iter().chain(terminal).any(|id| hidden.names.contains(id)) {
            hidden.notifications.insert(notification.id.as_str().to_string());
        }
    }
    Some(hidden)
}

impl Hidden {
    /// Whether `value`, the value of field `key`, names a hidden object.
    fn names(&self, key: &str, value: &Value) -> bool {
        match value {
            Value::Number(number) => number.as_u64().is_some_and(|number| {
                let numbers =
                    if key_family(key) == Some("split") { &self.splits } else { &self.numbers };
                self.all || numbers.contains(&number)
            }),
            Value::String(text) => self.all || self.names.contains(text) || self.is_saved(text),
            Value::Array(values) => values.iter().any(|value| self.names(key, value)),
            _ => false,
        }
    }

    /// Whether `text` is the id of a hidden saved group or notification.
    /// Failing closed, any saved group's id (`saved_...`, `ssaved_...`) is.
    fn is_saved(&self, text: &str) -> bool {
        self.saved.contains(text)
            || self.notifications.contains(text)
            || (self.all && (text.starts_with("saved_") || text.starts_with("ssaved_")))
    }

    /// Whether `value` holds, at any depth and in any field, a hidden saved
    /// group's id (a saved-group row's `id`, a request's `saved`, a live
    /// group's `saved_id`). Saved ids are random, so no other value matches.
    fn mentions_saved(&self, value: &Value) -> bool {
        self.saved_in(value).is_some()
    }

    /// The hidden saved group's id `value` holds, at any depth.
    fn saved_in<'a>(&self, value: &'a Value) -> Option<&'a str> {
        match value {
            Value::String(text) => self.is_saved(text).then_some(text.as_str()),
            Value::Array(values) => values.iter().find_map(|value| self.saved_in(value)),
            Value::Object(object) => object.values().find_map(|value| self.saved_in(value)),
            _ => None,
        }
    }

    /// Whether `value`, in a request's field `key`, names a hidden object or
    /// picks one the daemon resolves (`current`, a `name:` or bare-name
    /// selector).
    fn names_in_request(&self, key: &str, value: &Value) -> bool {
        match value {
            Value::String(text) => {
                self.names(key, value)
                    || text == "current"
                    || text.starts_with("name:")
                    || self.labels.contains(text)
            }
            Value::Array(values) => values.iter().any(|value| self.names_in_request(key, value)),
            other => self.names(key, other),
        }
    }

    /// Whether row or event `object` names a hidden object in one of its
    /// own fields or in an object it holds (not in its lists, which are
    /// pruned row by row). An `ids` row names its object by `kind`, `id` and
    /// `short_id`; a sidebar item's `ref` by `kind` and `value`.
    fn row_named(&self, object: &serde_json::Map<String, Value>) -> bool {
        let id_row = object
            .get("kind")
            .and_then(Value::as_str)
            .is_some_and(|kind| REF_KINDS.contains(&kind));
        object.iter().any(|(key, value)| {
            ((is_target_key(key) && self.names(key, value))
                || (id_row
                    && matches!(key.as_str(), "id" | "short_id" | "value")
                    && (self.names(key, value) || self.names(key, &unqualified(value)))))
                || self.mentions_saved(value)
                || value.as_object().is_some_and(|inner| self.row_named(inner))
        })
    }

    /// The target field and value anywhere in a request (a v2 line's
    /// `params` included) that name a hidden object.
    fn named_in_request<'a>(&self, request: &'a Value) -> Option<(&'a str, &'a Value)> {
        match request {
            Value::Object(object) => {
                // A sidebar item's `ref` (`sidebar_layout.update`'s op).
                let kind = object.get("kind").and_then(Value::as_str);
                if let (Some(kind), Some(value)) = (kind, object.get("value"))
                    && REF_KINDS.contains(&kind)
                    && (self.names_in_request(kind, value) || self.names(kind, &unqualified(value)))
                {
                    return Some((kind, value));
                }
                self.named_in_object(object)
            }
            Value::Array(values) => values.iter().find_map(|value| self.named_in_request(value)),
            _ => None,
        }
    }

    fn named_in_object<'a>(
        &self,
        object: &'a serde_json::Map<String, Value>,
    ) -> Option<(&'a str, &'a Value)> {
        object.iter().find_map(|(key, value)| {
            if is_target_key(key) && self.names_in_request(key, value) {
                return Some((key.as_str(), value));
            }
            self.named_in_request(value)
        })
    }

    /// Whether a command names any target (an id or a selector in a target
    /// field; never the request's own `id`).
    fn names_a_target(request: &Value) -> bool {
        fn selector(value: &Value) -> bool {
            match value {
                Value::Number(_) => true,
                Value::String(text) => !text.is_empty(),
                Value::Array(values) => values.iter().any(selector),
                _ => false,
            }
        }
        fn walk(value: &Value) -> bool {
            match value {
                Value::Object(object) => object
                    .iter()
                    .any(|(key, value)| (is_target_key(key) && selector(value)) || walk(value)),
                Value::Array(values) => values.iter().any(walk),
                _ => false,
            }
        }
        request.as_object().is_some_and(|object| {
            object
                .iter()
                .filter(|(key, _)| key.as_str() != "id")
                .any(|(key, value)| (is_target_key(key) && selector(value)) || walk(value))
        })
    }

    /// Whether a subscription event names a hidden object.
    pub(super) fn hides_event(&self, event: &Value) -> bool {
        event.as_object().is_some_and(|object| self.row_named(object))
    }

    /// Leave out of `reply` every row (an object in a list, at any depth)
    /// and every listed id that names a hidden object.
    pub(super) fn prune_reply(&self, reply: &mut Value) {
        match reply {
            Value::Object(object) => {
                for (key, value) in object.iter_mut() {
                    let key = key.as_str();
                    if let Value::Array(rows) = value {
                        let ids = is_target_key(key) || SURFACE_LIST_KEYS.contains(&key);
                        rows.retain(|row| match row {
                            Value::Object(row) => !self.row_named(row),
                            scalar => !(ids && self.names(key, scalar)),
                        });
                    }
                    self.prune_reply(value);
                }
            }
            Value::Array(values) => values.iter_mut().for_each(|value| self.prune_reply(value)),
            _ => {}
        }
    }

    /// The ids of `other` join these: a closed incognito workspace's late
    /// events stay hidden on a subscription that saw it.
    pub(super) fn absorb(&mut self, other: Option<Hidden>) {
        let Some(other) = other else {
            self.all = false;
            self.current_hidden = false;
            return;
        };
        self.numbers.extend(other.numbers);
        self.splits.extend(other.splits);
        self.names.extend(other.names);
        self.saved.extend(other.saved);
        self.labels = other.labels;
        self.current_hidden = other.current_hidden;
        self.all = other.all;
    }
}

/// A sidebar ref's value without its session (`<session>:ws_...`).
fn unqualified(value: &Value) -> Value {
    match value.as_str().and_then(|text| text.rsplit_once(':')) {
        Some((_, id)) => Value::String(id.to_string()),
        None => value.clone(),
    }
}

/// The kind word an unknown-object answer uses for field `key`.
fn kind_of(key: &str) -> &'static str {
    match key_family(key) {
        Some("screen") => "screen",
        Some("pane" | "target") => "pane",
        Some("terminal") => "terminal",
        Some("surface" | "tab") => "surface",
        Some("group") => "group",
        Some("split") => "split",
        _ => "workspace",
    }
}

/// Answer a remote device's line before it is parsed or dispatched when it
/// is not for a remote device: a resource operation the splices do not
/// forward, or a request about an incognito workspace (answered as an
/// unknown object). Some(keep_open) when answered, None to go on.
pub(super) fn refuse_line(
    mux: &Mux,
    client: u64,
    message: &str,
    writer: &super::MessageWriter,
) -> Option<bool> {
    if !is_remote_device(mux, client) {
        return None;
    }
    let request = serde_json::from_str::<Value>(message).ok()?;
    let resource = request.get("protocol").is_some();
    if resource {
        let operation = request.get("operation").and_then(Value::as_str).unwrap_or_default();
        if !REMOTE_RESOURCE_OPERATIONS.contains(&operation) {
            let error = crate::resource::ResourceError::new(
                "origin.forbidden",
                format!("{operation} is not available to a phone"),
                json!({
                    "derived": super::origin_gate::derived_origin(mux, client).wire_name(),
                    "reason": "phone_policy",
                }),
                false,
            );
            let response = crate::resource_router::malformed_resource_response(message, error);
            return Some(writer.send_control(&response).is_ok());
        }
    }
    let hidden = hidden(mux)?;
    let (kind, selector) = hidden.refusal(&request, resource)?;
    if resource {
        let scope = match kind {
            "surface" => "tab",
            "group" | "saved group" => "tab_group",
            kind => kind,
        };
        let error = crate::resource::ResourceError::not_found(scope, &selector);
        let response = crate::resource_router::malformed_resource_response(message, error);
        return Some(writer.send_control(&response).is_ok());
    }
    let id = request.get("id").cloned();
    Some(super::responses::send_request_error(writer, id, &format!("unknown {kind} {selector}")))
}

impl Hidden {
    /// Why a remote device's `request` is refused: the kind and selector of
    /// the hidden object it names, or the current workspace when it names
    /// none and acts on an incognito current workspace.
    fn refusal(&self, request: &Value, resource: bool) -> Option<(&'static str, String)> {
        let saved = self.saved_in(request).map(str::to_string);
        let refused = match self.named_in_request(request) {
            Some((key, value)) => (
                kind_of(key),
                match value {
                    Value::String(text) => text.clone(),
                    other => other.to_string(),
                },
            ),
            // `reopen-saved-tab-group`, `delete-saved-screen-group`, ... by a
            // saved group of an incognito workspace.
            None if saved.is_some() => ("saved group", saved.unwrap_or_default()),
            None => {
                let command = request.get("cmd").and_then(Value::as_str).unwrap_or_default();
                if resource
                    || !self.current_hidden
                    || NO_CURRENT_TARGET.contains(&command)
                    || Hidden::names_a_target(request)
                {
                    return None;
                }
                ("workspace", "current".to_string())
            }
        };
        Some(refused)
    }
}

/// A remote device's command line, kept to be judged again when it is
/// dispatched: a command the connection's scheduler queued runs after the
/// Mac may have switched to, or opened, an incognito workspace.
pub(super) fn line_to_recheck(mux: &Mux, client: u64, message: &str) -> Option<String> {
    is_remote_device(mux, client).then(|| message.to_string())
}

/// The refusal of a remote device's command line at dispatch, judged against
/// the incognito workspaces of that moment, as [`refuse_line`] judged it on
/// arrival.
pub(super) fn recheck(mux: &Mux, line: &str) -> Option<String> {
    let request = serde_json::from_str::<Value>(line).ok()?;
    let (kind, selector) = hidden(mux)?.refusal(&request, false)?;
    Some(format!("unknown {kind} {selector}"))
}

/// Leave hidden rows out of a remote device's command reply.
pub(super) fn prune_reply(mux: &Mux, client: u64, reply: &mut Value) {
    if let Some(hidden) = for_client(mux, client) {
        hidden.prune_reply(reply);
    }
}

/// A subscription's view of what its connection must not hear. It reads the
/// hidden objects when the subscription starts and again on each tree event
/// (a workspace, screen, pane or tab came or went). Ids once hidden stay
/// hidden, and a tree event about a workspace this process ever marked
/// ephemeral (`store::was_ephemeral`) is hidden and teaches the filter that
/// workspace's ids, so a queued event of an incognito workspace closed since
/// never leaks.
#[derive(Default)]
pub(super) struct EventFilter {
    hidden: Hidden,
}

impl EventFilter {
    /// The filter of a subscription `client` starts now.
    pub(super) fn start(mux: &Mux, client: u64) -> Self {
        let mut filter = Self::default();
        if is_remote_device(mux, client) {
            filter.hidden.absorb(hidden(mux));
        }
        filter
    }

    /// Whether `value`, the wire form of `event`, is kept from `client`;
    /// when it is not, the rows of it that name a hidden object are left out.
    pub(super) fn hides(
        &mut self,
        mux: &Mux,
        client: u64,
        event: &crate::MuxEvent,
        value: &mut Value,
    ) -> bool {
        if !is_remote_device(mux, client) {
            return false;
        }
        let tree = matches!(
            event,
            crate::MuxEvent::TreeDelta(_)
                | crate::MuxEvent::TreeChanged
                | crate::MuxEvent::TreeSelectionChanged
                | crate::MuxEvent::LayoutChanged(..)
        );
        if tree {
            self.hidden.absorb(hidden(mux));
        }
        if self.hidden.hides_event(value) || names_an_ephemeral_workspace(value) {
            self.hidden.learn(value, false);
            return true;
        }
        // An event about shared state (a sidebar layout, a group) keeps only
        // its rows that name nothing hidden.
        self.hidden.prune_reply(value);
        false
    }
}

/// Whether an event names, anywhere, the public id of a workspace that was
/// ever ephemeral (a delta's `entity` carries it).
fn names_an_ephemeral_workspace(value: &Value) -> bool {
    match value {
        Value::Object(object) => object.iter().any(|(key, value)| {
            (key == "resource_id" && value.as_str().is_some_and(crate::state::store::was_ephemeral))
                || names_an_ephemeral_workspace(value)
        }),
        Value::Array(values) => values.iter().any(names_an_ephemeral_workspace),
        _ => false,
    }
}

impl Hidden {
    /// Learn every id a hidden event names: its target fields, and inside
    /// its `entity` every `id` too (the workspace's, its screens', panes'
    /// and groups').
    fn learn(&mut self, value: &Value, entity: bool) {
        let Value::Object(object) = value else {
            if let Value::Array(values) = value {
                values.iter().for_each(|value| self.learn(value, entity));
            }
            return;
        };
        for (key, value) in object {
            // A workspace's `group` is its sidebar group, shared with
            // normal workspaces: never learned (tab and screen groups are,
            // by their `id`).
            let family = key_family(key);
            let target =
                (family.is_some() && family != Some("group")) || (entity && key.as_str() == "id");
            if target {
                self.learn_ids(key, value);
            }
            // A hidden live group's saved record stays hidden.
            if matches!(key.as_str(), "saved_id" | "saved")
                && let Value::String(saved) = value
            {
                crate::state::store::note_incognito_saved(saved);
                self.saved.insert(saved.clone());
            }
            if matches!(value, Value::Object(_) | Value::Array(_)) {
                self.learn(value, entity || key == "entity");
            }
        }
    }

    fn learn_ids(&mut self, key: &str, value: &Value) {
        match value {
            Value::Number(number) => {
                if let Some(number) = number.as_u64() {
                    if key_family(key) == Some("split") {
                        self.splits.insert(number);
                    } else {
                        self.numbers.insert(number);
                    }
                }
            }
            Value::String(text) => {
                self.names.insert(text.clone());
            }
            Value::Array(values) => values.iter().for_each(|value| self.learn_ids(key, value)),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_keys_name_objects_and_never_counters() {
        for key in [
            "workspace",
            "workspace_key",
            "destination_workspace",
            "surfaces",
            "tab_resource_id",
            "terminal_id",
            "resource_id",
            "key",
            "target",
            "screens",
        ] {
            assert!(is_target_key(key), "{key}");
        }
        for key in
            ["workspace_revision", "terminal_revision", "pane_revision", "id", "name", "cols"]
        {
            assert!(!is_target_key(key), "{key}");
        }
    }

    #[test]
    fn prune_drops_nested_rows_and_ids_rows() {
        let hidden = Hidden {
            numbers: HashSet::from([7]),
            names: HashSet::from(["ws_hidden".to_string()]),
            ..Hidden::default()
        };
        let mut reply = json!({
            "ids": [{"kind": "workspace", "id": 7, "short_id": "a"},
                    {"kind": "workspace", "id": 8, "short_id": "b"}],
            "clients": [{"client": 7, "attached": [{"surface": 7}, {"surface": 9}]}],
            "workspace_revision": 7,
        });
        hidden.prune_reply(&mut reply);
        assert_eq!(
            reply,
            json!({
                "ids": [{"kind": "workspace", "id": 8, "short_id": "b"}],
                "clients": [{"client": 7, "attached": [{"surface": 9}]}],
                "workspace_revision": 7,
            })
        );
    }

    #[test]
    fn selectors_that_could_resolve_to_a_hidden_workspace_are_refused() {
        let hidden = Hidden { labels: HashSet::from(["private".to_string()]), ..Hidden::default() };
        for request in [
            json!({"cmd": "x", "workspace": "current"}),
            json!({"params": {"destination_workspace": "name:anything"}}),
            json!({"cmd": "x", "workspace": "private"}),
        ] {
            assert!(hidden.named_in_request(&request).is_some(), "{request}");
        }
        assert!(hidden.named_in_request(&json!({"cmd": "x", "workspace": 3})).is_none());
    }

    #[test]
    fn the_request_id_is_never_a_target() {
        assert!(!Hidden::names_a_target(&json!({"id": {"pane": 4}, "cmd": "new-tab"})));
        assert!(!Hidden::names_a_target(&json!({"id": 1, "cmd": "new-tab", "pane": false})));
        assert!(Hidden::names_a_target(&json!({"id": 1, "cmd": "new-tab", "pane": 4})));
        assert!(Hidden::names_a_target(&json!({"id": 1, "cmd": "set-split-ratio", "split": 9})));
    }

    #[test]
    fn groups_and_splits_of_a_hidden_workspace_are_refused() {
        let hidden = Hidden {
            numbers: HashSet::from([5]),
            splits: HashSet::from([9]),
            names: HashSet::from(["tg_hidden".to_string()]),
            ..Hidden::default()
        };
        for request in [
            json!({"cmd": "close-tab-group", "group": "tg_hidden", "end_terminals": true}),
            json!({"cmd": "set-split-ratio", "split": 9, "ratio": 0.5}),
        ] {
            assert!(hidden.named_in_request(&request).is_some(), "{request}");
        }
        // A split id is its own id space: pane 9 is not split 9.
        assert!(hidden.named_in_request(&json!({"cmd": "focus-pane", "pane": 9})).is_none());
        assert!(hidden.named_in_request(&json!({"cmd": "set-split-ratio", "split": 5})).is_none());
    }

    #[test]
    fn row_and_column_fields_name_splits_but_terminal_sizes_do_not() {
        let hidden = Hidden { splits: HashSet::from([9]), ..Hidden::default() };
        for request in [
            json!({"cmd": "set-row-heights", "column": 9, "heights": []}),
            json!({"cmd": "set-row-heights", "column": 4, "heights": [{"row": 9, "height": 1}]}),
            json!({"cmd": "move-tab", "surface": 3, "after_column": 9}),
        ] {
            assert!(hidden.named_in_request(&request).is_some(), "{request}");
        }
        assert!(hidden.named_in_request(&json!({"cmd": "resize", "rows": 9, "cols": 9})).is_none());
        assert!(!is_target_key("rows") && !is_target_key("top_row"));
    }

    #[test]
    fn saved_groups_of_a_hidden_workspace_are_left_out_and_refused() {
        let hidden =
            Hidden { saved: HashSet::from(["ssaved_hidden".to_string()]), ..Hidden::default() };
        let mut reply = json!({"groups": [
            {"id": "ssaved_hidden", "name": "secret"},
            {"id": "ssaved_other", "name": "shown"},
        ]});
        hidden.prune_reply(&mut reply);
        assert_eq!(reply, json!({"groups": [{"id": "ssaved_other", "name": "shown"}]}));
        let request = json!({"cmd": "reopen-saved-screen-group", "saved": "ssaved_hidden"});
        assert_eq!(hidden.saved_in(&request), Some("ssaved_hidden"));
        assert!(hidden.saved_in(&json!({"saved": "ssaved_other"})).is_none());
        let failing_closed = Hidden { all: true, ..Hidden::default() };
        assert!(failing_closed.mentions_saved(&json!({"saved": "saved_x"})));
    }

    #[test]
    fn sidebar_items_and_ungrouped_rows_of_a_hidden_workspace_are_left_out() {
        let hidden =
            Hidden { names: HashSet::from(["ws_hidden".to_string()]), ..Hidden::default() };
        let mut reply = json!({"ok": true, "result": {"value": {
            "sections": [{"id": "sec_pinned", "items": [
                {"id": "i1", "ref": {"kind": "workspace", "value": "main:ws_hidden"}},
                {"id": "i2", "ref": {"kind": "workspace", "value": "ws_shown"}},
            ]}],
            "ungrouped": [{"workspace": {"workspace_id": "ws_hidden"}},
                          {"workspace": {"workspace_id": "ws_shown"}}],
        }}});
        hidden.prune_reply(&mut reply);
        let text = reply.to_string();
        assert!(!text.contains("ws_hidden"), "{text}");
        assert_eq!(text.matches("ws_shown").count(), 2, "{text}");
    }

    #[test]
    fn a_clients_attached_surfaces_of_a_hidden_workspace_are_left_out() {
        let hidden = Hidden { numbers: HashSet::from([7]), ..Hidden::default() };
        let mut reply = json!({"clients": [{"client": 3, "attached": [7, 9], "sizes": []}]});
        hidden.prune_reply(&mut reply);
        assert_eq!(reply, json!({"clients": [{"client": 3, "attached": [9], "sizes": []}]}));
    }

    #[test]
    fn a_sidebar_ref_to_a_hidden_workspace_is_refused() {
        let hidden =
            Hidden { names: HashSet::from(["ws_hidden".to_string()]), ..Hidden::default() };
        let request = json!({"protocol": "cmux.protocol/2", "params": {"op": {"kind": "item.add",
            "item": {"id": "it_1", "ref": {"kind": "workspace", "value": "main:ws_hidden"}}}}});
        assert_eq!(hidden.named_in_request(&request).map(|(kind, _)| kind), Some("workspace"));
        let shown =
            json!({"params": {"op": {"item": {"ref": {"kind": "workspace", "value": "ws_x"}}}}});
        assert!(hidden.named_in_request(&shown).is_none());
    }

    #[test]
    fn window_title_commands_never_act_on_the_current_workspace() {
        for command in ["set-window-title", "clear-window-title"] {
            assert!(NO_CURRENT_TARGET.contains(&command), "{command}");
        }
    }

    #[test]
    fn a_hidden_event_teaches_its_entity_ids_but_never_its_sidebar_group() {
        let mut hidden = Hidden::default();
        hidden.learn(
            &json!({"event": "workspace-added", "workspace": 3, "entity": {
                "id": 3, "resource_id": "ws_x", "key": "k", "group": "grp_shared",
                "screens": [{"id": 4, "panes": [{"id": 5, "tabs": [{"surface": 6}]}]}]}}),
            false,
        );
        for number in [3, 4, 5, 6] {
            assert!(hidden.numbers.contains(&number), "{number}");
        }
        assert!(hidden.names.contains("ws_x") && hidden.names.contains("k"));
        assert!(!hidden.names.contains("grp_shared"));
        assert!(!hidden.hides_event(&json!({"event": "workspace-changed", "group": "grp_shared"})));
        assert!(hidden.hides_event(&json!({"event": "title-changed", "surface": 6})));
    }
}
