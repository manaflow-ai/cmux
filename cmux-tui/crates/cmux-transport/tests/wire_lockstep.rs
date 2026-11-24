//! The relay frame's wire manifest (`spec/wire/relay-frame.json`): every frame kind the decoder
//! accepts, by number, and the header version. `wire-lockstep-check` compares it with the base and,
//! with `--against origin/lane/x`, with another open change, so two drafts that each take the next
//! kind number fail before the second lands (cmux#54103 and cmux#54189 both took kind 4).
//!
//! Kinds 1 to 3 predate negotiation. A new kind is sent only to a relay that serves it (a hub relay
//! answers `/v1/hub`; a two-party relay answers `bad_frame:kind`), so it is listed in [`GATED`]
//! under the capability the relay advertises for it. Regenerate the manifest with
//! `CMUX_UPDATE_WIRE_MANIFEST=1 cargo test -p cmux-transport --test wire_lockstep`.

use std::path::Path;

use cmux_transport::relay_frame::{PeerId, RELAY_FRAME_VERSION, RelayFrame, RelayFrameError};
use cmux_wire_lockstep::{Manifest, assert_manifest_current, base_manifest};

const PROTOCOL: &str = "relay-frame";

/// Kinds spoken before relay frames were negotiated.
const LEGACY: &[&str] = &["datagrams", "candidates", "wake"];

/// Each newer kind and the capability id that gates it.
const GATED: &[(&str, &str)] = &[];

fn frame(version: u8, kind: u8) -> Vec<u8> {
    let mut bytes = vec![version, kind];
    bytes.extend_from_slice(&[7; 16]);
    // One one-byte datagram record: a valid payload for every kind.
    bytes.extend_from_slice(&[0, 1, 0xAA]);
    bytes
}

fn kebab(debug: &str) -> String {
    let mut out = String::new();
    for (i, c) in debug.chars().enumerate() {
        if c.is_ascii_uppercase() && i > 0 {
            out.push('-');
        }
        out.push(c.to_ascii_lowercase());
    }
    out
}

/// Every kind byte the decoder accepts, with its label.
fn kinds() -> Vec<(u8, String)> {
    (0..=u8::MAX)
        .filter_map(|byte| {
            RelayFrame::decode(&frame(RELAY_FRAME_VERSION, byte))
                .ok()
                .map(|f| (byte, kebab(&format!("{:?}", f.kind))))
        })
        .collect()
}

fn generated_manifest() -> Manifest {
    let mut m = Manifest::new(
        PROTOCOL,
        "the relay route and its hello (a relay that lacks a kind answers bad_frame:kind)",
    );
    for (byte, label) in kinds() {
        let name = format!("frame:kind/{label}={byte}");
        match GATED.iter().find(|(l, _)| *l == label) {
            Some((_, cap)) => {
                m.capabilities.entry((*cap).to_owned()).or_default().insert(name);
            }
            None => {
                assert!(
                    LEGACY.contains(&label.as_str()),
                    "relay frame kind {byte} ({label}) is new: send it only to a relay that \
                     advertises it, and list it in GATED with that capability id"
                );
                m.legacy.insert(name);
            }
        }
    }
    let version = u32::from(RELAY_FRAME_VERSION);
    m.versions.insert(PROTOCOL.into(), version);
    let accepts = (0..=u8::MAX)
        .filter(|v| !matches!(RelayFrame::decode(&frame(*v, 1)), Err(RelayFrameError::Version(_))))
        .map(u32::from)
        .collect();
    m.accepts.insert(PROTOCOL.into(), accepts);
    m
}

#[test]
fn wire_lockstep_manifest_is_current() {
    assert_manifest_current(
        &generated_manifest(),
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/wire/relay-frame.json"),
    )
    .unwrap();
}

/// Old against new: every kind the base sends still decodes at the head to the same kind, and a
/// frame the head adds is one the base would refuse by kind, never misread as another.
#[test]
fn wire_lockstep_base_kinds_still_decode() {
    let head = generated_manifest();
    let base = base_manifest(PROTOCOL, &head.to_json()).unwrap();
    let head_kinds = kinds();
    for (space, numbers) in base.codes() {
        assert_eq!(space, "frame:kind", "unexpected numbering space in the base");
        for (number, labels) in numbers {
            let byte = u8::try_from(number).unwrap();
            let decoded = head_kinds.iter().find(|(b, _)| *b == byte).map(|(_, l)| l.clone());
            assert_eq!(decoded.as_ref(), labels.iter().next(), "base kind {number} at the head");
        }
    }
    // Encode round-trips every kind under the current version.
    for (byte, _) in &head_kinds {
        let decoded = RelayFrame::decode(&frame(RELAY_FRAME_VERSION, *byte)).unwrap();
        assert_eq!(decoded.encode().unwrap(), frame(RELAY_FRAME_VERSION, *byte));
        assert_eq!(decoded.peer, PeerId([7; 16]));
    }
}
