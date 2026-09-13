use super::*;

#[test]
fn cloud_image_paste_advertises_a_versioned_capability() {
    let mux = Mux::new_for_test("image-paste", crate::SurfaceOptions::default());
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let identity = handle_command(&mux, 0, Command::Identify, &writer).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| { value == "terminal-image-paste-v1" })
    );
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
    assert!(
        serde_json::from_value::<Command>(request).is_ok(),
        "the authenticated mux protocol needs an image transfer, not shell input"
    );
}

struct PasteInputRecorder(std::sync::mpsc::Sender<Vec<u8>>);

impl std::io::Write for PasteInputRecorder {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.send(bytes.to_vec()).unwrap();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn cloud_image_paste_leased_daemon_path_reaches_bracketed_paste() {
    let mux = Mux::new_for_test("image-paste-wire", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let terminal_id = surface.terminal_public_id().unwrap().as_str().to_owned();
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients
        .set_info(client, None, None, Some(vec![VIEW_ATTACHMENT_LEASE_CAPABILITY.into()]))
        .unwrap();
    let stream = writer.start_stream(&json!({ "event": "test" })).unwrap();
    let lease =
        mux.control_clients.attach_surface(client, surface.id, stream.clone()).unwrap().unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream.id, None).unwrap();
    let (written, input) = std::sync::mpsc::channel();
    surface.replace_input_writer_for_test(Box::new(PasteInputRecorder(written)));
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?2004h"));
    let request = |fields: Value| {
        let mut command = json!({
            "cmd": "paste-image", "surface": surface.id, "terminal_id": terminal_id,
            "lease": lease, "upload_id": "0123456789abcdef0123456789abcdef"
        });
        command.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
        serde_json::from_value::<Command>(command).unwrap()
    };
    let png = b"\x89PNG\r\n\x1a\nremote-image-fixture";
    handle_command(
        &mux,
        client,
        request(json!({"op":"begin", "mime":"image/png", "size":png.len()})),
        &writer,
    )
    .unwrap();
    assert!(input.try_recv().is_err(), "begin must not emit any local path");
    handle_command(&mux, client, request(json!({"op":"chunk", "offset":0, "data":base64::engine::general_purpose::STANDARD.encode(png)})), &writer).unwrap();
    assert!(input.try_recv().is_err(), "upload must finish before paste");
    handle_command(&mux, client, request(json!({"op":"commit"})), &writer).unwrap();
    let bytes: Vec<u8> = input.try_iter().flatten().collect();
    assert!(bytes.starts_with(b"\x1b[200~") && bytes.ends_with(b"\x1b[201~"));
    let quoted = std::str::from_utf8(&bytes[6..bytes.len() - 6]).unwrap();
    let path = quoted.strip_prefix('\'').unwrap().strip_suffix('\'').unwrap();
    assert_eq!(std::fs::read(path).unwrap(), png);
    assert!(handle_command(&mux, client + 1, request(json!({"op":"commit"})), &writer).is_err());
    assert!(input.try_recv().is_err(), "a foreign connection must not paste");
    mux.image_pastes.close_surface(surface.id);
    assert!(!std::path::Path::new(path).exists());
    disconnect_client(&mux, client, false);
}
