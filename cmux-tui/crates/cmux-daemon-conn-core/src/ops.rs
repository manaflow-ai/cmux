//! The JSON ops of the C ABI (`cmux_daemon_conn_call`, and
//! `cmux_daemon_conn_scope_call` on a scope handle). Each takes one JSON
//! object and answers one; see `include/cmux_daemon_conn.h` for the list.

use crate::compat::{self, Refusal};
use crate::errors::{self, Class, StartupState};
use crate::handshake::{self, Verdict};
use crate::identity::Identity;
use crate::idle::{self, Clients};
use crate::latency;
use crate::offline::{self, Held};
use crate::retry::{BUSY_RETRY_CAP_NS, Preset};
use crate::scope::{self, Created, Failure, Scope};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

/// Why an op failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpError {
    /// The request is not the JSON the op takes.
    Invalid(String),
    /// No such op.
    Unknown,
}

type OpResult = Result<Value, OpError>;

fn invalid(what: &str) -> OpError {
    OpError::Invalid(what.to_string())
}

fn text<'a>(request: &'a Value, key: &str) -> Result<&'a str, OpError> {
    request.get(key).and_then(Value::as_str).ok_or_else(|| invalid(key))
}

fn optional_text<'a>(request: &'a Value, key: &str) -> Option<&'a str> {
    request.get(key).and_then(Value::as_str)
}

fn flag(request: &Value, key: &str) -> bool {
    request.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn number(request: &Value, key: &str) -> Result<u64, OpError> {
    request.get(key).and_then(Value::as_u64).ok_or_else(|| invalid(key))
}

fn strings(request: &Value, key: &str) -> Result<Vec<String>, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(value) => serde_json::from_value(value.clone()).map_err(|_| invalid(key)),
    }
}

/// An identity from `<key>` (an object) or `<key>_reply` (a reply line).
fn identity(request: &Value, key: &str) -> Result<Identity, OpError> {
    if let Some(line) = request.get(format!("{key}_reply")).and_then(Value::as_str) {
        return Identity::from_reply(line).map_err(OpError::Invalid);
    }
    let value = request.get(key).ok_or_else(|| invalid(key))?;
    serde_json::from_value(value.clone()).map_err(|e| OpError::Invalid(format!("{key}: {e}")))
}

fn verdict_json(verdict: &Verdict) -> Value {
    match verdict {
        Verdict::Accept => json!({"verdict": "accept"}),
        Verdict::WrongApp(app) => json!({"verdict": "wrong_app", "app": app}),
        Verdict::UnsupportedProtocol(protocol) => {
            json!({"verdict": "unsupported_protocol", "protocol": protocol})
        }
        Verdict::MissingCapabilities(names) => {
            json!({"verdict": "missing_capabilities", "names": names})
        }
    }
}

fn to_value(value: impl serde::Serialize) -> OpResult {
    serde_json::to_value(value).map_err(|e| OpError::Invalid(e.to_string()))
}

/// One op with no handle.
pub fn call(op: &str, request: &Value) -> OpResult {
    match op {
        "retry_policies" => {
            let mut presets = Map::new();
            for preset in Preset::ALL {
                let p = preset.policy();
                presets.insert(
                    preset.name().to_string(),
                    json!({
                        "initial_ns": p.initial_ns,
                        "maximum_ns": p.maximum_ns,
                        "timed_retries": p.timed_retries,
                        "socket_retries": p.socket_retries,
                        "keeps_trying": p.keeps_trying,
                    }),
                );
            }
            Ok(json!({"presets": presets, "busy_retry_cap_ns": BUSY_RETRY_CAP_NS}))
        }
        "handshake_verdict" => {
            let identity = identity(request, "identity")?;
            Ok(verdict_json(&handshake::verdict(&identity, &strings(request, "required")?)))
        }
        "page_relay_verdict" => {
            let identity = identity(request, "identity")?;
            Ok(match handshake::page_relay_verdict(&identity, optional_text(request, "page")) {
                Ok(page) => json!({"verdict": "accept", "page": page}),
                Err(refusal) => verdict_json(&refusal),
            })
        }
        "serves_machine_metadata" => Ok(
            json!({"serves": handshake::serves_machine_metadata(&identity(request, "identity")?)}),
        ),
        "metadata_fenced" => {
            let first = identity(request, "first")?;
            let enriched = identity(request, "enriched")?;
            Ok(json!({"fenced": handshake::metadata_fenced(&first, &enriched)}))
        }
        "handshake_capabilities" => Ok(json!({"capabilities": handshake::handshake_capabilities(
            &strings(request, "advertised")?,
            flag(request, "resolves_shell_integration"),
            flag(request, "echoes_placement_shift"),
        )})),
        "compatibility" => {
            let identity = identity(request, "identity")?;
            let not_needed: BTreeSet<String> =
                strings(request, "not_needed")?.into_iter().collect();
            to_value(compat::of_identity(
                &identity,
                &strings(request, "required")?,
                &strings(request, "optional")?,
                &not_needed,
            ))
        }
        "compatibility_refusal" => {
            let refusal = match text(request, "kind")? {
                "missingCapabilities" => Refusal::MissingCapabilities(strings(request, "names")?),
                "unsupportedProtocol" => Refusal::UnsupportedProtocol(
                    request
                        .get("protocol")
                        .and_then(Value::as_i64)
                        .ok_or_else(|| invalid("protocol"))?,
                ),
                "wrongApp" => Refusal::WrongApp(text(request, "app")?.to_string()),
                _ => return Ok(json!({"compatibility": null})),
            };
            Ok(json!({"compatibility": to_value(compat::of_refusal(&refusal))?}))
        }
        "version_label" => Ok(json!({"label": compat::version_label(
            optional_text(request, "version").unwrap_or_default(),
            optional_text(request, "build_commit"),
        )})),
        "error_classes" => {
            let mut classes = Map::new();
            for class in Class::ALL {
                classes.insert(
                    to_value(class)?.as_str().unwrap_or_default().to_string(),
                    json!(class.kinds()),
                );
            }
            Ok(json!({"kinds": errors::KINDS, "classes": classes}))
        }
        "startup_failure" => {
            to_value(errors::startup_failure(text(request, "kind")?, flag(request, "busy_refusal")))
        }
        "shows_failure" => {
            let state =
                StartupState::from_name(text(request, "state")?).ok_or_else(|| invalid("state"))?;
            Ok(
                json!({"shows": errors::shows_failure(state, text(request, "kind")?, flag(request, "retries"))}),
            )
        }
        "startup_policy" => Ok(json!({"deadline_ms": errors::STARTUP_DEADLINE_MS})),
        "owner_idle_policy" => Ok(json!({
            "standard_call_seconds": idle::STANDARD_CALL_SECONDS,
            "busy_client_kinds": idle::BUSY_CLIENT_KINDS,
        })),
        "owner_idle_clients" => {
            let call_seconds = request
                .get("call_seconds")
                .and_then(Value::as_f64)
                .unwrap_or(idle::STANDARD_CALL_SECONDS);
            Ok(match idle::clients(request.get("clients").unwrap_or(&Value::Null), call_seconds) {
                Clients::Busy => json!({"busy": true}),
                Clients::Call(seconds) => json!({"busy": false, "call_seconds": seconds.max(0.0)}),
            })
        }
        "owner_idle_conversations" => {
            Ok(match idle::conversation_ids(request.get("conversations").unwrap_or(&Value::Null)) {
                Some(ids) => json!({"busy": false, "ids": ids}),
                None => json!({"busy": true}),
            })
        }
        "owner_idle_typing" => {
            Ok(json!({"idle": idle::nobody_types(request.get("snapshot").unwrap_or(&Value::Null))}))
        }
        "may_end_busy" => Ok(
            json!({"may": idle::may_end_busy(text(request, "kind")?, optional_text(request, "name"))}),
        ),
        "latency_bounds" => {
            Ok(json!({"bounds_us": latency::bounds_us(), "bucket_count": latency::BUCKET_COUNT}))
        }
        "latency_bucket" => Ok(json!({"bucket": latency::bucket(number(request, "us")?)})),
        "latency_percentile" => {
            let counts: Vec<u64> =
                serde_json::from_value(request.get("counts").cloned().unwrap_or(Value::Null))
                    .map_err(|_| invalid("counts"))?;
            Ok(
                json!({"us": latency::percentile_us(&counts, number(request, "max_us")?, number(request, "percent")?)}),
            )
        }
        "derived_uuid" => Ok(
            json!({"uuid": scope::derived_uuid(text(request, "key")?, text(request, "kind")?, number(request, "ordinal")?)}),
        ),
        "offline_intent_disposition" => {
            let answering = request.get("answering").and_then(Value::as_bool).unwrap_or(true);
            let kind = text(request, "kind")?;
            Ok(json!({
                "disposition": offline::disposition(kind, answering),
                "sent": offline::maybe_sent(kind),
                "bound_ms": offline::HOLD_BOUND_MS,
            }))
        }
        "offline_intent_sweep" => {
            let held: Vec<Held> =
                serde_json::from_value(request.get("held").cloned().unwrap_or(json!([])))
                    .map_err(|_| invalid("held"))?;
            let bound_ms =
                request.get("bound_ms").and_then(Value::as_u64).unwrap_or(offline::HOLD_BOUND_MS);
            let now_ms = number(request, "now_ms")?;
            to_value(offline::sweep(&held, now_ms, flag(request, "reachable"), bound_ms))
        }
        "offline_intent_requeue" => {
            let entry: Held =
                serde_json::from_value(request.get("held").cloned().unwrap_or_default())
                    .map_err(|_| invalid("held"))?;
            to_value(offline::requeue(&entry, text(request, "kind")?))
        }
        "offline_intent_text" => to_value(offline::text(
            text(request, "action")?,
            optional_text(request, "name").unwrap_or_default(),
        )),
        "session_ending_keeps_layout" => {
            let capabilities: BTreeSet<String> =
                strings(request, "capabilities")?.into_iter().collect();
            let keeps = flag(request, "keeping_layout")
                && !flag(request, "deleting_workspaces")
                && capabilities.contains(END_TERMINALS_KEEP_LAYOUT)
                && capabilities.contains(TAB_RESTART_KEPT_LAYOUT);
            Ok(json!({"keeps": keeps}))
        }
        _ => Err(OpError::Unknown),
    }
}

/// Kept tabs restart only in place (`restart-tab` of a kept tab), so a daemon
/// that cannot do that removes the tabs instead of keeping them.
pub const END_TERMINALS_KEEP_LAYOUT: &str = "end-terminals-keep-layout-v1";
pub const TAB_RESTART_KEPT_LAYOUT: &str = "tab-restart-kept-layout-v1";

/// One op on a command scope.
pub fn scope_call(scope: &mut Scope, op: &str, request: &Value) -> OpResult {
    let at_ms = request.get("at_ms").and_then(Value::as_u64).unwrap_or(0);
    match op {
        "note" => {
            scope.note(text(request, "stage")?, at_ms);
            Ok(json!({}))
        }
        "stage_log" => Ok(json!({"log": scope.stage_log()})),
        "begin" => Ok(json!({"ticket": scope.begin(optional_text(request, "label"), at_ms)})),
        "end" => {
            let failure: Option<Failure> = match request.get("failure") {
                None | Some(Value::Null) => None,
                Some(value) => {
                    Some(serde_json::from_value(value.clone()).map_err(|_| invalid("failure"))?)
                }
            };
            let idle = scope.end(
                number(request, "ticket")?,
                failure,
                optional_text(request, "label"),
                at_ms,
            );
            Ok(json!({"became_idle": idle}))
        }
        "note_barrier" => {
            scope.note_barrier(number(request, "sequence")?, text(request, "machine")?);
            Ok(json!({}))
        }
        "note_created" => {
            let objects: Vec<Created> =
                serde_json::from_value(request.get("objects").cloned().unwrap_or(json!([])))
                    .map_err(|_| invalid("objects"))?;
            scope.note_created(objects);
            Ok(json!({}))
        }
        "close" => {
            scope.close();
            Ok(json!({}))
        }
        "state" => Ok(json!({
            "idle": scope.is_idle(),
            "open": scope.is_open(),
            "failures": scope.failures(),
            "created": scope.created(),
            "ticket_count": scope.ticket_count(),
            "barriers": scope.barriers(),
        })),
        "next_mutation_id" => Ok(json!({"id": scope.next_mutation_id()})),
        "next_derived" => Ok(json!({"uuid": scope.next_derived(text(request, "kind")?)})),
        _ => Err(OpError::Unknown),
    }
}
