//! Session event streams and session journal streams: replay, cursors, filters and remote redaction.

use super::*;

#[test]
fn session_event_stream_acknowledges_before_snapshot_and_cancel_ends_before_response() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let stream_id = "stream_00000000000000000000000000000001";
    let open = resource_request(
        "events-open",
        "session.events",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));

    let response = pop_json(&outbound);
    assert_eq!(response["type"], "response");
    assert_eq!(response["id"], "events-open");
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["stream_id"], stream_id);
    let snapshot = pop_json(&outbound);
    assert_eq!(snapshot["type"], "stream_item");
    assert_eq!(snapshot["stream_id"], stream_id);
    assert_eq!(snapshot["sequence"], "0");
    assert_eq!(snapshot["item"]["kind"], "snapshot");
    assert_eq!(snapshot["item"]["reset_reason"], "initial");
    let clients = snapshot["item"]["snapshot"]["clients"].as_array().unwrap();
    assert_eq!(clients.len(), 1);
    assert_eq!(clients[0]["self"], true);
    assert_eq!(clients[0]["transport"], "unix");

    let cancel = resource_request(
        "events-cancel",
        "stream.cancel",
        json!({
            "machine":"current",
            "session":"current",
            "stream":stream_id,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    let end = pop_json(&outbound);
    assert_eq!(end["type"], "stream_end");
    assert_eq!(end["stream_id"], stream_id);
    assert_eq!(end["reason"], "canceled");
    let response = pop_json(&outbound);
    assert_eq!(response["type"], "response");
    assert_eq!(response["id"], "events-cancel");
    assert_eq!(response["ok"], true);
    assert!(
        mux.control_clients
            .resource_stream_admission
            .wait_until_idle(Instant::now() + Duration::from_secs(2)),
        "canceled event stream retained server worker capacity"
    );
    assert!(outbound.try_pop().is_none(), "an item followed stream_end");
    disconnect_client(&mux, client, false);
}

#[test]
fn session_journal_stream_replays_filters_and_resumes_from_its_cursor() {
    let mux = test_mux();
    let created = crate::resource_router::handle_resource_message(
        &mux,
        &resource_request(
            "journal-create",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"journal",
                "initial_content":"empty",
            }),
            Some("journal-create"),
        ),
    )
    .unwrap();
    let workspace_id = created["result"]["value"]["workspace_id"].as_str().unwrap().to_string();
    let session_id = crate::resource_api::public_session_snapshot(&mux).unwrap()["session"]["id"]
        .as_str()
        .unwrap()
        .to_string();

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let first_stream = "stream_00000000000000000000000000000031";
    let open = resource_request(
        "journal-open",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":first_stream,
            "start":"beginning",
            "filter":journal_subscription_filter(JournalSensitivity::Sensitive, json!({
                "kinds":["workspace.*"],
                "classes":["state"],
                "subjects":[{"kind":"workspace","id":workspace_id}],
                "regex":{
                    "pattern":"JOURNAL|missing",
                    "field":"payload",
                    "case_sensitive":false,
                },
            })),
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["id"], "journal-open");
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["cursor"]["generation"], session_id);
    assert_eq!(response["result"]["cursor"]["revision"], "0");
    let item = pop_json(&outbound);
    assert_eq!(item["type"], "stream_item");
    assert_eq!(item["stream_id"], first_stream);
    assert_eq!(item["cursor"]["generation"], session_id);
    assert_eq!(item["cursor"]["revision"], item["item"]["sequence"]);
    assert_eq!(item["item"]["kind"], "workspace.create");
    assert_eq!(item["item"]["class"], "state");
    assert_eq!(item["item"]["sensitivity"], "sensitive");
    assert!(item["item"]["payload"]["changes"].is_array());
    let cursor = item["cursor"].clone();

    let cancel = resource_request(
        "journal-cancel",
        "stream.cancel",
        json!({
            "machine":"current",
            "session":"current",
            "stream":first_stream,
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["reason"], "canceled");
    assert_eq!(pop_json(&outbound)["id"], "journal-cancel");

    crate::resource_router::handle_resource_message(
        &mux,
        &resource_request(
            "journal-rename",
            "workspace.rename",
            json!({
                "machine":"current",
                "session":"current",
                "workspace":workspace_id,
                "name":"resumed",
            }),
            Some("journal-rename"),
        ),
    )
    .unwrap();
    let second_stream = "stream_00000000000000000000000000000032";
    let resume = resource_request(
        "journal-resume",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":second_stream,
            "cursor":cursor,
            "filter":journal_subscription_filter(
                JournalSensitivity::Sensitive,
                json!({"kinds":["workspace.rename"]}),
            ),
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &resume, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["id"], "journal-resume");
    let resumed = pop_json(&outbound);
    assert_eq!(resumed["item"]["kind"], "workspace.rename");
    assert!(resumed["item"]["payload"]["changes"].as_array().unwrap().iter().any(|change| {
        change["resource"] == "workspace" && change["value"]["name"] == "resumed"
    }));

    let invalid_stream = "stream_00000000000000000000000000000035";
    let invalid = resource_request(
        "journal-invalid-regex",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":invalid_stream,
            "filter":{
                "regex":{
                    "pattern":"(",
                    "field":"record",
                    "case_sensitive":true,
                },
            },
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &invalid, &writer, &scheduler));
    let rejected = pop_json(&outbound);
    assert_eq!(rejected["id"], "journal-invalid-regex");
    assert_eq!(rejected["error"]["code"], "validation.invalid");
    assert_eq!(rejected["error"]["details"]["field"], "filter.regex.pattern");
    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn bounded_journal_read_includes_the_durable_exact_subject_head() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-subject-head-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("journal-subject-head", SurfaceOptions::default(), &root).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

    for index in 0..32_u128 {
        let marker = format!("subject-head-child-{index}");
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            "SubagentStop",
            None,
            json!({
                "session_id":"subject-head-root",
                "root_session_id":"subject-head-root",
                "parent_session_id":"subject-head-root",
                "child_agent_id":marker.clone(),
                "message":"complete",
            }),
        )
        .unwrap();
        let subject =
            ingress.subjects.iter().find(|subject| subject.kind == "agent_tree").cloned().unwrap();
        let commit = mux
            .append_journal_ingress(
                &ingress,
                "client_subject_head",
                &format!("subject_head_{index}"),
            )
            .unwrap();
        let filter_value = journal_subscription_filter(
            JournalSensitivity::Sensitive,
            json!({
                "kinds":["agent.child.completed"],
                "subjects":[subject.clone()],
                "regex":{
                    "pattern":marker,
                    "field":"payload",
                    "case_sensitive":true,
                },
            }),
        );
        let direct = mux
            .session_journal_reader()
            .unwrap()
            .unwrap()
            .after_subjects(commit.sequence.saturating_sub(1), 1, std::slice::from_ref(&subject))
            .unwrap();
        let document = JournalDocument::new(direct.records.into_iter().next().unwrap());
        assert!(JournalStreamFilter::parse(Some(&filter_value)).unwrap().matches(&document));
        let stream_id = format!("stream_{:032x}", 0x5000_u128 + index);
        let open = resource_request(
            &format!("subject-head-open-{index}"),
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
                "start":"beginning",
                "follow":false,
                "filter":filter_value,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["ok"], true);
        let item = pop_json(&outbound);
        assert_eq!(item["type"], "stream_item", "missing durable subject head {index}");
        assert_eq!(item["item"]["sequence"], commit.sequence.to_string());
        assert_eq!(pop_json(&outbound)["reason"], "completed");
    }

    assert!(disconnect_client(&mux, client, false));
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn bounded_session_journal_replay_completes_at_its_open_head() {
    let mux = test_mux();
    crate::resource_router::handle_resource_message(
        &mux,
        &resource_request(
            "journal-bounded-create",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"bounded",
                "initial_content":"empty",
            }),
            Some("journal-bounded-create"),
        ),
    )
    .unwrap();

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let stream_id = "stream_00000000000000000000000000000039";
    let open = resource_request(
        "journal-bounded-open",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream_id,
            "start":"beginning",
            "follow":false,
            "filter":journal_subscription_filter(JournalSensitivity::Sensitive, json!({
                "kinds":["workspace.*"],
            })),
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["ok"], true);
    assert_eq!(pop_json(&outbound)["item"]["kind"], "workspace.create");
    let end = pop_json(&outbound);
    assert_eq!(end["type"], "stream_end");
    assert_eq!(end["reason"], "completed");
    assert_eq!(end["stream_id"], stream_id);
    assert!(end["cursor"]["revision"].as_str().is_some());

    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn bounded_filtered_replay_advances_to_head_without_matching_items() {
    let mux = test_mux();
    crate::resource_router::handle_resource_message(
        &mux,
        &resource_request(
            "journal-bounded-filter-create",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "name":"bounded-filter",
                "initial_content":"empty",
            }),
            Some("journal-bounded-filter-create"),
        ),
    )
    .unwrap();

    let head = mux.session_journal_after(0, 1).unwrap().head_sequence;
    assert!(head > 0);
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let stream_id = "stream_0000000000000000000000000000003a";
    let open = resource_request(
        "journal-bounded-filter-open",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream_id,
            "start":"beginning",
            "follow":false,
            "filter":{"kinds":["agent.*"]},
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["ok"], true);
    let end = pop_json(&outbound);
    assert_eq!(end["type"], "stream_end");
    assert_eq!(end["reason"], "completed");
    assert_eq!(end["cursor"]["revision"], head.to_string());

    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn session_journal_stream_regex_matches_exact_terminal_output_bytes() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-terminal-regex-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent("terminal-regex", SurfaceOptions::default(), &root).unwrap();
    let terminal_id = TerminalPublicId::parse("term_00000000000000000000000000000041").unwrap();
    let output = b"ready\xff\x00fatal: SIMD needle\r\n".to_vec();
    mux.journal_terminal_output(
        Arc::new(terminal_id),
        Arc::from("terminal-regex-generation"),
        output.clone(),
    );
    mux.flush_terminal_journal().unwrap();

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let stream_id = "stream_00000000000000000000000000000041";
    let open = resource_request(
        "journal-terminal-regex-open",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream_id,
            "start":"beginning",
            "filter":journal_subscription_filter(JournalSensitivity::Sensitive, json!({
                "kinds":["terminal.output"],
                "regex":{
                    "pattern":"fatal: SIMD [a-z]+",
                    "field":"terminal_output",
                    "case_sensitive":true
                }
            }))
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["ok"], true);
    let item = pop_json(&outbound);
    assert_eq!(item["item"]["kind"], "terminal.output");
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(item["item"]["payload"]["data"].as_str().unwrap())
            .unwrap(),
        output
    );
    assert!(disconnect_client(&mux, client, false));
    drop(scheduler);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

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
fn journal_hook_list_omits_absent_optional_filters() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-hook-list-contract-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent("hook-list-contract", SurfaceOptions::default(), &root).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let put = resource_request(
        "journal-hook-put",
        "session.journal.hook.put",
        json!({
            "machine":"current",
            "session":"current",
            "manifest":{
                "hook_id":"contract_hook",
                "manifest_version":1,
                "filter":{"kinds":["plugin.contract.*"]},
                "exec":{"argv":["/usr/bin/true"],"timeout_ms":1000,"max_parallel":1},
                "delivery":{"start":"tail","retry":{"max_attempts":1,"backoff_ms":0}},
                "permissions":["journal.read"],
            },
        }),
        Some("journal-hook-put-1"),
    );
    assert!(handle_connection_message(&mux, client, &put, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["ok"], true);

    let list = resource_request(
        "journal-hook-list",
        "session.journal.hook.list",
        json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(handle_connection_message(&mux, client, &list, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], true, "{response}");
    let filter = &response["result"]["hooks"][0]["manifest"]["filter"];
    assert_eq!(filter["kinds"], json!(["plugin.contract.*"]));
    assert!(filter.get("classes").is_none());
    assert!(filter.get("subject_kinds").is_none());

    assert!(disconnect_client(&mux, client, false));
    drop(scheduler);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn invalid_journal_manifests_do_not_echo_private_field_names() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

    for (request_id, operation, expected_field) in [
        (
            "private-producer-manifest",
            "session.journal.producer.put",
            "session.journal.producer.put.manifest",
        ),
        ("private-hook-manifest", "session.journal.hook.put", "session.journal.hook.put.manifest"),
    ] {
        let request = resource_request(
            request_id,
            operation,
            json!({
                "machine":"current",
                "session":"current",
                "manifest":{"private-provider-token-name":true},
            }),
            Some(request_id),
        );
        assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "validation.invalid");
        assert_eq!(response["error"]["details"]["field"], expected_field);
        assert!(!response.to_string().contains("private-provider-token-name"));
    }

    assert!(disconnect_client(&mux, client, false));
}

#[test]
#[ignore = "manual throughput probe"]
fn journal_compiled_regex_throughput_probe() {
    let document = JournalDocument::new(SessionJournalRecord {
        sequence: 1,
        event_id: "event_benchmark".into(),
        schema_version: 1,
        kind: "plugin.benchmark.observation".into(),
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "benchmark".into(), id: "benchmark".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "workspace".into(), id: "ws_benchmark".into() }],
        sensitivity: JournalSensitivity::Metadata,
        payload: json!({"message":"approval-42 is ready"}),
        resource_revision: None,
        previous_resource_revision: None,
        terminal_output: None,
    });
    let filter = JournalStreamFilter::parse(Some(&json!({
        "kinds":["plugin.benchmark.*"],
        "classes":["observation"],
        "max_sensitivity":"metadata",
        "regex":{
            "pattern":"approval-[0-9]+",
            "field":"payload",
            "case_sensitive":true
        }
    })))
    .unwrap();
    let iterations = 1_000_000_u64;
    let started = Instant::now();
    let mut matched = 0_u64;
    for _ in 0..iterations {
        if std::hint::black_box(&filter).matches(std::hint::black_box(&document)) {
            matched += 1;
        }
    }
    let elapsed = started.elapsed();
    let per_second = iterations as f64 / elapsed.as_secs_f64();
    eprintln!(
        "journal compiled-regex filter: {iterations} records in {elapsed:?}, {per_second:.0} records/s"
    );
    assert_eq!(matched, iterations);

    let mut output = vec![b'x'; 256 * 1024];
    let needle = b"fatal: SIMD needle";
    let needle_start = output.len() - needle.len();
    output[needle_start..].copy_from_slice(needle);
    let output_bytes = output.len();
    let terminal_document = JournalDocument::new(SessionJournalRecord {
        sequence: 2,
        event_id: "event_terminal_benchmark".into(),
        schema_version: 1,
        kind: "terminal.output".into(),
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: 2,
        committed_at_ms: 2,
        producer: JournalProducer { kind: "terminal_runtime".into(), id: "benchmark".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "terminal".into(), id: "benchmark".into() }],
        sensitivity: JournalSensitivity::Sensitive,
        payload: json!({"format":"cmux.terminal-output.v1"}),
        resource_revision: None,
        previous_resource_revision: None,
        terminal_output: Some(Arc::from(output)),
    });
    let terminal_filter = JournalStreamFilter::parse(Some(&json!({
        "max_sensitivity":"sensitive",
        "regex":{
            "pattern":"fatal: SIMD needle",
            "field":"terminal_output",
            "case_sensitive":true
        }
    })))
    .unwrap();
    let terminal_iterations = 8_192_u64;
    let started = Instant::now();
    let mut terminal_matches = 0_u64;
    for _ in 0..terminal_iterations {
        if std::hint::black_box(&terminal_filter).matches(std::hint::black_box(&terminal_document))
        {
            terminal_matches += 1;
        }
    }
    let elapsed = started.elapsed();
    let gibibytes_per_second = output_bytes as f64 * terminal_iterations as f64
        / (1024.0 * 1024.0 * 1024.0)
        / elapsed.as_secs_f64();
    eprintln!(
        "journal terminal-output regex: {} MiB in {elapsed:?}, {gibibytes_per_second:.1} GiB/s",
        output_bytes * usize::try_from(terminal_iterations).unwrap() / (1024 * 1024)
    );
    assert_eq!(terminal_matches, terminal_iterations);
    assert!(
        gibibytes_per_second >= 1.0,
        "terminal-output regex regressed: {gibibytes_per_second:.1} GiB/s"
    );
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

#[test]
fn journal_producer_ingress_is_namespaced_schema_validated_and_idempotent() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let manifest = json!({
        "producer_id":"demo",
        "namespace":"plugin.demo",
        "manifest_version":1,
        "max_sensitivity":"sensitive",
        "permissions":["journal.append.plugin.demo"],
        "events":[{
            "kind":"plugin.demo.agent.question",
            "schema_version":1,
            "class":"observation",
            "replay":"advisory",
            "sensitivity":"metadata",
            "payload_schema":{
                "type":"object",
                "properties":{"question":{"type":"string"}},
                "required":["question"],
                "additionalProperties":false
            }
        }]
    });
    let put = resource_request(
        "journal-producer-put",
        "session.journal.producer.put",
        json!({"machine":"current","session":"current","manifest":manifest}),
        Some("producer-put-1"),
    );
    assert!(handle_connection_message(&mux, client, &put, &writer, &scheduler));
    let installed = pop_json(&outbound);
    assert_eq!(installed["ok"], true);
    assert_eq!(installed["result"]["value"]["producer_id"], "demo");
    assert_eq!(installed["result"]["replayed"], false);

    let event = json!({
        "producer_id":"demo",
        "manifest_version":1,
        "kind":"plugin.demo.agent.question",
        "schema_version":1,
        "subjects":[{"kind":"pane","id":"pane_00000000000000000000000000000001"}],
        "payload":{"question":"Continue?"}
    });
    let append = resource_request(
        "journal-ingress-append",
        "session.journal.append",
        json!({"machine":"current","session":"current","event":event}),
        Some("append-question-1"),
    );
    assert!(handle_connection_message(&mux, client, &append, &writer, &scheduler));
    let appended = pop_json(&outbound);
    assert_eq!(appended["ok"], true);
    assert_eq!(appended["result"]["replayed"], false);
    let event_id = appended["result"]["value"]["event_id"].clone();

    assert!(handle_connection_message(&mux, client, &append, &writer, &scheduler));
    let replayed = pop_json(&outbound);
    assert_eq!(replayed["result"]["replayed"], true);
    assert_eq!(replayed["result"]["value"]["event_id"], event_id);

    let (retry_writer, retry_outbound) = captured_writer();
    let retry_client = mux.control_clients.register(ClientTransport::Unix, retry_writer.clone());
    assert!(handle_connection_message(&mux, retry_client, &append, &retry_writer, &scheduler,));
    let reconnected_replay = pop_json(&retry_outbound);
    assert_eq!(reconnected_replay["result"]["replayed"], true);
    assert_eq!(reconnected_replay["result"]["value"]["event_id"], event_id);

    let invalid = resource_request(
        "journal-ingress-invalid",
        "session.journal.append",
        json!({
            "machine":"current",
            "session":"current",
            "event":{
                "producer_id":"demo",
                "manifest_version":1,
                "kind":"plugin.demo.agent.question",
                "schema_version":1,
                "payload":{"wrong":true}
            }
        }),
        Some("append-question-invalid"),
    );
    assert!(handle_connection_message(&mux, client, &invalid, &writer, &scheduler));
    let rejected = pop_json(&outbound);
    assert_eq!(rejected["error"]["code"], "validation.invalid");
    assert_eq!(rejected["error"]["message"], "journal request is invalid");
    assert_eq!(rejected["error"]["details"], json!({"reason":"journal request is invalid"}));

    let subscribe = resource_request(
        "journal-plugin-subscribe",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":"stream_00000000000000000000000000000038",
            "start":"beginning",
            "filter":journal_subscription_filter(
                JournalSensitivity::Metadata,
                json!({"kinds":["plugin.demo.*"]}),
            )
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &subscribe, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["ok"], true);
    let item = pop_json(&outbound);
    assert_eq!(item["item"]["event_id"], event_id);
    assert_eq!(item["item"]["producer"]["id"], "demo");
    assert_eq!(item["item"]["payload"]["question"], "Continue?");
    assert!(disconnect_client(&mux, retry_client, false));
    assert!(disconnect_client(&mux, client, false));
}

#[test]
fn session_journal_stream_redacts_remote_clients_and_rejects_foreign_cursors() {
    let mux = test_mux();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

    let (remote_writer, remote_outbound) = captured_writer();
    let remote = mux.control_clients.register(ClientTransport::WebSocket, remote_writer.clone());
    let remote_open = resource_request(
        "journal-remote",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":"stream_00000000000000000000000000000033",
            "filter":{"max_sensitivity":"metadata","kinds":["plugin.remote_test.*"]},
        }),
        None,
    );
    assert!(handle_connection_message(&mux, remote, &remote_open, &remote_writer, &scheduler,));
    let accepted = pop_json(&remote_outbound);
    assert_eq!(accepted["ok"], true);

    let producer: crate::JournalProducerManifest = serde_json::from_value(json!({
        "producer_id":"remote_test",
        "namespace":"plugin.remote_test",
        "manifest_version":1,
        "max_sensitivity":"metadata",
        "permissions":["journal.append.plugin.remote_test"],
        "events":[{
            "kind":"plugin.remote_test.changed",
            "schema_version":1,
            "class":"observation",
            "replay":"advisory",
            "sensitivity":"metadata",
            "payload_schema":{"type":"object"}
        }]
    }))
    .unwrap();
    mux.put_journal_producer(&producer, "client_test", "remote_producer_1").unwrap();
    let ingress: crate::JournalIngress = serde_json::from_value(json!({
        "producer_id":"remote_test",
        "manifest_version":1,
        "kind":"plugin.remote_test.changed",
        "schema_version":1,
        "payload":{"visible":"metadata"},
        "correlation_id":"local_correlation_secret"
    }))
    .unwrap();
    mux.append_journal_ingress(&ingress, "client_private", "remote_event_1").unwrap();
    let item = pop_json(&remote_outbound);
    assert_eq!(item["item"]["kind"], "plugin.remote_test.changed");
    assert_eq!(item["item"]["payload"]["visible"], "metadata");
    assert_eq!(item["item"]["authority"], Value::Null);
    assert_eq!(item["item"]["causation_id"], Value::Null);
    assert_eq!(item["item"]["correlation_id"], Value::Null);

    let sensitive = resource_request(
        "journal-remote-sensitive",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":"stream_00000000000000000000000000000039",
            "filter":{"max_sensitivity":"sensitive"},
        }),
        None,
    );
    assert!(handle_connection_message(&mux, remote, &sensitive, &remote_writer, &scheduler,));
    let rejected = pop_json(&remote_outbound);
    assert_eq!(rejected["error"]["code"], "operation.failed");
    assert!(rejected["error"]["message"].as_str().unwrap().contains("metadata"));

    let payload_regex = resource_request(
        "journal-remote-payload-regex",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":"stream_00000000000000000000000000000040",
            "filter":{"regex":{"pattern":"secret","field":"payload"}},
        }),
        None,
    );
    assert!(handle_connection_message(&mux, remote, &payload_regex, &remote_writer, &scheduler,));
    let rejected = pop_json(&remote_outbound);
    assert_eq!(rejected["error"]["code"], "operation.failed");
    assert!(rejected["error"]["message"].as_str().unwrap().contains("kind or subjects"));
    assert!(disconnect_client(&mux, remote, false));

    let (local_writer, local_outbound) = captured_writer();
    let local = mux.control_clients.register(ClientTransport::Unix, local_writer.clone());
    let foreign = resource_request(
        "journal-foreign",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":"stream_00000000000000000000000000000034",
            "cursor":{
                "generation":"session_ffffffffffffffffffffffffffffffff",
                "revision":"0",
            },
        }),
        None,
    );
    assert!(handle_connection_message(&mux, local, &foreign, &local_writer, &scheduler,));
    let rejected = pop_json(&local_outbound);
    assert_eq!(rejected["error"]["code"], "cursor.invalid");
    assert_eq!(rejected["error"]["details"]["reason"], "cursor belongs to a different session");
    assert!(disconnect_client(&mux, local, false));
}

#[test]
fn resource_shutdown_requires_local_authority_and_force_for_a_live_browser_owner() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let owner_writer = test_writer();
    let owner = mux.control_clients.register(ClientTransport::Unix, owner_writer.clone());
    handle_command(
        &mux,
        owner,
        Command::SetClientInfo {
            name: Some("browser owner".to_string()),
            kind: Some("native-browser".to_string()),
            capabilities: None,
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &owner_writer,
    )
    .unwrap();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

    let (websocket_writer, websocket_outbound) = captured_writer();
    let websocket =
        mux.control_clients.register(ClientTransport::WebSocket, websocket_writer.clone());
    let websocket_request = resource_request(
        "websocket-shutdown",
        "session.shutdown",
        json!({"machine":"current","session":"current","force":true}),
        Some("websocket-shutdown"),
    );
    assert!(handle_connection_message(
        &mux,
        websocket,
        &websocket_request,
        &websocket_writer,
        &scheduler,
    ));
    let rejected = pop_json(&websocket_outbound);
    assert_eq!(rejected["ok"], false);
    assert!(rejected["error"]["message"].as_str().unwrap().contains("trusted local"));
    assert!(!mux.daemon_shutdown_requested());
    assert!(!mux.control_clients.daemon_handoff_pending());

    let (local_writer, local_outbound) = captured_writer();
    let local = mux.control_clients.register(ClientTransport::Unix, local_writer.clone());
    let ordinary_request = resource_request(
        "ordinary-shutdown",
        "session.shutdown",
        json!({"machine":"current","session":"current","force":false}),
        Some("ordinary-shutdown"),
    );
    assert!(handle_connection_message(&mux, local, &ordinary_request, &local_writer, &scheduler,));
    let rejected = pop_json(&local_outbound);
    assert_eq!(rejected["ok"], false);
    assert!(rejected["error"]["message"].as_str().unwrap().contains("still owns"));
    assert!(!mux.daemon_shutdown_requested());
    assert!(!mux.control_clients.daemon_handoff_pending());

    let forced_request = resource_request(
        "forced-shutdown",
        "session.shutdown",
        json!({"machine":"current","session":"current","force":true}),
        Some("forced-shutdown"),
    );
    assert!(handle_connection_message(&mux, local, &forced_request, &local_writer, &scheduler,));
    // Observing shutdown means the durable result was returned and queued
    // before the owning loop was asked to exit.
    assert!(mux.daemon_shutdown_requested());
    assert!(mux.control_clients.daemon_handoff_pending());
    assert!(mux.control_clients.contains(local));
    let accepted = pop_json(&local_outbound);
    assert_eq!(accepted["ok"], true);
    assert_eq!(accepted["result"]["value"]["accepted"], true);
    assert_eq!(accepted["result"]["replayed"], false);
}

#[test]
fn paused_server_rejects_resource_shutdown_until_lifecycle_readiness() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let request = resource_request(
        "paused-resource-shutdown",
        "session.shutdown",
        json!({"machine":"current","session":"current","force":true}),
        Some("paused-resource-shutdown"),
    );

    assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], false);
    assert!(response["error"]["message"].as_str().unwrap().contains("not ready"));
    assert_eq!(response["error"]["details"]["reason"], "lifecycle_not_ready");
    assert!(!mux.daemon_shutdown_requested());
    assert!(!mux.control_clients.daemon_handoff_pending());
}

#[test]
fn paused_server_rejects_resource_reload_until_lifecycle_readiness() {
    let mux = test_mux();
    let events = mux.subscribe_config_reload();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let request = resource_request(
        "paused-resource-reload",
        "session.reload_config",
        json!({"machine":"current","session":"current"}),
        Some("paused-resource-reload"),
    );

    assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], false);
    assert!(response["error"]["message"].as_str().unwrap().contains("not ready"));
    assert_eq!(response["error"]["details"]["reason"], "lifecycle_not_ready");
    assert!(events.try_recv().is_err());
}

#[test]
fn resource_shutdown_replay_reserves_handoff_and_retries_the_post_ack_exit() {
    let root = std::env::temp_dir().join(format!(
        "cmux-resource-shutdown-replay-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let request = resource_request(
        "shutdown-replay",
        "session.shutdown",
        json!({"machine":"current","session":"current","force":false}),
        Some("shutdown-replay"),
    );

    let first = Mux::open_persistent("shutdown-replay", SurfaceOptions::default(), &root).unwrap();
    first.mark_server_lifecycle_ready();
    let (closed_writer, _) = captured_writer();
    let client = first.control_clients.register(ClientTransport::Unix, closed_writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(first.surface_operation_admission.clone()));
    closed_writer.close();
    assert!(!handle_connection_message(&first, client, &request, &closed_writer, &scheduler,));
    assert!(!first.daemon_shutdown_requested());
    assert!(!first.control_clients.daemon_handoff_pending());
    drop(scheduler);
    drop(first);

    let reopened =
        Mux::open_persistent("shutdown-replay", SurfaceOptions::default(), &root).unwrap();
    reopened.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let client = reopened.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(reopened.surface_operation_admission.clone()));
    assert!(handle_connection_message(&reopened, client, &request, &writer, &scheduler,));
    assert!(reopened.daemon_shutdown_requested());
    assert!(reopened.control_clients.daemon_handoff_pending());
    assert!(reopened.control_clients.contains(client));
    let replay = pop_json(&outbound);
    assert_eq!(replay["ok"], true);
    assert_eq!(replay["result"]["value"]["accepted"], true);
    assert_eq!(replay["result"]["replayed"], true);
    drop(scheduler);
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn pairing_request_resources_require_a_trusted_local_connection() {
    let mux = test_mux();
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let (websocket_writer, websocket_outbound) = captured_writer();
    // Registered WebSocket clients are already authenticated or paired;
    // pairing never upgrades their transport to trusted local authority.
    let websocket =
        mux.control_clients.register(ClientTransport::WebSocket, websocket_writer.clone());

    let list = resource_request(
        "pairing-list-websocket",
        "pairing_request.list",
        json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(handle_connection_message(&mux, websocket, &list, &websocket_writer, &scheduler,));
    let rejected = pop_json(&websocket_outbound);
    assert_eq!(rejected["ok"], false);
    assert!(rejected["error"]["message"].as_str().unwrap().contains("trusted local"));

    let resolve = resource_request(
        "pairing-resolve-websocket",
        "pairing_request.resolve",
        json!({
            "machine":"current",
            "session":"current",
            "pairing_request":format!("pairing_{:032x}", challenge.id),
            "decision":"accept",
        }),
        Some("pairing-resolve-websocket"),
    );
    assert!(handle_connection_message(&mux, websocket, &resolve, &websocket_writer, &scheduler,));
    let rejected = pop_json(&websocket_outbound);
    assert_eq!(rejected["ok"], false);
    assert!(rejected["error"]["message"].as_str().unwrap().contains("trusted local"));
    assert_eq!(mux.pending_pairings().len(), 1);
    assert!(matches!(decision.try_recv(), Err(TryRecvError::Empty)));

    let (local_writer, local_outbound) = captured_writer();
    let local = mux.control_clients.register(ClientTransport::Unix, local_writer.clone());
    assert!(handle_connection_message(&mux, local, &list, &local_writer, &scheduler,));
    let listed = pop_json(&local_outbound);
    assert_eq!(listed["ok"], true);
    assert_eq!(listed["result"].as_array().unwrap().len(), 1);
    assert_eq!(listed["result"][0]["code"], challenge.code);
}
