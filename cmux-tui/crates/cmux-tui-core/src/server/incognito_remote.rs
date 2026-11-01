//! Incognito workspaces stay off remote devices (#31210; design/spaces.md
//! "Incognito": nothing of the window shows outside it).
//!
//! A phone reaches this socket through a splice (the Mac app's daemon lane,
//! cmux-mobile-host), which marks its `set-client-info` `remote: true`
//! (`ClientRecord::remote_device`). For such a connection the daemon:
//!
//! - refuses a request that names an object of an ephemeral workspace (the
//!   workspace, its key, a screen, pane, tab or terminal of it) with the
//!   answer an unknown object gets, so its existence is not revealed;
//! - leaves the rows that name such an object out of a reply's lists
//!   (`list-workspaces`, `list-terminals`, `list-notifications`, ...);
//! - drops the subscription events that name such an object.
//!
//! The Mac app's own connections are not remote devices and see everything.
//! Nothing here allows a command or a field: a remote device's commands are
//! still the splice's allowlist (deny by default).

use std::collections::HashSet;

use serde_json::Value;

use crate::Mux;
use crate::panic_free::RecoverPoison;

/// The request and reply fields that name a workspace or an object in one.
const TARGET_KEYS: [&str; 14] = [
    "workspace",
    "workspace_id",
    "workspace_key",
    "key",
    "resource_id",
    "screen",
    "screens",
    "pane",
    "target",
    "surface",
    "surfaces",
    "tab",
    "terminal",
    "terminal_id",
];

/// The objects of the live ephemeral workspaces, by every id a client can
/// name them with.
#[derive(Default)]
pub(super) struct Hidden {
    /// Workspace, screen, pane and tab (surface) slot ids: one id space.
    numbers: HashSet<u64>,
    /// Public ids, workspace keys, short ids and terminal ids.
    names: HashSet<String>,
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
pub(super) fn for_client(mux: &Mux, client: u64) -> Option<Hidden> {
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
                return Some(Hidden { all: true, ..Hidden::default() });
            }
        };
    if ephemeral.is_empty() {
        return None;
    }
    let mut hidden = Hidden::default();
    mux.with_state(|state| {
        let indexes = &state.resource_indexes;
        let mut numbers = Vec::new();
        for workspace in &state.workspaces {
            if !ephemeral.contains(workspace.public_id.as_str()) {
                continue;
            }
            hidden.names.insert(workspace.public_id.as_str().to_string());
            hidden.names.insert(workspace.key.clone());
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

    /// The target field and value of `object` that name a hidden object, at
    /// its top level only.
    fn named_in<'a>(&self, object: &'a Value) -> Option<(&'static str, &'a Value)> {
        let object = object.as_object()?;
        TARGET_KEYS.iter().find_map(|key| {
            object.get(*key).filter(|value| self.names(value)).map(|value| (*key, value))
        })
    }

    /// The target field and value anywhere in a request (a v2 line's
    /// `params` included) that name a hidden object.
    fn named_in_request<'a>(&self, request: &'a Value) -> Option<(&'static str, &'a Value)> {
        if let Some(found) = self.named_in(request) {
            return Some(found);
        }
        match request {
            Value::Object(object) => object.values().find_map(|value| self.named_in_request(value)),
            Value::Array(values) => values.iter().find_map(|value| self.named_in_request(value)),
            _ => None,
        }
    }

    /// Whether a subscription event names a hidden object.
    pub(super) fn hides_event(&self, event: &Value) -> bool {
        self.named_in(event).is_some()
    }

    /// Leave out of `reply`'s top-level lists every row that names a hidden
    /// object.
    pub(super) fn prune_reply(&self, reply: &mut Value) {
        let Some(object) = reply.as_object_mut() else { return };
        for value in object.values_mut() {
            if let Value::Array(rows) = value {
                rows.retain(|row| self.named_in(row).is_none());
            }
        }
    }

    /// The ids of `other` join these: a closed incognito workspace's late
    /// events stay hidden on a subscription that saw it.
    pub(super) fn absorb(&mut self, other: Option<Hidden>) {
        let Some(other) = other else {
            self.all = false;
            return;
        };
        self.numbers.extend(other.numbers);
        self.names.extend(other.names);
        self.all = other.all;
    }
}

/// Answer a remote device's request that names a hidden object as an
/// unknown object, before it is parsed or dispatched. Some(keep_open) when
/// answered, None to go on.
pub(super) fn refuse_line(
    mux: &Mux,
    client: u64,
    message: &str,
    writer: &super::MessageWriter,
) -> Option<bool> {
    let hidden = for_client(mux, client)?;
    let request = serde_json::from_str::<Value>(message).ok()?;
    let (key, value) = hidden.named_in_request(&request)?;
    let kind = match key {
        "workspace" | "workspace_id" | "workspace_key" | "key" | "resource_id" => "workspace",
        "screen" | "screens" => "screen",
        "pane" | "target" => "pane",
        "terminal" | "terminal_id" => "terminal",
        _ => "surface",
    };
    let selector = match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    };
    if request.get("protocol").is_some() {
        let error = crate::resource::ResourceError::not_found(kind, &selector);
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
