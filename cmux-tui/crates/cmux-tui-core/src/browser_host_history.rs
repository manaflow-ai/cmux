//! The browser host's history link (H3; ff decision 2026-10-07): the daemon
//! spawns `cmux-browser-host` with one end of a socketpair as an inherited
//! fd and serves the other end here. It is not a general daemon client:
//!
//! - Deny by default: only [`LINK_OPERATIONS`] (history.entries.list,
//!   history.entries.remove, history.site.remove, history.visit.remove,
//!   history.clear, history.restore) are admitted, before any other check; every other
//!   operation, `history.backups.purge` included, is refused.
//! - The caller is what the daemon can verify: the host it spawned and
//!   holds the other end for. Every request is stamped origin `agent`,
//!   principal `browser-host:<pid>`, whatever origin the line claims; it is
//!   never `user`.
//! - `on_behalf_of` (the REPL session's label, sent by the host) is
//!   attribution only: logged, never used for authorization, at most
//!   [`ON_BEHALF_OF_MAX`] characters with control characters removed.
//! - Page history only: a list or clear names `kinds: ["page"]`, a removal
//!   only `page:` ids; agent and command history never cross the link.
//! - Deletes keep their restore ids (history_ops: recoverable by default).
//!
//! One line in: `{"on_behalf_of": string?, "request": <cmux.protocol/2
//! request>}`; one line out: the protocol response.

use std::sync::Arc;

use serde_json::{Value, json};

use crate::Mux;
use crate::request_origin::RequestOrigin;
use crate::resource::{ResourceError, ResourceOperation, ResponseEnvelope};

/// The only operations the link admits.
pub(crate) const LINK_OPERATIONS: [ResourceOperation; 6] = [
    ResourceOperation::HistoryEntriesList,
    ResourceOperation::HistoryEntriesRemove,
    ResourceOperation::HistorySiteRemove,
    ResourceOperation::HistoryVisitRemove,
    ResourceOperation::HistoryClear,
    ResourceOperation::HistoryRestore,
];

/// The longest `on_behalf_of` kept, in characters.
pub(crate) const ON_BEHALF_OF_MAX: usize = 128;

/// Who sent a line on the link, as the daemon stamps it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LinkCaller {
    pub origin: RequestOrigin,
    pub principal: String,
    /// Attribution only (never authorization).
    pub on_behalf_of: Option<String>,
}

fn response(id: crate::resource::RequestId, result: Result<Value, ResourceError>) -> Value {
    let envelope = match result {
        Ok(value) => return value,
        Err(error) => ResponseEnvelope::failure(id, error),
    };
    serde_json::to_value(envelope).unwrap_or(Value::Null)
}

fn refused(reason: &str, message: &str) -> ResourceError {
    crate::request_origin::forbidden(
        message,
        json!({"derived": RequestOrigin::Agent.wire_name(), "reason": reason}),
    )
}

/// `on_behalf_of` as kept: control characters removed, at most
/// [`ON_BEHALF_OF_MAX`] characters, none when empty.
fn label(value: Option<&Value>) -> Option<String> {
    let text: String =
        value?.as_str()?.chars().filter(|c| !c.is_control()).take(ON_BEHALF_OF_MAX).collect();
    (!text.is_empty()).then_some(text)
}

/// Answers one line from the host `host_pid`: the stamped caller (`None`
/// for a line that is not a link request) and the protocol response.
pub(crate) fn handle_line(
    mux: &Arc<Mux>,
    host_pid: u32,
    line: &str,
) -> (Option<LinkCaller>, Value) {
    // crash-allow: a constant id that is valid by construction.
    let fallback = || crate::resource::RequestId::parse("link").expect("static request id");
    let wrapper: Option<serde_json::Map<String, Value>> = serde_json::from_str(line).ok();
    let Some((wrapper, request)) =
        wrapper.and_then(|w| w.get("request").map(Value::to_string).map(|r| (w, r)))
    else {
        let error = refused("not_a_link_request", "the history link takes {on_behalf_of, request}");
        return (None, response(fallback(), Err(error)));
    };
    let caller = LinkCaller {
        // Never the claim on the line: only what the daemon verified.
        origin: RequestOrigin::Agent,
        principal: format!("browser-host:{host_pid}"),
        on_behalf_of: label(wrapper.get("on_behalf_of")),
    };
    let envelope = match crate::resource_router::parse_resource_line(&request) {
        Some(Ok(envelope)) => envelope,
        Some(Err(error)) => return (Some(caller), response(fallback(), Err(error))),
        None => {
            let error = refused("not_a_link_request", "the request is not cmux.protocol/2");
            return (Some(caller), response(fallback(), Err(error)));
        }
    };
    let (id, operation) = (envelope.id.clone(), envelope.operation);
    // Deny by default, before any other check.
    if !LINK_OPERATIONS.contains(&operation) {
        let error = refused(
            "not_on_the_link",
            "the browser host's history link admits only history.entries.list, \
             history.entries.remove, history.site.remove, history.visit.remove, history.clear \
             and history.restore",
        );
        log(&caller, operation, false);
        return (Some(caller), response(id, Err(error)));
    }
    if !page_history_only(operation, &envelope.params) {
        let error = refused(
            "page_history_only",
            "the browser host's history link reaches page history only: list and clear name \
             kinds [\"page\"], and a removal names page ids",
        );
        log(&caller, operation, false);
        return (Some(caller), response(id, Err(error)));
    }
    let result = crate::request_origin::require_origin(operation.wire_name(), caller.origin)
        // The actor of a plain local connection: the link proves no user.
        .and_then(|()| {
            crate::resource_router::validate_resource_envelope(
                envelope,
                crate::workspace_registry::Actor::local_user(),
            )
        })
        .and_then(|request| crate::resource_router::handle_parsed_resource_request(mux, request));
    log(&caller, operation, result.as_ref().is_ok_and(|value| value["ok"] == true));
    (Some(caller), response(id, result))
}

/// Whether a link request stays in page history: a list or clear names
/// `kinds: ["page"]` exactly (the default is every kind), and a removal
/// names only `page:` ids. Agent and command history is never read or
/// hidden over the link.
fn page_history_only(operation: ResourceOperation, params: &Value) -> bool {
    match operation {
        ResourceOperation::HistoryEntriesList | ResourceOperation::HistoryClear => {
            params.get("kinds") == Some(&json!(["page"]))
        }
        ResourceOperation::HistoryEntriesRemove => {
            params.get("ids").and_then(Value::as_array).is_some_and(|ids| {
                ids.iter().all(|id| id.as_str().is_some_and(|id| id.starts_with("page:")))
            })
        }
        _ => true,
    }
}

/// The daemon's record of a link request: operation, the stamped caller and
/// the attribution (never a field value).
fn log(caller: &LinkCaller, operation: ResourceOperation, ok: bool) {
    eprintln!(
        "cmux-tui: browser host history link: {} by {} (origin {}) on behalf of {:?}: {}",
        operation.wire_name(),
        caller.principal,
        caller.origin.wire_name(),
        caller.on_behalf_of.as_deref().unwrap_or("-"),
        if ok { "ok" } else { "refused" },
    );
}

/// Serves the daemon's end of the link until the host closes it: one
/// response line per request line. A line over [`MAX_LINE`] bytes ends the
/// link.
#[cfg(unix)]
pub(crate) fn serve(
    mux: std::sync::Weak<Mux>,
    stream: std::os::unix::net::UnixStream,
    host_pid: u32,
) {
    use std::io::{BufRead, BufReader, Read, Write};
    let Ok(mut writer) = stream.try_clone() else { return };
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        match (&mut reader).take(MAX_LINE as u64 + 1).read_line(&mut line) {
            Ok(0) | Err(_) => return,
            Ok(read) if read > MAX_LINE => return,
            Ok(_) => {}
        }
        let Some(mux) = mux.upgrade() else { return };
        let (_, reply) = handle_line(&mux, host_pid, line.trim_end());
        drop(mux);
        if writeln!(writer, "{reply}").is_err() {
            return;
        }
    }
}

/// The longest request line the link reads (1 MiB).
pub(crate) const MAX_LINE: usize = 1 << 20;
