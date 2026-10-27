//! `debug-hang-inject` (p09-observability-088), debug builds only: arms a hang
//! on a named hang-watch lane of the daemon, its holder, a terminal host or
//! acpmux, for scripts/cmux-next/hang-matrix.py. The lane's next scope sleeps
//! for `ms` on its own thread (`cmux_threads::hang_inject`), so the watcher of
//! the process that owns the lane writes one hang record for it. Chrome hangs a
//! target thread the same way (`chrome://uithreadhang`, `chrome://gpuhang`;
//! content/browser/renderer_host/debug_urls.cc).
//!
//! The arm goes into the per-user injection page that every debug cmux
//! process maps at its first watched scope; `pid` names the one process that
//! may take it (the daemon itself by default). Like `oracle-state`, the line
//! is answered before the `Command` parse, so it is not in the `Command`
//! enum, its name table or the SDK catalog; a release daemon does not compile
//! this module and answers the line as an unknown command. Only the trusted
//! local connection gets an answer; remote relay frames never reach feature
//! routes.
//!
//! Request: `{"cmd": "debug-hang-inject", "lane": "mux-conn", "ms": 3000,
//! "pid": 123}` arms (`ms` defaults to 3000, `pid` to the daemon);
//! `"action": "disarm"` with `lane` (and `pid`) disarms; `"action": "list"`
//! arms nothing. Every answer has the page, its entries, the daemon's pid, its
//! hang log and its own lanes with their hang tiers.

use std::sync::Arc;
use std::time::Duration;

use cmux_threads::hang_inject::{self, EntryState, InjectError, Page};
use serde_json::{Map, Value, json};

use super::{MessageWriter, Response, WatchKind, send_request_error, send_response};
use crate::Mux;

/// The line's `cmd`.
pub(super) const COMMAND: &str = "debug-hang-inject";
const COMMANDS: [&str; 1] = [COMMAND];
/// How long an armed lane blocks when the request names no `ms` (done check 7: 3 s).
const DEFAULT_BLOCK: Duration = Duration::from_millis(3000);

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[crate::server::routes::RouteName::OneOf(&COMMANDS)],
        stage: crate::server::FrameStage::Route,
        entry: |line| try_handle(line.mux, line.client, line.message, line.writer),
    }];

/// The daemon's watched lanes (`every_watch_kind_is_listed` keeps it whole).
const DAEMON_LANES: &[WatchKind] = &[
    WatchKind::MuxConn,
    WatchKind::JournalWriter,
    #[cfg(unix)]
    WatchKind::HolderLink,
    WatchKind::LineOut,
    WatchKind::PtyInput,
    WatchKind::AttachOut,
    WatchKind::RenderAttachOut,
];

/// What a request asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Request {
    Arm { lane: String, pid: u32, block: Duration },
    Disarm { lane: String, pid: u32 },
    List,
}

/// Answer a `debug-hang-inject` line; `None` for any other line.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    let Ok(Value::Object(mut fields)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    if fields.get("cmd").and_then(Value::as_str) != Some(COMMAND) {
        return None;
    }
    let id = fields.remove("id");
    fields.remove("cmd");
    let reply = if mux.control_clients.is_unix(client) {
        parse(fields, std::process::id()).and_then(|request| {
            let hang_log = crate::diagnostics::owner_hang_log_path(&mux.session);
            answer(&request, hang_inject::page(), hang_log)
        })
    } else {
        Err(format!("{COMMAND} requires a trusted local connection"))
    };
    Some(match reply {
        Ok(data) => send_response(
            writer,
            Response {
                id,
                ok: true,
                data: Some(data),
                error: None,
                error_code: None,
                error_delivery: None,
            },
        ),
        Err(error) => send_request_error(writer, id, &error),
    })
}

/// Reads the request's fields; any other field is refused. `daemon` is the
/// pid an arm without `pid` is for.
fn parse(mut fields: Map<String, Value>, daemon: u32) -> Result<Request, String> {
    let action = match fields.remove("action") {
        None => "arm".to_owned(),
        Some(Value::String(action)) => action,
        Some(_) => return Err(bad("action must be arm, disarm or list")),
    };
    let lane = match fields.remove("lane") {
        None => None,
        Some(Value::String(lane)) => Some(lane),
        Some(_) => return Err(bad("lane must be a string")),
    };
    let pid = match fields.remove("pid") {
        None => daemon,
        Some(value) => value
            .as_u64()
            .and_then(|pid| u32::try_from(pid).ok())
            .filter(|pid| *pid != 0)
            .ok_or_else(|| bad("pid must be a process id"))?,
    };
    let block = match fields.remove("ms") {
        None => DEFAULT_BLOCK,
        Some(value) => value
            .as_u64()
            .map(Duration::from_millis)
            .ok_or_else(|| bad("ms must be a whole number of milliseconds"))?,
    };
    if let Some(field) = fields.keys().next() {
        return Err(bad(&format!("{COMMAND} takes no field {field:?}")));
    }
    match (action.as_str(), lane) {
        ("arm", Some(lane)) => Ok(Request::Arm { lane, pid, block }),
        ("disarm", Some(lane)) => Ok(Request::Disarm { lane, pid }),
        ("list", None) => Ok(Request::List),
        ("arm" | "disarm", None) => Err(bad("lane is required")),
        ("list", Some(_)) => Err(bad("list takes no lane")),
        _ => Err(bad("action must be arm, disarm or list")),
    }
}

fn bad(why: &str) -> String {
    format!("bad request: {why}")
}

/// Runs `request` on `page` (None: the page could not be mapped) and reports it.
fn answer(
    request: &Request,
    page: Option<&Page>,
    hang_log: Option<std::path::PathBuf>,
) -> Result<Value, String> {
    let mut reply = Map::new();
    match request {
        Request::Arm { lane, pid, block } => {
            page.ok_or(InjectError::NotMapped)
                .and_then(|page| page.arm(lane, *pid, *block))
                .map_err(|error| format!("{COMMAND}: {error}"))?;
            reply.insert("armed".into(), json!(lane));
            reply.insert("for_pid".into(), json!(pid));
            reply.insert("ms".into(), json!(millis(*block)));
        }
        Request::Disarm { lane, pid } => {
            reply.insert("disarmed".into(), json!(page.map_or(0, |page| page.disarm(lane, *pid))));
        }
        Request::List => {}
    }
    reply.insert(
        "page".into(),
        hang_inject::page_path().map_or(Value::Null, |path| json!(path.display().to_string())),
    );
    reply.insert(
        "entries".into(),
        Value::Array(page.map_or_else(Vec::new, Page::entries).iter().map(entry_json).collect()),
    );
    reply.insert("pid".into(), json!(std::process::id()));
    // Where this daemon's watchdog writes each hang (the holder's arrive there too).
    reply.insert(
        "hang_log".into(),
        hang_log.map_or(Value::Null, |path| json!(path.display().to_string())),
    );
    reply.insert(
        "lanes".into(),
        Value::Array(
            DAEMON_LANES
                .iter()
                .map(|kind| json!({"name": kind.name(), "hang_ms": millis(kind.hang())}))
                .collect(),
        ),
    );
    Ok(Value::Object(reply))
}

fn entry_json(entry: &EntryState) -> Value {
    json!({"lane": entry.lane, "pid": entry.pid, "ms": entry.block_ms, "taken": entry.taken})
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
#[path = "debug_hang_inject_tests.rs"]
mod tests;
