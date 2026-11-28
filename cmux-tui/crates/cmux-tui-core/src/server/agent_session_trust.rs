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
//! the machine kind gate), so a team VM, and a Cloud VM unless the caller
//! sends `vm_kind: "owner"` (`agent-session-trust-vm-kind-v1`, the Cloud
//! API's answer for it on its link), records no trust from here. A page
//! (the routed operations) cannot vouch for that answer, so it reaches no
//! Cloud VM's trust. The tab may already have a session.
//!
//! Folder rule, as for a chat on the Mac (`workspace.agent_start.get`): a
//! trust answer for `/` or a folder above this user's home folder is refused
//! (`agent_session.above_home`), and the home folder itself is trusted only
//! with `home_confirmed` (the person first chose it as the chat's folder;
//! `agent_session.home_unconfirmed` otherwise), so one click never trusts a
//! whole home folder.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_start::{connect, store_host, vm_word};
use super::{MessageWriter, Refusal, SurfaceId, ok, refuse};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::ConversationTabRecord;

pub const AGENT_SESSION_TRUST_CAPABILITY: &str = "agent-session-trust-v1";
/// `vm_kind` on `agent-session-trust`, as on `agent-session-start`.
pub const AGENT_SESSION_TRUST_VM_KIND_CAPABILITY: &str = "agent-session-trust-vm-kind-v1";

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
    #[serde(default)]
    home_confirmed: bool,
    /// The Cloud API's `vmKind` for the caller (only `owner` counts; an
    /// explicit `null` is a word, and refuses).
    #[serde(default, deserialize_with = "crate::server::command_args::present_nullable")]
    vm_kind: Option<Option<String>>,
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
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    params: TrustParams,
    writer: &MessageWriter,
) -> bool {
    if !params.valid() {
        return refuse(writer, id, Refusal::BadRequest);
    }
    if let Err(refusal) = mux.agent_host_gate(client, vm_word(&params.vm_kind)) {
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
pub(super) fn own_agent_tab(mux: &Mux, surface: SurfaceId) -> bool {
    let Some(runtime) = mux.surface(surface) else { return false };
    matches!(
        mux.conversation_tab_of(&runtime),
        Some(ConversationTabRecord::AgentSession { host, .. }) if host == store_host(mux)
    )
}

/// The home folder rule of a remote chat's folder (see the module doc),
/// shared with `agent-session-start`: `/` and the folders above this user's
/// home folder are refused, the home folder needs `home_confirmed`. Fails
/// closed: with no home folder known, every folder needs `home_confirmed`.
pub(super) fn home_rule(cwd: &str, home_confirmed: bool) -> Result<(), Refusal> {
    let canonical = |path: &std::path::Path| std::fs::canonicalize(path).ok();
    // A folder that does not exist is acpmux's to refuse.
    let Some(cwd) = canonical(cwd.as_ref()) else { return Ok(()) };
    if cwd.parent().is_none() {
        return Err(Refusal::AboveHome);
    }
    let Some(home) = crate::platform::home_dir().and_then(|home| canonical(&home)) else {
        return if home_confirmed { Ok(()) } else { Err(Refusal::HomeUnconfirmed) };
    };
    if cwd == home {
        return if home_confirmed { Ok(()) } else { Err(Refusal::HomeUnconfirmed) };
    }
    if home.starts_with(&cwd) { Err(Refusal::AboveHome) } else { Ok(()) }
}

/// Whether a call runs on the caller's own Cloud VM: the machine kind gate
/// reads a Cloud VM and the caller's `vm_kind` is exactly `owner`, the Cloud API's
/// answer for it, which it gives the machine's creator alone (also on a team
/// VM, #28788). The machine kind gate ran before, so a word it refused never
/// reaches here.
pub(super) fn callers_own_cloud_vm(mux: &Mux, vm_kind: &Option<Option<String>>) -> bool {
    vm_word(vm_kind) == Some("owner") && mux.control_clients.agent_sessions.starts.on_cloud_vm()
}

/// The folder a start on the caller's own Cloud VM runs in when no folder was
/// selected. It is made per chat under `~/chats/<chat-id>` so separate chats
/// never share state. An older caller that supplied the home folder without a
/// confirmation is treated as the same no-folder choice; an explicitly chosen
/// folder (including Use Home Folder) is preserved.
pub(super) fn owner_cloud_cwd(
    own: bool,
    cwd: Option<&str>,
    home_confirmed: bool,
    chat_id: u64,
) -> Option<String> {
    if !own || home_confirmed {
        return None;
    }
    let no_folder = match cwd {
        None => true,
        Some(cwd) => {
            let home =
                crate::platform::home_dir().and_then(|home| std::fs::canonicalize(home).ok());
            home.zip(std::fs::canonicalize(cwd).ok()).is_some_and(|(home, cwd)| home == cwd)
        }
    };
    no_folder
        .then(|| super::agent_session_folders::own_chat_folder(chat_id, true))
        .flatten()
        .map(|path| path.to_string_lossy().into_owned())
}

/// acpmux's trust answer (`acp.trust.get`) for the caller's own Cloud VM:
/// the machine's own work folder (`$HOME/work`, exactly) is the person's, so
/// with no decision of acpmux's and no agent holding it untrusted it reads
/// trusted, as acpmux answers a folder cmux made (`decided`, `auto`:
/// `cloud_work`), and a new chat there starts with no trust question. The
/// rule widens an unknown only: a person's "Don't trust" (a decision) and an
/// agent's own untrusted level still win, and it never applies to another
/// folder, another machine or a caller without the owner word.
pub(super) fn owner_cloud_trust(own: bool, mut answer: Value) -> Value {
    if !own || answer.get("decided").and_then(Value::as_bool) == Some(true) {
        return answer;
    }
    let untrusted = |name: &str| {
        answer.pointer(&format!("/harnesses/{name}")).and_then(Value::as_str) == Some("untrusted")
    };
    if untrusted("claude") || untrusted("codex") {
        return answer;
    }
    let canonical = |path: &str| std::fs::canonicalize(path).ok();
    let work = super::agent_session_folders::own_work_folder(false);
    let at_work = answer.get("cwd").and_then(Value::as_str).and_then(canonical);
    let chat_root = crate::platform::home_dir().and_then(|home| {
        std::fs::canonicalize(home)
            .ok()
            .map(|home| home.join(super::agent_session_folders::CHAT_FOLDER))
    });
    let at_chat = answer.get("cwd").and_then(Value::as_str).and_then(canonical);
    let in_chat = chat_root.as_ref().is_some_and(|root| {
        super::agent_session_folders::private_owned_dir(root)
            && at_chat.as_ref().is_some_and(|path| {
                path.parent() == Some(root) && super::agent_session_folders::private_owned_dir(path)
            })
    });
    if (work.is_none() || at_work != work) && !in_chat {
        return answer;
    }
    if let Some(object) = answer.as_object_mut() {
        object.insert("level".into(), json!("trusted"));
        object.insert("decided".into(), json!(true));
        object.insert("auto".into(), json!(if in_chat { "cloud_chat" } else { "cloud_work" }));
    }
    answer
}

/// `agent_session.trust.get` and `agent_session.trust.set`: the verb for a
/// page, as a routed v2 operation (page-router.json namespace
/// `agent_session`, hq-6d). The page router already applied the page's allow
/// list (only page `agent` reads or answers) and, for a set, the person's
/// gesture (a host confirmation for exactly this request) and origin user.
/// The rest is the verb's: a trusted local connection, the machine kind
/// gate, an agent tab of this store, the home folder rule.
pub(super) fn routed(
    mux: &Mux,
    client: u64,
    operation: &str,
    mut params: serde_json::Map<String, Value>,
) -> Result<Value, crate::resource::ResourceError> {
    let fail = |refusal: Refusal| {
        crate::resource::ResourceError::operation_failed(
            operation,
            refusal.message(),
            json!({"code": refusal.code()}),
        )
    };
    let setting = operation == "agent_session.trust.set";
    params.remove("idempotency_key");
    let params: TrustParams =
        serde_json::from_value(Value::Object(params)).map_err(|_| fail(Refusal::BadRequest))?;
    if !params.valid() || params.level.is_some() != setting {
        return Err(fail(Refusal::BadRequest));
    }
    // A page cannot prove the person chose the home folder first (Use Home
    // Folder), and one confirmed click must never trust a whole home folder:
    // a page never trusts it (home_rule refuses it without home_confirmed).
    // Nor can it vouch for the Cloud API's answer: no `vm_kind` from a page.
    if params.home_confirmed || params.vm_kind.is_some() {
        return Err(fail(Refusal::BadRequest));
    }
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Err(fail(Refusal::NotTrusted));
    }
    mux.agent_host_gate(client, None).map_err(fail)?;
    if !own_agent_tab(mux, params.surface) {
        return Err(fail(Refusal::UnknownTab));
    }
    let socket = mux.control_clients.agent_sessions.socket().ok_or(fail(Refusal::Unavailable))?;
    let Some(_slot) = CallSlot::take() else { return Err(fail(Refusal::Limit)) };
    run(mux, &socket, &params).map_err(fail)
}

fn run(mux: &Mux, socket: &std::path::Path, params: &TrustParams) -> Result<Value, Refusal> {
    if params.level.as_deref() == Some("trusted") {
        home_rule(&params.cwd, params.home_confirmed)?;
    }
    let link = connect(mux, socket)?;
    let own = callers_own_cloud_vm(mux, &params.vm_kind);
    let result = match &params.level {
        None => link
            .call("acp.trust.get", json!({"cwd": params.cwd}), CALL_TIMEOUT)
            .map(|answer| owner_cloud_trust(own, answer)),
        Some(level) => {
            link.call("acp.trust.set", json!({"cwd": params.cwd, "level": level}), CALL_TIMEOUT)
        }
    }
    .map_err(Refusal::of);
    link.close();
    result
}
