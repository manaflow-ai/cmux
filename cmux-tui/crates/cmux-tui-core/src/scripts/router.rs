//! Routes a script's ops into this daemon's dispatcher (and the app's
//! actions to the Mac app), and turns committed resource changes and
//! terminal events into script event streams.

use std::sync::{Arc, Weak};

use std::collections::HashMap;

use cmux_app_host::script::{Publish, ScriptRouter};
use serde_json::{Value, json};

use crate::apps::routing::{answer, is_daemon_op, request};
use crate::mux::Mux;
use crate::request_origin::{RequestOrigin, require_origin};
use crate::resource::ContentPublicId;
use crate::stream_interrupt::StreamInterrupt;
use crate::{Actor, MuxEvent, SurfaceId, resource_router};

/// Streams a committed resource change publishes. The journal epoch does not
/// say which family changed, so every family stream fires; scripts re-check
/// their predicate (`cmux.wait`).
pub(crate) const STREAMS: [&str; 6] = [
    "resource.changed",
    "workspace.changed",
    "screen.changed",
    "pane.changed",
    "tab.changed",
    "terminal.changed",
];

pub(crate) struct DaemonRouter {
    mux: Weak<Mux>,
    /// Prefix of every idempotency key: `script:<daemon nonce>:<session>:`.
    key_prefix: String,
}

impl DaemonRouter {
    pub(crate) fn new(mux: &Arc<Mux>, session: &str) -> Self {
        Self { mux: Arc::downgrade(mux), key_prefix: format!("script:{session}:") }
    }
}

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({ "code": code, "message": message.into(), "retryable": false })
}

fn mint_key() -> Result<String, Value> {
    let mut bytes = [0u8; 12];
    getrandom::fill(&mut bytes).map_err(|e| {
        error("operation.failed", format!("could not mint an idempotency key: {e}"))
    })?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// The ops a script may call: the ops this daemon's dispatcher owns, and
/// the app's actions ([`provided`]).
pub(crate) fn admits(op: &str) -> bool {
    is_daemon_op(op) || provided(op)
}

/// Ops a script reaches through the Mac app's provider channel
/// (`apps::provider`): only the action family (`action.run`, `action.list`),
/// so a script can do what a palette or a key can.
pub(crate) fn provided(op: &str) -> bool {
    crate::apps::script_provided(op)
}

/// The public ids of the tab a surface shows: its tab, and its terminal
/// when it shows one.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ScriptIds {
    pub tab: String,
    pub terminal: Option<String>,
}

/// The script stream and fields of a terminal event (`terminal.output`,
/// `terminal.bell`, `terminal.title_changed`, `terminal.program_status_changed`,
/// `terminal.exited`), with the surface's public ids from `ids`. `None` for
/// every other event and for a surface `ids` does not know.
pub(crate) fn script_event(
    event: &MuxEvent,
    ids: &dyn Fn(SurfaceId) -> Option<ScriptIds>,
) -> Option<(&'static str, Value)> {
    let (stream, surface, extra) = match event {
        MuxEvent::SurfaceOutput(surface) => ("terminal.output", *surface, None),
        MuxEvent::Bell(surface) => ("terminal.bell", *surface, None),
        MuxEvent::TitleChanged { surface, title } => {
            ("terminal.title_changed", *surface, Some(("title", json!(title.as_ref()))))
        }
        MuxEvent::ProgramStatusChanged { surface, status } => (
            "terminal.program_status_changed",
            *surface,
            Some(("program_status", status.as_ref().map_or(Value::Null, |s| s.wire()))),
        ),
        MuxEvent::SurfaceExited(surface, _) => ("terminal.exited", *surface, None),
        _ => return None,
    };
    let ids = ids(surface)?;
    let mut fields = json!({ "terminal": ids.terminal, "tab": ids.tab });
    if let Some((key, value)) = extra {
        fields[key] = value;
    }
    Some((stream, fields))
}

/// The public ids of every surface now.
fn surface_ids(mux: &Mux) -> HashMap<SurfaceId, ScriptIds> {
    mux.with_state(|state| {
        state
            .surfaces
            .iter()
            .filter_map(|(id, surface)| {
                let identity = surface.resource_identity()?;
                let terminal = match &identity.content_id {
                    ContentPublicId::Terminal(terminal) => Some(terminal.as_str().to_string()),
                    ContentPublicId::Browser(_) => None,
                };
                Some((*id, ScriptIds { tab: identity.tab_id.as_str().to_string(), terminal }))
            })
            .collect()
    })
}

/// Publishes the terminal events of `mux` to a script until `interrupt`
/// fires. Public ids come from a map refreshed when a surface is unknown, so
/// a terminal that already left the tree when its exit arrives keeps them.
fn publish_terminal_events(mux: Arc<Mux>, interrupt: Arc<StreamInterrupt>, publish: Publish) {
    let events = mux.subscribe();
    events.wake_on(&interrupt);
    let mut known = surface_ids(&mux);
    loop {
        let event = match events.recv_until_interrupted(&interrupt) {
            Ok(event) => event,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if interrupt.is_fired() {
                    return;
                }
                continue;
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        };
        if interrupt.is_fired() {
            return;
        }
        let surface = match &event {
            MuxEvent::SurfaceOutput(s) | MuxEvent::Bell(s) | MuxEvent::SurfaceExited(s, _) => *s,
            MuxEvent::TitleChanged { surface, .. }
            | MuxEvent::ProgramStatusChanged { surface, .. } => *surface,
            _ => continue,
        };
        if !known.contains_key(&surface) {
            known = surface_ids(&mux);
        }
        let lookup = |id: SurfaceId| known.get(&id).cloned();
        let Some((stream, mut fields)) = script_event(&event, &lookup) else { continue };
        if let MuxEvent::SurfaceExited(..) = event {
            add_exit(&mux, &mut fields);
            known.remove(&surface);
        }
        publish(stream, fields);
    }
}

/// `outcome` and `exit_code` of an exited terminal, when its durable exit
/// record has them.
fn add_exit(mux: &Mux, fields: &mut Value) {
    let Some(terminal) = fields["terminal"].as_str() else { return };
    let Ok(terminal) = crate::resource::TerminalPublicId::parse(terminal) else { return };
    let Ok(state) = mux.terminal_exit_state(&terminal) else { return };
    if state["state"] != "exited" {
        return;
    }
    let outcome = state["outcome"].clone();
    if let Some(code) = outcome.get("code").or_else(|| outcome.get("exit_code")) {
        fields["exit_code"] = code.clone();
    }
    fields["outcome"] = outcome;
}

impl ScriptRouter for DaemonRouter {
    fn call(&self, op: &str, params: Value, options: Value) -> Result<Value, Value> {
        if !admits(op) {
            return Err(error(
                "operation.unsupported",
                format!("{op} is not available to scripts on this cmux"),
            ));
        }
        let mux = self
            .mux
            .upgrade()
            .ok_or_else(|| error("operation.failed", "the daemon is shutting down"))?;
        if provided(op) {
            let own =
                options.get("idempotencyKey").and_then(Value::as_str).filter(|k| !k.is_empty());
            let own = match own {
                Some(own) => own.to_string(),
                None => mint_key()?,
            };
            let key = format!("{}{own}", self.key_prefix);
            return mux.script_provider_call(op, params, key);
        }
        // A script has the rights of the CLI that started it: a plain local
        // connection, which derives origin `agent` (request-origin.md).
        require_origin(op, RequestOrigin::Agent)
            .map_err(|e| json!({ "code": e.code, "message": e.message, "details": e.details, "retryable": e.retryable }))?;
        // Script keys live in their own namespace so they never meet another
        // caller's keys in an owner's replay cache.
        let own = options.get("idempotencyKey").and_then(Value::as_str).filter(|k| !k.is_empty());
        let own = match own {
            Some(own) => own.to_string(),
            None => mint_key()?,
        };
        let key = format!("{}{own}", self.key_prefix);
        let message = request(op, params, Some(key))?;
        let parsed = resource_router::parse_resource_request_as(&message, Actor::local_user())
            .map_err(|e| answer(op, json!({ "ok": false, "error": e })).unwrap_err())?;
        if resource_router::requires_connection_context(parsed.envelope.operation) {
            return Err(error(
                "operation.unsupported",
                format!("{op} needs a client connection and is not available to scripts"),
            ));
        }
        let response = resource_router::handle_parsed_resource_request(&mux, parsed)
            .map_err(|e| answer(op, json!({ "ok": false, "error": e })).unwrap_err())?;
        answer(op, response)
    }

    fn watch(&self, publish: Publish) -> Box<dyn Send> {
        let interrupt = StreamInterrupt::new();
        let guard = Box::new(FireOnDrop(interrupt.clone()));
        let Some(mux) = self.mux.upgrade() else { return guard };
        {
            let (mux, interrupt, publish) = (mux.clone(), interrupt.clone(), publish.clone());
            // Without the thread the session gets no terminal events.
            let _ = std::thread::Builder::new()
                .name("cmux-script-terminal-events".into())
                .spawn(move || publish_terminal_events(mux, interrupt, publish));
        }
        mux.wake_journal_waiters_on(&interrupt);
        // Without a thread the session gets no events: `cmux.wait` then ends
        // at its own timeout.
        let _ = std::thread::Builder::new().name("cmux-script-events".into()).spawn(move || {
            let mut epoch = mux.journal_event_epoch();
            loop {
                let next = mux.wait_for_journal_event_until_interrupted(epoch, &interrupt);
                if interrupt.is_fired() {
                    return;
                }
                if next != epoch {
                    epoch = next;
                    for stream in STREAMS {
                        publish(stream, json!({}));
                    }
                }
            }
        });
        guard
    }
}

/// Fires the watcher's interrupt when the session drops its guard.
struct FireOnDrop(Arc<StreamInterrupt>);

impl Drop for FireOnDrop {
    fn drop(&mut self) {
        self.0.fire();
    }
}
