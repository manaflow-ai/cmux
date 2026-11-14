use crate::routes::{Route, file_from_json};

fn route(file: serde_json::Value) -> Route {
    Route { id: "r".into(), file: file_from_json(&file).unwrap(), path: Default::default() }
}

/// A probe of a route's Anthropic endpoint says nothing of its OpenAI one, and back.
#[test]
fn a_probe_speaks_for_the_family_whose_endpoint_it_tests() {
    let both = route(json!({"kind": "custom-anthropic", "anthropicBaseUrl": "http://a",
                                "openaiBaseUrl": "http://o"}));
    assert!(probes_for(&both, "claude") && !probes_for(&both, "codex"));
    let openai = route(json!({"kind": "custom-openai", "openaiBaseUrl": "http://o"}));
    assert!(probes_for(&openai, "codex") && !probes_for(&openai, "claude"));
    // Every family that uses the OpenAI endpoint sends the route's own secret to it.
    assert!(probes_for(&openai, "opencode") && probes_for(&openai, "pi"));
    let health = route(json!({"kind": "custom-anthropic", "anthropicBaseUrl": "http://a",
                                  "openaiBaseUrl": "http://o", "healthUrl": "http://h"}));
    assert!(probes_for(&health, "claude") && probes_for(&health, "codex"));
    // A relay route mints a key per family: a probe with Codex's says nothing of Claude's,
    // OpenCode's or Pi's, health URL or not.
    let relay = route(json!({"kind": "local-coderouter"}));
    assert!(probes_for(&relay, "codex") && !probes_for(&relay, "claude"));
    assert!(!probes_for(&relay, "opencode") && !probes_for(&relay, "pi"));
    let relay = route(json!({"kind": "cmux-router", "healthUrl": "http://h"}));
    assert!(probes_for(&relay, "codex") && !probes_for(&relay, "claude"));
    let relay = route(json!({"kind": "local-coderouter", "anthropicBaseUrl": "http://a"}));
    assert!(probes_for(&relay, "claude") && !probes_for(&relay, "codex"));
}

use super::*;

/// The kept answers stay young and few, however many routes were probed.
#[test]
fn kept_answers_are_recent_and_bounded() {
    let file = route(json!({"kind": "custom-openai", "openaiBaseUrl": "http://o"})).file;
    let mut last = BTreeMap::new();
    last.insert("stale".to_owned(), (0, file.clone(), json!({})));
    for i in 0..100u64 {
        last.insert(format!("r{i}"), (KEPT_MS + i, file.clone(), json!({})));
    }
    keep_recent(&mut last, KEPT_MS + 100);
    assert_eq!(last.len(), KEPT_ROUTES);
    assert!(!last.contains_key("stale") && !last.contains_key("r0"), "{last:?}");
    assert!(last.contains_key("r99"), "{last:?}");
}

/// An answer is for the route as it was probed: once its file changes (another endpoint),
/// the answer is not read as the edited route's.
#[test]
fn a_kept_answer_is_for_the_route_as_probed() {
    let mut probed = route(json!({"kind": "custom-anthropic", "anthropicBaseUrl": "http://a",
                                      "openaiBaseUrl": "http://o"}));
    probed.id = "kept-answer-edited-route".into();
    remember(&probed, json!({"status": "auth_needed"}));
    assert_eq!(
        recent(&probed, KEPT_MS).map(|(_, a)| a["status"].clone()),
        Some(json!("auth_needed"))
    );
    let mut edited = probed.clone();
    edited.file.anthropic_base_url = None;
    assert!(recent(&edited, KEPT_MS).is_none());
}

/// A failed health request is a route status, not an error that can fail a wake.
#[tokio::test]
async fn an_unreachable_probe_is_an_observation() {
    let route = route(json!({
        "kind": "custom-openai",
        "openaiBaseUrl": "http://127.0.0.1:1"
    }));
    let answer = probe(&route, std::path::Path::new(".")).await;
    assert_eq!(answer["status"], "unreachable", "{answer}");
    assert!(answer["message"].is_string(), "{answer}");
}

/// A slow health endpoint times out into the same status value and remains non-fatal.
#[tokio::test]
async fn a_timed_out_probe_is_an_observation() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (_stream, _) = listener.accept().await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    });
    let route = route(json!({
        "kind": "custom-openai",
        "openaiBaseUrl": format!("http://{address}")
    }));
    let answer = probe_once_with_timeout(
        &route,
        std::path::Path::new("."),
        std::time::Duration::from_millis(20),
    )
    .await;
    server.await.unwrap();
    assert_eq!(answer["status"], "unreachable", "{answer}");
}
