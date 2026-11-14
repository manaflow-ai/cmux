use super::*;

/// The JSON value the worker built for each event before it wrote
/// `output` events straight into the outbound buffer.
fn frame_json_reference(
    surface: SurfaceId,
    frame: &AttachFrame,
    generation: u64,
    offset: u64,
) -> Option<Value> {
    match frame {
        AttachFrame::Output(output) => Some(json!({
            "event": "output", "surface": surface, "data": base64(output),
            "generation": generation, "offset": offset,
        })),
        AttachFrame::OutputWithColors { output, colors } => Some(json!({
            "event": "output", "surface": surface, "data": base64(output),
            "generation": generation, "offset": offset,
            "colors": terminal_colors_json(**colors, true),
        })),
        AttachFrame::ColorsChanged(colors) => {
            let mut value = terminal_colors_json(**colors, true);
            value.insert("event", json!("colors-changed"));
            value.insert("surface", json!(surface));
            Some(value)
        }
        AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. } => None,
    }
}

/// Serializing one 64 KiB `output` event: the value path against the
/// direct writer. Run on the fleet:
/// `cargo test -p cmux-tui-core --release --lib snapshot_output_event_bench -- --ignored --nocapture`
#[test]
#[ignore = "bench"]
fn snapshot_output_event_bench() {
    let service = crate::server::RenderService::new();
    let output: Vec<u8> = (0..64 * 1024).map(|index| (index % 251) as u8).collect();
    let frame = AttachFrame::Output(output.clone());
    let rounds = 2_000u32;
    let start = Instant::now();
    for round in 0..rounds {
        let value = frame_json_reference(1, &frame, 1, u64::from(round)).unwrap();
        std::hint::black_box(service.serialize(&value).unwrap());
    }
    let value_path = start.elapsed() / rounds;
    let start = Instant::now();
    for round in 0..rounds {
        std::hint::black_box(
            service.serialize_snapshot_output(1, &output, 1, u64::from(round), None).unwrap(),
        );
    }
    let direct = start.elapsed() / rounds;
    println!("SNAPSHOT-OUTPUT-BENCH 64KiB value_path={value_path:?} direct={direct:?}");
}

/// A snapshot viewer's `output` event is byte-identical to the line the
/// worker serialized from a JSON value: every base64 padding length,
/// binary bytes, an empty chunk, large offsets, with and without colors.
#[test]
fn snapshot_output_events_match_the_value_serialization() {
    let service = crate::server::RenderService::new();
    let colors = crate::TerminalColors {
        fg_override: Some(ghostty_vt::Rgb { r: 1, g: 2, b: 3 }),
        ..crate::TerminalColors::default()
    };
    let outputs: Vec<Vec<u8>> = vec![
        Vec::new(),
        b"a".to_vec(),
        b"ab".to_vec(),
        b"abc".to_vec(),
        (0..=255u8).collect(),
        b"\x1b[31m\"quoted\" \\ back\x1b[0m\r\n".repeat(400),
    ];
    for output in outputs {
        for (generation, offset) in [(0, 0), (7, 1 << 40), (u64::MAX, u64::MAX)] {
            let frames = [
                AttachFrame::Output(output.clone()),
                AttachFrame::OutputWithColors { output: output.clone(), colors: Box::new(colors) },
            ];
            for frame in frames {
                let value = frame_json_reference(42, &frame, generation, offset).unwrap();
                let expected = service.serialize(&value).unwrap();
                let with_colors = match &frame {
                    AttachFrame::OutputWithColors { colors, .. } => {
                        Some(terminal_colors_json(**colors, true))
                    }
                    _ => None,
                };
                let written = service
                    .serialize_snapshot_output(
                        42,
                        &output,
                        generation,
                        offset,
                        with_colors.as_ref(),
                    )
                    .unwrap();
                assert_eq!(written.as_bytes(), expected.as_bytes());
            }
        }
    }
}

#[test]
fn snapshot_throttled_reply_names_its_request() {
    let reply = request_reply(
        SnapshotAdmission::Throttled { retry_after_ms: 120 },
        7,
        Some("req-42".into()),
        Some("digest_mismatch".into()),
    )
    .unwrap();
    assert_eq!(
        reply,
        json!({
            "status": "snapshot_throttled",
            "retry_after_ms": 120,
            "surface": 7,
            "request_id": "req-42",
            "reason": "digest_mismatch",
        })
    );
    let collapsed =
        request_reply(SnapshotAdmission::Collapsed, 7, Some("req-43".into()), None).unwrap();
    assert_eq!(collapsed["request_id"], "req-43");
    assert!(request_reply(SnapshotAdmission::NotAttached, 7, None, None).is_err());
}

#[test]
fn snapshot_request_accepts_only_spec_reasons_and_bounded_ids() {
    let request =
        |value: Value| -> SnapshotRequestParams { serde_json::from_value(value).unwrap() };
    assert!(validate_request(&request(json!({"surface": 1}))).is_ok());
    for reason in SNAPSHOT_REQUEST_REASONS {
        assert!(validate_request(&request(json!({"surface": 1, "reason": reason}))).is_ok());
    }
    assert!(validate_request(&request(json!({"surface": 1, "reason": "because"}))).is_err());
    let long = "x".repeat(MAX_REQUEST_ID_BYTES + 1);
    assert!(validate_request(&request(json!({"surface": 1, "request_id": long}))).is_err());
    let ok = "x".repeat(MAX_REQUEST_ID_BYTES);
    assert!(validate_request(&request(json!({"surface": 1, "request_id": ok}))).is_ok());
}

#[test]
fn snapshot_attach_params_fall_back_on_another_version() {
    let ours = ghostty_vt::snapshot_version();
    let params: SnapshotAttachParams =
        serde_json::from_value(json!({"snapshot": "ghostsnp", "snapshot_version": ours})).unwrap();
    assert!(params.wants_snapshot().unwrap());
    assert_eq!(params.backlog_bytes(), DEFAULT_VIEWER_BACKLOG_BYTES);
    let other: SnapshotAttachParams = serde_json::from_value(
        json!({"snapshot": "ghostsnp", "snapshot_version": ours.wrapping_add(1)}),
    )
    .unwrap();
    assert!(!other.wants_snapshot().unwrap());
    let unknown: SnapshotAttachParams = serde_json::from_value(json!({"snapshot": "png"})).unwrap();
    assert!(unknown.wants_snapshot().is_err());
    let tiny: SnapshotAttachParams =
        serde_json::from_value(json!({"viewer_backlog_bytes": 1})).unwrap();
    assert_eq!(tiny.backlog_bytes(), MIN_VIEWER_BACKLOG_BYTES);
    let older: SnapshotAttachParams = serde_json::from_value(
        json!({"snapshot": "ghostsnp", "snapshot_version": ours, "snapshot_images": true}),
    )
    .unwrap();
    assert!(older.wants_snapshot().unwrap(), "an older viewer's snapshot_images still parses");
}
