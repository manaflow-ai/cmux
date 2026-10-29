//! What a reply to a connection that is not the local unix socket may not
//! carry: any token.

use crate::no_panic::JsonExt;
use serde_json::Value;

/// A peer daemon's connection never lists this host's peers: `_acpmux/peers`, `_acpmux/status`
/// and the `peer_*` replies answer it with an empty `peers` (as `_acpmux/peer_status` answers it
/// with this machine's row only). Nothing on a peer reads them.
pub(super) fn hide_peers_from_peer(reply: &mut Value) {
    if let Some(peers) = reply.get_mut("peers").filter(|p| p.is_array()) {
        *peers = Value::Array(Vec::new());
    }
}

/// Nor does a `peer_unreachable` refusal name one to a peer daemon's connection: the request it
/// forwarded for a session of a peer that is down (or of a peer's peer) was not sent, and that is
/// all it says. No peer name, link state, last-seen time or connection error (`peer_link.rs`).
pub(super) fn hide_unreachable_peer(e: crate::rpc::RpcError) -> crate::rpc::RpcError {
    let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    if reason != Some("peer_unreachable") {
        return e;
    }
    crate::rpc::RpcError::internal("peer_unreachable: the request was not sent; retry later")
        .with_data(serde_json::json!({
            "reason": "peer_unreachable",
            "retryable": true,
            "detail": "the request was not sent",
        }))
}

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
    // `_acpmux/harnesses` already hides its env above; `_acpmux/defaults`
    // says only whether a family's spawn defaults carry an env.
    if method == "_acpmux/defaults" {
        hide_defaults_view(reply);
    }
    if let Some(peers) = reply.get_mut("peers").and_then(Value::as_array_mut) {
        for peer in peers {
            if let Some(url) = peer.get("url").and_then(Value::as_str) {
                peer.set("url", Value::String(url_without_secrets(url)));
            }
            // The machines' resources (`peer_health.rs`) stay on the unix
            // socket: `_acpmux/peers`, `status`, `peer_add`/`remove`/`reconnect`.
            if let Some(row) = peer.as_object_mut() {
                row.remove("health");
                row.remove("healthAt");
            }
        }
    }
    // Nor in `_acpmux/peer_status`, which asks each peer live: a peer's row
    // says whether it answered, how fast and on which build, not its numbers.
    // This machine's own row is `_acpmux/host_health`'s, which it may read.
    if method == "_acpmux/peer_status"
        && let Some(hosts) = reply.get_mut("hosts").and_then(Value::as_array_mut)
    {
        for row in hosts.iter_mut().filter(|r| r.get("self") != Some(&Value::Bool(true))) {
            if let Some(row) = row.as_object_mut() {
                for key in PEER_RESOURCES {
                    row.remove(key);
                }
            }
        }
    }
}

/// The `_acpmux/host_health` fields a peer's `peer_status` row copies that
/// are its resources, and what its health loop found wrong (`problems`).
const PEER_RESOURCES: [&str; 9] =
    ["cpus", "load", "ram", "swap", "disk", "pressure", "liveSessions", "uptimeSecs", "problems"];

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

/// A defaults view without the environment that will be passed to a harness.
/// Keep an explicit marker so remote clients can distinguish an empty env from
/// an env intentionally withheld by the daemon.
fn hide_defaults_view(reply: &mut Value) {
    let Some(map) = reply.as_object_mut() else {
        return;
    };
    if let Some(families) = map.get_mut("families") {
        hide_defaults_map(families);
    }
    if let Some(defaults) = map.get_mut("defaults") {
        hide_defaults_map(defaults);
    }
    if !map.contains_key("families") && !map.contains_key("defaults") {
        hide_default_entry(reply);
    }
}

fn hide_defaults_map(defaults: &mut Value) {
    let Some(map) = defaults.as_object_mut() else {
        return;
    };
    for value in map.values_mut() {
        hide_default_entry(value);
    }
}

fn hide_default_entry(defaults: &mut Value) {
    let Some(map) = defaults.as_object_mut() else {
        return;
    };
    hide_env_field(map);
}

fn hide_env_field(map: &mut serde_json::Map<String, Value>) {
    let has_env = map.remove("env").is_some_and(|env| has_content(&env));
    map.insert("hasEnv".into(), Value::Bool(has_env));
}

fn has_content(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Array(values) => !values.is_empty(),
        Value::Object(values) => !values.is_empty(),
        _ => true,
    }
}

/// `scheme://user:secret@host/path?q#f` -> `scheme://host/path`.
pub(crate) fn url_without_secrets(url: &str) -> String {
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

    #[test]
    fn remote_defaults_hide_env_for_one_family() {
        let mut reply = json!({
            "kind": "family",
            "model": "claude-opus",
            "env": {"ANTHROPIC_API_KEY": "canary"},
        });

        redact_for_remote("_acpmux/defaults", &mut reply);

        assert_eq!(reply["model"], "claude-opus");
        assert_eq!(reply["hasEnv"], true);
        assert!(reply.get("env").is_none());
        assert!(!reply.to_string().contains("canary"));
    }

    #[test]
    fn remote_defaults_hide_env_in_all_families() {
        let mut reply = json!({
            "families": {
                "claude": {"env": {"ROUTER_KEY": "canary"}},
                "codex": {"model": "gpt-6.1-sol", "env": {}},
                "env": {"model": "gpt-6.1-sol", "env": {"FAMILY_KEY": "canary"}},
            },
            "defaults": {
                "claude": {"env": {"OPENAI_API_KEY": "canary"}},
                "env": {"env": {"OTHER_KEY": "canary"}},
            },
        });

        redact_for_remote("_acpmux/defaults", &mut reply);

        assert_eq!(reply["families"]["claude"]["hasEnv"], true);
        assert_eq!(reply["families"]["codex"]["hasEnv"], false);
        assert_eq!(reply["families"]["env"]["hasEnv"], true);
        assert_eq!(reply["defaults"]["claude"]["hasEnv"], true);
        assert_eq!(reply["defaults"]["env"]["hasEnv"], true);
        assert!(!reply.to_string().contains("canary"));
        assert!(!reply.to_string().contains("API_KEY"));
    }

    #[test]
    fn remote_harnesses_hide_profile_and_inline_defaults_env() {
        let mut reply = json!({
            "harnesses": {
                "fake": {
                    "env": {"PROFILE_KEY": "canary"},
                    "defaults": {"env": {"DEFAULT_KEY": "canary"}},
                },
            },
            "defaults": {
                "fake": {"env": {"TOP_LEVEL_KEY": "canary"}},
            },
        });

        redact_for_remote("_acpmux/harnesses", &mut reply);

        assert_eq!(reply["harnesses"]["fake"]["hasEnv"], true);
        assert_eq!(reply["harnesses"]["fake"]["defaults"]["hasEnv"], true);
        assert_eq!(reply["defaults"]["fake"]["hasEnv"], true);
        assert!(!reply.to_string().contains("canary"));
    }
}
