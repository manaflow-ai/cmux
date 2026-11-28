//! ACP handshake conformance: acpmux's `initialize` against fake agents that follow the
//! spec's version rules (agentclientprotocol.com/protocol/initialization) and the ones that
//! do not (zed#67357). Each case is a row of cmuxterm-hq
//! `goals/competitive-acp-conformance.results.json`.

use super::*;
use std::sync::{Arc, Mutex};

/// A fake agent: answers each `initialize` with `answer(offered version)`, and records what it
/// was offered.
fn agent(
    answer: impl Fn(u64) -> Result<Value, RpcError> + Send + Sync + 'static,
) -> (impl FnMut(Value) -> std::future::Ready<Result<Value, RpcError>>, Arc<Mutex<Vec<u64>>>) {
    let offers = Arc::new(Mutex::new(Vec::new()));
    let seen = offers.clone();
    let call = move |params: Value| {
        let v = params["protocolVersion"].as_u64().expect("initialize names a protocolVersion");
        assert_eq!(params["clientInfo"]["name"], "acpmux", "the rest of the params survive");
        seen.lock().unwrap().push(v);
        std::future::ready(answer(v))
    };
    (call, offers)
}

fn ok(version: u64) -> Result<Value, RpcError> {
    Ok(json!({"protocolVersion": version, "agentCapabilities": {"loadSession": true},
        "agentInfo": {"name": "fake"}}))
}

/// Spec: an agent answers the offered version if it supports it, else its latest.
fn speaks(max: u64) -> impl Fn(u64) -> Result<Value, RpcError> + Send + Sync + 'static {
    move |offered| ok(offered.min(max))
}

fn params() -> Value {
    crate::hub::pool::initialize_params()
}

#[tokio::test]
async fn v1_handshake_offers_1_and_keeps_the_answer() {
    let (call, offers) = agent(speaks(1));
    let n = negotiate(params(), false, call).await.unwrap();
    assert_eq!(*offers.lock().unwrap(), vec![1]);
    assert_eq!(n.version, Some(1));
    assert!(!n.fell_back);
    assert_eq!(n.result["agentCapabilities"]["loadSession"], true);
}

#[tokio::test]
async fn v2_handshake_agrees_on_2_in_one_request() {
    let (call, offers) = agent(speaks(2));
    let n = negotiate(params(), true, call).await.unwrap();
    assert_eq!(*offers.lock().unwrap(), vec![2]);
    assert_eq!(n.version, Some(2));
    assert!(!n.fell_back);
}

/// A v1-only agent that follows the spec answers a v2 offer with 1: kept, no second request.
#[tokio::test]
async fn a_v1_agent_downgrades_a_v2_offer_itself() {
    let (call, offers) = agent(speaks(1));
    let n = negotiate(params(), true, call).await.unwrap();
    assert_eq!(*offers.lock().unwrap(), vec![2]);
    assert_eq!(n.version, Some(1));
    assert!(!n.fell_back);
}

/// A v1-only agent that refuses a version it does not know: retried once at 1.
#[tokio::test]
async fn an_error_to_the_v2_offer_falls_back_to_v1() {
    let (call, offers) = agent(|v| {
        if v == 1 { ok(1) } else { Err(RpcError::invalid_params("unsupported protocolVersion")) }
    });
    let n = negotiate(params(), true, call).await.unwrap();
    assert_eq!(*offers.lock().unwrap(), vec![2, 1]);
    assert_eq!(n.version, Some(1));
    assert!(n.fell_back);
}

/// An answer at a version acpmux never offered (or none) to the v2 offer: retried at 1.
#[tokio::test]
async fn an_unknown_answer_to_the_v2_offer_falls_back_to_v1() {
    let (call, offers) = agent(|v| if v == 1 { ok(1) } else { Ok(json!({"protocolVersion": 7})) });
    let n = negotiate(params(), true, call).await.unwrap();
    assert_eq!(*offers.lock().unwrap(), vec![2, 1]);
    assert_eq!(n.version, Some(1));
    assert!(n.fell_back);
}

/// A process that closed answers nothing: one request, its error kept.
#[tokio::test]
async fn a_closed_agent_is_not_retried() {
    let (call, offers) = agent(|_| {
        Err(RpcError::internal(format!("{} (fake): exited", crate::agent::AGENT_CLOSED)))
    });
    let e = negotiate(params(), true, call).await.unwrap_err();
    assert!(e.message.starts_with(crate::agent::AGENT_CLOSED), "{e:?}");
    assert_eq!(*offers.lock().unwrap(), vec![2]);
}

/// Both offers failing returns the v1 attempt's error.
#[tokio::test]
async fn a_failed_fallback_returns_the_v1_error() {
    let (call, offers) = agent(|v| Err(RpcError::internal(format!("no v{v}"))));
    let e = negotiate(params(), true, call).await.unwrap_err();
    assert_eq!(e.message, "no v1");
    assert_eq!(*offers.lock().unwrap(), vec![2, 1]);
}
