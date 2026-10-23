//! Remote agent session adopt (`agent-session-adopt-v1`): a trusted local
//! client (an app on another Mac, through the SSH or Cloud carrier) opens a
//! chat that already runs in THIS machine's acpmux (an agent or `cmux agent
//! open` started it here) in an agent tab of this daemon's store, and the
//! daemon binds it to the tab. The app then shows it through
//! `agent-session-attach-v1`, as for a started chat.
//!
//! `agent-session-adopt {surface, session}` answers `{surface, session,
//! conversation, family, mode, asking}`.
//!
//! Scope: the tab is checked as for `agent-session-start` (an unbound
//! `agent_session` tab of this store), and the session must be one this
//! machine's own acpmux lists (`_acpmux/sessions`): never a chat mirrored
//! from a peer (a session never leaves its machine, cx-k21v), never the Home
//! Chief's, never an id acpmux does not know (`agent_session.unknown_session`).
//! acpmux is never started for an adopt: nothing listening runs no chat.
//!
//! Permissions: the session keeps its mode. A chat in a mode that does not ask
//! before acting (bypass) is adopted too, only on a host the start's host gate
//! allows (a Mac, an SSH host or an owner-bound Cloud VM the person enrolled;
//! never a team VM or a Cloud VM of unknown kind), and the answer says so
//! (`asking: false`), which the app shows as a "bypass" badge on the
//! workspace. The daemon changes no mode.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_link::AcpmuxLink;
use super::agent_session_start::{
    AgentSessionStarts, CALL_TIMEOUT, THREAD_STACK_BYTES, checked_mode, is_chief, read_mode,
    startable,
};
use super::{MessageWriter, Refusal, SurfaceId, ok, refuse};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::{validate_harness, validate_session};

pub const AGENT_SESSION_ADOPT_CAPABILITY: &str = "agent-session-adopt-v1";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ModeParams {
    surface: SurfaceId,
}

/// At most [`MAX_MODE_READS`] `agent-session-mode` reads run at once, each on
/// its own thread and acpmux connection; one more is `agent_session.limit`.
const MAX_MODE_READS: usize = 8;
static MODE_READS: AtomicUsize = AtomicUsize::new(0);

/// One running mode read; dropping it frees the slot.
struct ModeRead;

impl ModeRead {
    fn admit() -> Option<Self> {
        MODE_READS
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < MAX_MODE_READS).then_some(n + 1)
            })
            .ok()
            .map(|_| Self)
    }
}

impl Drop for ModeRead {
    fn drop(&mut self) {
        MODE_READS.fetch_sub(1, Ordering::AcqRel);
    }
}

/// `agent-session-mode {surface}` of a trusted local connection (the parent
/// checked trust and the acpmux socket): the mode of the chat the tab is bound
/// to, `{surface, session, family, mode, asking}`, read from this machine's
/// acpmux. Read-only: the app reads it once for each bound tab it lists at a
/// connect (a restored tab it does not show), so the bypass badge never
/// depends on what this app remembers.
pub(super) fn mode(
    mux: &Arc<Mux>,
    id: Option<Value>,
    socket: PathBuf,
    params: ModeParams,
    writer: &MessageWriter,
) -> bool {
    let Some(session) = super::tab_session(mux, params.surface) else {
        return refuse(writer, id, Refusal::UnknownTab);
    };
    let Some(slot) = ModeRead::admit() else {
        return refuse(writer, id, Refusal::Limit);
    };
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-mode".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let _slot = slot;
            let read = AcpmuxLink::connect(&socket, |_| {})
                .map_err(|_| Refusal::Unavailable)
                .and_then(|link| {
                    let read = read_mode(&link, &session);
                    link.close();
                    read
                });
            match read {
                Ok(mut facts) => {
                    facts["surface"] = json!(params.surface);
                    ok(&worker_writer, worker_id, facts)
                }
                Err(refusal) => refuse(&worker_writer, worker_id, refusal),
            };
        });
    if spawned.is_err() {
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AdoptParams {
    surface: SurfaceId,
    session: String,
}

/// `agent-session-adopt` of a trusted local connection (the parent checked
/// trust and the acpmux socket).
pub(super) fn adopt(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    params: AdoptParams,
    writer: &MessageWriter,
) -> bool {
    if validate_session(&params.session).is_err() {
        return refuse(writer, id, Refusal::BadRequest);
    }
    if let Err(refusal) = mux.control_clients.agent_sessions.starts.host_gate() {
        return refuse(writer, id, refusal);
    }
    if let Err(refusal) = startable(mux, params.surface) {
        return refuse(writer, id, refusal);
    }
    let Some(slot) = AgentSessionStarts::reserve(mux, params.surface) else {
        return refuse(writer, id, Refusal::Limit);
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-adopt".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let result = run(&worker_mux, client, &socket, &params);
            drop(slot);
            match result {
                Ok(data) => ok(&worker_writer, worker_id, data),
                Err(refusal) => refuse(&worker_writer, worker_id, refusal),
            };
        });
    // A failed spawn drops the closure and with it the slot.
    if spawned.is_err() {
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

fn run(
    mux: &Arc<Mux>,
    client: u64,
    socket: &std::path::Path,
    params: &AdoptParams,
) -> Result<Value, Refusal> {
    let link = AcpmuxLink::connect(socket, |_| {}).map_err(|_| Refusal::AcpmuxUnavailable)?;
    let result = adopt_and_bind(mux, client, &link, params);
    link.close();
    result
}

fn adopt_and_bind(
    mux: &Arc<Mux>,
    client: u64,
    link: &AcpmuxLink,
    params: &AdoptParams,
) -> Result<Value, Refusal> {
    let listed = link.call("_acpmux/sessions", json!({}), CALL_TIMEOUT).map_err(Refusal::of)?;
    let summary = own_session(&listed, &params.session).ok_or(Refusal::UnknownSession)?;
    let table = link
        .call("_acpmux/web_modes", json!({"sessionId": params.session}), CALL_TIMEOUT)
        .map_err(Refusal::of)?;
    let facts = checked_mode(&params.session, &table)?;
    let family = facts["family"].as_str().unwrap_or_default();
    // The tab's brand mark: the agent acpmux runs (a profile by its last
    // part), else its family.
    let harness = [summary.get("harness").and_then(Value::as_str), Some(family)]
        .into_iter()
        .flatten()
        .filter_map(|harness| harness.rsplit('/').next())
        .find(|harness| validate_harness(harness).is_ok());
    // The tab may have closed, or a start or adopt bound it, meanwhile.
    let actor = super::super::origin_gate::connection_actor(mux, client);
    let (record, _) = mux
        .bind_conversation_tab_session_as(&actor, params.surface, &params.session, None, harness)
        .map_err(|_| startable(mux, params.surface).err().unwrap_or(Refusal::Refused))?;
    Ok(json!({
        "surface": params.surface,
        "session": params.session,
        "conversation": record.wire(),
        "family": family,
        "mode": facts["mode"],
        "asking": facts["asking"],
    }))
}

/// `session`'s summary in a `_acpmux/sessions` answer when it is a chat of
/// this machine: not mirrored from a peer and not the Home Chief's.
fn own_session<'a>(listed: &'a Value, session: &str) -> Option<&'a Value> {
    let list = listed.get("sessions").unwrap_or(listed).as_array()?;
    list.iter().find(|summary| {
        summary.get("sessionId").and_then(Value::as_str) == Some(session)
            && summary.get("peer").is_none_or(Value::is_null)
            && !is_chief(summary)
    })
}
