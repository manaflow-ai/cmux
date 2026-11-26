//! `agent-session-prewarm` (`agent-session-prewarm-v1`, cmux#45953): the owner's app, on the
//! owner's own Cloud VM, says which agent a new chat's coming `agent-session-start` will run, so
//! this machine's acpmux warms that agent before the start asks for it.
//!
//! A composer Cloud send copies its folder, opens the chat's tab and loads its page before the
//! page's first send starts the agent; the harness's own start (`session/new`, 3.4 to 4.3 s on a
//! fresh machine, cmux#45842's measurements) then ran after all of that, one step after another.
//! The app sends this as soon as the chat's tab and folder exist, and the start that follows
//! takes the warmed agent (acpmux `hub/pool`, `_acpmux/prewarm`).
//!
//! The params are the start's own ([`StartParams`]): the same tab, folder, agent, model and the
//! owner's model credential the start will send. acpmux keys the warmed agent by exactly what
//! the start's `session/new` carries (its folder as acpmux checked it, agent, model, workspace,
//! and the credential's spawn env), so a start that differs in any of them starts cold, as
//! before; the credential is never written anywhere and only the same credential takes the agent.
//! Gemini and Grok keys go only to the bound start, which lets Cloud opt-out withdraw them.
//!
//! Gated as the start is, and narrower: only on the caller's own Cloud VM (never a Mac, an SSH
//! host, a team VM or a phone's channel), only for an unbound agent tab of this store, only in an
//! explicit folder the home rule allows, and only in a folder whose trust answer lets the agent
//! start. It changes no tab and binds nothing; acpmux's hidden session ends by itself when no
//! start takes it (`pool.idleMinutes`).

use super::*;

pub const AGENT_SESSION_PREWARM_CAPABILITY: &str = "agent-session-prewarm-v1";

/// How long the prewarm's acpmux calls wait: acpmux accepts a hint at once and warms behind it.
const PREWARM_PATIENCE: Duration = Duration::from_secs(20);

/// What a prewarm sends acpmux (`_acpmux/prewarm`) for a start of `params` in `cwd`, the folder
/// acpmux's trust answer checked: the start's harness, model, workspace and credential, as the
/// start's own `session/new` names them (`start_and_bind`).
fn prewarm_body(params: &StartParams, cwd: &str, workspace: Option<String>) -> Value {
    let mut body = json!({"cwd": cwd});
    if let Some(harness) = &params.harness {
        body.insert("harness", json!(harness));
    }
    if let Some(model) = &params.model {
        body.insert("model", json!(model));
    }
    if let Some(workspace) = workspace {
        body.insert("workspaceId", json!(workspace));
    }
    if let Some(credentials) = &params.credentials {
        body.insert("credentials", credentials.wire());
    }
    body
}

/// `agent-session-prewarm` of a trusted local connection (the parent checked the carrier).
pub(in crate::server::agent_session_attach) fn prewarm(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    params: StartParams,
    writer: &MessageWriter,
) -> bool {
    if let Some(field) = params.invalid_field() {
        return super::super::bad_field::refuse_field(writer, id, Some(field));
    }
    if let Err(refusal) = mux.agent_host_gate(client, vm_word(&params.vm_kind)) {
        return refuse(writer, id, refusal);
    }
    // Only the caller's own Cloud VM, never a phone's channel: the start this serves is the
    // owner's own Cloud start (`credentials_admitted` holds both, also with no credential).
    let own = super::super::agent_session_trust::callers_own_cloud_vm(mux, &params.vm_kind);
    if !own || !credentials_admitted(mux, client, &params.vm_kind) {
        return refuse(writer, id, Refusal::OwnerOnly);
    }
    if let Err(refusal) = startable(mux, params.surface) {
        return refuse(writer, id, refusal);
    }
    // An explicit folder only: the start's own `~/chats/<id>` does not exist yet.
    let Some(cwd) = params.cwd.clone() else {
        return super::super::bad_field::refuse_field(writer, id, Some("cwd"));
    };
    if let Err(refusal) = super::super::agent_session_trust::home_rule(&cwd, params.home_confirmed)
    {
        return refuse(writer, id, refusal);
    }
    if params.credentials.as_ref().is_some_and(|credential| {
        credential.env.keys().any(|name| {
            matches!(name.as_str(), "GEMINI_API_KEY" | "GOOGLE_API_KEY" | "XAI_API_KEY")
        })
    }) {
        return ok(writer, id, json!({"accepted": false}));
    }
    let workspace = mux.surface_workspace_key(params.surface);
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-prewarm".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            // Never starts acpmux: one started here would run without the person's key, which
            // the start then refuses (`keyed_gate`); with nothing listening, nothing is warmed.
            let answer = match AcpmuxLink::connect(&socket, |_| {}) {
                Ok(link) => {
                    let answer = hint(&worker_mux, &link, &params, &cwd, workspace);
                    link.close();
                    answer
                }
                Err(_) => Err(Refusal::AcpmuxUnavailable),
            };
            match answer {
                Ok(data) => ok(&worker_writer, worker_id, data),
                Err(refusal) => refuse(&worker_writer, worker_id, refusal),
            };
        });
    if spawned.is_err() {
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

/// The trust check the start makes, then the hint; answers `{accepted}` (acpmux's word, never the
/// folder, agent or credential).
fn hint(
    mux: &Mux,
    link: &AcpmuxLink,
    params: &StartParams,
    cwd: &str,
    workspace: Option<String>,
) -> Result<Value, Refusal> {
    let trust =
        link.call("acp.trust.get", json!({"cwd": cwd}), PREWARM_PATIENCE).map_err(Refusal::of)?;
    let trust = super::super::agent_session_trust::owner_cloud_trust(
        super::super::agent_session_trust::callers_own_cloud_vm(mux, &params.vm_kind),
        trust,
    );
    if !folder_trusted(&trust, params.harness.as_deref()) {
        return Err(Refusal::UntrustedFolder);
    }
    // The folder acpmux checked, as the start's `session/new` sends it.
    let cwd = trust.get("cwd").and_then(Value::as_str).ok_or(Refusal::UntrustedFolder)?;
    let answer = link
        .call("_acpmux/prewarm", prewarm_body(params, cwd, workspace), PREWARM_PATIENCE)
        .map_err(Refusal::of)?;
    Ok(json!({"accepted": answer.get("accepted").and_then(Value::as_bool) == Some(true)}))
}
