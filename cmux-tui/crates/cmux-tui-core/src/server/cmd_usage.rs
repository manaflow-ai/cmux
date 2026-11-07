//! `usage-record`, `usage-set-enabled` and `usage-set-sharing`: the app's
//! opt-in usage recording (cmux-usage: interaction shape, never content) and
//! its second opt-in, sharing it with the team. The verified cmux app only
//! (the `frontend` actor): the app sends each switch after the person's own
//! write and per-Mac consent, so no other client (an agent in a pane, a
//! script, the `cmux` CLI, a remote or WebSocket peer) can switch recording or
//! sharing on or write into the person's usage folder. Each function is one
//! `Command` arm of `handle_command_with_cancellation`.
//!
//! A request runs on its connection's own thread (server/line_connection.rs),
//! so the append is a plain file write here; it holds only this module's
//! lock, never a mux-wide one.

use crate::Mux;
use cmux_usage::{Recorder, Source, UsageDir};
use parking_lot::Mutex;
use serde::Deserialize;
use serde_json::Value;
use serde_json::json;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

/// `usage-record`: `source` is the writer's file stem (`app-nightly`), `events`
/// the text of a JSON array of `{"at": ms, "ev": {...}}`.
#[derive(Deserialize)]
pub(super) struct RecordParams {
    source: String,
    events: String,
}

/// `usage-set-enabled`.
#[derive(Deserialize)]
pub(super) struct SetEnabledParams {
    on: bool,
}

/// `usage-set-sharing`.
#[derive(Deserialize)]
pub(super) struct SetSharingParams {
    on: bool,
}

/// Writers kept at once. A source is a client-named stem, so the map is
/// bounded: past this many it starts over (a `Recorder` holds only its
/// cached salt, so a rebuilt one costs one read of the salt file).
const MAX_RECORDERS: usize = 16;

/// One `Recorder` per (usage folder, source stem), so each keeps its salt.
static RECORDERS: Mutex<Option<HashMap<(PathBuf, String), Recorder>>> = Mutex::new(None);

/// `usage-record`: append the app's batch to `<usage dir>/<source>.jsonl`.
pub(super) fn record(mux: &Arc<Mux>, client: u64, params: &RecordParams) -> anyhow::Result<Value> {
    require_app(mux, client)?;
    let dir = default_dir()?;
    record_in(&dir, &params.source, &params.events)
}

/// `usage-set-enabled`: write or remove the `<usage dir>/enabled` marker.
pub(super) fn set_enabled(
    mux: &Arc<Mux>,
    client: u64,
    params: &SetEnabledParams,
) -> anyhow::Result<Value> {
    require_app(mux, client)?;
    let dir = default_dir()?;
    set_enabled_in(&dir, params.on)
}

/// `usage-set-sharing`: write or remove the `<usage dir>/share` marker that
/// `cmux usage upload` requires, from this Mac's own consent in the app.
pub(super) fn set_sharing(
    mux: &Arc<Mux>,
    client: u64,
    params: &SetSharingParams,
) -> anyhow::Result<Value> {
    require_app(mux, client)?;
    let dir = default_dir()?;
    set_sharing_in(&dir, params.on)
}

/// Refuses every client but the verified cmux app: a role-main Unix
/// connection whose code signature or install key was proved in
/// `client-hello` (the check `cloud_conversations::is_app` makes).
fn require_app(mux: &Mux, client: u64) -> anyhow::Result<()> {
    if !matches!(super::origin_gate::connection_actor(mux, client), crate::Actor::Frontend { .. }) {
        anyhow::bail!(
            "usage recording and sharing are switched and written only by the verified cmux app"
        );
    }
    Ok(())
}

fn default_dir() -> anyhow::Result<UsageDir> {
    UsageDir::default_location()
        .ok_or_else(|| anyhow::anyhow!("usage folder unavailable: no home folder"))
}

/// The handler body of `usage-record`, on a given folder.
pub(super) fn record_in(dir: &UsageDir, source: &str, events: &str) -> anyhow::Result<Value> {
    let mut recorders = RECORDERS.lock();
    let recorders = recorders.get_or_insert_with(HashMap::new);
    let key = (dir.path().to_path_buf(), source.to_owned());
    if !recorders.contains_key(&key) && recorders.len() >= MAX_RECORDERS {
        recorders.clear();
    }
    let recorder =
        recorders.entry(key).or_insert_with(|| Recorder::new(dir.clone(), Source::App, source));
    let written = recorder.append_json(events).map_err(|error| {
        if error.kind() == std::io::ErrorKind::InvalidData {
            anyhow::anyhow!("bad request: events: {error}")
        } else {
            anyhow::anyhow!("usage record failed: {error}")
        }
    })?;
    Ok(json!({ "written": written }))
}

/// The handler body of `usage-set-enabled`, on a given folder.
pub(super) fn set_enabled_in(dir: &UsageDir, on: bool) -> anyhow::Result<Value> {
    dir.set_enabled(on).map_err(|error| anyhow::anyhow!("usage switch failed: {error}"))?;
    Ok(json!({ "on": on, "dir": dir.path().to_string_lossy() }))
}

/// The handler body of `usage-set-sharing`, on a given folder. On refuses
/// while recording is off: sharing has nothing to send without it.
pub(super) fn set_sharing_in(dir: &UsageDir, on: bool) -> anyhow::Result<Value> {
    if on && !dir.is_enabled() {
        anyhow::bail!("usage sharing needs usage recording on");
    }
    dir.set_sharing(on).map_err(|error| anyhow::anyhow!("usage sharing switch failed: {error}"))?;
    Ok(json!({ "on": on, "dir": dir.path().to_string_lossy() }))
}

#[cfg(test)]
#[path = "cmd_usage_tests.rs"]
mod tests;
