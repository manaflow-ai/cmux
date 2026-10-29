//! `memory.limit`: the app's memory pressure level, Memory
//! Saver mode and debug override, pushed to the daemon on each change.
//!
//! Chrome's browser process owns the memory limit of each child process
//! through `ChildMemoryConsumerRegistryHost`, and the most restrictive limit
//! wins (content/browser/memory_coordinator/README.md). The daemon is cmux's
//! child: the app's level votes in its registry next to the daemon's own
//! kernel source (memory.rs), so the level its consumers hear is the worse of
//! the two. The vote lasts as long as the control connection that sent it, so
//! a quit or crashed app leaves the daemon on its own source. The daemon
//! passes the app's limit on to acpmux (mux/acpmux_energy.rs).
//!
//! The verified local app only: a CLI, an agent, a WebSocket page or anything
//! through a remote relay gets `memory.not_trusted`. The handler stores one
//! atomic and votes; under pressure the consumers release on this thread
//! before the reply, so a critical push frees the lossless caches at once.
//! No thread, timer or I/O of its own. The line is answered before the
//! `Command` parse (server/routes.rs), on the connection's reader thread.

use std::sync::Arc;

use cmux_memory::PressureLevel;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::{MessageWriter, Response, origin_gate, responses::send_response};
use crate::memory::{AppLimit, SaverMode};
use crate::mux::Mux;

/// `identify` advertises this while the daemon answers `memory.limit`.
pub(crate) const CAPABILITY: &str = "memory-limit-v1";
/// Sets the app's limit.
pub(in crate::server) const LIMIT: &str = "memory.limit";

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[crate::server::routes::RouteName::Exact(LIMIT)],
        stage: crate::server::FrameStage::Route,
        entry: |line| try_handle(line.mux, line.client, line.message, line.writer),
    }];

/// A pressure level as the app's `MemoryPressureLevel` spells it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum WireLevel {
    Normal,
    Warning,
    Critical,
}

impl WireLevel {
    pub(crate) fn level(self) -> PressureLevel {
        match self {
            Self::Normal => PressureLevel::Normal,
            Self::Warning => PressureLevel::Warning,
            Self::Critical => PressureLevel::Critical,
        }
    }

    pub(crate) fn name(level: PressureLevel) -> &'static str {
        match level {
            PressureLevel::Normal => "normal",
            PressureLevel::Warning => "warning",
            PressureLevel::Critical => "critical",
        }
    }
}

/// `memory.limit`'s fields after `cmd` and `id`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LimitRequest {
    level: WireLevel,
    mode: SaverMode,
    #[serde(default, rename = "override")]
    pressure_override: Option<WireLevel>,
}

/// Answers a `memory.limit` line; `None` for any other line.
pub(in crate::server) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains(LIMIT) {
        return None;
    }
    let Ok(Value::Object(mut fields)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    if fields.remove("cmd").as_ref().and_then(Value::as_str) != Some(LIMIT) {
        return None;
    }
    let id = fields.remove("id");
    let trusted = mux.control_clients.is_unix(client)
        && !mux.is_remote_client(client)
        && origin_gate::is_user(mux, client);
    Some(reply(writer, id, set(mux, client, trusted, fields)))
}

fn set(
    mux: &Mux,
    client: u64,
    trusted: bool,
    fields: Map<String, Value>,
) -> Result<Value, &'static str> {
    if !trusted {
        return Err("memory.not_trusted");
    }
    let request: LimitRequest =
        serde_json::from_value(Value::Object(fields)).map_err(|_| "memory.bad_request")?;
    let limit = AppLimit {
        level: request.level.level(),
        mode: request.mode,
        pressure_override: request.pressure_override.map(WireLevel::level),
    };
    let changed = mux.memory.set_app(client, limit);
    Ok(json!({
        "changed": changed,
        "level": WireLevel::name(mux.memory.registry().level()),
    }))
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, &str>) -> bool {
    let (ok, data, error_code) = match result {
        Ok(value) => (true, Some(value), None),
        Err(code) => (false, None, Some(code.to_owned())),
    };
    let error = error_code.as_deref().map(|code| match code {
        "memory.not_trusted" => "memory.limit needs the verified local app".to_owned(),
        _ => "bad request: memory.limit takes level (normal, warning or critical), mode (off, \
              conservative, medium or aggressive) and an optional override level"
            .to_owned(),
    });
    send_response(writer, Response { id, ok, data, error, error_code, error_delivery: None })
}

#[cfg(test)]
#[path = "memory_limit_tests.rs"]
mod tests;
