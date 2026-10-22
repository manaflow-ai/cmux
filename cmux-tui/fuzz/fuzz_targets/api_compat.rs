//! Daemon API compatibility rewriter on client JSON lines. Mode byte 0..127:
//! a fixed schema that uses every change kind (kind = mode parity), then a
//! byte whose nibbles pick the two revisions the message is rewritten between. 128..255: the input is `schema JSON \0 message`.
#![no_main]

use std::sync::OnceLock;

use cmux_api_compat::{Change, Compat, Conversion, Direction, MessageChange, Schema};
use libfuzzer_sys::fuzz_target;
use serde_json::json;

const KINDS: [&str; 2] = ["request:m", "event:e"];

fn change(message: &str, change: Change) -> MessageChange {
    MessageChange { message: message.into(), change }
}

fn fixed() -> &'static Compat {
    static COMPAT: OnceLock<Compat> = OnceLock::new();
    COMPAT.get_or_init(|| {
        let mut schema = Schema::new("fuzz", 1);
        for kind in KINDS {
            schema.push(
                "rename and move",
                vec![
                    change(kind, Change::Rename { path: "/a/name".into(), to: "title".into() }),
                    change(kind, Change::Move { from: "/a/x".into(), path: "/b/y".into() }),
                ],
            );
            schema.push(
                "add and remove",
                vec![
                    change(kind, Change::Add { path: "/c".into(), default: json!({"n": 1}) }),
                    change(kind, Change::Remove { path: "/d".into(), default: json!([1, 2]) }),
                ],
            );
            schema.push(
                "retype",
                vec![
                    change(
                        kind,
                        Change::Retype {
                            path: "/e".into(),
                            up: Conversion::NumberToString,
                            down: Conversion::StringToNumber,
                        },
                    ),
                    change(
                        kind,
                        Change::Retype {
                            path: "/f".into(),
                            up: Conversion::Wrap,
                            down: Conversion::Unwrap,
                        },
                    ),
                    change(
                        kind,
                        Change::Retype {
                            path: "/list/*/g".into(),
                            up: Conversion::Nest { key: "v".into() },
                            down: Conversion::Unnest { key: "v".into() },
                        },
                    ),
                    change(
                        kind,
                        Change::Retype {
                            path: "/h".into(),
                            up: Conversion::BoolToNumber,
                            down: Conversion::NumberToBool,
                        },
                    ),
                ],
            );
            schema.push(
                "values and fills",
                vec![
                    change(
                        kind,
                        Change::RenameValue {
                            path: "/state".into(),
                            from: json!("old"),
                            to: json!("new"),
                        },
                    ),
                    change(
                        kind,
                        Change::Fill {
                            path: "/i".into(),
                            default: json!(false),
                            direction: Direction::Both,
                        },
                    ),
                    change(
                        kind,
                        Change::Move { from: "/list/*/x".into(), path: "/list/*/z/x".into() },
                    ),
                ],
            );
        }
        Compat::new(schema)
            .unwrap_or_else(|error| panic!("fixed fuzz schema is invalid: {error:?}"))
    })
}

fn rewrite(compat: &Compat, kind: &str, from: u32, to: u32, message: &[u8]) {
    let _ = compat.translate(kind, from, to, message);
    if let Ok(program) = compat.program(kind, from, to) {
        let mut out = Vec::new();
        let _ = program.rewrite_into(message, &mut out);
        if let Ok(mut value) = serde_json::from_slice(message) {
            program.apply_reference(&mut value);
        }
    }
}

fuzz_target!(|data: &[u8]| {
    let Some((&mode, rest)) = data.split_first() else { return };
    if mode < 128 {
        // The next byte picks the two revisions (low and high nibble).
        let Some((&revisions, message)) = rest.split_first() else { return };
        let compat = fixed();
        let base = compat.schema().base;
        let span = compat.current() - base + 1;
        let from = base + u32::from(revisions & 0x0f) % span;
        let to = base + u32::from(revisions >> 4) % span;
        let kind = KINDS[usize::from(mode) % KINDS.len()];
        rewrite(compat, kind, from, to, message);
        return;
    }
    let (schema, message) = match rest.iter().position(|byte| *byte == 0) {
        Some(split) => (&rest[..split], &rest[split + 1..]),
        None => (rest, &[][..]),
    };
    let Ok(schema) = Schema::from_json(schema) else { return };
    let Ok(compat) = Compat::new(schema) else { return };
    let base = compat.schema().base;
    let current = compat.current();
    let kinds: Vec<String> = compat
        .schema()
        .revisions
        .iter()
        .flat_map(|revision| revision.changes.iter().map(|change| change.message.clone()))
        .take(4)
        .collect();
    for kind in &kinds {
        rewrite(&compat, kind, base, current, message);
        rewrite(&compat, kind, current, base, message);
    }
});
