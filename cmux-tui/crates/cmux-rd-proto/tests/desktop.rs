//! The `desktop/1` messages against the shared vectors in
//! schemas/remote-desktop/desktop.json. The Swift side (CmuxRemoteDesktop
//! `DesktopWireTests`) replays the same file.
#![cfg(feature = "serde")]

use cmux_rd_proto::desktop::{DesktopMessage, HOST_SEQ_BASE, Password, View};
use serde_json::Value;

const VECTORS: &str = include_str!("../../../../schemas/remote-desktop/desktop.json");

fn list(key: &str) -> Vec<Value> {
    let file: Value = serde_json::from_str(VECTORS).expect("vectors");
    file[key].as_array().expect(key).clone()
}

#[test]
fn every_message_decodes_and_reencodes_to_the_same_value() {
    let messages = list("messages");
    assert!(messages.len() >= 19);
    for value in messages {
        let message: DesktopMessage =
            serde_json::from_value(value.clone()).unwrap_or_else(|e| panic!("{value}: {e}"));
        let again = serde_json::to_value(&message).expect("encode");
        assert_eq!(again, value, "{value}");
    }
}

#[test]
fn invalid_messages_are_refused() {
    let invalid = list("invalid");
    assert!(!invalid.is_empty());
    for value in invalid {
        assert!(serde_json::from_value::<DesktopMessage>(value.clone()).is_err(), "{value}");
    }
}

#[test]
fn the_service_name_matches_the_vectors() {
    let file: Value = serde_json::from_str(VECTORS).expect("vectors");
    assert_eq!(file["service"], cmux_rd_proto::desktop::SERVICE);
}

#[test]
fn view_streams_keep_host_and_phone_views_apart() {
    let view = |seq| View { seq, x: 0, y: 0, width: 2, height: 2, pixel_width: 2, pixel_height: 2 };
    assert_eq!(view(0x1_0005).stream(), 5);
    assert_eq!(view(HOST_SEQ_BASE + 5).stream(), 0x8005);
}

#[test]
fn a_password_never_reaches_debug_output() {
    let message = DesktopMessage::Auth { password: Password("hunter22".into()) };
    assert!(!format!("{message:?}").contains("hunter22"));
}
