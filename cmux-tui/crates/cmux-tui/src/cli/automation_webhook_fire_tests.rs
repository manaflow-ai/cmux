use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| s.to_string()).collect()
}
const ID: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";

#[test]
fn the_signature_is_the_platforms_cmux_form() {
    // Same bytes as cmux-platform's webhookSigningBytes; checked against Node's
    // createHmac("sha256", "s3cret").update("1795520000\nd-1\n{\"event\":\"deploy\"}").
    let [delivery, timestamp, signature] =
        signed_headers("s3cret", 1_795_520_000, "d-1", br#"{"event":"deploy"}"#);
    assert_eq!(delivery, ("x-cmux-webhook-delivery", "d-1".to_owned()));
    assert_eq!(timestamp, ("x-cmux-webhook-timestamp", "1795520000".to_owned()));
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, b"s3cret");
    let tag = ring::hmac::sign(&key, b"1795520000\nd-1\n{\"event\":\"deploy\"}");
    let hex: String = tag.as_ref().iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(signature, ("x-cmux-webhook-signature", format!("sha256={hex}")));
}

#[test]
fn a_shot_takes_the_event_into_the_body_and_the_secret_from_env() {
    let none = |_: &str| None;
    let env = |key: &str| (key == SECRET_ENV).then(|| "from-env".to_owned());
    let Ok(s) = shot(&words(&[ID, "--event", "deploy", "--body", r#"{"level":"error"}"#]), &env)
    else {
        panic!("shot");
    };
    assert_eq!(s.secret, "from-env");
    let body: Value = serde_json::from_slice(&s.body).unwrap();
    assert_eq!(body, json!({"level": "error", "event": "deploy"}));
    assert!(shot(&words(&[ID]), &none).is_err(), "no secret");
    assert!(shot(&words(&["nope", "--secret", "s"]), &none).is_err(), "bad trigger");
    assert!(shot(&words(&[ID, "--secret", "s", "--body", "[1]"]), &none).is_err());
    assert!(shot(&words(&[ID, "--secret", "s", "--event", "has space"]), &none).is_err());
    let Ok(plain) = shot(&words(&[ID, "--secret", "s"]), &none) else { panic!("plain") };
    assert_eq!(plain.body, b"{}");
}

#[test]
fn the_answer_says_whether_a_run_started() {
    let queued = answer_line(&json!({"accepted": true, "id": "dlv_1", "state": "queued"}));
    assert!(queued.contains("dlv_1") && queued.contains("queued"), "{queued}");
    let skipped = answer_line(&json!({"accepted": false, "reason": "condition_unmet"}));
    assert!(skipped.contains("condition_unmet"), "{skipped}");
}
