use super::*;

#[test]
fn only_an_older_machine_is_outdated() {
    let identity = json!({"capabilities": ["agent-session-start-v1"], "build_id": "other-build"});
    let outdated = outdated_identity(&identity, &["fs-v1"]).expect("fs-v1 is missing");
    assert!(outdated.older);
    assert_eq!(outdated.line()["error_code"], json!(OUTDATED));
    assert!(outdated.message().contains("update the machine"));
    let current = Outdated { older: false, ..outdated };
    assert_eq!(current.line()["error_code"], json!(CAPABILITY_MISSING));
    let message = current.message();
    assert!(message.contains("fs-v1") && !message.contains("update the machine"), "{message}");
    assert!(outdated_identity(&json!({"capabilities": ["fs-v1"]}), &["fs-v1"]).is_none());
}
