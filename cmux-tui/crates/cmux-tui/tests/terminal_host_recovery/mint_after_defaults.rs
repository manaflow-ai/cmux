//! A renderer mint sent right after `set-default-colors` must succeed.
//!
//! A smart host applies new defaults by publishing ResyncRequired on the
//! daemon's admin stream and then answers the next control request (here
//! MintCapability) behind that marker. The daemon's surface reader abandons
//! the stream at ResyncRequired to reconnect from a fresh snapshot. Before the
//! fix the abandon failed the pending mint waiter, or discarded the
//! Capability reply as an ordered frame, so the mint failed with "terminal
//! host did not mint renderer grant" until the reconnect finished about
//! three seconds later (browser lane probe on 4a232fc2).
//!
//! The same reconnect used to stall a control request that waited for its
//! reply while holding the surface's runtime lock (mint, clear history):
//! the reconnecting reader takes that lock before it reads the new stream,
//! so the reply sat unread until the request timed out.

use super::*;

/// Distinct complete defaults per round, so every round changes the host's
/// defaults and publishes a new ResyncRequired.
fn defaults_request(id: u64, round: u8) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "cmd": "set-default-colors",
        "complete": true,
        "fg": format!("#0102{round:02x}"),
        "bg": format!("#0405{round:02x}"),
        "palette": {},
    })
}

#[test]
fn renderer_mint_right_after_default_colors_succeeds() {
    const ROUNDS: u8 = 4;
    let harness = RecoveryHarness::start("mint-after-defaults");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert!(record.supports_set_defaults);

    let mut id = 10;
    for round in 0..ROUNDS {
        request(&harness.socket, defaults_request(id, round + 1));
        let minted = request_response(
            &harness.socket,
            serde_json::json!({
                "id": id + 1,
                "cmd": "mint-terminal-renderer",
                "surface": surface,
                "ttl_ms": 10_000,
            }),
        );
        assert_eq!(
            minted["ok"], true,
            "mint {round} right after set-default-colors failed: {minted}"
        );
        assert_eq!(minted["data"]["terminal_id"].as_str(), Some(record.terminal_id.as_str()));
        id += 2;
    }

    // The last grant still attaches: the reply was the host's real token.
    request(&harness.socket, defaults_request(id, ROUNDS + 1));
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id": id + 1,
            "cmd": "mint-terminal-renderer",
            "surface": surface,
            "ttl_ms": 10_000,
        }),
    );
    connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .expect("the grant minted after set-default-colors did not attach");

    close_terminal_surface(&harness.socket, surface, id + 2);
    wait_for_no_host_records(&harness.host_root());
}

/// A clear-history right after `set-default-colors` succeeds while the
/// daemon reconnects the host from the defaults' ResyncRequired.
#[test]
fn clear_history_right_after_default_colors_succeeds() {
    const ROUNDS: u8 = 4;
    let harness = RecoveryHarness::start("clear-after-defaults");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert!(record.supports_set_defaults && record.supports_clear_history);

    let mut id = 10;
    for round in 0..ROUNDS {
        request(&harness.socket, defaults_request(id, round + 1));
        let cleared = request_response(
            &harness.socket,
            serde_json::json!({"id": id + 1, "cmd": "clear-history", "surface": surface}),
        );
        assert_eq!(
            cleared["ok"], true,
            "clear-history {round} right after set-default-colors failed: {cleared}"
        );
        id += 2;
    }

    close_terminal_surface(&harness.socket, surface, id);
    wait_for_no_host_records(&harness.host_root());
}
