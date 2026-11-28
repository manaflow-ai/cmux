//! Wire tests for the `linux` and `windows` device kinds and
//! `open-device-kinds-v1` (spec/commands.md `set-client-info`).

use super::tests::{attach_test_view, captured_writer, drain_json, json_command, test_mux};
use super::*;

/// `linux` and `windows` reach clients that sent `open-device-kinds-v1`.
/// Older clients decode a closed set of kinds, so they read both as
/// `unknown`; a kind no daemon knows is `unknown` for everyone.
#[test]
fn os_device_kinds_reach_open_clients_and_read_as_unknown_for_older_clients() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);
    let join = |device_kind: &str, capabilities: Value| {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            client,
            json_command(json!({
                "cmd": "set-client-info", "name": "cmux2-gpui", "kind": "frontend",
                "capabilities": capabilities, "user_id": format!("u-{device_kind}"),
                "device_kind": device_kind,
            })),
            &writer,
        )
        .unwrap();
        attach_test_view(&mux, client, surface.id, &writer);
        (client, writer, outbound)
    };
    let open = json!([SHARED_SIZING_CAPABILITY, "open-device-kinds-v1"]);
    let (linux, linux_writer, _) = join("linux", open.clone());
    let (windows, ..) = join("windows", open.clone());
    let (future, ..) = join("quantum", open);
    let (mac, mac_writer, mac_outbound) = join("mac", json!([SHARED_SIZING_CAPABILITY]));

    let kinds = |client: u64, writer: &MessageWriter| {
        let reply = handle_command(
            &mux,
            client,
            json_command(json!({"cmd": "get-size-state", "surface": surface.id})),
            writer,
        )
        .unwrap();
        reply["state"]["participants"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                (
                    row["id"].as_str().unwrap().to_string(),
                    row["device_kind"].as_str().unwrap().to_string(),
                    row["priority_key"].as_str().unwrap().to_string(),
                )
            })
            .collect::<Vec<_>>()
    };
    let row = |client: u64, kind: &str, key: &str| {
        (format!("c{client}"), kind.to_string(), format!("u-{key}/{key}"))
    };
    assert_eq!(
        kinds(linux, &linux_writer),
        [
            row(linux, "linux", "linux"),
            row(windows, "windows", "windows"),
            (format!("c{future}"), "unknown".into(), "u-quantum/unknown".into()),
            row(mac, "mac", "mac"),
        ]
    );
    // The older client reads both OS kinds as unknown; priority keys keep
    // the real kind so a priority list it sends back still matches.
    assert_eq!(
        kinds(mac, &mac_writer),
        [
            (format!("c{linux}"), "unknown".into(), "u-linux/linux".into()),
            (format!("c{windows}"), "unknown".into(), "u-windows/windows".into()),
            (format!("c{future}"), "unknown".into(), "u-quantum/unknown".into()),
            row(mac, "mac", "mac"),
        ]
    );
    let published = drain_json(&mac_outbound)
        .into_iter()
        .filter(|event| event["event"] == "size-state")
        .collect::<Vec<_>>();
    assert!(!published.is_empty(), "the older client still receives size-state");
    for event in published {
        for participant in event["state"]["participants"].as_array().unwrap() {
            let kind = participant["device_kind"].as_str().unwrap();
            assert!(
                ["mac", "iphone", "ipad", "tui", "browser", "unknown"].contains(&kind),
                "older client got device_kind {kind}"
            );
        }
    }
}
