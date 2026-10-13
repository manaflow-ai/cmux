//! Folder trust for a chat of this machine (`agent-session-trust-v1`,
//! cx-1bhjj): the app on another Mac (through the SSH or Cloud carrier)
//! reads the trust of a folder of THIS machine and records the person's
//! answer in this machine's acpmux, so a chat that `agent-session-start`
//! refused with `agent_session.untrusted_folder` can start once the person
//! trusts the folder.
//!
//! `agent-session-trust {surface, cwd, level?}`: without `level` it answers
//! acpmux's `acp.trust.get {cwd}`; with `level` (`trusted`, `untrusted` or
//! `unknown`) it answers acpmux's `acp.trust.set {cwd, level}`. The daemon
//! never answers by itself: the client sends a set only for the person's
//! own answer (the app's relay needs a fresh gesture for a set that trusts),
//! as the app does for a chat on this Mac's acpmux. acpmux takes the answer
//! from this daemon as a unix client, as from the person's own CLI.
//!
//! Who and where: the same as `agent-session-start` (trusted local
//! connections; an agent tab of this store whose record names this store;
//! the machine kind gate), so a team VM or a Cloud VM of unknown kind
//! records no trust from here. The tab may already have a session.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_start::{connect, store_host};
use super::{MessageWriter, Refusal, SurfaceId, ok, refuse};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::ConversationTabRecord;

pub const AGENT_SESSION_TRUST_CAPABILITY: &str = "agent-session-trust-v1";

const MAX_CWD_BYTES: usize = 4096;
const CALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const THREAD_STACK_BYTES: usize = 256 * 1024;
/// Trust calls that may run at once on one daemon (each waits up to
/// `CALL_TIMEOUT` on acpmux).
const MAX_CALLS: usize = 8;
static RUNNING: AtomicUsize = AtomicUsize::new(0);

/// A taken call slot, given back on drop (also on a panic).
struct CallSlot;

impl CallSlot {
    fn take() -> Option<Self> {
        RUNNING
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| (n < MAX_CALLS).then_some(n + 1))
            .ok()
            .map(|_| Self)
    }
}

impl Drop for CallSlot {
    fn drop(&mut self) {
        RUNNING.fetch_sub(1, Ordering::SeqCst);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct TrustParams {
    surface: SurfaceId,
    cwd: String,
    #[serde(default)]
    level: Option<String>,
}

impl TrustParams {
    fn valid(&self) -> bool {
        let cwd = &self.cwd;
        (1..=MAX_CWD_BYTES).contains(&cwd.len())
            && cwd.starts_with('/')
            && !cwd.chars().any(char::is_control)
            && self
                .level
                .as_deref()
                .is_none_or(|level| matches!(level, "trusted" | "untrusted" | "unknown"))
    }
}

/// `agent-session-trust` of a trusted local connection (the parent checked
/// trust and the acpmux socket).
pub(super) fn trust(
    mux: &Arc<Mux>,
    id: Option<Value>,
    socket: PathBuf,
    params: TrustParams,
    writer: &MessageWriter,
) -> bool {
    if !params.valid() {
        return refuse(writer, id, Refusal::BadRequest);
    }
    if let Err(refusal) = mux.agent_host_gate() {
        return refuse(writer, id, refusal);
    }
    if !own_agent_tab(mux, params.surface) {
        return refuse(writer, id, Refusal::UnknownTab);
    }
    let Some(slot) = CallSlot::take() else {
        return refuse(writer, id, Refusal::Limit);
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-trust".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let result = run(&worker_mux, &socket, &params);
            drop(slot);
            match result {
                Ok(data) => ok(&worker_writer, worker_id, data),
                Err(refusal) => refuse(&worker_writer, worker_id, refusal),
            }
        });
    if spawned.is_err() {
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

/// True when `surface` is an agent tab whose record names this store.
fn own_agent_tab(mux: &Mux, surface: SurfaceId) -> bool {
    let Some(runtime) = mux.surface(surface) else { return false };
    matches!(
        mux.conversation_tab_of(&runtime),
        Some(ConversationTabRecord::AgentSession { host, .. }) if host == store_host(mux)
    )
}

fn run(mux: &Mux, socket: &std::path::Path, params: &TrustParams) -> Result<Value, Refusal> {
    let link = connect(mux, socket)?;
    let result = match &params.level {
        None => link.call("acp.trust.get", json!({"cwd": params.cwd}), CALL_TIMEOUT),
        Some(level) => {
            link.call("acp.trust.set", json!({"cwd": params.cwd, "level": level}), CALL_TIMEOUT)
        }
    }
    .map_err(Refusal::of);
    link.close();
    result
}
