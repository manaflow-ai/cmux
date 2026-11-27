//! Golden vectors for hop/1. The Cloudflare relay's TypeScript record
//! parser reads the same file, so both sides agree byte for byte.

use cmux_transport::hop::{HopClass, HopError, HopMsg, Record, decode_records, encode_records};

const VECTORS: &str = include_str!("vectors/hop-frames.json");

fn hex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&text[index..index + 2], 16).expect("hex"))
        .collect()
}

/// Reads `"key": "value"` pairs line by line; the vector file is written in
/// that one-object-per-line shape so no JSON dependency is needed.
fn field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let marker = format!("\"{key}\": \"");
    let start = line.find(&marker)? + marker.len();
    let end = line[start..].find('"')? + start;
    Some(&line[start..end])
}

fn num<T: std::str::FromStr>(line: &str, key: &str) -> T
where
    T::Err: std::fmt::Debug,
{
    field(line, key).unwrap_or_else(|| panic!("{key} field")).parse().expect("number")
}

/// `class:key:key_seq:hex`, `-` for an untagged key and key_seq.
fn records(text: &str) -> Vec<Record> {
    text.split(',')
        .map(|one| {
            let parts: Vec<&str> = one.split(':').collect();
            let [class, key, seq, bytes] = parts[..] else { panic!("record {one}") };
            let class = HopClass::from_byte(class.parse().expect("class")).expect("class");
            let bytes = hex(bytes);
            match (key, seq) {
                ("-", "-") => Record::new(class, bytes),
                (key, seq) => {
                    let record = Record::tagged(key.parse().unwrap(), seq.parse().unwrap(), bytes);
                    assert_eq!(record.class, class);
                    record
                }
            }
        })
        .collect()
}

fn expected(line: &str) -> HopMsg {
    match field(line, "type").expect("type field") {
        "data" => HopMsg::Data {
            seq: num(line, "seq"),
            records: records(field(line, "records").expect("records")),
        },
        "nack" => HopMsg::Nack {
            base: num(line, "base"),
            bitmap: num(line, "bitmap"),
            highest: num(line, "highest"),
            loss_permille: num(line, "loss_permille"),
        },
        "parity" => HopMsg::Parity {
            first_seq: num(line, "first_seq"),
            count: num(line, "count"),
            len_xor: num(line, "len_xor"),
            xor: hex(field(line, "xor").expect("xor")),
        },
        "bind" => HopMsg::Bind { ticket: hex(field(line, "ticket").expect("ticket")) },
        "bind_ok" => {
            HopMsg::BindOk { addr: num(line, "addr"), lifetime_s: num(line, "lifetime_s") }
        }
        "ping" => HopMsg::Ping { nonce: num(line, "nonce"), sent_ms: num(line, "sent_ms") },
        "pong" => HopMsg::Pong {
            nonce: num(line, "nonce"),
            sent_ms: num(line, "sent_ms"),
            loss_permille: num(line, "loss_permille"),
        },
        "error" => HopMsg::Error { code: num(line, "code") },
        other => panic!("unknown type {other}"),
    }
}

#[test]
fn valid_vectors_round_trip() {
    let mut types = std::collections::BTreeSet::new();
    for line in VECTORS.lines().filter(|line| line.contains("\"valid\": \"yes\"")) {
        let bytes = hex(field(line, "hex").expect("hex field"));
        let message = expected(line);
        assert_eq!(HopMsg::decode(&bytes).as_ref(), Ok(&message), "{line}");
        assert_eq!(message.encode().expect("encodes"), bytes, "{line}");
        if let HopMsg::Data { records, .. } = &message {
            // The body after the 6-byte header is what the relay frame carries.
            assert_eq!(decode_records(&bytes[6..]).as_ref(), Ok(records));
            assert_eq!(encode_records(records).expect("encodes"), bytes[6..]);
        }
        types.insert(field(line, "type").expect("type field"));
    }
    assert_eq!(types.len(), 8, "vector file lost a message type: {types:?}");
}

#[test]
fn invalid_vectors_are_refused() {
    let mut errors = std::collections::BTreeSet::new();
    for line in VECTORS.lines().filter(|line| line.contains("\"valid\": \"no\"")) {
        let bytes = hex(field(line, "hex").expect("hex field"));
        let error = HopMsg::decode(&bytes).expect_err("invalid vector is refused");
        let name = match error {
            HopError::Short => "short",
            HopError::Magic(_) => "magic",
            HopError::Type(_) => "type",
            HopError::Trailing => "trailing",
            HopError::NoRecords => "no_records",
            HopError::RecordTruncated => "record_truncated",
            HopError::Class(_) => "class",
            HopError::Flags(_) => "flags",
            HopError::TagClass => "tag_class",
            HopError::EmptyRecord => "empty_record",
            HopError::Family(_) => "family",
            HopError::BadParity => "bad_parity",
            HopError::TooLarge(_) => "too_large",
        };
        let expected = field(line, "error").expect("error field");
        assert_eq!(name, expected, "{line}");
        // A DATA body fails the same way through the records decoder.
        if bytes.get(1) == Some(&1) && bytes.len() >= 6 {
            assert_eq!(decode_records(&bytes[6..]), Err(error), "{line}");
        }
        errors.insert(expected);
    }
    // Every decode error (`too_large` is encode-only).
    assert_eq!(errors.len(), 12, "vector file lost a decode error: {errors:?}");
}
