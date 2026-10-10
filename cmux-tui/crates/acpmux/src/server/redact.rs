//! What a reply to a connection that is not the local unix socket may not
//! carry: any token.

use serde_json::Value;

/// A remote-origin (Web) connection never learns a token: not the
/// dashboard link (`webUrl` carries this listener's token) and not the
/// userinfo, query or fragment of a peer's URL (a user may have written a
/// peer's token there). The local socket keeps both (`acpmux web`, the app's host).
pub(super) fn redact_for_remote(method: &str, reply: &mut Value) {
    if let Some(obj) = reply.as_object_mut() {
        obj.remove("webUrl");
    }
    // A preset's args, env and system prompt never leave the unix socket
    // (the Web and the local app alike): `_acpmux/presets` (one or all) and
    // `_acpmux/harnesses` say only whether a preset has them.
    match reply.get_mut("presets") {
        Some(Value::Array(list)) => list.iter_mut().for_each(hide_preset_contents),
        Some(Value::Object(map)) => map.values_mut().for_each(hide_preset_contents),
        _ if method == "_acpmux/presets" => hide_preset_contents(reply),
        _ => {}
    }
    if let Some(peers) = reply.get_mut("peers").and_then(Value::as_array_mut) {
        for peer in peers {
            if let Some(url) = peer.get("url").and_then(Value::as_str) {
                peer["url"] = Value::String(url_without_secrets(url));
            }
        }
    }
}

/// A preset view without what shapes the harness command.
fn hide_preset_contents(preset: &mut Value) {
    let Some(p) = preset.as_object_mut() else { return };
    let has = |p: &serde_json::Map<String, Value>, k: &str| {
        p.get(k).is_some_and(|v| match v {
            Value::Null => false,
            Value::Array(a) => !a.is_empty(),
            Value::Object(o) => !o.is_empty(),
            _ => true,
        })
    };
    let has_args = has(p, "args");
    let has_env = has(p, "env");
    let has_prompt = has(p, "systemPromptSha256") || has(p, "systemPrompt");
    for k in ["args", "env", "systemPrompt", "systemPromptSha256"] {
        p.remove(k);
    }
    p.insert("hasArgs".into(), Value::Bool(has_args));
    p.insert("hasEnv".into(), Value::Bool(has_env));
    p.insert("hasSystemPrompt".into(), Value::Bool(has_prompt));
}

/// `scheme://user:secret@host/path?q#f` -> `scheme://host/path`.
fn url_without_secrets(url: &str) -> String {
    let bare = url.split(['?', '#']).next().unwrap_or_default();
    let Some((scheme, rest)) = bare.split_once("://") else { return bare.to_owned() };
    let (authority, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    format!("{scheme}://{host}{path}")
}
