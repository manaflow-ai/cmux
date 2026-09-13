use super::*;

#[test]
fn cloud_image_paste_advertises_a_versioned_capability() {
    let mux = Mux::new_for_test("image-paste", crate::SurfaceOptions::default());
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let identity = handle_command(&mux, 0, Command::Identify, &writer).unwrap();
    assert!(identity["capabilities"].as_array().unwrap().iter().any(|value| {
        value == "terminal-image-paste-v1"
    }));
}

#[test]
fn cloud_image_paste_is_a_daemon_owned_operation() {
    let request = json!({
        "cmd": "paste-image",
        "surface": 1,
        "terminal_id": "term_0123456789abcdef0123456789abcdef",
        "lease": "connection-owned-lease",
        "upload_id": "0123456789abcdef0123456789abcdef",
        "op": "begin",
        "mime": "image/png",
        "size": 68
    });
    assert!(serde_json::from_value::<Command>(request).is_ok(),
        "the authenticated mux protocol needs an image transfer, not shell input");
}
