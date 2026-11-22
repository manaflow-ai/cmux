//! Wire conformance vectors shared by the Rust, TS and Go lanes
//! (`spec/pane-protocol-vectors.json`). Expected outcomes are written by
//! hand here; bytes, hex and tokens are computed by this crate's encoders.
//! Every lane runs the committed file.
//!
//! Layout:
//! - `vectors`: the flat list every lane's harness reads. Each entry has a
//!   `kind`: `envelope` (`text`, `valid`), `data_frame` (`hex`, `valid`,
//!   `stream`, `credit`, `payload_hex`) or `validation` (`type`, `value`,
//!   `valid`, checked with the IR schema).
//! - `transport_envelopes`: frames an adapter consumes before the session
//!   (`auth`, MessagePort `bye`).
//! - `unix_framing`: 4-byte length-prefixed byte-stream framing.
//! - `token`: the compact JWS format with a fixed test key.
//! - `session`: scripted exchanges against the `com.example.hello` provider.
//! - `fragments`: IR fragments merged into the committed IR.
//! - `ir_keywords`: the JSON Schema subset generators support.
//!
//! `decision` tags a vector with the wire decision it covers
//! (`/tmp/pane-protocol/ir-changes.md`, numbered 1-16).

use serde_json::{Value, json};

use crate::frame::{self, DataFrame, Message};
use crate::token::{Claims, SigningKey};

/// The fixed test seed (never a real key): bytes 0x00..=0x1f.
pub const TEST_SEED: [u8; 32] = {
    let mut seed = [0u8; 32];
    let mut index = 0;
    while index < 32 {
        seed[index] = index as u8;
        index += 1;
    }
    seed
};

/// Verification time used by the token checks.
pub const TEST_NOW: u64 = 1_700_000_000;
/// Expiry of the test tokens (2100-01-01).
pub const TEST_EXP: u64 = 4_102_444_800;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn envelope(name: &str, text: &str, valid: bool, decision: Option<u32>) -> Value {
    let mut case = json!({ "kind": "envelope", "name": name, "text": text, "valid": valid });
    if valid {
        let encoded = crate::envelope::Envelope::decode(text)
            .map(|envelope| envelope.encode())
            .unwrap_or_default();
        case["encoded"] = json!(encoded);
    }
    if let Some(decision) = decision {
        case["decision"] = json!(decision);
    }
    case
}

fn envelope_cases() -> Vec<Value> {
    let valid: &[(&str, &str, Option<u32>)] = &[
        ("call", r#"{"t":"call","id":1,"op":"cmux.git.status","params":{"cwd":"/repo"}}"#, None),
        ("call without params", r#"{"t":"call","id":2,"op":"cmux.git.status"}"#, None),
        (
            "call with cap",
            r#"{"t":"call","id":3,"op":"cmux.git.diff","params":{"cwd":"/r"},"cap":"h1"}"#,
            None,
        ),
        (
            "call with non-object params (the session rejects them)",
            r#"{"t":"call","id":4,"op":"cmux.git.status","params":[]}"#,
            None,
        ),
        ("ok", r#"{"t":"ok","id":1,"value":{"branch":"main","files":[]}}"#, None),
        ("ok without value", r#"{"t":"ok","id":1}"#, None),
        ("auth ack is ok id 0", r#"{"t":"ok","id":0}"#, Some(5)),
        (
            "auth refusal is err id 0",
            r#"{"t":"err","id":0,"code":"cmux.protocol.auth_refused","message":"bad token","retryable":false}"#,
            Some(5),
        ),
        (
            "err",
            r#"{"t":"err","id":1,"code":"cmux.git.not_a_repo","message":"no repo","retryable":false}"#,
            None,
        ),
        (
            "err with details",
            r#"{"t":"err","id":1,"code":"cmux.protocol.internal","message":"x","retryable":true,"details":{"k":1}}"#,
            None,
        ),
        (
            "session code forbidden",
            r#"{"t":"err","id":2,"code":"cmux.protocol.forbidden","message":"no scope","retryable":false}"#,
            Some(13),
        ),
        (
            "session code busy",
            r#"{"t":"err","id":2,"code":"cmux.protocol.busy","message":"overloaded","retryable":true}"#,
            Some(13),
        ),
        (
            "sub",
            r#"{"t":"sub","id":4,"stream":"cmux.git.status.changed","filter":{"cwd":"/r"}}"#,
            None,
        ),
        (
            "ev seq starts at 1",
            r#"{"t":"ev","sub":1,"seq":1,"data":{"branch":null,"files":[]}}"#,
            Some(4),
        ),
        (
            "ev after a drop carries gap",
            r#"{"t":"ev","sub":1,"seq":7,"data":{"branch":null,"files":[]},"gap":true}"#,
            Some(15),
        ),
        ("unsub", r#"{"t":"unsub","sub":1}"#, None),
        ("cancel", r#"{"t":"cancel","id":1}"#, None),
        ("release", r#"{"t":"release","handle":"h1"}"#, None),
        (
            "open carries id and params",
            r#"{"t":"open","id":5,"stream":1,"op":"cmux.fs.file.read","params":{"path":"/a"}}"#,
            Some(1),
        ),
        ("credit", r#"{"t":"credit","stream":1,"bytes":65536}"#, None),
        ("end", r#"{"t":"end","stream":1}"#, Some(2)),
        (
            "end as abort",
            r#"{"t":"end","stream":1,"code":"cmux.protocol.stream_aborted","message":"gone"}"#,
            Some(2),
        ),
        ("unknown field is ignored", r#"{"t":"cancel","id":1,"future":true}"#, None),
        ("max id 2^53-1", r#"{"t":"cancel","id":9007199254740991}"#, Some(12)),
        ("max stream id 2^32-1", r#"{"t":"credit","stream":4294967295,"bytes":1}"#, Some(12)),
    ];
    let invalid: &[(&str, &str, Option<u32>)] = &[
        ("not json", "{", None),
        ("not an object", "[1]", None),
        ("unknown kind", r#"{"t":"bogus","id":1}"#, None),
        ("missing t", r#"{"id":1}"#, None),
        ("call id 0", r#"{"t":"call","id":0,"op":"cmux.git.status"}"#, Some(12)),
        ("id above 2^53-1", r#"{"t":"cancel","id":9007199254740992}"#, Some(12)),
        ("negative id", r#"{"t":"cancel","id":-1}"#, Some(12)),
        ("fractional id", r#"{"t":"cancel","id":1.5}"#, Some(12)),
        ("ev seq 0", r#"{"t":"ev","sub":1,"seq":0,"data":null}"#, Some(12)),
        ("open stream 0", r#"{"t":"open","id":1,"stream":0,"op":"cmux.fs.file.read"}"#, Some(12)),
        ("open without id", r#"{"t":"open","stream":1,"op":"cmux.fs.file.read"}"#, Some(1)),
        ("end without stream", r#"{"t":"end"}"#, Some(2)),
        (
            "gap that is not a boolean",
            r#"{"t":"ev","sub":1,"seq":1,"data":null,"gap":"yes"}"#,
            Some(15),
        ),
        ("err without retryable", r#"{"t":"err","id":1,"code":"c.d.e","message":"x"}"#, None),
        ("err without code", r#"{"t":"err","id":1,"message":"x","retryable":false}"#, None),
        (
            "details not an object",
            r#"{"t":"err","id":1,"code":"c","message":"x","retryable":false,"details":[1]}"#,
            None,
        ),
        ("filter not an object", r#"{"t":"sub","id":1,"stream":"a.b.c","filter":1}"#, None),
        ("stream id 2^32 (above u32)", r#"{"t":"credit","stream":4294967296,"bytes":1}"#, Some(12)),
        (
            "open stream id 2^32",
            r#"{"t":"open","id":1,"stream":4294967296,"op":"cmux.fs.file.read"}"#,
            Some(12),
        ),
    ];
    let mut cases: Vec<Value> =
        valid.iter().map(|(name, text, decision)| envelope(name, text, true, *decision)).collect();
    cases.extend(
        invalid.iter().map(|(name, text, decision)| envelope(name, text, false, *decision)),
    );
    cases
}

fn data_frame_cases() -> Vec<Value> {
    let data = DataFrame { stream: 5, credit: 4096, payload: bytes::Bytes::from_static(b"hello") };
    let empty = DataFrame { stream: 2, credit: 0, payload: bytes::Bytes::new() };
    vec![
        json!({ "kind": "data_frame", "name": "data frame", "valid": true, "stream": 5, "credit": 4096, "payload_hex": hex(b"hello"), "hex": hex(&data.encode()) }),
        json!({ "kind": "data_frame", "name": "empty payload", "valid": true, "stream": 2, "credit": 0, "payload_hex": "", "hex": hex(&empty.encode()) }),
        json!({ "kind": "data_frame", "name": "shorter than the 8-byte header", "valid": false, "hex": "00000005000010" }),
    ]
}

fn unix_framing_cases() -> Value {
    let text = r#"{"t":"cancel","id":1}"#;
    let text_bytes = frame::encode(&Message::Text(text.into())).unwrap_or_default();
    let data = DataFrame { stream: 5, credit: 4096, payload: bytes::Bytes::from_static(b"hello") };
    let data_bytes = frame::encode(&Message::Binary(data.encode())).unwrap_or_default();
    let empty = frame::encode(&Message::Text(String::new())).unwrap_or_default();
    json!([
        { "name": "text message", "valid": true, "kind": "text", "text": text, "hex": hex(&text_bytes) },
        { "name": "empty text message", "valid": true, "kind": "text", "text": "", "hex": hex(&empty) },
        {
            "name": "binary message (bit 31 set) carrying a data frame", "valid": true, "kind": "binary",
            "data_frame": { "stream": 5, "credit": 4096, "payload_hex": hex(b"hello") },
            "hex": hex(&data_bytes)
        },
        { "name": "largest allowed length header", "valid": true, "header_only": true, "hex": "01000000" },
        { "name": "length above 16 MiB", "valid": false, "header_only": true, "hex": "01000001" },
        { "name": "binary flag with length above 16 MiB", "valid": false, "header_only": true, "hex": "81000001" },
        { "name": "text that is not UTF-8", "valid": false, "kind": "text", "hex": "00000002c328" }
    ])
}

fn test_claims() -> Claims {
    Claims {
        sub: "surface-1".into(),
        page: None,
        app: "cmux.agent".into(),
        ns: vec!["cmux.git".into()],
        scopes: vec!["git:read".into()],
        roots: vec!["/home/user/repo".into()],
        origin: Some("http://127.0.0.1:4100".into()),
        aud: "cmux.git".into(),
        exp: TEST_EXP,
        iat: TEST_NOW,
    }
}

/// A data-plane token for the example provider, used by the session vectors.
pub fn example_token() -> anyhow::Result<String> {
    let claims = Claims {
        sub: "session-vectors".into(),
        page: None,
        app: "cmux.agent".into(),
        ns: vec![crate::example::APP_ID.into()],
        scopes: vec![crate::example::SCOPE.into()],
        roots: Vec::new(),
        origin: None,
        aud: crate::example::APP_ID.into(),
        exp: TEST_EXP,
        iat: TEST_NOW,
    };
    Ok(SigningKey::from_seed(&TEST_SEED)?.sign(&claims))
}

fn token_case() -> anyhow::Result<Value> {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let key = SigningKey::from_seed(&TEST_SEED)?;
    let claims = test_claims();
    let token = key.sign(&claims);
    let other = SigningKey::from_seed(&[0xff; 32])?.sign(&claims);
    let native = key.sign(&Claims { origin: None, ..claims.clone() });
    let page_origin = "cmux-page://cmux.settings";
    let page = key.sign(&Claims {
        page: Some("cmux.settings".into()),
        ns: Vec::new(),
        scopes: vec!["settings:read".into()],
        origin: Some(page_origin.into()),
        aud: crate::token::ROUTER_AUDIENCE.into(),
        ..claims.clone()
    });
    let rest = token.split_once('.').map(|(_, rest)| rest).unwrap_or_default();
    let none_header =
        format!("{}.{rest}", URL_SAFE_NO_PAD.encode(br#"{"alg":"none","typ":"cmux-cap+jwt"}"#));
    let origin = "http://127.0.0.1:4100";
    let check = |name: &str,
                 token: &str,
                 aud: &str,
                 origin: Option<&str>,
                 now: u64,
                 result: &str,
                 decision: Option<u32>| {
        let mut case = json!({ "name": name, "token": token, "aud": aud, "origin": origin, "now": now, "result": result });
        if let Some(decision) = decision {
            case["decision"] = json!(decision);
        }
        case
    };
    Ok(json!({
        "decision": 10,
        "format": "compact JWS: base64url(header).base64url(claims).base64url(ed25519 over 'header.claims'), no padding",
        "header": { "alg": crate::token::TOKEN_ALG, "typ": crate::token::TOKEN_TYPE },
        "origin_rule": "a connection with an Origin requires claims.origin to equal it exactly; a connection without one (native peer) skips the origin check",
        "seed_hex": hex(&TEST_SEED),
        "public_key_hex": hex(&key.public_key()),
        "claims": claims,
        "token": token,
        "checks": [
            check("valid", &token, "cmux.git", Some(origin), TEST_NOW, "ok", None),
            check("expired", &token, "cmux.git", Some(origin), TEST_EXP, "expired", None),
            check("other audience", &token, "com.example.hello", Some(origin), TEST_NOW, "wrong_audience", None),
            check("other origin", &token, "cmux.git", Some("http://evil.test"), TEST_NOW, "wrong_origin", None),
            check("browser token on a native connection", &token, "cmux.git", None, TEST_NOW, "ok", None),
            check("native token", &native, "cmux.git", None, TEST_NOW, "ok", None),
            check("native token from a browser", &native, "cmux.git", Some(origin), TEST_NOW, "wrong_origin", None),
            check("signed by another key", &other, "cmux.git", Some(origin), TEST_NOW, "bad_signature", Some(10)),
            check("tampered claims", &tamper(&token), "cmux.git", Some(origin), TEST_NOW, "bad_signature", Some(10)),
            check("alg none", &none_header, "cmux.git", Some(origin), TEST_NOW, "wrong_header", Some(10)),
            check("two segments", "e30.e30", "cmux.git", Some(origin), TEST_NOW, "malformed", Some(10)),
            check("page token, bundled page origin", &page, "router", Some(page_origin), TEST_NOW, "ok", Some(16)),
            check("page token, another page's origin", &page, "router", Some("cmux-page://com.evil.page"), TEST_NOW, "wrong_origin", Some(16)),
            check("page token, dev origin", &page, "router", Some(origin), TEST_NOW, "wrong_origin", Some(16))
        ],
        "allows": [
            { "op": "cmux.git.status", "scope": "git:read", "allowed": true },
            { "op": "cmux.git.status", "scope": "git:write", "allowed": false },
            { "op": "cmux.gitx.status", "scope": "git:read", "allowed": false },
            { "op": "com.example.hello.greet.say", "scope": "git:read", "allowed": false }
        ]
    }))
}

/// Flip one character inside the claims part, keeping it base64url.
fn tamper(token: &str) -> String {
    let mut bytes = token.as_bytes().to_vec();
    let index = token.find('.').unwrap_or_default() + 3;
    bytes[index] = if bytes[index] == b'A' { b'B' } else { b'A' };
    String::from_utf8(bytes).unwrap_or_default()
}

fn validation_cases() -> Vec<Value> {
    let case = |name: &str, ty: &str, value: Value, valid: bool| json!({ "kind": "validation", "name": name, "type": ty, "value": value, "valid": valid });
    let hello = json!({
        "proto": "cmux.pane/0", "app": "com.example.hello", "namespaces": ["com.example.hello"],
        "ops": [{ "name": "com.example.hello.greet.say", "kind": "read", "scope": "hello:read" }],
        "events": [], "interfaces": [], "ir": { "version": "0.1.0", "sha256": "00" },
        "endpoints": [{ "kind": "ws", "url": "ws://127.0.0.1:4100/" }]
    });
    let mut hello_op_strings = hello.clone();
    hello_op_strings["ops"] = json!(["com.example.hello.greet.say"]);
    let mut hello_digest_string = hello.clone();
    hello_digest_string["ir"] = json!("sha256:00");
    let mut cases = vec![
        case("status params", "GitStatusParams", json!({ "cwd": "/repo" }), true),
        case("status params without cwd", "GitStatusParams", json!({}), false),
        case(
            "status params with extra field",
            "GitStatusParams",
            json!({ "cwd": "/r", "x": 1 }),
            false,
        ),
        case("status params with numeric cwd", "GitStatusParams", json!({ "cwd": 5 }), false),
        case("diff params minimal", "GitDiffParams", json!({ "cwd": "/r" }), true),
        case(
            "diff params full",
            "GitDiffParams",
            json!({ "cwd": "/r", "base": null, "include_patch": true }),
            true,
        ),
        case(
            "diff params with string bool",
            "GitDiffParams",
            json!({ "cwd": "/r", "include_patch": "yes" }),
            false,
        ),
        case("status detached", "GitStatus", json!({ "branch": null, "files": [] }), true),
        case(
            "status with a file",
            "GitStatus",
            json!({ "branch": "main", "files": [{ "path": "a", "index": "M", "worktree": " " }] }),
            true,
        ),
        case("status without branch", "GitStatus", json!({ "files": [] }), false),
        case(
            "status file missing worktree",
            "GitStatus",
            json!({ "branch": "m", "files": [{ "path": "a", "index": "M" }] }),
            false,
        ),
        case(
            "diff file",
            "GitDiff",
            json!({ "files": [{ "path": "a", "additions": 1, "deletions": 0 }] }),
            true,
        ),
        case(
            "diff file with patch",
            "GitDiff",
            json!({ "files": [{ "path": "a", "additions": 1, "deletions": 0, "patch": "+x\n" }] }),
            true,
        ),
        case(
            "diff file with negative count",
            "GitDiff",
            json!({ "files": [{ "path": "a", "additions": -1, "deletions": 0 }] }),
            false,
        ),
        case(
            "diff file with fractional count",
            "GitDiff",
            json!({ "files": [{ "path": "a", "additions": 1.5, "deletions": 0 }] }),
            false,
        ),
        case("hello params", "HelloParams", json!({ "name": "x" }), true),
        case("hello params with extra field", "HelloParams", json!({ "name": "x", "n": 1 }), false),
        case("hello result", "HelloResult", json!({ "message": "hi" }), true),
    ];
    let mut tagged = |name: &str, ty: &str, value: Value, valid: bool, decision: u32| {
        let mut entry = case(name, ty, value, valid);
        entry["decision"] = json!(decision);
        cases.push(entry);
    };
    tagged("provider hello", "ProviderHello", hello, true, 11);
    tagged("provider hello with ops as strings", "ProviderHello", hello_op_strings, false, 11);
    tagged("provider hello with ir as a string", "ProviderHello", hello_digest_string, false, 11);
    tagged(
        "welcome",
        "ProviderWelcome",
        json!({ "router_key": "AAAA", "provider": "com.example.hello" }),
        true,
        11,
    );
    tagged(
        "welcome with extra field",
        "ProviderWelcome",
        json!({ "router_key": "AAAA", "provider": "p", "x": 1 }),
        false,
        11,
    );
    tagged(
        "resolve result names the provider's IR digest",
        "ResolveResult",
        json!({ "app_id": "a.b", "namespace": "a.b", "endpoint": { "kind": "ws", "url": "ws://127.0.0.1:1/" }, "ir": "00", "token": null, "exp": null }),
        true,
        14,
    );
    tagged(
        "resolve result without ir",
        "ResolveResult",
        json!({ "app_id": "a.b", "namespace": "a.b", "endpoint": { "kind": "ws", "url": "ws://127.0.0.1:1/" }, "token": null, "exp": null }),
        false,
        14,
    );
    tagged(
        "page manifest",
        "PageManifest",
        json!({
            "id": "cmux.settings", "route": "/settings", "entry": "pages/settings/index.html", "namespace": "cmux.settings",
            "provider": { "kind": "daemon-module" }, "consumes": ["cmux.settings/1", "cmux.git.status"],
            "scopes": ["settings:read", "settings:write"], "engines": ["webkit", "cef", "browser"]
        }),
        true,
        16,
    );
    tagged(
        "page manifest with an unknown engine",
        "PageManifest",
        json!({
            "id": "cmux.settings", "route": "/settings", "entry": "e", "namespace": "cmux.settings",
            "provider": { "kind": "daemon-module" }, "engines": ["gecko"]
        }),
        false,
        16,
    );
    cases
}

fn session_cases() -> anyhow::Result<Value> {
    let auth = format!(r#"{{"t":"auth","token":"{}"}}"#, example_token()?);
    let ok_auth = json!({ "t": "ok", "id": 0 });
    Ok(json!([
        {
            "name": "call before auth is refused with err id 0", "decision": 5,
            "send": [r#"{"t":"call","id":1,"op":"com.example.hello.greet.say","params":{"name":"x"}}"#],
            "expect": [{ "t": "err", "id": 0, "code": "cmux.protocol.auth_refused" }]
        },
        {
            "name": "auth ack, then a call", "decision": 5,
            "send": [auth, r#"{"t":"call","id":1,"op":"com.example.hello.greet.say","params":{"name":"v"}}"#],
            "expect": [ok_auth, { "t": "ok", "id": 1, "value": { "message": "hello, v" } }]
        },
        {
            "name": "invalid params", "decision": 6,
            "send": [auth, r#"{"t":"call","id":1,"op":"com.example.hello.greet.say","params":{"name":1}}"#],
            "expect": [ok_auth, { "t": "err", "id": 1, "code": "cmux.protocol.invalid_params" }]
        },
        {
            "name": "an op not in the IR", "decision": 7,
            "send": [auth, r#"{"t":"call","id":1,"op":"com.example.hello.greet.shout","params":{}}"#],
            "expect": [ok_auth, { "t": "err", "id": 1, "code": "cmux.protocol.unknown_op" }]
        },
        {
            "name": "an event stream not in the IR", "decision": 7,
            "send": [auth, r#"{"t":"sub","id":1,"stream":"com.example.hello.greet.nope"}"#],
            "expect": [ok_auth, { "t": "err", "id": 1, "code": "cmux.protocol.unknown_stream" }]
        },
        {
            "name": "seq starts at 1", "decision": 4,
            "send": [auth, r#"{"t":"sub","id":1,"stream":"com.example.hello.greet.ticks"}"#],
            "expect": [
                ok_auth, { "t": "ok", "id": 1 },
                { "t": "ev", "seq": 1, "data": { "message": "tick 1" } },
                { "t": "ev", "seq": 2, "data": { "message": "tick 2" } },
                { "t": "ev", "seq": 3, "data": { "message": "tick 3" } }
            ]
        },
        {
            "name": "the connecting side may not open an even stream id", "decision": 3,
            "send": [auth, r#"{"t":"open","id":1,"stream":2,"op":"com.example.hello.greet.say"}"#],
            "expect": [ok_auth, { "t": "err", "id": 1, "code": "cmux.protocol.stream_aborted" }]
        },
        {
            "name": "open of an op that is not a stream op", "decision": 1,
            "send": [auth, r#"{"t":"open","id":1,"stream":1,"op":"com.example.hello.greet.say"}"#],
            "expect": [ok_auth, { "t": "err", "id": 1, "code": "cmux.protocol.unknown_op" }]
        },
        {
            "name": "an id above 2^53-1 is a bad message", "decision": 12,
            "send": [auth, r#"{"t":"call","id":9007199254740992,"op":"com.example.hello.greet.say","params":{"name":"x"}}"#],
            "expect": [ok_auth, { "t": "err", "id": 0, "code": "cmux.protocol.bad_message" }]
        }
    ]))
}

fn fragment_cases() -> Value {
    let fragment = json!({
        "namespaces": [{ "name": "octo.diff_tools", "owner": "app:octo.diff_tools" }],
        "ops": [{
            "name": "octo.diff_tools.diff.list", "kind": "read", "scope": "diff:read", "risk": "read", "gesture": false,
            "owner": "app:octo.diff_tools",
            "params": { "$ref": "#/types/OctoListParams" }, "result": { "type": "array", "items": { "type": "string" } },
            "errors": []
        }],
        "types": { "OctoListParams": { "type": "object", "properties": {}, "additionalProperties": false } }
    });
    let mut keyword = fragment.clone();
    keyword["types"]["OctoListParams"]["patternProperties"] = json!({});
    let mut squatter = fragment.clone();
    squatter["ops"][0]["name"] = json!("cmux.git.steal");
    let mut third_party_alias = fragment.clone();
    third_party_alias["ops"][0]["aliases"] = json!(["difftools.list"]);
    let first_party = |alias: &str| {
        json!({ "ops": [{
            "name": "cmux.workspace.list", "kind": "read", "scope": "workspace:read", "risk": "read", "gesture": false,
            "owner": "first-party", "aliases": [alias],
            "params": { "type": "object" }, "result": { "type": "object" }, "errors": []
        }] })
    };
    let with_pattern = |pattern: &str| {
        let mut case = fragment.clone();
        case["types"]["OctoListParams"]["properties"]["id"] =
            json!({ "type": "string", "pattern": pattern });
        case
    };
    let mut two_all_of = fragment.clone();
    two_all_of["ops"][0]["result"] = json!({ "allOf": [{ "type": "array" }, { "maxItems": 3 }] });
    // Decision 21: mcp, cli and secret_output.
    let op21 = |name: &str, mcp: Option<Value>, cli: Option<Value>, result: Value| {
        let mut op = json!({
            "name": name, "kind": "read", "scope": "diff:read", "risk": "read", "gesture": false, "owner": "app:octo.diff_tools",
            "params": { "$ref": "#/types/OctoGetParams" }, "result": result, "errors": []
        });
        if let Some(mcp) = mcp {
            op["mcp"] = mcp;
        }
        if let Some(cli) = cli {
            op["cli"] = cli;
        }
        op
    };
    let fragment21 = |ops: Vec<Value>| {
        json!({
            "namespaces": [{ "name": "octo.diff_tools", "owner": "app:octo.diff_tools" }],
            "ops": ops,
            "types": {
                "OctoGetParams": {
                    "type": "object", "properties": { "id": { "type": "string" }, "count": { "type": "integer" } },
                    "required": ["id"], "additionalProperties": false
                },
                "OctoCredential": {
                    "type": "object", "properties": { "token": { "type": "string", "x-cmux-secret": true } },
                    "required": ["token"], "additionalProperties": false
                }
            }
        })
    };
    let plain = || json!({ "type": "string" });
    let full = op21(
        "octo.diff_tools.diff.get",
        Some(json!({ "expose": "opt_in", "group": "diff" })),
        Some(json!({ "path": "diff get", "visible": true, "positional": ["id"] })),
        plain(),
    );
    let bad_expose =
        op21("octo.diff_tools.diff.get", Some(json!({ "expose": "always" })), None, plain());
    let bad_path = op21(
        "octo.diff_tools.diff.get",
        None,
        Some(json!({ "path": "Diff_Get", "visible": true })),
        plain(),
    );
    let exposed = || Some(json!({ "expose": "default" }));
    // Both map to the tool name octo_diff_tools_diff_x_get (G7).
    let twin_a = op21("octo.diff_tools.diff-x.get", exposed(), None, plain());
    let twin_b = op21("octo.diff_tools.diff.x-get", exposed(), None, plain());
    let nested_secret = json!({
        "type": "object", "properties": { "credential": { "$ref": "#/types/OctoCredential" } },
        "required": ["credential"], "additionalProperties": false
    });
    let secret = op21("octo.diff_tools.auth.get", exposed(), None, nested_secret);
    let with_paths = |paths: Value| {
        let mut op = op21("octo.diff_tools.file.get", None, None, plain());
        op["paths"] = paths;
        op
    };
    let no_mcp = op21("octo.diff_tools.diff.get", None, None, plain());
    // Decision 27: risk, gesture and the derived scope class.
    let with = |name: &str, fields: Value| {
        let mut op = op21(name, None, None, plain());
        for (key, value) in fields.as_object().into_iter().flatten() {
            op[key] = value.clone();
        }
        op
    };
    let every_risk: Vec<Value> = crate::op::RISKS
        .iter()
        .map(|risk| {
            let verb = risk.replace('-', "_");
            with(
                &format!("octo.diff_tools.risk.{verb}"),
                json!({ "risk": risk, "scope": "diff:write" }),
            )
        })
        .collect();
    let bad_risk = with("octo.diff_tools.diff.get", json!({ "risk": "money" }));
    let mut no_gesture = op21("octo.diff_tools.diff.get", None, None, plain());
    no_gesture.as_object_mut().map(|op| op.remove("gesture"));
    let scoped =
        |scope: &str| fragment21(vec![with("octo.diff_tools.diff.get", json!({ "scope": scope }))]);
    let declared_class = with("octo.diff_tools.diff.get", json!({ "scope_class": "standard" }));
    json!([
        { "name": "third-party fragment", "decision": 14, "fragment": fragment, "valid": true },
        { "name": "unsupported keyword", "decision": 9, "fragment": keyword, "valid": false },
        { "name": "op in a namespace the app does not own", "decision": 14, "fragment": squatter, "valid": false },
        { "name": "third-party op with aliases", "decision": 18, "fragment": third_party_alias, "valid": false },
        { "name": "first-party alias for an old wire name", "decision": 18, "fragment": first_party("workspace.list"), "valid": true },
        { "name": "first-party alias that names an existing op", "decision": 18, "fragment": first_party("cmux.git.status"), "valid": false },
        { "name": "portable pattern", "decision": 19, "fragment": with_pattern("^[a-z0-9_]+$"), "valid": true },
        { "name": "lookahead pattern", "decision": 19, "fragment": with_pattern("^(?=a)a$"), "valid": false },
        { "name": "backreference pattern", "decision": 19, "fragment": with_pattern("^(a)\\1$"), "valid": false },
        { "name": "multi-schema allOf", "decision": 9, "fragment": two_all_of, "valid": false },
        { "name": "op with scope, mcp and cli", "decision": 21, "fragment": fragment21(vec![full]), "valid": true,
          "expect": { "op": "octo.diff_tools.diff.get", "mcp": { "expose": "opt_in", "group": "diff" }, "secret_output": false } },
        { "name": "mcp.expose outside the enum", "decision": 21, "fragment": fragment21(vec![bad_expose]), "valid": false },
        { "name": "bad cli.path", "decision": 21, "fragment": fragment21(vec![bad_path]), "valid": false },
        { "name": "two ops with the same MCP tool name", "decision": 21, "fragment": fragment21(vec![twin_a, twin_b]), "valid": false },
        { "name": "nested x-cmux-secret gives secret_output", "decision": 21, "fragment": fragment21(vec![secret]), "valid": true,
          "expect": { "op": "octo.diff_tools.auth.get", "secret_output": true } },
        { "name": "an op without mcp is never exposed", "decision": 21, "fragment": fragment21(vec![no_mcp]), "valid": true,
          "expect": { "op": "octo.diff_tools.diff.get", "mcp": { "expose": "never" }, "secret_output": false, "paths": [] } },
        { "name": "path param that is a string param", "decision": 22, "fragment": fragment21(vec![with_paths(json!(["id"]))]), "valid": true,
          "expect": { "op": "octo.diff_tools.file.get", "paths": ["id"] } },
        { "name": "path param that is not a param", "decision": 22, "fragment": fragment21(vec![with_paths(json!(["nope"]))]), "valid": false },
        { "name": "path param that is not a string", "decision": 22, "fragment": fragment21(vec![with_paths(json!(["count"]))]), "valid": false },
        { "name": "an op of each risk", "decision": 27, "fragment": fragment21(every_risk), "valid": true,
          "expect": { "op": "octo.diff_tools.risk.send_external", "risk": "send-external", "gesture": false } },
        { "name": "risk outside the enum", "decision": 27, "fragment": fragment21(vec![bad_risk]), "valid": false },
        { "name": "gesture missing", "decision": 27, "fragment": fragment21(vec![no_gesture]), "valid": false },
        { "name": "standard scope", "decision": 27, "fragment": scoped("diff:read"), "valid": true,
          "expect": { "op": "octo.diff_tools.diff.get", "scope_class": "standard" } },
        { "name": "sensitive scope", "decision": 27, "fragment": scoped("diff:write"), "valid": true,
          "expect": { "op": "octo.diff_tools.diff.get", "scope_class": "sensitive" } },
        { "name": "restricted scope", "decision": 27, "fragment": scoped("fs:write"), "valid": true,
          "expect": { "op": "octo.diff_tools.diff.get", "scope_class": "restricted" } },
        { "name": "server-only rule", "decision": 27, "fragment": scoped("process:spawn:git"), "valid": true,
          "expect": { "op": "octo.diff_tools.diff.get", "scope_class": "restricted", "server_only": true } },
        { "name": "scope that matches no rule", "decision": 27, "fragment": scoped("diff:use"), "valid": false },
        { "name": "fragment declares scope_class", "decision": 27, "fragment": fragment21(vec![declared_class]), "valid": false },
        { "name": "op name with only a verb below its namespace", "decision": 26,
          "fragment": fragment21(vec![op21("octo.diff_tools.get", None, None, plain())]), "valid": false },
        { "name": "two never-exposed ops with the same MCP tool name", "decision": 23,
          "fragment": fragment21(vec![op21("octo.diff_tools.diff-x.get", None, None, plain()), op21("octo.diff_tools.diff.x-get", None, None, plain())]),
          "valid": false }
    ])
}

/// Decision 20: path params must resolve inside the token's roots. A runner
/// builds `layout` under a fresh directory, canonicalizes it as `$BASE`,
/// substitutes it, and checks each path against each case's roots.
fn roots_cases() -> Value {
    let case = |name: &str, roots: &[&str], path: &str, allowed: bool| json!({ "name": name, "decision": 20, "roots": roots, "path": path, "allowed": allowed });
    let root = &["$BASE/root"][..];
    json!({
        "layout": {
            "dirs": ["root/sub", "rootx", "outside"],
            "symlinks": [{ "path": "root/link", "target": "../outside" }, { "path": "root/inner", "target": "sub" }]
        },
        "refusal_code": crate::error::FORBIDDEN,
        "cases": [
            case("path inside a root", root, "$BASE/root/sub", true),
            case("the root itself", root, "$BASE/root", true),
            case("symlink that stays inside", root, "$BASE/root/inner", true),
            case("dot-dot that stays inside", root, "$BASE/root/sub/..", true),
            case("path outside every root", root, "$BASE/outside", false),
            case("symlink that escapes", root, "$BASE/root/link", false),
            case("dot-dot traversal out of the root", root, "$BASE/root/sub/../../outside", false),
            case("sibling sharing the root's name as a prefix", root, "$BASE/rootx", false),
            case("relative path", root, "root/sub", false),
            case("path that does not exist", root, "$BASE/root/missing", false),
            case("missing roots claim", &[], "$BASE/root/sub", false)
        ]
    })
}

/// Decision 20 (follow-up): a first-party provider's hello must carry the
/// router's IR digest; a third party's is recorded and allowed.
fn admission_cases() -> Value {
    let case = |name: &str, app: &str, ir: &str, result: &str| json!({ "name": name, "app": app, "ir_sha256": ir, "result": result });
    json!({
        "router_ir_sha256": crate::catalog::catalog().digest(),
        "rule": "ir_sha256 \"router\" stands for router_ir_sha256",
        "cases": [
            case("first party with the router's IR", "cmux.git", "router", "ok"),
            case("first party with another IR", "cmux.git", "00", "cmux.protocol.bad_message:ir_mismatch"),
            case("third party with its own fragment digest", "octo.diff_tools", "00", "ok")
        ]
    })
}

/// The vectors document.
pub fn vectors() -> anyhow::Result<Value> {
    let mut list = envelope_cases();
    list.extend(data_frame_cases());
    list.extend(validation_cases());
    Ok(crate::ir::canonical(&json!({
        "version": crate::ir::IR_VERSION,
        "vectors": list,
        "transport_envelopes": [
            { "name": "auth", "text": r#"{"t":"auth","token":"e30.e30.e30"}"#, "valid": true },
            { "name": "bye (MessagePort only)", "decision": 8, "text": r#"{"t":"bye"}"#, "valid": true }
        ],
        "unix_framing": unix_framing_cases(),
        "token": token_case()?,
        "session": session_cases()?,
        "fragments": fragment_cases(),
        "roots": roots_cases(),
        "admission": admission_cases(),
        "ir_keywords": {
            "decision": 9,
            "supported": crate::ir::SUPPORTED_KEYWORDS,
            "annotations": crate::ir::ANNOTATION_KEYWORDS,
        },
    })))
}

/// The committed file's exact text.
pub fn vectors_text() -> anyhow::Result<String> {
    let mut text = serde_json::to_string_pretty(&vectors()?).unwrap_or_default();
    text.push('\n');
    Ok(text)
}
