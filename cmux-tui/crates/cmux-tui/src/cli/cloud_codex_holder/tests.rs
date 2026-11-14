use super::*;
use serde_json::json;

fn answer(body: Value, file: Option<Spool>) -> Answer {
    Answer { status: 200, body, code: None, file }
}

#[test]
fn reads_every_answer_shape() {
    assert_eq!(read_bytes(answer(json!({"dataBase64": BASE64.encode("a")}), None)).unwrap(), b"a");
    assert_eq!(read_bytes(answer(json!({"data": BASE64.encode("b")}), None)).unwrap(), b"b");
    let mut bytes = tempfile::tempfile().unwrap();
    std::io::Write::write_all(&mut bytes, b"spooled").unwrap();
    assert_eq!(
        read_bytes(answer(json!({"path": "/x"}), Some(Spool::Bytes(bytes)))).unwrap(),
        b"spooled"
    );
    let mut spooled = tempfile::tempfile().unwrap();
    std::io::Write::write_all(
        &mut spooled,
        json!({"dataBase64": BASE64.encode("j")}).to_string().as_bytes(),
    )
    .unwrap();
    assert_eq!(read_bytes(answer(Value::Null, Some(Spool::Json(spooled)))).unwrap(), b"j");
    assert!(read_bytes(answer(json!({}), None)).is_err());
}

/// cmux#37306 review: a refusal that echoes the credential never reaches the app's text.
#[test]
fn a_refusal_never_carries_the_credential() {
    let refused = Answer {
        status: 403,
        body: json!({"error": {"code": "denied", "message": "bad token secret-token-1"}}),
        code: None,
        file: None,
    };
    let text = scrub(refused, "secret-token-1").body.to_string();
    assert!(!text.contains("secret-token-1"), "{text}");
}

#[test]
fn only_the_codex_holder_command_runs_it() {
    assert_eq!(run_if_requested(&["cloud".into(), "machine-io".into()]), None);
    assert_eq!(run_if_requested(&["status".into()]), None);
}
