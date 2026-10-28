//! `frontend.visibility.set`: the surfaces the verified
//! app shows, which scope its own `subscribe` streams.
//!
//! The app sends the whole set of surfaces it shows, at most once per frame
//! and only when it changed. On that connection's subscriptions, the field
//! events of every other surface (title, agent, program status, output and
//! scroll) wait in their coalesced slots and flush together once per aligned
//! second, or at once when the surface shows (event_bus/hidden_surfaces.rs).
//! Structural events, exits and the app's own changes never wait, and every
//! other connection (agents, the CLI, pages) is unaffected: only the
//! connection that set the scope is scoped, and only the verified app may set
//! one. Chrome's renderer does the same for a hidden page: its scheduler
//! hears `SetPageVisible(false)` from the browser and throttles that page's
//! work to aligned 1 s wakes (third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc).
//!
//! The set lives on the connection's record, so a subscription made after it
//! is scoped too, and it ends with the connection. `visible: null` clears it.

use std::collections::HashSet;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::{MessageWriter, Response, origin_gate, responses::send_response};
use crate::SurfaceId;
use crate::event_bus::{HiddenFlush, MuxEventReceiver, WeakMuxEventReceiver};
use crate::mux::Mux;
use crate::panic_free::RecoverPoison;

/// `identify` advertises this while the daemon answers [`SET`].
pub(crate) const CAPABILITY: &str = "frontend-visibility-v1";
/// Sets or clears the connection's visible surfaces.
pub(in crate::server) const SET: &str = "frontend.visibility.set";
/// The most surfaces one set may name: far more than a Mac shows at once.
const MAX_VISIBLE: usize = 4_096;

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[crate::server::routes::RouteName::Exact(SET)],
        stage: crate::server::FrameStage::Route,
        entry: |line| try_handle(line.mux, line.client, line.message, line.writer),
    }];

/// One connection's visible surfaces and the subscriptions they scope.
#[derive(Default)]
pub(in crate::server) struct ClientVisibility {
    /// `None` until the app sets a scope, and after it clears it.
    visible: Option<HashSet<SurfaceId>>,
    subscriptions: Vec<WeakMuxEventReceiver>,
}

/// Scopes the connection's new subscription `events` by its visible
/// surfaces, now and on each later set. Called by `subscribe`.
pub(in crate::server) fn follow(mux: &Mux, client: u64, events: &MuxEventReceiver) {
    let mut state = mux.control_clients.state.lock().recover_poison();
    let Some(record) = state.clients.get_mut(&client) else { return };
    let visibility = &mut record.frontend_visibility;
    visibility.subscriptions.retain(|subscription| subscription.upgrade().is_some());
    visibility.subscriptions.push(events.downgrade());
    // Under the clients lock, so a concurrent set cannot apply first and be overwritten.
    if let Some(visible) = &visibility.visible {
        events.scope_visibility(Some(visible), &HiddenFlush::system());
    }
}

/// `frontend.visibility.set`'s fields after `cmd` and `id`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetRequest {
    visible: Option<Vec<SurfaceId>>,
}

/// Answers a `frontend.visibility.set` line; `None` for any other line.
pub(in crate::server) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    let Ok(Value::Object(mut fields)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    if fields.remove("cmd").as_ref().and_then(Value::as_str) != Some(SET) {
        return None;
    }
    let id = fields.remove("id");
    let result = set(mux, client, origin_gate::is_user(mux, client), fields);
    Some(reply(writer, id, result))
}

fn set(
    mux: &Mux,
    client: u64,
    trusted: bool,
    fields: Map<String, Value>,
) -> Result<Value, &'static str> {
    if !trusted {
        return Err("frontend_visibility.not_trusted");
    }
    if !fields.contains_key("visible") {
        return Err("frontend_visibility.bad_request");
    }
    let request: SetRequest = serde_json::from_value(Value::Object(fields))
        .map_err(|_| "frontend_visibility.bad_request")?;
    if request.visible.as_ref().is_some_and(|visible| visible.len() > MAX_VISIBLE) {
        return Err("frontend_visibility.bad_request");
    }
    let visible: Option<HashSet<SurfaceId>> = request.visible.map(|ids| ids.into_iter().collect());
    let flush = HiddenFlush::system();
    let mut state = mux.control_clients.state.lock().recover_poison();
    let Some(record) = state.clients.get_mut(&client) else {
        return Err("frontend_visibility.not_trusted");
    };
    let scope = &mut record.frontend_visibility;
    scope.visible = visible;
    let mut released = 0;
    scope.subscriptions.retain(|subscription| {
        let Some(events) = subscription.upgrade() else { return false };
        released += events.scope_visibility(scope.visible.as_ref(), &flush);
        true
    });
    let shown = scope.visible.as_ref().map(HashSet::len);
    Ok(json!({"visible": shown, "released": released}))
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, &str>) -> bool {
    let (ok, data, error_code) = match result {
        Ok(value) => (true, Some(value), None),
        Err(code) => (false, None, Some(code.to_owned())),
    };
    let error = error_code.as_deref().map(|code| match code {
        "frontend_visibility.not_trusted" => {
            "frontend.visibility.set needs the verified app's connection".to_owned()
        }
        _ => format!(
            "bad request: frontend.visibility.set takes visible (at most {MAX_VISIBLE} surface \
             ids, or null)"
        ),
    });
    send_response(writer, Response { id, ok, data, error, error_code, error_delivery: None })
}

#[cfg(test)]
#[path = "frontend_visibility_tests.rs"]
mod tests;
