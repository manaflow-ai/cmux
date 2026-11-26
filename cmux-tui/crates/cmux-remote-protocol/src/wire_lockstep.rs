//! The serialize schema uses the real enums' serde renames and includes optional
//! fields even when a particular example omits them. A new tag or field therefore
//! appears in the snapshot even before a test driver knows how to exercise it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use cmux_wire_lockstep::{Manifest, assert_manifest_current, base_manifest};
use schemars::{JsonSchema, generate::SchemaSettings};
use serde_json::Value;

use super::*;

fn schema<T: JsonSchema>() -> Value {
    SchemaSettings::draft2020_12()
        .for_serialize()
        .into_generator()
        .into_root_schema_for::<T>()
        .to_value()
}

/// Unit variants may share an enum schema or have individual const schemas
/// (e.g. a variant with its own documentation). RemoteCapability also has a
/// catch-all string for IDs only the other revision understands.
fn wire_strings(schema: &Value, allow_unknown: bool) -> Vec<&str> {
    if let Some(names) = schema["enum"].as_array() {
        return names.iter().map(|name| name.as_str().unwrap()).collect();
    }
    if let Some(name) = schema["const"].as_str() {
        return vec![name];
    }
    if let Some(variants) = schema.get("oneOf").or_else(|| schema.get("anyOf")) {
        return variants
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|v| wire_strings(v, allow_unknown))
            .collect();
    }
    assert!(allow_unknown && schema["type"] == "string", "unexpected wire enum: {schema}");
    Vec::new()
}

type MessageFields = BTreeMap<String, BTreeSet<String>>;

fn tagged<T: JsonSchema>(messages: &mut MessageFields, name_prefix: &str, field_prefix: &str) {
    let schema = schema::<T>();
    for variant in schema["oneOf"].as_array().expect("internally tagged enum") {
        let fields = variant["properties"].as_object().unwrap();
        let tag = fields["type"]["const"].as_str().unwrap();
        let names = fields
            .keys()
            .filter(|key| key.as_str() != "type")
            .map(|key| format!("{field_prefix}{tag}#{key}"))
            .collect();
        assert!(messages.insert(format!("{name_prefix}{tag}"), names).is_none());
    }
}

fn encoded_frame() -> Vec<u8> {
    WireFrame {
        session: SessionId([0; 16]),
        generation: 0,
        lane: Lane::Control,
        flags: FrameFlags::empty(),
        sequence: 0,
        acknowledgement: 0,
        stream: 0,
        payload: vec![],
    }
    .encode()
    .unwrap()
}

// ServiceControl carries open metadata as a string map. Each service owns its
// keys; the server validates them after decoding the outer control envelope.
fn open_metadata(service: Service) -> &'static [&'static str] {
    match service {
        Service::MuxControl => &[MUX_CONTROL_LINE_CODECS],
        Service::WorkspaceRpc => &["lane", "purpose"],
        Service::ProcessStream => &["process", "after", "reserve"],
        Service::TerminalBytes => &["terminal", TERMINAL_BYTES_VIEWER_SIZE_PRIORITY],
        Service::TcpTunnel => &["route"],
        Service::LocalSocket => &["path"],
        Service::ComputerUse | Service::Acpmux => &[],
    }
}

fn generated_manifest() -> Manifest {
    let mut head = Manifest::new(
        "cmux-remote",
        "workspace-rpc capabilities response; mux-control open metadata and opened.features; relay connect.accepts_parked",
    );
    let mut messages = MessageFields::new();
    tagged::<WorkspaceRequest>(&mut messages, "method:", "param:");
    tagged::<WorkspaceResponse>(&mut messages, "method:response/", "field:response.");
    tagged::<ProcessEvent>(&mut messages, "event:", "field:");
    tagged::<ServiceControl>(&mut messages, "control:", "field:");
    tagged::<RelayControl>(&mut messages, "control:relay/", "field:relay/");
    for (name, fields) in &messages {
        head.legacy.insert(name.clone());
        head.legacy.extend(fields.iter().cloned());
    }
    for name in wire_strings(&schema::<Service>(), false) {
        head.legacy.insert(format!("service:{name}"));
        let service = serde_json::from_value(Value::from(name)).unwrap();
        for key in open_metadata(service) {
            head.legacy.insert(format!("param:{name}#{key}"));
        }
    }
    for (name, flag) in FrameFlags::NAMED {
        head.legacy.insert(format!("frame:flag/{name}={}", flag.bits()));
    }

    let header = |bytes: [u8; 4]| format!("header:{}", std::str::from_utf8(&bytes).unwrap());
    head.legacy.extend([
        header(MUX_LINE_MAGIC),
        "field:opened#features".to_owned(),
        "header:*** Begin Patch".to_owned(),
    ]);

    // Prefer a field's explicit contract over the enclosing message's
    // contract, e.g. pagination extended the original list-directory.
    let mut owners = BTreeMap::new();
    for id in wire_strings(&schema::<RemoteCapability>(), true) {
        let cap: RemoteCapability = serde_json::from_value(Value::from(id)).unwrap();
        assert!(
            cap.changes_no_wire() == cap.wire_names().is_empty(),
            "{id} needs a wire contract, or changes_no_wire if it only changes behavior"
        );
        for &name in cap.wire_names() {
            assert!(head.legacy.contains(name), "{id}: unknown wire name {name}");
            assert!(owners.insert(name.to_owned(), id.to_owned()).is_none(), "{name}");
        }
    }
    owners.insert("control:relay/parked".into(), "accepts_parked".into());
    for (message, fields) in messages {
        if let Some(owner) = owners.get(&message).cloned() {
            for field in fields {
                owners.entry(field).or_insert_with(|| owner.clone());
            }
        }
    }
    for (name, owner) in owners {
        head.legacy.remove(&name);
        head.capabilities.entry(owner).or_default().insert(name);
    }
    head.capabilities.insert(MUX_INPUT_V1_FEATURE.into(), [header(MUX_INPUT_MAGIC)].into());
    head.capabilities.insert(MUX_LINE_ZLIB_V1_FEATURE.into(), [header(MUX_LINE_ZLIB_MAGIC)].into());

    // The frame version is byte 4 after CMXR. Query the decoder for every
    // possible version byte, so adding support for an older version shows up.
    let mut bytes = encoded_frame();
    for byte in 0..=u8::MAX {
        bytes[5] = byte;
        if let Ok(frame) = WireFrame::decode(&bytes) {
            let name = serde_json::to_value(frame.lane).unwrap();
            head.legacy.insert(format!("frame:lane/{}={byte}", name.as_str().unwrap()));
        }
    }
    bytes[5] = Lane::Control as u8;
    head.versions.insert("remote-frame".into(), u32::from(bytes[4]));
    let accepts = (0..=u8::MAX)
        .filter(|&version| {
            bytes[4] = version;
            WireFrame::decode(&bytes).is_ok()
        })
        .map(u32::from)
        .collect();
    head.accepts.insert("remote-frame".into(), accepts);
    // cmux-relay ticket validation compares claims.version to this constant.
    let ticket = u32::from(RelayTicketClaims::VERSION);
    head.versions.insert("relay-ticket".into(), ticket);
    head.accepts.insert("relay-ticket".into(), [ticket].into());
    head
}

#[test]
fn wire_lockstep_manifest_is_current() {
    assert_manifest_current(
        &generated_manifest(),
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/wire/cmux-remote.json"),
    )
    .unwrap();
}

#[test]
fn wire_lockstep_frame_version_both_directions() {
    let base = base_manifest("cmux-remote", include_str!("../../../spec/wire/cmux-remote.json"))
        .expect("cmux-remote base manifest");
    let mut frame = encoded_frame();
    assert!(
        base.accepts["remote-frame"].contains(&u32::from(frame[4])),
        "head sent frame version {} to an old decoder accepting {:?}",
        frame[4],
        base.accepts["remote-frame"],
    );
    frame[4] = base.versions["remote-frame"].try_into().unwrap();
    WireFrame::decode(&frame).expect("head must read frames using the old sender's version");
}
