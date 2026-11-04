//! The agent setup request (`_acpmux/agent_setup {sessionId}`): what a chat's agent is told beside
//! the person's messages (`agent_setup.rs`), for the app's Agent setup viewer. Read only; the
//! viewer saves the chat's preset's system prompt with `_acpmux/agent_setup/save {sessionId,
//! systemPrompt}`, a `_acpmux/presets` write (`presets.rs`) named by the chat, so the app's pane
//! (which may send only methods about its own chats) never names a preset itself.

use super::*;

/// `{harness, family, harnessPrompt, servers: [{name, instructions, tools}], preset}`. `preset` is
/// null for a chat started without one, else `{name, hasSystemPrompt, systemPrompt,
/// takesSystemPrompt, editable}`. Like `_acpmux/presets` (`redact.rs`), no other connection reads a
/// preset's contents: the prompt's text, and `editable`, only for the unix socket and the app's
/// pane proven as the person (`presets::writes_command`), the one that may save it; `systemPrompt`
/// is null for every other.
pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    let s = hub.resolve_told(session_key(params)?, conn.origin == Origin::Local)?;
    let meta = s.meta();
    let cfg = hub.config.read().await;
    let profile = cfg.harnesses.get(&meta.harness);
    let family = meta
        .family
        .clone()
        .or_else(|| profile.map(|h| crate::config::derive_family(&meta.harness, h)))
        .unwrap_or_default();
    let preset = meta.preset.as_deref().and_then(|n| cfg.presets.get(n).map(|p| (n, p)));
    // The env and args the session's tools are judged by (`agent_tools::left_out`): its
    // profile's, then its preset's on top.
    let mut env = profile.map(|h| h.env.clone()).unwrap_or_default();
    let mut args = profile.map(|h| h.argv.clone()).unwrap_or_default();
    if let Some((_, p)) = preset {
        env.extend(p.env.clone());
        args.extend(p.args.clone());
    }
    let names = crate::agent_setup::server_names(
        &crate::agent_tools::current(),
        meta.remote_origin,
        &env,
        &args,
    );
    let takes_prompt = profile.is_some_and(|h| h.kind == crate::config::HarnessKind::ClaudeStdio);
    let own = presets::writes_command(conn);
    let preset = preset.map(|(name, p)| {
        let text = (own && p.system_prompt_sha256.is_some())
            .then(|| cfg.presets_dir())
            .flatten()
            .and_then(|dir| {
                std::fs::read_to_string(
                    crate::config::preset_dir(&dir, name).join(crate::config::SYSTEM_PROMPT_FILE),
                )
                .ok()
            });
        json!({
            "name": name,
            "hasSystemPrompt": p.system_prompt_sha256.is_some(),
            "systemPrompt": text,
            "takesSystemPrompt": takes_prompt,
            "editable": takes_prompt && own,
        })
    });
    Ok(json!({
        "harness": meta.harness,
        "family": family,
        "harnessPrompt": crate::agent_setup::harness_prompt(&family),
        "servers": names.iter().map(|n| crate::agent_setup::server(n)).collect::<Vec<_>>(),
        "preset": preset,
    }))
}

/// `_acpmux/agent_setup/save {sessionId, systemPrompt}`: sets (a string) or removes (null) the
/// system prompt of the preset the chat was started from, then answers like [`handle`]. New sessions
/// of the preset start with it; the chat itself keeps the prompt its agent started with.
pub(super) async fn save(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    let prompt = match params.get("systemPrompt") {
        Some(Value::String(text)) => json!(text),
        Some(Value::Null) => Value::Null,
        _ => {
            return Err(RpcError::invalid_params(
                "systemPrompt must be the prompt's text (a string) or null",
            ));
        }
    };
    let s = hub.resolve_told(session_key(params)?, conn.origin == Origin::Local)?;
    let Some(preset) = s.meta().preset else {
        return Err(RpcError::invalid_params(
            "this chat was started without a preset, so it has no system prompt to save",
        ));
    };
    presets::handle(hub, conn, &json!({"name": preset, "set": {"systemPrompt": prompt}})).await?;
    handle(hub, conn, params).await
}
