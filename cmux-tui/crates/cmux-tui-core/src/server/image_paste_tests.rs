use super::*;

const PNG: &[u8] = b"\x89PNG\r\n\x1a\nremote-image-fixture";
const UPLOAD_ID: &str = "0123456789abcdef0123456789abcdef";

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

impl Write for PasteInputRecorder {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.send(bytes.to_vec()).unwrap();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn image_paste_client(mux: &Arc<Mux>) -> (u64, MessageWriter) {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients
        .set_info(client, None, None, Some(vec![VIEW_ATTACHMENT_LEASE_CAPABILITY.into()]))
        .unwrap();
    (client, writer)
}

fn image_paste_view_lease(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    writer: &MessageWriter,
) -> (String, u64) {
    let stream = writer.start_stream(&json!({ "event": "test" })).unwrap();
    let lease =
        mux.control_clients.attach_surface(client, surface, stream.clone()).unwrap().unwrap();
    mux.control_clients.commit_surface(client, surface, stream.id, None).unwrap();
    (lease, stream.id)
}

fn image_paste_request(
    surface: &crate::Surface,
    lease: &str,
    upload_id: &str,
    fields: Value,
) -> Command {
    let mut command = json!({
        "cmd": "paste-image", "surface": surface.id,
        "terminal_id": surface.terminal_public_id().unwrap().as_str(),
        "lease": lease, "upload_id": upload_id
    });
    command.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    serde_json::from_value::<Command>(command).unwrap()
}

fn prepare_image_paste(
    mux: &Arc<Mux>,
    client: u64,
    surface: &crate::Surface,
    lease: &str,
    upload_id: &str,
    writer: &MessageWriter,
) {
    handle_command(
        mux,
        client,
        image_paste_request(
            surface,
            lease,
            upload_id,
            json!({"op":"begin", "mime":"image/png", "size":PNG.len()}),
        ),
        writer,
    )
    .unwrap();
    handle_command(
        mux,
        client,
        image_paste_request(
            surface,
            lease,
            upload_id,
            json!({"op":"chunk", "offset":0, "data":base64::engine::general_purpose::STANDARD.encode(PNG)}),
        ),
        writer,
    )
    .unwrap();
}

fn pasted_image_path(input: &std::sync::mpsc::Receiver<Vec<u8>>) -> PathBuf {
    let bytes: Vec<u8> = input.try_iter().flatten().collect();
    assert!(bytes.starts_with(b"\x1b[200~") && bytes.ends_with(b"\x1b[201~"));
    let quoted = std::str::from_utf8(&bytes[6..bytes.len() - 6]).unwrap();
    let path = quoted.strip_prefix('\'').unwrap().strip_suffix('\'').unwrap();
    assert_eq!(std::fs::read(path).unwrap(), PNG);
    PathBuf::from(path)
}

fn projected_image_paste_view(mux: &Arc<Mux>, source: &crate::Surface) -> Arc<crate::Surface> {
    let terminal = source.terminal_public_id().unwrap().clone();
    let pane = mux.with_state(|state| {
        state.resource_indexes.pane_ids[&state.pane_of(source.id).unwrap()].to_string()
    });
    let selectors = crate::ResourceSelectors {
        machine: Some("current".into()),
        session: Some("current".into()),
        ..Default::default()
    };
    mux.resource_project_terminal_selected(
        crate::ResourceSelectors { terminal: Some(terminal.to_string()), ..selectors.clone() },
        crate::ResourceSelectors { pane: Some(pane), ..selectors },
        usize::MAX,
        None,
        None,
        &WorkspaceMutation::local("image-paste-projection"),
    )
    .unwrap();
    mux.with_state(|state| {
        state
            .placements_of_content(&ContentPublicId::Terminal(terminal))
            .iter()
            .find(|placement| **placement != source.id)
            .and_then(|placement| state.surfaces.get(placement))
            .cloned()
            .unwrap()
    })
}

#[test]
fn cloud_image_paste_leased_daemon_path_reaches_bracketed_paste() {
    let mux = Mux::new_for_test("image-paste-wire", crate::SurfaceOptions::default());
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    let surface = projected_image_paste_view(&mux, &source);
    let terminal = surface.terminal_public_id().unwrap();
    assert!(source.shares_terminal_runtime(&surface));
    assert_ne!(mux.resolve_terminal(terminal.as_str()).unwrap().unwrap().surface, Some(surface.id));

    let (client, writer) = image_paste_client(&mux);
    let (foreign_client, foreign_writer) = image_paste_client(&mux);
    image_paste_view_lease(&mux, client, source.id, &writer);
    let (lease, stream) = image_paste_view_lease(&mux, client, surface.id, &writer);
    let (foreign_lease, _) =
        image_paste_view_lease(&mux, foreign_client, surface.id, &foreign_writer);
    let (written, input) = std::sync::mpsc::channel();
    source.replace_input_writer_for_test(Box::new(PasteInputRecorder(written)));
    source.with_terminal(|terminal| terminal.vt_write(b"\x1b[?2004h")).unwrap();

    prepare_image_paste(&mux, client, &surface, &lease, UPLOAD_ID, &writer);
    assert!(input.try_recv().is_err(), "begin and chunks must not emit a path");
    for op in ["commit", "cancel"] {
        let error = handle_command(
            &mux,
            foreign_client,
            image_paste_request(&surface, &lease, UPLOAD_ID, json!({"op":op})),
            &foreign_writer,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "image-link-unavailable");
    }
    let error = handle_command(
        &mux,
        foreign_client,
        image_paste_request(&surface, &foreign_lease, UPLOAD_ID, json!({"op":"commit"})),
        &foreign_writer,
    )
    .unwrap_err();
    assert_eq!(error.to_string(), "image-upload-expired");
    assert!(input.try_recv().is_err(), "a foreign connection must not paste");

    handle_command(
        &mux,
        client,
        image_paste_request(&surface, &lease, UPLOAD_ID, json!({"op":"commit"})),
        &writer,
    )
    .unwrap();
    let path = pasted_image_path(&input);

    let pending_id = "fedcba9876543210fedcba9876543210";
    prepare_image_paste(&mux, client, &surface, &lease, pending_id, &writer);
    detach_committed_attach(&mux, client, surface.id, stream);
    let error = handle_command(
        &mux,
        client,
        image_paste_request(&surface, &lease, pending_id, json!({"op":"commit"})),
        &writer,
    )
    .unwrap_err();
    assert_eq!(error.to_string(), "image-link-unavailable");
    let (replacement_lease, _) = image_paste_view_lease(&mux, client, surface.id, &writer);
    let error = handle_command(
        &mux,
        client,
        image_paste_request(&surface, &replacement_lease, pending_id, json!({"op":"commit"})),
        &writer,
    )
    .unwrap_err();
    assert_eq!(error.to_string(), "image-owner-mismatch");
    assert!(input.try_recv().is_err(), "retirement must not retarget an upload to a new lease");
    assert_eq!(std::fs::read(&path).unwrap(), PNG);

    assert!(mux.close_surface(surface.id).unwrap());
    assert_eq!(std::fs::read(&path).unwrap(), PNG, "closing a view must preserve its attachment");
    assert!(mux.close_surface(source.id).unwrap());
    assert_eq!(mux.resolve_terminal(terminal.as_str()).unwrap().unwrap().surface, None);
    assert!(path.exists(), "a catalog-owned terminal can outlive every view");
    let host = mux.resource_terminal_host_identity(&source).unwrap();
    mux.close_terminal(&host.terminal_id, &host.incarnation).unwrap();
    assert!(!path.exists(), "terminal close must remove attachments from every projection");
    disconnect_client(&mux, client, false);
    disconnect_client(&mux, foreign_client, false);
}

#[test]
fn cloud_image_paste_keep_on_exit_cleans_image_without_closing_the_view() {
    let mux = Mux::new_for_test("image-paste-keep-exit", crate::SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let created = mux
        .create_terminal_in_workspace_with_mutation(
            workspace.workspace,
            None,
            None,
            None,
            Some((80, 24)),
            None,
            None,
            None,
            &WorkspaceMutation::local("image-paste-keep-exit"),
            Some(crate::workspace_registry::TerminalOnExit::Keep),
        )
        .unwrap();
    let surface = mux.surface(created.placement.unwrap().surface).unwrap();
    let terminal = surface.terminal_public_id().unwrap();
    let (client, writer) = image_paste_client(&mux);
    let (lease, _) = image_paste_view_lease(&mux, client, surface.id, &writer);
    let (written, input) = std::sync::mpsc::channel();
    surface.replace_input_writer_for_test(Box::new(PasteInputRecorder(written)));
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?2004h")).unwrap();
    prepare_image_paste(&mux, client, &surface, &lease, UPLOAD_ID, &writer);
    handle_command(
        &mux,
        client,
        image_paste_request(&surface, &lease, UPLOAD_ID, json!({"op":"commit"})),
        &writer,
    )
    .unwrap();
    let path = pasted_image_path(&input);
    assert!(
        mux.persist_terminal_exit_for_test(
            terminal,
            &crate::terminal_host_protocol::TerminalExit {
                outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
                exited_at_ms: 9_999_999,
            },
        )
        .unwrap()
    );
    assert!(!path.exists(), "a kept final screen must not retain the exited process's image");
    assert!(mux.with_state(|state| state.surfaces.contains_key(&surface.id)));
    let resolved = mux.resolve_terminal(terminal.as_str()).unwrap().unwrap();
    assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
    assert_eq!(resolved.surface, Some(surface.id));
    mux.close_terminal(&created.terminal_id, created.terminal_incarnation.as_deref().unwrap())
        .unwrap();
    disconnect_client(&mux, client, false);
}
