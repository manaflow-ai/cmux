//! The hot-message codec (p05-ipc-183): the generated layouts write the
//! golden bytes of spec/fixtures/ipc-hot-codec/golden.json (the Swift codec
//! is checked against the same file), read them back, refuse every payload
//! that is not exactly their layout, and agree with the method tables.

use std::path::PathBuf;

use serde_json::{Value, json};

use crate::hot::*;
use crate::methods::{EventId, MethodId, MethodTables, Payload};

#[allow(dead_code, reason = "the build script uses the emitter; the tests use the reader")]
#[path = "../../build-support/hot_codec.rs"]
mod reader;

fn golden() -> Vec<Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../spec/fixtures/ipc-hot-codec/golden.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let doc: Value = serde_json::from_str(&text).unwrap();
    doc["cases"].as_array().unwrap().clone()
}

fn golden_bytes(name: &str, part: &str) -> Vec<u8> {
    let cases = golden();
    let case = cases
        .iter()
        .find(|case| case["name"] == name && case["part"] == part)
        .unwrap_or_else(|| panic!("no golden case {name} {part}"));
    let hex = case["hex"].as_str().unwrap();
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2).unwrap(), 16).unwrap())
        .collect()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `value` encodes to the golden bytes and they decode back to `value`.
fn assert_golden<T: HotValue + PartialEq + std::fmt::Debug>(layout: &Layout<T>, value: T) {
    let part = match layout.info.part {
        HotPart::Request => "request",
        HotPart::Result => "result",
        HotPart::Event => "event",
    };
    let expected = golden_bytes(layout.info.name, part);
    let mut out = Vec::new();
    layout.encode(&value, &mut out).unwrap();
    assert_eq!(hex(&out), hex(&expected), "{} {part}", layout.info.name);
    assert_eq!(layout.decode(&expected).unwrap(), value, "{} {part}", layout.info.name);
}

fn resize_request() -> ResizeAttachedViewRequest {
    ResizeAttachedViewRequest {
        cols: 120,
        identity: Some(SizingIdentity {
            device_id: None,
            device_kind: Some("iphone".into()),
            device_name: Some("Pocket".into()),
            display_name: None,
            user_id: Some("u1".into()),
        }),
        lease: None,
        rows: 40,
        stream: Some(3),
        surface: 42,
        view: Some("phone-1".into()),
    }
}

fn size_state_event() -> SizeStateEvent {
    SizeStateEvent {
        cause: None,
        self_participant: Some("p1".into()),
        state: SizeState {
            cols: 100,
            generation: 7,
            owners: vec!["mac".into(), "device:ipad-1".into()],
            participants: vec![SizeParticipant {
                counts: true,
                counts_override: None,
                device_id: Some("d-1".into()),
                device_kind: SizeDeviceKind::Mac,
                device_name: None,
                display_name: Some("Lawrence".into()),
                id: "p1".into(),
                priority_key: "anon:1/mac".into(),
                user_id: None,
                via: None,
                viewport: Some(Size { cols: 100, rows: 30 }),
            }],
            policy: SizePolicy {
                fixed: Some(Size { cols: 80, rows: 24 }),
                mode: Some(SizeMode::Priority),
                priority: Some(vec!["anon:1/mac".into()]),
            },
            reason: SizeReason::PriorityFallback,
            rows: 30,
        },
        surface: 5,
    }
}

#[test]
fn hot_codec_writes_and_reads_the_golden_bytes() {
    assert_golden(&RESIZE_ATTACHED_VIEW_REQUEST, resize_request());
    assert_golden(
        &RESIZE_ATTACHED_VIEW_RESULT,
        AttachedViewResizeResult {
            accepted: true,
            outcome: ViewAttachmentOutcome::Applied,
            participant: Some("p-7".into()),
            reservation_id: None,
        },
    );
    assert_golden(
        &SET_CLIENT_SIZING_REQUEST,
        SetClientSizingRequest {
            client: Some(77),
            enabled: true,
            exclusive: Some(false),
            surface: 9,
        },
    );
    assert_golden(&SET_CLIENT_SIZING_RESULT, EmptyResult {});
    assert_golden(&SCROLL_SURFACE_REQUEST, ScrollSurfaceRequest { delta: -3, surface: 5 });
    assert_golden(&SCROLL_SURFACE_RESULT, EmptyResult {});
    assert_golden(
        &SNAPSHOT_REQUEST_REQUEST,
        SnapshotRequestRequest {
            have: Some(SnapshotRequestHave {
                generation: Some(4),
                offset: Some(1_048_576),
                snapshot_version: Some(2),
            }),
            reason: Some("digest_mismatch".into()),
            request_id: Some("r-1".into()),
            stream: None,
            surface: 12,
        },
    );
    assert_golden(
        &SNAPSHOT_REQUEST_RESULT,
        SnapshotRequestResult {
            reason: None,
            request_id: Some("r-1".into()),
            retry_after_ms: Some(250),
            status: SnapshotRequestResultStatus::SnapshotThrottled,
            surface: 12,
        },
    );
    assert_golden(
        &SCROLL_CHANGED_EVENT,
        ScrollChangedEvent {
            at_bottom: false,
            cause: Some(EventCause::Frontend),
            offset: 300,
            surface: 5,
        },
    );
    assert_golden(
        &SURFACE_RESIZED_EVENT,
        SurfaceResizedEvent { cause: None, cols: 80, reservation_id: None, rows: 24, surface: 5 },
    );
    assert_golden(&SIZE_STATE_EVENT, size_state_event());
    assert_golden(
        &DIGEST_EVENT,
        DigestEvent {
            generation: 3,
            offset: 4096,
            sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08".into(),
            surface: 5,
            version: 2,
        },
    );
}

/// A snapshot digest's sha256 is 64 hex digits, its layout's bound; one more
/// byte goes as JSON.
#[test]
fn hot_codec_digest_carries_a_hex_sha256() {
    let mut event =
        DigestEvent { generation: 1, offset: 2, sha256: "f".repeat(64), surface: 3, version: 2 };
    let mut out = Vec::new();
    DIGEST_EVENT.encode(&event, &mut out).unwrap();
    assert_eq!(DIGEST_EVENT.decode(&out).unwrap(), event);
    event.sha256.push('f');
    assert_eq!(
        DIGEST_EVENT.encode(&event, &mut Vec::new()),
        Err(HotEncodeError::StringTooLong { len: 65, max: 64 })
    );
}

/// Every layout has a golden case and every golden case a layout.
#[test]
fn hot_codec_golden_file_covers_every_layout() {
    let mut cases: Vec<(String, String)> = golden()
        .iter()
        .map(|case| {
            (case["name"].as_str().unwrap().to_owned(), case["part"].as_str().unwrap().to_owned())
        })
        .collect();
    cases.sort();
    let mut layouts: Vec<(String, String)> = MESSAGES
        .iter()
        .map(|m| (m.name.to_owned(), format!("{:?}", m.part).to_ascii_lowercase()))
        .collect();
    layouts.sort();
    assert_eq!(cases, layouts);
}

/// A layout is exactly the binary payload the method tables give its id.
#[test]
fn hot_codec_layouts_agree_with_the_method_tables() {
    let tables = MethodTables::schema();
    for m in MESSAGES {
        let payload = match m.part {
            HotPart::Request | HotPart::Result => {
                let method = tables.method(MethodId::new(m.wire_id)).unwrap();
                assert_eq!(method.name, m.name);
                method.payload
            }
            HotPart::Event => {
                let event = tables.event(EventId::new(m.wire_id)).unwrap();
                assert_eq!(event.name, m.name);
                event.payload
            }
        };
        assert_eq!(payload, Payload::Binary { layout_version: m.layout_version }, "{}", m.name);
    }
    let methods = tables.v12_families().chain(tables.v2_families()).flat_map(|f| f.iter());
    for method in methods.filter(|m| m.payload != Payload::Json) {
        for part in [HotPart::Request, HotPart::Result] {
            assert!(
                MESSAGES.iter().any(|m| m.wire_id == method.id.raw() && m.part == part),
                "{} {part:?} has no layout",
                method.name
            );
        }
    }
    let events = tables.event_families().flat_map(|f| f.iter());
    for event in events.filter(|e| e.payload != Payload::Json) {
        assert!(
            MESSAGES.iter().any(|m| m.wire_id == event.id.raw() && m.part == HotPart::Event),
            "{} has no layout",
            event.name
        );
    }
    // The hot set of the design (p05-ipc.md, task 183); title-changed stays JSON.
    let mut names: Vec<&str> = MESSAGES.iter().map(|m| m.name).collect();
    names.dedup();
    assert_eq!(
        names,
        [
            "resize-attached-view",
            "scroll-surface",
            "set-client-sizing",
            "snapshot-request",
            "digest",
            "scroll-changed",
            "size-state",
            "surface-resized",
        ]
    );
    let title = tables.event(tables.event_id("title-changed").unwrap()).unwrap();
    assert_eq!(title.payload, Payload::Json);
}

/// Another revision's layout is refused, not misread.
#[test]
fn hot_codec_refuses_another_layout_version() {
    let mut bytes = golden_bytes("scroll-surface", "request");
    bytes[0] = 2;
    assert_eq!(
        SCROLL_SURFACE_REQUEST.decode(&bytes),
        Err(HotDecodeError::Version { name: "scroll-surface", expected: 1, found: 2 })
    );
    assert_eq!(SCROLL_SURFACE_REQUEST.decode(&[]), Err(HotDecodeError::Truncated));
}

/// Every proper prefix is truncated and an extra byte is refused.
#[test]
fn hot_codec_refuses_truncated_and_trailing_payloads() {
    let bytes = golden_bytes("size-state", "event");
    for len in 0..bytes.len() {
        assert!(SIZE_STATE_EVENT.decode(&bytes[..len]).is_err(), "prefix {len}");
    }
    let mut longer = bytes;
    longer.push(0);
    assert_eq!(SIZE_STATE_EVENT.decode(&longer), Err(HotDecodeError::TrailingBytes(1)));
}

#[test]
fn hot_codec_refuses_bad_tags_booleans_enums_and_strings() {
    // scroll-changed: version, at_bottom, cause tag, cause, offset, surface.
    let bytes = golden_bytes("scroll-changed", "event");
    let mut bad_tag = bytes.clone();
    bad_tag[2] = 2;
    assert_eq!(SCROLL_CHANGED_EVENT.decode(&bad_tag), Err(HotDecodeError::BadTag(2)));
    let mut bad_enum = bytes.clone();
    bad_enum[3] = 9;
    assert_eq!(
        SCROLL_CHANGED_EVENT.decode(&bad_enum),
        Err(HotDecodeError::BadEnum { type_name: "EventCause", index: 9 })
    );
    let mut bad_bool = bytes;
    bad_bool[1] = 7;
    assert_eq!(SCROLL_CHANGED_EVENT.decode(&bad_bool), Err(HotDecodeError::BadBool(7)));

    // resize-attached-view result: version, accepted, outcome, participant
    // tag, u16 length, "p-7", reservation tag.
    let bytes = golden_bytes("resize-attached-view", "result");
    let mut over = bytes.clone();
    over[4..6].copy_from_slice(&257u16.to_le_bytes());
    assert_eq!(
        RESIZE_ATTACHED_VIEW_RESULT.decode(&over),
        Err(HotDecodeError::OverBound { len: 257, max: 256 })
    );
    let mut not_utf8 = bytes;
    not_utf8[6] = 0xFF;
    assert_eq!(RESIZE_ATTACHED_VIEW_RESULT.decode(&not_utf8), Err(HotDecodeError::InvalidUtf8));
}

/// A value over its layout's bounds is refused and leaves the buffer as it
/// was, so the sender writes the message as JSON instead.
#[test]
fn hot_codec_refuses_values_over_their_bounds() {
    let mut request = resize_request();
    request.view = Some("v".repeat(129));
    let mut out = vec![0xAA];
    assert_eq!(
        RESIZE_ATTACHED_VIEW_REQUEST.encode(&request, &mut out),
        Err(HotEncodeError::StringTooLong { len: 129, max: 128 })
    );
    assert_eq!(out, [0xAA]);

    let mut event = size_state_event();
    event.state.owners = vec!["mac".into(); 65];
    assert_eq!(
        SIZE_STATE_EVENT.encode(&event, &mut out),
        Err(HotEncodeError::ArrayTooLong { len: 65, max: 64 })
    );
    assert_eq!(out, [0xAA]);
    event.state.owners.truncate(64);
    SIZE_STATE_EVENT.encode(&event, &mut out).unwrap();
    assert_eq!(SIZE_STATE_EVENT.decode(&out[1..]).unwrap(), event);
}

fn schema_with(command: Value, types: Value) -> Value {
    json!({ "types": types, "commands": { "hot": command }, "events": {} })
}

fn binary_command(request: Value) -> Value {
    json!({
        "method_id": 0x0300,
        "payload": "binary",
        "layout_version": 3,
        "request": request,
        "result": { "kind": "object", "fields": {}, "additional_properties": false }
    })
}

/// The layout is the byte order of the field names, whatever order the
/// schema file lists them in, and literal fields are not on the wire.
#[test]
fn hot_codec_reader_orders_fields_by_name() {
    let request = json!({ "kind": "object", "additional_properties": false, "fields": {
        "zeta": { "type": { "kind": "scalar", "name": "uint16" }, "presence": "required", "nullable": false },
        "kind": { "type": { "kind": "literal", "value": "x" }, "presence": "required", "nullable": false },
        "Alpha": { "type": { "kind": "scalar", "name": "boolean" }, "presence": "optional", "nullable": false },
        "alpha": { "type": { "kind": "scalar", "name": "string" }, "presence": "required", "nullable": true, "max_bytes": 8 }
    }});
    let model = reader::read(&schema_with(binary_command(request), json!({}))).unwrap();
    let body = &model.structs["HotRequest"];
    let order: Vec<(&str, bool)> =
        body.fields.iter().map(|f| (f.wire.as_str(), f.tagged)).collect();
    assert_eq!(order, [("Alpha", true), ("alpha", true), ("zeta", false)]);
    assert_eq!(model.messages.len(), 2);
    assert_eq!(model.messages[0].layout_version, 3);
}

/// A field's `max_items` bounds the field's own array in the layout (the
/// array type, which JSON decoders read, stays unbounded); an inner array
/// still needs its own bound.
#[test]
fn hot_codec_reader_takes_a_field_max_items_as_its_array_bound() {
    let request = json!({ "kind": "object", "additional_properties": false, "fields": {
        "keys": {
            "type": { "kind": "array", "items": { "kind": "scalar", "name": "string" } },
            "presence": "required", "nullable": false, "max_bytes": 16, "max_items": 3
        }
    }});
    let model = reader::read(&schema_with(binary_command(request), json!({}))).unwrap();
    let keys = &model.structs["HotRequest"].fields[0];
    assert_eq!(
        keys.ty,
        reader::Ty::Array { items: Box::new(reader::Ty::Str { max_bytes: 16 }), max_items: 3 }
    );

    let nested = json!({ "kind": "object", "additional_properties": false, "fields": {
        "rows": {
            "type": { "kind": "array", "items": {
                "kind": "array", "items": { "kind": "scalar", "name": "uint16" }
            }},
            "presence": "required", "nullable": false, "max_items": 3
        }
    }});
    let error = reader::read(&schema_with(binary_command(nested), json!({}))).unwrap_err();
    assert!(error.contains("$.commands.hot.request.fields.rows.items"), "{error}");
    assert!(error.contains("needs max_items"), "{error}");
}

/// What a layout cannot bound fails the build with its JSON path.
#[test]
fn hot_codec_reader_refuses_unbounded_layouts() {
    let field = |ty: Value| {
        json!({ "kind": "object", "additional_properties": false, "fields": {
            "f": { "type": ty, "presence": "required", "nullable": false }
        }})
    };
    let cases = [
        (field(json!({ "kind": "scalar", "name": "string" })), json!({}), "needs max_bytes"),
        (
            field(json!({ "kind": "array", "items": { "kind": "scalar", "name": "uint16" } })),
            json!({}),
            "needs max_items",
        ),
        (
            field(json!({ "kind": "map", "values": { "kind": "scalar", "name": "uint16" } })),
            json!({}),
            "has no binary layout",
        ),
        (
            field(json!({ "kind": "ref", "name": "Node" })),
            json!({ "Node": { "kind": "object", "additional_properties": false, "fields": {
                "next": { "type": { "kind": "ref", "name": "Node" }, "presence": "optional", "nullable": true }
            }}}),
            "recursive type",
        ),
    ];
    for (request, types, message) in cases {
        let error = reader::read(&schema_with(binary_command(request), types)).unwrap_err();
        assert!(error.contains("$.") && error.contains(message), "{error}");
    }
}
