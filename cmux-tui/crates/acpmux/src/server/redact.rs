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
    if method == "_acpmux/harnesses" {
        hide_harness_contents(reply);
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

/// A harness catalog without values that shape its process. The app and Web
/// clients need the picker metadata, not literal argv or environment values.
fn hide_harness_contents(reply: &mut Value) {
    if let Some(harnesses) = reply.get_mut("harnesses").and_then(Value::as_object_mut) {
        for profile in harnesses.values_mut().filter_map(Value::as_object_mut) {
            let has_args =
                profile.get("argv").and_then(Value::as_array).is_some_and(|v| !v.is_empty());
            let has_env =
                profile.get("env").and_then(Value::as_object).is_some_and(|v| !v.is_empty());
            profile.remove("argv");
            profile.remove("env");
            profile.insert("hasArgs".into(), Value::Bool(has_args));
            profile.insert("hasEnv".into(), Value::Bool(has_env));
            if let Some(defaults) = profile.get_mut("defaults").and_then(Value::as_object_mut) {
                let has_env =
                    defaults.get("env").and_then(Value::as_object).is_some_and(|v| !v.is_empty());
                defaults.remove("env");
                defaults.insert("hasEnv".into(), Value::Bool(has_env));
            }
            if let Some(auth) = profile.get_mut("auth").and_then(Value::as_object_mut) {
                let has_check =
                    auth.get("check").and_then(Value::as_array).is_some_and(|v| !v.is_empty());
                auth.remove("check");
                auth.insert("hasCheck".into(), Value::Bool(has_check));
            }
            let has_models_command = profile
                .get("modelsCommand")
                .and_then(Value::as_array)
                .is_some_and(|v| !v.is_empty());
            profile.remove("modelsCommand");
            profile.insert("hasModelsCommand".into(), Value::Bool(has_models_command));
            let has_sessions = profile.remove("sessions").is_some_and(|value| !value.is_null());
            profile.insert("hasSessions".into(), Value::Bool(has_sessions));
            let has_description =
                profile.remove("description").is_some_and(|value| !value.is_null());
            profile.insert("hasDescription".into(), Value::Bool(has_description));
            if profile.remove("unavailable").is_some() {
                profile.insert("unavailable".into(), Value::String("unavailable".into()));
            }
            if profile.remove("probeError").is_some() {
                profile.insert("probeError".into(), Value::String("unavailable".into()));
            }
        }
    }
    if let Some(defaults) = reply.get_mut("defaults").and_then(Value::as_object_mut) {
        for values in defaults.values_mut().filter_map(Value::as_object_mut) {
            let has_env =
                values.get("env").and_then(Value::as_object).is_some_and(|v| !v.is_empty());
            values.remove("env");
            values.insert("hasEnv".into(), Value::Bool(has_env));
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn remote_harness_view_hides_nested_commands_and_raw_failures() {
        const SENTINEL: &str = "remote-private-harness-detail";
        let mut reply = json!({
            "harnesses": {"private": {
                "argv": ["agent", SENTINEL],
                "env": {"PRIVATE_TOKEN": SENTINEL},
                "sessions": {"adapter": "jsonl", "resume": {"argv": ["agent", SENTINEL]}},
                "description": format!("route https://user:{SENTINEL}@example.invalid"),
                "unavailable": format!("launcher failed: {SENTINEL}"),
                "probeError": format!("probe failed: {SENTINEL}"),
            }},
            "defaults": {"private": {"env": {"PRIVATE_TOKEN": SENTINEL}}},
        });
        redact_for_remote("_acpmux/harnesses", &mut reply);
        let text = reply.to_string();
        assert!(!text.contains(SENTINEL), "remote harness view leaked process details: {text}");
        let profile = &reply["harnesses"]["private"];
        assert_eq!(profile["hasSessions"], true);
        assert_eq!(profile["unavailable"], "unavailable");
        assert_eq!(profile["probeError"], "unavailable");
    }
}
