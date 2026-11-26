//! ACP `session/fork` (`requests.rs`): a new chat from a chat's history.

use super::*;

pub(super) async fn fork(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
    resolved: Option<Arc<crate::hub::Session>>,
) -> Result<Value, RpcError> {
    let s = resolved_session(hub, resolved.as_ref(), &params)?;
    let cwd = str_param(&params, "cwd").map(PathBuf::from);
    let name = mux_meta(&params)
        .and_then(|m| m.get("name"))
        .and_then(Value::as_str)
        .or_else(|| params.get("name").and_then(Value::as_str))
        .map(str::to_owned);
    let env = crate::session_env::parse(mux_meta(&params))?;
    let workspace_id = crate::session_env::workspace_id(mux_meta(&params), &env)?;
    let through = super::fork_through::through(&params);
    let start_later = super::fork_through::starts_later(&params);
    // A remote device's switch is its new chat (`hub/fork.rs` `Retarget::remote`); the
    // owner's own daemon's is this machine's (`remote_guard::owner_control`).
    let remote_switch = conn.origin.web_class()
        && !super::remote_guard::owner_control(conn.origin, conn.auth, &params);
    let retarget = super::fork_through::retarget(&params)?
        .map(|r| crate::hub::Retarget { remote: remote_switch, ..r });
    let switched = retarget.is_some();
    // A subagent's own conversation, a model, a mode (`hub/fork_subagent.rs`). The mode
    // pick is the person's own on this Mac: one that does not ask widens a narrow policy
    // first, as their mode pick does (`SESSION_SET_MODE` below).
    let start = crate::hub::fork_subagent::ForkStart::from_params(
        &params,
        conn.is_person() && !conn.origin.web_class(),
    )?;
    let who = who(conn);
    let (new, warning) = if let Some(prompt) =
        params.pointer("/_meta/acpmux/beforePromptId").and_then(Value::as_str)
    {
        // A switch forks the chat as it is now; a fork before a prompt keeps its harness.
        if retarget.is_some() || !start.is_plain() {
            return Err(RpcError::invalid_params(
                "a fork before a prompt keeps the chat's harness: omit harness",
            ));
        }
        let request =
            params.pointer("/_meta/acpmux/requestId").and_then(Value::as_str).unwrap_or_default();
        Box::pin(hub.fork_before(&s, prompt, request, ask(conn, &params, &who))).await?
    } else {
        // Fork Conversation's Cancel names the fork by this token (`hub/fork_cancel.rs`),
        // from before its admission: a Cancel while it is admitted stops it too.
        let token = params.pointer("/_meta/acpmux/cancelToken").and_then(Value::as_str);
        let fork = async {
            let admitted = hub.admit_new(ask(conn, &params, &who)).await?;
            if crate::hub::fork_cancel::cancelled() {
                return Err(crate::hub::fork_cancel::cancelled_refusal());
            }
            // Onto another harness (`_meta.acpmux.harness`, `hub/fork.rs` `Retarget`): a
            // pick of another harness's model in a started chat, at its next send.
            let new = match retarget {
                _ if !start.is_plain() => {
                    if through.is_some() {
                        return Err(RpcError::invalid_params(
                            "a fork of a subagent, or one on a picked model or mode, forks the chat as it is now: omit throughSeq",
                        ));
                    }
                    let fork = hub.fork_with_start(
                        &s,
                        retarget,
                        name,
                        cwd,
                        env,
                        workspace_id,
                        start_later,
                        start,
                    );
                    admitted.run(fork).await?
                }
                Some(retarget) => {
                    let fork = hub.fork_to(&s, retarget, name, cwd, env, workspace_id, start_later);
                    admitted.run(fork).await?
                }
                None => {
                    let fork = hub.fork(&s, name, cwd, env, workspace_id, through, start_later);
                    admitted.run(fork).await?
                }
            };
            Ok((new, admitted.warning.clone()))
        };
        // One fork per `requestId`: a retry after a restart gets the fork it made
        // (`hub/fork_request.rs`, cmux#50084).
        let request = params.pointer("/_meta/acpmux/requestId").and_then(Value::as_str);
        hub.fork_once(&s, request, hub.fork_cancellable(token, fork)).await?
    };
    // Onto another harness from a remote device: the mode a chat that device starts runs
    // in (`session/new` above), its family's reviewed asking default, or the fork is
    // ended and refused. A plain fork keeps the chat's mode, which the guard checked.
    if switched && remote_switch {
        let peer = super::remote_guard::settles_as_peer(conn.origin, conn.auth, &params);
        let cloud_mobile = super::remote_guard::cloud_mobile(&params);
        heap(|| super::remote_guard::settle_web_session_mode(hub, &new, peer, cloud_mobile))
            .await?;
    }
    attach(hub, conn, &new.id);
    let meta = new.meta();
    let mut summary = hub.session_summary(&new);
    if let Some(w) = warning {
        summary.set("admission", w);
    }
    Ok(
        json!({"sessionId": new.id, "modes": crate::hub::permission_modes::of_session(&meta), "configOptions": meta.config_options, "_meta": {"acpmux": summary}}),
    )
}
