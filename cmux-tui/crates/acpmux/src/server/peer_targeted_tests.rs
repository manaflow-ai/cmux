//! Exercise explicit machine routes through a local client and the normal server dispatch.

use super::super::cancel_prompt_tests::{Client, until};
use super::super::vm_host;
use crate::hub::Hub;
use crate::peer::test_dial;
use crate::rpc::{Message, method};
use serde_json::json;

#[tokio::test]
async fn explicit_requests_dial_only_the_selected_machines_after_admission() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-targeted-dial");
    test_dial::refuse_all();
    let hub = Hub::started_lazily_for_test(dir.path(), 7).await;
    let mut client = Client::connect(&hub);
    for (id, host) in [("steered", "m0"), ("reported", "m1"), ("already-steered", "m5")] {
        hub.briefs.put(json!({"briefId": id, "host": host, "lastSteerKey": "applied"}));
    }

    let replay = client
        .call(
            1,
            method::MUX_STEER,
            json!({
                "briefId": "already-steered", "idempotencyKey": "applied", "text": "same steer"
            }),
        )
        .await;
    assert_eq!(replay["result"]["replayed"], true, "{replay}");
    let invalid = client.call(2, vm_host::METHOD, json!({"name": "m5", "on": "invalid"})).await;
    assert_eq!(invalid["error"]["code"], -32602, "{invalid}");
    assert!(test_dial::attempts().is_empty());

    let requests = [
        (method::MUX_STEER, json!({"briefId": "steered", "text": "continue"})),
        (method::MUX_REPORT, json!({"briefId": "reported", "status": "reported"})),
        (vm_host::METHOD, json!({"name": "m2"})),
        (
            method::MUX_KEYS_MINT,
            json!({
                "machine": "m3", "kind": "cloudflare-r2", "bucket": "test-bucket", "access": "ro"
            }),
        ),
        (
            method::MUX_COMPUTER_USE_CALL,
            json!({
                "machine": "m4", "name": "click", "session": "test", "call_id": "call"
            }),
        ),
        (method::MUX_HARNESSES, json!({"_meta": {"acpmux": {"peer": "m6"}}})),
        (method::MUX_HARNESS_HEALTH, json!({"_meta": {"acpmux": {"peer": "m6"}}})),
    ];
    for (i, (method, params)) in requests.into_iter().enumerate() {
        client.send(Message::request(10 + i as i64, method, params)).await;
    }
    let parked = |i| hub.peer_by_name(&format!("m{i}")).unwrap().idle_parked();
    until("an addressed machine stayed parked", || (0..5).all(|i| !parked(i))).await;
    until("the addressed machines never dialed", || test_dial::attempts().len() >= 6).await;
    assert!(!parked(6), "a selected harness read left its peer parked");
    assert!(parked(5), "a replay or rejected request woke its machine");
    hub.begin_shutdown();
    test_dial::clear();
}
