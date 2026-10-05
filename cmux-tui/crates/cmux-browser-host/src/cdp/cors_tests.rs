//! a9's red tests for HOST-FETCH-CORS (rule 6).

use super::*;

const URL: &str = "https://api.peer.test/data";

fn token_request(token: &str) -> Value {
    json!({"Origin": "https://a.test", TOKEN_HEADER: token, "Accept": "*/*"})
}

fn granted() -> Cors {
    let mut cors = Cors::default();
    cors.issue("t1".into(), "T", URL, "PUT", &["Content-Type".to_owned()]);
    cors
}

#[test]
fn the_token_request_is_relaxed_and_its_header_never_leaves() {
    let mut cors = granted();
    let action = cors.on_request("T", "n1", "GET", URL, &token_request("t1"));
    let RequestAction::ContinueWith { headers } = action else { panic!("{action:?}") };
    assert!(
        headers.iter().all(|h| !h["name"].as_str().unwrap().eq_ignore_ascii_case(TOKEN_HEADER))
    );
    assert!(headers.iter().any(|h| h["name"] == "Accept"));
    let response = cors.on_response(
        "n1",
        URL,
        &[json!({"name": "Content-Type", "value": "application/json"})],
    );
    let response = response.expect("relaxed");
    let get = |name: &str| response.iter().find(|h| h["name"] == name).map(|h| h["value"].clone());
    assert_eq!(
        get("Access-Control-Allow-Origin"),
        Some(json!("https://a.test")),
        "the exact origin, never *"
    );
    assert_eq!(get("Access-Control-Allow-Credentials"), Some(json!("true")));
    assert_eq!(cors.take_log("t1").len(), 1, "each relaxation is logged");
}

#[test]
fn a_parallel_page_fetch_to_the_same_url_stays_cors_blocked() {
    let mut cors = granted();
    let page = json!({"Origin": "https://a.test", "Accept": "*/*"});
    assert_eq!(cors.on_request("T", "n2", "GET", URL, &page), RequestAction::Continue);
    assert_eq!(cors.on_response("n2", URL, &[]), None, "no relaxation without a live token");
}

#[test]
fn a_guessed_or_replayed_token_is_stripped_and_relaxes_nothing() {
    let mut cors = granted();
    // Guessed.
    let guessed = cors.on_request("T", "n3", "GET", URL, &token_request("nope"));
    assert!(
        matches!(guessed, RequestAction::ContinueWith { .. }),
        "the header is removed: {guessed:?}"
    );
    assert_eq!(cors.on_response("n3", URL, &[]), None);
    // Another tab cannot use the token.
    cors.on_request("OTHER", "n4", "GET", URL, &token_request("t1"));
    assert_eq!(cors.on_response("n4", URL, &[]), None);
    // Used once, then replayed.
    cors.on_request("T", "n5", "GET", URL, &token_request("t1"));
    assert!(cors.on_response("n5", URL, &[]).is_some());
    cors.on_request("T", "n6", "GET", URL, &token_request("t1"));
    assert_eq!(cors.on_response("n6", URL, &[]), None, "single use");
    // Expired with its fetch.
    cors.revoke("t1");
    assert_eq!(cors.on_response("n5", URL, &[]), None);
    assert!(!cors.active());
}

#[test]
fn a_redirect_hop_of_the_token_request_stays_relaxed() {
    let mut cors = granted();
    cors.on_request("T", "n1", "GET", URL, &token_request("t1"));
    // The browser re-sends the header on the next hop, same network id.
    let hop = "https://cdn.peer.test/data";
    let action = cors.on_request("T", "n1", "GET", hop, &token_request("t1"));
    assert!(matches!(action, RequestAction::ContinueWith { .. }));
    assert!(cors.on_response("n1", hop, &[]).is_some());
}

#[test]
fn a_token_preflight_is_answered_locally_and_never_sent() {
    let mut cors = granted();
    let preflight = json!({"Origin": "https://a.test", "Access-Control-Request-Method": "PUT",
        "Access-Control-Request-Headers": format!("content-type,{TOKEN_HEADER}")});
    let action = cors.on_request("T", "p1", "OPTIONS", URL, &preflight);
    let RequestAction::Fulfill { status, headers, .. } = action else {
        panic!("sent to the server: {action:?}")
    };
    assert_eq!(status, 204);
    let get = |name: &str| headers.iter().find(|h| h["name"] == name).map(|h| h["value"].clone());
    assert_eq!(get("Access-Control-Allow-Methods"), Some(json!("PUT")));
    assert_eq!(get("Access-Control-Allow-Origin"), Some(json!("https://a.test")));
    // A page's own preflight (no token header named) goes to the server.
    let page = json!({"Origin": "https://a.test", "Access-Control-Request-Method": "PUT",
        "Access-Control-Request-Headers": "content-type"});
    assert_eq!(cors.on_request("T", "p2", "OPTIONS", URL, &page), RequestAction::Continue);
    // A header the fetch does not send, or another method, is not answered.
    let extra = json!({"Origin": "https://a.test", "Access-Control-Request-Method": "PUT",
        "Access-Control-Request-Headers": format!("x-other,{TOKEN_HEADER}")});
    assert_eq!(cors.on_request("T", "p5", "OPTIONS", URL, &extra), RequestAction::Continue);
    let other = json!({"Origin": "https://a.test", "Access-Control-Request-Method": "DELETE",
        "Access-Control-Request-Headers": format!("content-type,{TOKEN_HEADER}")});
    assert_eq!(cors.on_request("T", "p4", "OPTIONS", URL, &other), RequestAction::Continue);
    // Without a live grant even a preflight naming the header goes out.
    cors.revoke("t1");
    assert_eq!(cors.on_request("T", "p3", "OPTIONS", URL, &preflight), RequestAction::Continue);
}

#[test]
fn tokens_are_128_bits_and_fresh() {
    let (a, b) = (fresh_token(), fresh_token());
    assert_eq!(a.len(), 32);
    assert_ne!(a, b);
}

#[test]
fn a_fetch_shell_document_is_answered_locally_for_its_tab_only() {
    let mut cors = Cors::default();
    let shell = "https://api.peer.test/.well-known/cmux-fetch-shell";
    cors.add_shell("BG", shell);
    let page = json!({});
    assert!(matches!(
        cors.on_request("BG", "s1", "GET", shell, &page),
        RequestAction::Fulfill { status: 200, .. }
    ));
    assert_eq!(cors.on_request("OTHER", "s2", "GET", shell, &page), RequestAction::Continue);
    cors.remove_shell("BG");
    assert_eq!(cors.on_request("BG", "s3", "GET", shell, &page), RequestAction::Continue);
}

/// a9 shell-tab condition (a): the shell document is empty and never
/// stored, and its main world may load nothing. Connects stay open: the
/// host world takes the main world's CSP (Chromium 143 probe, 2026-10-04),
/// so `default-src 'none'` alone also blocked the host's own fetch.
#[test]
fn a_fetch_shell_document_is_empty_uncached_and_locked_down() {
    let mut cors = Cors::default();
    let shell = "https://api.peer.test/.well-known/cmux-fetch-shell";
    cors.add_shell("BG", shell);
    let RequestAction::Fulfill { status, headers, body } =
        cors.on_request("BG", "s1", "GET", shell, &json!({}))
    else {
        panic!("the shell document is answered locally");
    };
    assert_eq!((status, body.as_str()), (200, ""));
    let header = |name: &str| {
        headers
            .iter()
            .find(|h| h["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(name)))
            .and_then(|h| h["value"].as_str())
    };
    assert_eq!(header("Cache-Control"), Some("no-store"));
    assert_eq!(
        header("Content-Security-Policy"),
        Some("default-src 'none'; connect-src http: https:; base-uri 'none'; form-action 'none'")
    );
}
