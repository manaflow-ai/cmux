//! Runs the committed conformance vectors and checks the committed IR and
//! vectors for drift against the generators.

use std::sync::Arc;

use cmux_pane_protocol::catalog::{IR_PATH, VECTORS_PATH, catalog};
use cmux_pane_protocol::envelope::Envelope;
use cmux_pane_protocol::example::{self, HelloParams, HelloResult};
use cmux_pane_protocol::frame::{self, DataFrame, Message};
use cmux_pane_protocol::git::{GitDiff, GitDiffParams, GitStatus, GitStatusParams};
use cmux_pane_protocol::ir::{self, FragmentValidator, ShapeValidator};
use cmux_pane_protocol::router::ops::{
    PageManifest, ProviderHello, ProviderWelcome, ResolveResult,
};
use cmux_pane_protocol::token::{Claims, SigningKey, Verifier};
use cmux_pane_protocol::transport::memory_pair;
use cmux_pane_protocol::vectors::TEST_SEED;
use serde_json::Value;

fn read(relative: &str) -> String {
    std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(relative))
        .unwrap()
}

fn vectors() -> Value {
    serde_json::from_str(&read(VECTORS_PATH)).unwrap()
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
}

fn of_kind(kind: &str) -> Vec<Value> {
    vectors()["vectors"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|case| case["kind"] == kind)
        .cloned()
        .collect()
}

#[test]
fn committed_ir_and_vectors_match_the_generators() {
    assert_eq!(
        read(IR_PATH),
        catalog().ir_text(),
        "IR drift: run cargo run -p cmux-pane-protocol --bin emit-ir"
    );
    assert_eq!(
        read(VECTORS_PATH),
        cmux_pane_protocol::vectors::vectors_text(),
        "vector drift: run emit-ir"
    );
}

#[test]
fn every_flat_vector_has_a_known_kind() {
    for case in vectors()["vectors"].as_array().unwrap() {
        assert!(
            ["envelope", "data_frame", "validation"].contains(&case["kind"].as_str().unwrap()),
            "{case}"
        );
    }
}

#[test]
fn envelope_vectors() {
    let transport = vectors()["transport_envelopes"].as_array().unwrap().clone();
    for case in of_kind("envelope").iter().chain(&transport) {
        let name = case["name"].as_str().unwrap();
        let decoded = Envelope::decode(case["text"].as_str().unwrap());
        if case["valid"].as_bool().unwrap() {
            let envelope = decoded.unwrap_or_else(|error| panic!("{name}: {error}"));
            if let Some(encoded) = case["encoded"].as_str() {
                assert_eq!(envelope.encode(), encoded, "{name}");
            }
            assert_eq!(Envelope::decode(&envelope.encode()).unwrap(), envelope, "{name}");
        } else {
            assert!(decoded.is_err(), "{name} should be rejected");
        }
    }
}

#[test]
fn data_frame_vectors() {
    for case in of_kind("data_frame") {
        let name = case["name"].as_str().unwrap();
        let bytes = bytes::Bytes::from(unhex(case["hex"].as_str().unwrap()));
        let decoded = DataFrame::decode(&bytes);
        if !case["valid"].as_bool().unwrap() {
            assert!(decoded.is_none(), "{name} should be rejected");
            continue;
        }
        let frame = decoded.unwrap();
        assert_eq!(u64::from(frame.stream), case["stream"].as_u64().unwrap(), "{name}");
        assert_eq!(u64::from(frame.credit), case["credit"].as_u64().unwrap(), "{name}");
        assert_eq!(frame.payload.to_vec(), unhex(case["payload_hex"].as_str().unwrap()), "{name}");
        assert_eq!(frame.encode(), bytes, "{name}");
    }
}

#[test]
fn unix_framing_vectors() {
    for case in vectors()["unix_framing"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let bytes = unhex(case["hex"].as_str().unwrap());
        let valid = case["valid"].as_bool().unwrap();
        if case["header_only"].as_bool().unwrap_or(false) {
            let header = [bytes[0], bytes[1], bytes[2], bytes[3]];
            assert_eq!(frame::parse_header(header).is_ok(), valid, "{name}");
            continue;
        }
        let decoded = frame::decode(&bytes);
        if !valid {
            assert!(decoded.is_err(), "{name} should be rejected");
            continue;
        }
        let (message, used) = decoded.unwrap().unwrap();
        assert_eq!(used, bytes.len(), "{name}");
        let expected = match case["kind"].as_str().unwrap() {
            "text" => Message::Text(case["text"].as_str().unwrap().to_owned()),
            _ => {
                let data = &case["data_frame"];
                let frame = DataFrame {
                    stream: data["stream"].as_u64().unwrap() as u32,
                    credit: data["credit"].as_u64().unwrap() as u32,
                    payload: unhex(data["payload_hex"].as_str().unwrap()).into(),
                };
                Message::Binary(frame.encode())
            }
        };
        assert_eq!(message, expected, "{name}");
        assert_eq!(frame::encode(&expected).unwrap(), bytes, "{name}");
    }
}

#[test]
fn token_vectors() {
    let vectors = vectors();
    let token = &vectors["token"];
    let key: [u8; 32] = unhex(token["public_key_hex"].as_str().unwrap()).try_into().unwrap();
    let seed: [u8; 32] = unhex(token["seed_hex"].as_str().unwrap()).try_into().unwrap();
    let signing = SigningKey::from_seed(&seed);
    assert_eq!(signing.public_key(), key);
    let claims: Claims = serde_json::from_value(token["claims"].clone()).unwrap();
    // Ed25519 is deterministic, so the vector token is reproducible.
    assert_eq!(signing.sign(&claims), token["token"].as_str().unwrap());
    for check in token["checks"].as_array().unwrap() {
        let name = check["name"].as_str().unwrap();
        let verifier = Verifier::new(key, check["aud"].as_str().unwrap());
        let result = verifier.verify(
            check["token"].as_str().unwrap(),
            check["now"].as_u64().unwrap(),
            check["origin"].as_str(),
        );
        let got = result.map_or_else(|error| error.as_str(), |_| "ok");
        assert_eq!(got, check["result"].as_str().unwrap(), "{name}");
    }
    for allow in token["allows"].as_array().unwrap() {
        let allowed =
            claims.allows(allow["op"].as_str().unwrap(), allow["scope"].as_str().unwrap());
        assert_eq!(allowed, allow["allowed"].as_bool().unwrap(), "{allow}");
    }
}

fn typed_ok(ty: &str, value: &Value) -> bool {
    fn ok<T: serde::de::DeserializeOwned>(value: &Value) -> bool {
        serde_json::from_value::<T>(value.clone()).is_ok()
    }
    match ty {
        "GitStatusParams" => ok::<GitStatusParams>(value),
        "GitDiffParams" => ok::<GitDiffParams>(value),
        "GitStatus" => ok::<GitStatus>(value),
        "GitDiff" => ok::<GitDiff>(value),
        "HelloParams" => ok::<HelloParams>(value),
        "HelloResult" => ok::<HelloResult>(value),
        "ProviderHello" => ok::<ProviderHello>(value),
        "ProviderWelcome" => ok::<ProviderWelcome>(value),
        "ResolveResult" => ok::<ResolveResult>(value),
        "PageManifest" => ok::<PageManifest>(value),
        other => panic!("no Rust type for {other}"),
    }
}

/// The IR schemas and the Rust types accept exactly the same values.
#[test]
fn validation_vectors_agree_for_the_ir_and_the_rust_types() {
    let ir_value = catalog().ir();
    for case in of_kind("validation") {
        let name = case["name"].as_str().unwrap();
        let ty = case["type"].as_str().unwrap();
        let expected = case["valid"].as_bool().unwrap();
        let schema = serde_json::json!({ "$ref": format!("#/types/{ty}") });
        let validator = ir::validator(&ir_value, &schema).unwrap();
        assert_eq!(validator.is_valid(&case["value"]), expected, "IR schema: {name}");
        assert_eq!(typed_ok(ty, &case["value"]), expected, "Rust type: {name}");
    }
}

#[test]
fn fragment_vectors() {
    let base = catalog().ir();
    for case in vectors()["fragments"].as_array().unwrap() {
        let merged = ir::merge(&base, &case["fragment"], &ShapeValidator);
        assert_eq!(
            merged.is_ok(),
            case["valid"].as_bool().unwrap(),
            "{}: {merged:?}",
            case["name"]
        );
        if let (Ok(merged), Some(expect)) = (&merged, case["expect"].as_object()) {
            let ops = merged["ops"].as_array().unwrap();
            let op = ops.iter().find(|op| op["name"] == expect["op"]).unwrap();
            for (field, value) in expect.iter().filter(|(field, _)| *field != "op") {
                assert_eq!(&op[field], value, "{}: {field}", case["name"]);
            }
        }
    }
}

/// Every schema in the IR stays inside the generators' keyword subset.
#[test]
fn ir_uses_only_supported_keywords() {
    let ir_value = catalog().ir();
    let mut schemas: Vec<(String, &Value)> = Vec::new();
    for op in ir_value["ops"].as_array().unwrap() {
        schemas.push((format!("{} params", op["name"]), &op["params"]));
        schemas.push((format!("{} result", op["name"]), &op["result"]));
    }
    for event in ir_value["events"].as_array().unwrap() {
        schemas.push((format!("{} data", event["name"]), &event["data"]));
    }
    for (name, schema) in ir_value["types"].as_object().unwrap() {
        schemas.push((name.clone(), schema));
    }
    for (at, schema) in schemas {
        ir::schema_keywords_supported(schema, &at).unwrap();
    }
    let fragment = ir::strip_derived(&ir_value);
    assert!(ShapeValidator.validate(&fragment).is_ok());
    // The whole IR passes the merge rules on its own (as emit-ir checks),
    // and the merge derives the same scope classes emit-ir wrote.
    let merged = ir::merge(&serde_json::json!({}), &fragment, &ShapeValidator).unwrap();
    assert_eq!(merged["ops"], ir_value["ops"]);
}

/// The emitted IR keeps the seed's top-level shape and the merge fields.
#[test]
fn ir_has_the_seed_shape() {
    let ir_value = catalog().ir();
    for key in ["version", "namespaces", "ops", "events", "interfaces", "types"] {
        assert!(ir_value.get(key).is_some(), "missing {key}");
    }
    let status = ir_value["ops"]
        .as_array()
        .unwrap()
        .iter()
        .find(|op| op["name"] == "cmux.git.status")
        .unwrap();
    assert_eq!(status["params"], serde_json::json!({ "$ref": "#/types/GitStatusParams" }));
    assert_eq!(status["result"], serde_json::json!({ "$ref": "#/types/GitStatus" }));
    assert_eq!(
        (status["kind"].as_str(), status["scope"].as_str()),
        (Some("read"), Some("git:read"))
    );
    assert_eq!(status["owner"], "first-party");
    assert_eq!(status["mcp"], serde_json::json!({ "expose": "default", "group": "git" }));
    assert_eq!(status["cli"], serde_json::json!({ "path": "git status", "visible": true }));
    assert_eq!(status["secret_output"], false);
    assert_eq!(status["paths"], serde_json::json!(["cwd"]));
    assert_eq!((status["risk"].as_str(), status["gesture"].as_bool()), (Some("read"), Some(false)));
    assert_eq!(status["scope_class"], "standard");
    for op in ir_value["ops"].as_array().unwrap() {
        if op["name"].as_str().unwrap().starts_with("cmux.router.") {
            assert_eq!(op["mcp"], serde_json::json!({ "expose": "never" }), "{}", op["name"]);
        }
    }
    let greet = ir_value["ops"]
        .as_array()
        .unwrap()
        .iter()
        .find(|op| op["name"] == "com.example.hello.greet.say")
        .unwrap();
    assert_eq!(greet["owner"], "app:com.example.hello");
    assert_eq!(ir_value["types"]["GitStatusParams"]["additionalProperties"], false);
    assert_eq!(ir_value["interfaces"][0]["methods"]["list"], "(context) -> DiffSummary[]");
}

/// Expected entries match when every field they name is equal.
fn matches(expected: &Value, got: &Value) -> bool {
    expected.as_object().unwrap().iter().all(|(key, value)| &got[key] == value)
}

#[tokio::test]
async fn session_vectors_against_the_example_provider() {
    let verifier = Verifier::new(SigningKey::from_seed(&TEST_SEED).public_key(), example::APP_ID);
    for case in vectors()["session"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let (mut ours, theirs) = memory_pair();
        let provider = Arc::new(example::provider());
        let verifier = verifier.clone();
        tokio::spawn(async move { provider.serve(theirs, &verifier, None).await });
        for text in case["send"].as_array().unwrap() {
            assert!(ours.send(Message::Text(text.as_str().unwrap().to_owned())).await, "{name}");
        }
        for expected in case["expect"].as_array().unwrap() {
            let message = tokio::time::timeout(std::time::Duration::from_secs(5), ours.recv())
                .await
                .expect(name);
            let Some(Message::Text(text)) = message else {
                panic!("{name}: expected {expected}, got {message:?}")
            };
            let got: Value = serde_json::from_str(&text).unwrap();
            assert!(matches(expected, &got), "{name}: expected {expected}, got {got}");
        }
    }
}

/// Decision 20: path confinement to the token's roots.
#[cfg(unix)]
#[tokio::test]
async fn roots_vectors() {
    let vectors = vectors();
    let roots = &vectors["roots"];
    let directory = tempfile::tempdir().unwrap();
    let base = directory.path().canonicalize().unwrap();
    for dir in roots["layout"]["dirs"].as_array().unwrap() {
        std::fs::create_dir_all(base.join(dir.as_str().unwrap())).unwrap();
    }
    for link in roots["layout"]["symlinks"].as_array().unwrap() {
        let path = base.join(link["path"].as_str().unwrap());
        std::os::unix::fs::symlink(link["target"].as_str().unwrap(), path).unwrap();
    }
    let base = base.to_string_lossy().into_owned();
    let expand = |text: &str| text.replace("$BASE", &base);
    for case in roots["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let claimed: Vec<String> =
            case["roots"].as_array().unwrap().iter().map(|r| expand(r.as_str().unwrap())).collect();
        let result = cmux_pane_protocol::provider::confine(
            &claimed,
            &expand(case["path"].as_str().unwrap()),
        )
        .await;
        assert_eq!(result.is_ok(), case["allowed"].as_bool().unwrap(), "{name}: {result:?}");
        if let Err(refusal) = result {
            assert_eq!(refusal.code, roots["refusal_code"].as_str().unwrap(), "{name}");
        }
    }
}

/// First-party hellos must carry the router's IR digest.
#[test]
fn admission_vectors() {
    use cmux_pane_protocol::router::ops::{HelloIr, PROTO};
    use cmux_pane_protocol::router::{Admission, AppRecord, Router};
    let vectors = vectors();
    let admission = &vectors["admission"];
    let router_digest = admission["router_ir_sha256"].as_str().unwrap();
    assert_eq!(router_digest, catalog().digest());
    for (conn, case) in admission["cases"].as_array().unwrap().iter().enumerate() {
        let name = case["name"].as_str().unwrap();
        let app = case["app"].as_str().unwrap();
        let router = Router::new(SigningKey::from_seed(&TEST_SEED), catalog());
        router
            .register_app(AppRecord { app_id: app.into(), credential: None, grants: vec![] })
            .unwrap();
        let sha256 = match case["ir_sha256"].as_str().unwrap() {
            "router" => router_digest.to_owned(),
            other => other.to_owned(),
        };
        let hello = ProviderHello {
            proto: PROTO.into(),
            app: app.into(),
            namespaces: vec![app.into()],
            ops: vec![],
            events: vec![],
            interfaces: vec![],
            ir: HelloIr { version: "0.1.0".into(), sha256 },
            endpoints: vec![],
            credential: None,
        };
        let got = match router.admit(conn as u64, &Admission::Spawned(app.into()), hello) {
            Ok(_) => "ok".to_owned(),
            Err(error) => {
                let reason =
                    error.details.as_ref().and_then(|d| d["reason"].as_str()).unwrap_or_default();
                format!("{}:{reason}", error.code)
            }
        };
        assert_eq!(got, case["result"].as_str().unwrap(), "{name}");
    }
}
