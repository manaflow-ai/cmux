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
const NO_CURRENT_TARGET: [&str; 33] = [
    "identify",
    "ping",
    "server-stats",
    "set-client-info",
    "list-clients",
    "list-workspaces",
    "list-workspace-groups",
    "list-tab-groups",
    "list-saved-tab-groups",
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
];

/// The object families a field can name (`workspace`, `destination_pane`,
/// `surfaces`, `tab_resource_id`, `workspace_key`, ...).
const FAMILIES: [&str; 9] =
    ["workspace", "screen", "pane", "surface", "tab", "terminal", "target", "key", "resource"];
const SUFFIXES: [&str; 6] = ["", "s", "_id", "_ids", "_key", "_keys"];

/// Whether field `key` names an object: a family, with an optional suffix
/// and an optional `<anything>_` prefix. `workspace_revision`,
/// `terminal_revision` and other counters do not.
fn is_target_key(key: &str) -> bool {
    FAMILIES.iter().any(|family| {
        SUFFIXES.iter().any(|suffix| {
            let tail = format!("{family}{suffix}");
            key == tail
                || key
                    .strip_suffix(tail.as_str())
                    .is_some_and(|prefix| !prefix.is_empty() && prefix.ends_with('_'))
        })
    })
}

/// The objects of the live ephemeral workspaces, by every id a client can
/// name them with.
#[derive(Default)]
pub(super) struct Hidden {
    /// Workspace, screen, pane and tab (surface) slot ids: one id space.
    numbers: HashSet<u64>,
    /// Public ids, workspace keys, short ids and terminal ids.
    names: HashSet<String>,
    /// The hidden workspaces' names: a request naming one is refused (a
    /// bare-name selector), but a reply row is not judged by them.
    labels: HashSet<String>,
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
    if ephemeral.is_empty() {
        return None;
    }
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
            for screen in &workspace.screens {
                numbers.push(screen.id);
                if let Some(id) = indexes.screen_ids.get(&screen.id) {
                    hidden.names.insert(id.as_str().to_string());
                }
                for pane in screen.root.pane_ids_vec() {
                    numbers.push(pane);
                    if let Some(id) = indexes.pane_ids.get(&pane) {
                        hidden.names.insert(id.as_str().to_string());
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
    Some(hidden)
}

impl Hidden {
    /// Whether `value` (a target field's value) names a hidden object.
    fn names(&self, value: &Value) -> bool {
        match value {
            Value::Number(number) => {
                number.as_u64().is_some_and(|number| self.all || self.numbers.contains(&number))
            }
            Value::String(text) => self.all || self.names.contains(text),
            Value::Array(values) => values.iter().any(|value| self.names(value)),
            _ => false,
        }
    }

    /// Whether `value`, in a request, names a hidden object or picks one
    /// the daemon resolves (`current`, a `name:` or bare-name selector).
    fn names_in_request(&self, value: &Value) -> bool {
        match value {
            Value::String(text) => {
                self.names(value)
                    || text == "current"
                    || text.starts_with("name:")
                    || self.labels.contains(text)
            }
            Value::Array(values) => values.iter().any(|value| self.names_in_request(value)),
            other => self.names(other),
        }
    }

    /// Whether row or event `object` names a hidden object in one of its
    /// own fields. An `ids` row names its object by `kind`, `id` and
    /// `short_id`.
    fn row_named(&self, object: &serde_json::Map<String, Value>) -> bool {
        let id_row = object
            .get("kind")
            .and_then(Value::as_str)
            .is_some_and(|kind| matches!(kind, "workspace" | "screen" | "pane" | "surface"));
        object.iter().any(|(key, value)| {
            (is_target_key(key) || (id_row && matches!(key.as_str(), "id" | "short_id")))
                && self.names(value)
        })
    }

    /// The target field and value anywhere in a request (a v2 line's
    /// `params` included) that name a hidden object.
    fn named_in_request<'a>(&self, request: &'a Value) -> Option<(&'a str, &'a Value)> {
        match request {
            Value::Object(object) => object.iter().find_map(|(key, value)| {
                if is_target_key(key) && self.names_in_request(value) {
                    return Some((key.as_str(), value));
                }
                self.named_in_request(value)
            }),
            Value::Array(values) => values.iter().find_map(|value| self.named_in_request(value)),
            _ => None,
        }
    }

    /// Whether a request names any target at all.
    fn names_a_target(request: &Value) -> bool {
        match request {
            Value::Object(object) => object.iter().any(|(key, value)| {
                (is_target_key(key) && !value.is_null()) || Self::names_a_target(value)
            }),
            Value::Array(values) => values.iter().any(Self::names_a_target),
            _ => false,
        }
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
                    if let Value::Array(rows) = value {
                        let ids = is_target_key(key);
                        rows.retain(|row| match row {
                            Value::Object(row) => !self.row_named(row),
                            scalar => !(ids && self.names(scalar)),
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
        self.names.extend(other.names);
        self.labels = other.labels;
        self.current_hidden = other.current_hidden;
        self.all = other.all;
    }
}

/// The kind word an unknown-object answer uses for field `key`.
fn kind_of(key: &str) -> &'static str {
    ["screen", "pane", "target", "terminal", "surface", "tab"]
        .into_iter()
        .find(|family| key.contains(family))
        .map_or("workspace", |family| match family {
            "target" => "pane",
            "tab" => "surface",
            family => family,
        })
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
    let (kind, selector) = match hidden.named_in_request(&request) {
        Some((key, value)) => (
            kind_of(key),
            match value {
                Value::String(text) => text.clone(),
                other => other.to_string(),
            },
        ),
        None => {
            let command = request.get("cmd").and_then(Value::as_str).unwrap_or_default();
            if resource
                || !hidden.current_hidden
                || NO_CURRENT_TARGET.contains(&command)
                || Hidden::names_a_target(&request)
            {
                return None;
            }
            ("workspace", "current".to_string())
        }
    };
    if resource {
        let scope = if kind == "surface" { "tab" } else { kind };
        let error = crate::resource::ResourceError::not_found(scope, &selector);
        let response = crate::resource_router::malformed_resource_response(message, error);
        return Some(writer.send_control(&response).is_ok());
    }
    let id = request.get("id").cloned();
    Some(super::responses::send_request_error(writer, id, &format!("unknown {kind} {selector}")))
}

/// Leave hidden rows out of a remote device's command reply.
pub(super) fn prune_reply(mux: &Mux, client: u64, reply: &mut Value) {
    if let Some(hidden) = for_client(mux, client) {
        hidden.prune_reply(reply);
    }
}

/// A subscription's view of what its connection must not hear. The hidden
/// objects are read again on each tree event (a workspace, screen, pane or
/// tab came or went), and ids once hidden stay hidden.
#[derive(Default)]
pub(super) struct EventFilter {
    hidden: Hidden,
    read: bool,
}

impl EventFilter {
    /// Whether `value`, the wire form of `event`, is kept from `client`.
    pub(super) fn hides(
        &mut self,
        mux: &Mux,
        client: u64,
        event: &crate::MuxEvent,
        value: &Value,
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
        if !self.read || tree {
            self.hidden.absorb(hidden(mux));
            self.read = true;
        }
        self.hidden.hides_event(value)
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
}
