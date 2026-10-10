//! Session event streams and session journal streams: replay, cursors, filters and remote redaction.

use super::*;

#[test]
fn journal_restore_preview_satisfies_the_public_result_contract() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-restore-contract-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent("restore-contract", SurfaceOptions::default(), &root).unwrap();
    mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let request = resource_request(
        "journal-restore-preview",
        "session.journal.restore.preview",
        json!({
            "machine":"current",
            "session":"current",
            "checkpoint":"latest",
        }),
        None,
    );

    assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["result"]["unsupported_required_record_count"], "0");
    assert_eq!(response["result"]["unsupported_required_records_truncated"], false);

    assert!(disconnect_client(&mux, client, false));
    drop(scheduler);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn persistent_journal_tail_subscribers_share_one_decoded_database_reader() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-shared-reader-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent("shared-journal", SurfaceOptions::default(), &root).unwrap();
    assert_eq!(mux.journal_database_reader_count_for_test(), 1);

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    for (request_id, stream_id) in [
        ("journal-shared-open-a", "stream_00000000000000000000000000000036"),
        ("journal-shared-open-b", "stream_00000000000000000000000000000037"),
    ] {
        let open = resource_request(
            request_id,
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
                "filter":journal_subscription_filter(
                    JournalSensitivity::Sensitive,
                    json!({}),
                ),
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["id"], request_id);
    }

    crate::resource_router::handle_resource_message(
        &mux,
        &resource_request(
            "journal-shared-create",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"shared",
                "initial_content":"empty",
            }),
            Some("journal-shared-create"),
        ),
    )
    .unwrap();

    let first = pop_json(&outbound);
    let second = pop_json(&outbound);
    assert_eq!(first["type"], "stream_item");
    assert_eq!(second["type"], "stream_item");
    assert_ne!(first["stream_id"], second["stream_id"]);
    assert_eq!(first["item"]["event_id"], second["item"]["event_id"]);
    assert_eq!(first["item"]["kind"], "workspace.create");
    assert_eq!(mux.journal_database_reader_count_for_test(), 1);

    assert!(disconnect_client(&mux, client, false));
    drop(scheduler);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
