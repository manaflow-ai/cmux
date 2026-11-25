//! Golden vectors for hub relay frames (kind 5, RFD 0142 R6). The
//! TypeScript `HubRelay` (cmux-next-ios/backend/src/hub-relay.ts) reads the
//! same file, so the relay and the clients agree on the clear header byte for
//! byte; the sealed cases also pin the seal (key derivation, nonce, associated
//! data), so another implementation of a source or viewer can check itself.
//!
//! Regenerate after a deliberate format change with
//! `CMUX_WRITE_HUB_VECTORS=1 cargo test -p cmux-transport --test hub_vectors`.

use cmux_transport::hub::{HubHeader, HubKey, HubPos, HubRole, HubTo, open, seal};
use cmux_transport::{FrameKind, PeerId, RelayFrame, RelayFrameError};

const VECTORS: &str = include_str!("vectors/relay-hub-frames.json");
const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors/relay-hub-frames.json");

const PEER: [u8; 16] = [
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
];
const SESSION: [u8; 16] = [
    0x5e, 0x55, 0x10, 0x4e, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
];
const SECRET: [u8; 32] = [0x07; 32];

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

fn field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let marker = format!("\"{key}\": \"");
    let start = line.find(&marker)? + marker.len();
    let end = line[start..].find('"')? + start;
    Some(&line[start..end])
}

fn role_name(role: HubRole) -> &'static str {
    match role {
        HubRole::Mac => "mac",
        HubRole::Vm => "vm",
    }
}

fn to_name(to: HubTo) -> &'static str {
    match to {
        HubTo::Viewers => "viewers",
        HubTo::Source(role) => role_name(role),
    }
}

fn frame_bytes(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = vec![1, kind];
    out.extend_from_slice(&PEER);
    out.extend_from_slice(payload);
    out
}

fn sealed_case(name: &str, header: HubHeader, event: &[u8]) -> String {
    let payload = seal(&HubKey::derive(&SECRET, &SESSION), &header, event).expect("fits");
    format!(
        "    {{\"name\": \"{name}\", \"valid\": \"yes\", \"sealed\": \"yes\", \"peer\": \"{}\", \"session\": \"{}\", \"epoch\": \"{}\", \"seq\": \"{}\", \"source\": \"{}\", \"to\": \"{}\", \"secret\": \"{}\", \"event\": \"{}\", \"payload\": \"{}\", \"hex\": \"{}\"}}",
        hex(&PEER),
        hex(&header.session),
        header.pos.epoch,
        header.pos.seq,
        role_name(header.source),
        to_name(header.to),
        hex(&SECRET),
        hex(event),
        hex(&payload),
        hex(&frame_bytes(5, &payload))
    )
}

fn clear_case(name: &str, header: HubHeader, body: &[u8]) -> String {
    let mut payload = header.encode().to_vec();
    payload.extend_from_slice(body);
    format!(
        "    {{\"name\": \"{name}\", \"valid\": \"yes\", \"sealed\": \"no\", \"peer\": \"{}\", \"session\": \"{}\", \"epoch\": \"{}\", \"seq\": \"{}\", \"source\": \"{}\", \"to\": \"{}\", \"payload\": \"{}\", \"hex\": \"{}\"}}",
        hex(&PEER),
        hex(&header.session),
        header.pos.epoch,
        header.pos.seq,
        role_name(header.source),
        to_name(header.to),
        hex(&payload),
        hex(&frame_bytes(5, &payload))
    )
}

fn invalid_case(name: &str, error: &str, bytes: &[u8]) -> String {
    format!(
        "    {{\"name\": \"{name}\", \"valid\": \"no\", \"error\": \"{error}\", \"hex\": \"{}\"}}",
        hex(bytes)
    )
}

fn generate() -> String {
    let header = |source, to, epoch, seq| HubHeader {
        session: SESSION,
        pos: HubPos::new(epoch, seq),
        source,
        to,
    };
    let good = header(HubRole::Mac, HubTo::Viewers, 1, 2).encode();
    let with = |index: usize, byte: u8| {
        let mut h = good.to_vec();
        h[index] = byte;
        h.extend_from_slice(&[0xab; 8]);
        frame_bytes(5, &h)
    };
    let cases = [
        sealed_case(
            "mac event to viewers",
            header(HubRole::Mac, HubTo::Viewers, 1, 2),
            b"{\"delta\":\"hello\"}",
        ),
        sealed_case(
            "the vm's copy of the same event",
            header(HubRole::Vm, HubTo::Viewers, 1, 2),
            b"{\"delta\":\"hello\"}",
        ),
        sealed_case(
            "mac-to-vm sync with no direct path",
            header(HubRole::Mac, HubTo::Source(HubRole::Vm), 3, 0),
            b"sync",
        ),
        sealed_case("empty event", header(HubRole::Vm, HubTo::Viewers, 0, 0), b""),
        clear_case(
            "largest epoch and seq (body not checked by the relay)",
            header(HubRole::Vm, HubTo::Source(HubRole::Mac), u64::MAX, u64::MAX),
            &[0x00],
        ),
        invalid_case("hub header cut short", "bad_hub", &frame_bytes(5, &good[..34])),
        invalid_case("empty hub payload", "bad_hub", &frame_bytes(5, &[])),
        invalid_case("unknown hub header version", "bad_hub", &with(0, 2)),
        invalid_case("source role zero", "bad_hub", &with(33, 0)),
        invalid_case("unknown source role", "bad_hub", &with(33, 3)),
        invalid_case("unknown target", "bad_hub", &with(34, 9)),
        invalid_case("a source sending to itself", "bad_hub", &with(34, 1)),
        invalid_case("kind past hub", "kind", &frame_bytes(6, &good)),
    ];
    format!(
        "{{\n  \"format\": \"cmux overlay relay frame kind 5 (hub, RFD 0142 R6): [u8 version=1][u8 kind=5][16-byte peer id][hub payload]; hub payload = [u8 hub header version=1][16-byte session id][u64 BE epoch][u64 BE seq][u8 source: 1 mac, 2 vm][u8 to: 0 viewers, 1 mac, 2 vm][sealed body]; the 35-byte clear header is all a relay reads; sealed body = XChaCha20-Poly1305 under key = BLAKE3 derive_key('cmux relay hub v1 session key', secret || session), nonce = [source][to][epoch BE][seq BE][6 zero bytes], associated data = the clear header, plaintext = [session][epoch BE][seq BE][source][event]; decoders check short, version, kind, too_large, then bad_hub (header short, version, source, to, a source to itself); epoch and seq are decimal strings; one case per line\",\n  \"cases\": [\n{}\n  ]\n}}\n",
        cases.join(",\n")
    )
}

#[test]
fn vectors_match_the_generator() {
    let generated = generate();
    if std::env::var_os("CMUX_WRITE_HUB_VECTORS").is_some() {
        std::fs::write(PATH, &generated).expect("write vectors");
        return;
    }
    assert_eq!(
        VECTORS, generated,
        "relay-hub-frames.json is stale; regenerate it (see the module doc)"
    );
}

#[test]
fn valid_vectors_decode_and_open() {
    let mut sealed = 0;
    for line in VECTORS.lines().filter(|l| l.contains("\"valid\": \"yes\"")) {
        let bytes = unhex(field(line, "hex").expect("hex"));
        let frame = RelayFrame::decode(&bytes).expect("valid vector decodes");
        assert_eq!(frame.kind, FrameKind::Hub);
        assert_eq!(frame.peer, PeerId(PEER));
        assert_eq!(frame.payload, unhex(field(line, "payload").expect("payload")));
        let header = HubHeader::decode(&frame.payload).expect("header");
        assert_eq!(hex(&header.session), field(line, "session").expect("session"));
        assert_eq!(header.pos.epoch.to_string(), field(line, "epoch").expect("epoch"));
        assert_eq!(header.pos.seq.to_string(), field(line, "seq").expect("seq"));
        assert_eq!(role_name(header.source), field(line, "source").expect("source"));
        assert_eq!(to_name(header.to), field(line, "to").expect("to"));
        if field(line, "sealed") == Some("yes") {
            let secret: [u8; 32] =
                unhex(field(line, "secret").expect("secret")).try_into().expect("32");
            let opened =
                open(&HubKey::derive(&secret, &header.session), &frame.payload).expect("opens");
            assert_eq!(opened.event, unhex(field(line, "event").expect("event")));
            assert_eq!(
                (opened.inner_session, opened.inner_pos, opened.inner_source),
                (header.session, header.pos, header.source)
            );
            sealed += 1;
        }
        assert_eq!(frame.encode().expect("encodes"), bytes);
    }
    assert!(sealed >= 3, "vector file lost its sealed cases");
}

#[test]
fn invalid_vectors_are_refused() {
    let mut checked = 0;
    for line in VECTORS.lines().filter(|l| l.contains("\"valid\": \"no\"")) {
        let error =
            RelayFrame::decode(&unhex(field(line, "hex").expect("hex"))).expect_err("refused");
        let expected = field(line, "error").expect("error");
        let matches = match error {
            RelayFrameError::BadHub => expected == "bad_hub",
            RelayFrameError::Kind(_) => expected == "kind",
            other => panic!("unexpected {other:?}"),
        };
        assert!(matches, "expected {expected}, got {error:?}");
        checked += 1;
    }
    assert!(checked >= 5);
}
