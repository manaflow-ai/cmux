//! The Computer Use relay's policy (default deny): who may run a call here,
//! who may send one on, and what a call may carry.

use super::*;
use serde_json::json;

fn device(role: &str) -> DeviceRecord {
    DeviceRecord { name: "Aziz's MacBook".into(), role: role.into() }
}

#[test]
fn only_the_local_socket_sends_a_call_on() {
    assert_eq!(admit(Origin::Local, ConnAuth::LocalSocket, None), Admission::Forward);
}

#[test]
fn a_peer_the_person_let_drive_this_daemon_runs_a_call_here() {
    assert_eq!(
        admit(Origin::Peer, ConnAuth::PeerToken, None),
        Admission::Run { machine: "peer".into() }
    );
    assert_eq!(
        admit(Origin::Peer, ConnAuth::Device, Some(&device("client"))),
        Admission::Run { machine: "Aziz's MacBook".into() }
    );
}

#[test]
fn every_other_connection_is_refused() {
    // The dashboard, the app pane, a phone, a read-only machine, a revoked or
    // unknown device, and a connection that proved nothing.
    for (origin, auth, dev) in [
        (Origin::Web, ConnAuth::ListenerToken, None),
        (Origin::Web, ConnAuth::Device, Some(device("phone"))),
        (Origin::Web, ConnAuth::ReadOnlyDevice, Some(device("read-only"))),
        (Origin::LocalApp, ConnAuth::LocalApp, None),
        (Origin::Peer, ConnAuth::Device, Some(device("read-only"))),
        (Origin::Peer, ConnAuth::Device, Some(device("daemon"))),
        (Origin::Peer, ConnAuth::Device, None),
        (Origin::Peer, ConnAuth::ReadOnlyDevice, Some(device("read-only"))),
        (Origin::Peer, ConnAuth::None, None),
        (Origin::Local, ConnAuth::None, None),
    ] {
        let got = admit(origin, auth, dev.as_ref());
        assert!(matches!(got, Admission::Refused(_)), "{origin:?} {auth:?}: {got:?}");
    }
}

#[test]
fn a_device_name_never_carries_control_characters() {
    let d = DeviceRecord { name: "evil\nname\u{1b}[31m".into(), role: "client".into() };
    let Admission::Run { machine } = admit(Origin::Peer, ConnAuth::Device, Some(&d)) else {
        panic!()
    };
    assert!(!machine.chars().any(char::is_control), "{machine:?}");
    let blank = DeviceRecord { name: "\n".into(), role: "client".into() };
    assert_eq!(
        admit(Origin::Peer, ConnAuth::Device, Some(&blank)),
        Admission::Run { machine: "peer".into() }
    );
}

/// A call for a machine is never forwarded by a session it names. A Computer Use call carries the
/// caller's Computer Use `session` and the tool's `name`; were the method session-scoped, a key
/// that names a peer's chat would forward it there whole with both fields dropped (`peer_forward`
/// strips them), and the far machine would refuse `unknown Computer Use tool ""` on every
/// `machine:` call. The other machine-routed methods name a machine the same way.
#[test]
fn a_call_for_a_machine_is_never_forwarded_by_its_session() {
    for m in [
        method::MUX_COMPUTER_USE_CALL,
        method::MUX_COMPUTER_USE_MACHINES,
        method::MUX_COMPUTER_USE_STATE,
        method::MUX_MACHINE_FILES_CALL,
        method::MUX_MACHINE_PORTS_CALL,
        method::MUX_KEYS_MINT,
    ] {
        assert!(!super::super::peer_forward::names_a_session(m), "{m}");
    }
}

fn base() -> serde_json::Value {
    json!({"name": "click", "arguments": {"window_id": "w"}, "session": "s", "call_id": "c"})
}

#[test]
fn a_call_names_one_catalog_tool_with_object_arguments() {
    let ok = parse(&base()).unwrap();
    assert_eq!(ok.name, "click");
    assert!(ok.machine.is_none());
    let mut with_machine = base();
    with_machine["machine"] = json!("studio");
    assert_eq!(parse(&with_machine).unwrap().machine.as_deref(), Some("studio"));
    for (key, value) in [
        ("name", json!("run_shell")),
        ("name", json!("list_machines")),
        ("arguments", json!("click")),
        ("arguments", json!([1])),
        ("session", json!("")),
        ("call_id", json!("")),
        ("label", json!("a\nb")),
    ] {
        let mut p = base();
        p[key] = value.clone();
        assert!(parse(&p).is_err(), "{key}={value}");
    }
}

/// The origin is the link's, never the request's: a call that names one, or
/// a machine inside its arguments (another hop), is refused.
#[test]
fn a_call_never_names_its_own_origin_or_another_hop() {
    let mut p = base();
    p["origin"] = json!({"kind": "local"});
    let e = parse(&p).err().unwrap();
    assert_eq!(e.data.unwrap()["code"], "computer_use_remote_denied");
    for key in ["machine", "origin"] {
        let mut p = base();
        p["arguments"][key] = json!("x");
        let e = parse(&p).err().unwrap();
        assert_eq!(e.data.unwrap()["code"], "computer_use_remote_denied", "{key}");
    }
}

/// The call sent on keeps its tool name and arguments, and its session key is no chat id: a far
/// daemon that mirrors the caller's chat reads no chat in it, so it never forwards the call back
/// as that chat's request (which dropped `name`: `unknown Computer Use tool ""`).
#[test]
fn the_call_sent_on_keeps_its_tool_and_names_no_chat() {
    let mut p = base();
    p["session"] = json!("0f8e2c1a-chat-id");
    p["machine"] = json!("studio");
    let sent = onward(&parse(&p).unwrap());
    assert!(sent.get("machine").is_none());
    assert_eq!(sent["session"], "cu:0f8e2c1a-chat-id");
    assert_eq!(super::super::session_key(&sent).unwrap(), "cu:0f8e2c1a-chat-id");
    // The far machine parses it whole: an older one and a newer one alike.
    let far = parse(&sent).unwrap();
    assert_eq!(far.name, "click");
    assert_eq!(far.arguments, json!({"window_id": "w"}));
    assert_eq!(far.call_id, "c");
    // Sent on again (a retry), the key is not prefixed twice.
    assert_eq!(onward(&far)["session"], "cu:0f8e2c1a-chat-id");
}

#[test]
fn a_lost_link_is_retryable_and_a_peer_refusal_keeps_its_code() {
    let lost = link_error(RpcError::new(-32000, "peer studio is unreachable"));
    assert_eq!(lost.data.unwrap()["code"], "unreachable");
    let refused = link_error(
        RpcError::invalid_params("no").with_data(json!({"code": "computer_use_remote_denied"})),
    );
    assert_eq!(refused.data.unwrap()["code"], "computer_use_remote_denied");
}
