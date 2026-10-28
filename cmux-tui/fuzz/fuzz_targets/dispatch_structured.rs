//! The daemon's request dispatch up to the handler, driven by REQUEST frames
//! whose header comes from the schema's method table and whose body comes
//! from the method's request shape (p05-ipc-182;
//! `cmux_tui_core::fuzz_entry::dispatch_request`, server/fuzz_dispatch.rs).
//! MojoLPM drives Mojo interfaces the same way: structured messages built
//! from the interface definition, with the fuzzer choosing the method and
//! the values (chromium mojo/public/tools/fuzzers/mojolpm.h).
//!
//! It checks that:
//! - a frame built exactly from the table, with a body within the method's
//!   `max_bytes`, is never refused: the daemon accepts what its own schema
//!   says a client may send;
//! - a framed `Command` is the command the body's line decodes to: the
//!   header, the head and the typed parse never name different commands;
//! - the line's head reads `cmd`, `operation` and `protocol` as a full
//!   `serde_json::Value` parse of the same line does;
//! - the v2 envelope a line decodes to names the head's operation.
//!
//! Input:
//! - bytes 0..2: the method, a little-endian index into the table's methods
//!   (modulo their count, so every method is one seed away);
//! - byte 2: below 160 the request is well formed; above, it picks one
//!   mutation (see `Mutation`);
//! - the rest: `arbitrary` bytes for the request id and the body's values.
//!
//! With CMUX_IPC_FUZZ_COVERAGE=1 every input prints the method id it framed
//! and whether its frame was routed and its body decoded (or claimed by a
//! feature route, which decodes it itself), and the first
//! input prints the table: scripts/cmux-next/ipc-fuzz-fleet.sh counts the
//! method-id coverage of a corpus from these lines.

#![no_main]

use std::sync::LazyLock;

use arbitrary::Unstructured;
use cmux_ipc::request_shapes::RequestShapes;
use cmux_ipc::{CallAux, CallFlags, MethodAttrs, MethodTables, PriorityHint};
use cmux_tui_core::fuzz_entry::{Dispatched, Framed, Line, dispatch_request};
use libfuzzer_sys::fuzz_target;
use serde_json::{Map, Value, json};

#[path = "support/schema_json.rs"]
mod schema_json;

use schema_json::Generator;

/// Every method of the table, v12 then v2, in id order.
static METHODS: LazyLock<Vec<&'static MethodAttrs>> = LazyLock::new(|| {
    let tables = MethodTables::schema();
    let methods: Vec<_> =
        tables.v12_families().chain(tables.v2_families()).flat_map(|f| f.iter()).collect();
    if *COVERAGE {
        eprintln!("cmux-ipc-fuzz table={}", methods.len());
        for method in &methods {
            eprintln!("cmux-ipc-fuzz table-method=0x{:04x} name={}", method.id.raw(), method.name);
        }
    }
    methods
});

static COVERAGE: LazyLock<bool> =
    LazyLock::new(|| std::env::var_os("CMUX_IPC_FUZZ_COVERAGE").is_some_and(|value| value == "1"));

/// How a request strays from what the schema allows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mutation {
    None,
    /// A priority hint other than the table's.
    Priority,
    /// Any known flags.
    Flags,
    /// Any method id in the header.
    MethodId,
    /// The body names another method.
    OtherName,
    /// The body names its method and, first, another one.
    DuplicateName,
    /// One value in four ignores its shape.
    Stray,
    /// A member of the request is left out.
    DropMember,
    /// A member the schema does not have.
    ExtraMember,
    /// The rest of the input, as is.
    RawBody,
    /// The body cut short.
    Truncate,
    /// Any JSON value instead of an object.
    NotObject,
    /// A v12 body with a `protocol` member, or a v2 body without one.
    Protocol,
}

const MUTATIONS: [Mutation; 12] = [
    Mutation::Priority,
    Mutation::Flags,
    Mutation::MethodId,
    Mutation::OtherName,
    Mutation::DuplicateName,
    Mutation::Stray,
    Mutation::DropMember,
    Mutation::ExtraMember,
    Mutation::RawBody,
    Mutation::Truncate,
    Mutation::NotObject,
    Mutation::Protocol,
];

/// The body's members, as a v12 line or a v2 envelope.
fn body(
    generator: &mut Generator<'_, '_>,
    method: &MethodAttrs,
    mutation: Mutation,
) -> arbitrary::Result<Map<String, Value>> {
    let shapes = RequestShapes::schema();
    let name_key;
    let mut members = Map::new();
    match shapes.request(method.id) {
        Some(request) => {
            let id = generator.u.int_in_range(0..=9_999u32)?;
            if let Value::Object(params) = generator.value(request.params, 0)? {
                members.extend(params);
            }
            // An open request may draw any extra member: it must not
            // rename the line or make it a v2 envelope.
            members.remove("protocol");
            members.insert("id".into(), json!(id));
            members.insert("cmd".into(), json!(method.name));
            name_key = "cmd";
        }
        None => {
            members.insert("protocol".into(), json!("cmux.protocol/2"));
            members.insert("type".into(), json!("request"));
            members.insert("id".into(), json!(format!("r{}", generator.u.arbitrary::<u16>()?)));
            members.insert("operation".into(), json!(method.name));
            members.insert("params".into(), generator.any(1)?);
            name_key = "operation";
        }
    }
    match mutation {
        Mutation::OtherName => {
            let other = generator.u.choose(&METHODS)?;
            members.insert(name_key.into(), json!(other.name));
        }
        Mutation::DropMember if !members.is_empty() => {
            let at = generator.u.choose_index(members.len())?;
            if let Some(key) = members.keys().nth(at).cloned() {
                members.remove(&key);
            }
        }
        Mutation::ExtraMember => {
            let key = generator.text(None)?;
            let value = generator.any(1)?;
            members.insert(key, value);
        }
        Mutation::Protocol => {
            if members.remove("protocol").is_none() {
                members.insert("protocol".into(), generator.any(1)?);
            }
        }
        _ => {}
    }
    Ok(members)
}

/// The request's frame header fields and body bytes.
fn request(
    u: &mut Unstructured<'_>,
    method: &'static MethodAttrs,
    mutation: Mutation,
) -> arbitrary::Result<(CallAux, Vec<u8>)> {
    let shapes = RequestShapes::schema();
    let stray = if mutation == Mutation::Stray { 64 } else { 0 };
    let mut generator = Generator { u, shapes, stray };
    let mut call = CallAux {
        request_id: generator.u.arbitrary()?,
        method_id: method.id.raw(),
        priority: method.priority,
        flags: CallFlags::empty(),
    };
    let mut bytes = match mutation {
        Mutation::RawBody => {
            let len = generator.u.len();
            generator.u.bytes(len)?.to_vec()
        }
        Mutation::NotObject => generator.any(0)?.to_string().into_bytes(),
        _ => Value::Object(body(&mut generator, method, mutation)?).to_string().into_bytes(),
    };
    match mutation {
        Mutation::Priority => {
            let others: Vec<_> =
                PriorityHint::ALL.into_iter().filter(|hint| *hint != method.priority).collect();
            call.priority = *generator.u.choose(&others)?;
        }
        Mutation::Flags => {
            let bits = generator.u.arbitrary::<u8>()? & CallFlags::KNOWN.bits();
            call.flags = CallFlags::from_wire(bits).unwrap_or_default();
        }
        Mutation::MethodId => call.method_id = generator.u.arbitrary()?,
        Mutation::DuplicateName => {
            let other = generator.u.choose(&METHODS)?;
            let key = if RequestShapes::schema().request(method.id).is_some() {
                "cmd"
            } else {
                "operation"
            };
            let first = format!("{{{}:{},", json!(key), json!(other.name));
            if bytes.first() == Some(&b'{') && bytes.len() > 2 {
                bytes.splice(..1, first.into_bytes());
            }
        }
        Mutation::Truncate => {
            let keep = generator.u.choose_index(bytes.len().max(1))?;
            bytes.truncate(keep);
        }
        _ => {}
    }
    Ok((call, bytes))
}

/// The head must read what a full parse of the same line reads.
fn check_head(dispatched: &Dispatched, body: &[u8]) {
    let Ok(value) = serde_json::from_slice::<Value>(body) else {
        return;
    };
    let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    let head = &dispatched.head;
    assert_eq!(head.cmd, text("cmd"), "the head's cmd is not the line's");
    assert_eq!(head.operation, text("operation"), "the head's operation is not the line's");
    let protocol = value.as_object().is_some_and(|object| object.contains_key("protocol"));
    assert_eq!(head.protocol, protocol, "the head's protocol is not the line's");
}

fn check(dispatched: &Dispatched, body: &[u8], method: &MethodAttrs, mutation: Mutation) {
    assert_eq!(dispatched.line.is_none(), std::str::from_utf8(body).is_err());
    check_head(dispatched, body);
    let within = method.max_bytes.is_none_or(|max| body.len() <= max as usize);
    if mutation == Mutation::None && within {
        assert!(
            dispatched.frame.is_ok(),
            "the daemon refuses a REQUEST of {} built from its own table: {:?}",
            method.name,
            dispatched.frame
        );
    }
    if let Ok(Framed::Command { method }) = dispatched.frame {
        assert_eq!(dispatched.head.command, Some(method), "a framed command's body names another");
        assert!(
            matches!(dispatched.line, Some(Line::Refused) | Some(Line::Command { method: _ })),
            "a framed command's body decodes as {:?}",
            dispatched.line
        );
    }
    match dispatched.line {
        Some(Line::Command { method }) => {
            assert_eq!(dispatched.head.command, Some(method), "the head and the parse disagree");
            if let Ok(Framed::Command { method: framed }) = dispatched.frame {
                assert_eq!(framed, method, "the header and the parse name different commands");
            }
        }
        Some(Line::Resource { operation: Some(operation), .. }) => {
            assert!(dispatched.head.protocol, "an envelope parsed from a line without protocol");
            assert_eq!(dispatched.head.operation.as_deref(), Some(operation));
        }
        _ => {}
    }
}

fuzz_target!(|data: &[u8]| {
    let [low, high, mutation, rest @ ..] = data else {
        return;
    };
    let methods = &*METHODS;
    let Some(method) =
        methods.get(usize::from(u16::from_le_bytes([*low, *high])) % methods.len().max(1))
    else {
        return;
    };
    let mutation = match mutation.checked_sub(160) {
        None => Mutation::None,
        Some(pick) => MUTATIONS[usize::from(pick) % MUTATIONS.len()],
    };
    let mut u = Unstructured::new(rest);
    let Ok((call, body)) = request(&mut u, method, mutation) else {
        return;
    };
    let dispatched = dispatch_request(call, &body);
    if *COVERAGE {
        // A feature route decodes its own line; the target does not run it.
        let decoded = dispatched.feature_route
            || matches!(
                dispatched.line,
                Some(Line::Command { .. }) | Some(Line::Resource { accepted: true, .. })
            );
        eprintln!(
            "cmux-ipc-fuzz method=0x{:04x} routed={} decoded={}",
            call.method_id,
            u8::from(dispatched.frame.is_ok()),
            u8::from(decoded)
        );
    }
    check(&dispatched, &body, method, mutation);
});
