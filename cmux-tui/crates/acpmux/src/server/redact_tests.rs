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

/// Review of #28170 at 5638771a: a waiting `peer_reconnect`'s `wait.peer` carried the raw
/// peer row to remote origins (its URL's userinfo, query and fragment, and its health).
#[test]
fn remote_peer_reconnect_wait_hides_the_peer_url_secrets_and_health() {
    const SECRET: &str = "peer-url-secret";
    let row = || {
        json!({
            "name": "m",
            "url": format!("wss://user:{SECRET}@example.invalid/m?token={SECRET}#{SECRET}"),
            "state": "connecting",
            "health": {"cpus": 8},
            "healthAt": 1,
        })
    };
    let reply = || {
        json!({
            "peers": [row()],
            "wait": {"settled": false, "waitedMs": 50, "peer": row()},
        })
    };

    let mut web = reply();
    redact_for_remote("_acpmux/peer_reconnect", &mut web);
    let peer = &web["wait"]["peer"];
    assert_eq!(peer["url"], "wss://example.invalid/m", "{web}");
    assert_eq!(peer["name"], "m", "{web}");
    assert!(peer.get("health").is_none() && peer.get("healthAt").is_none(), "{web}");
    assert_eq!(web["wait"]["settled"], false, "{web}");
    assert!(!web.to_string().contains(SECRET), "{web}");

    // A peer daemon's connection: both redactions, as `remote_guard::after` runs them.
    let mut peer_origin = reply();
    redact_for_remote("_acpmux/peer_reconnect", &mut peer_origin);
    hide_peers_from_peer(&mut peer_origin);
    assert!(peer_origin["wait"].get("peer").is_none(), "{peer_origin}");
    assert_eq!(peer_origin["wait"]["settled"], false, "{peer_origin}");
    assert_eq!(peer_origin["peers"], json!([]), "{peer_origin}");
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
