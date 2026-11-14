use super::*;

#[test]
fn cloud_repo_recovery_payload_keeps_retry_and_choices_quiet() {
    for value in [
        json!({"code":"repo.needs_github","install_url":"https://github.com/apps/cmux/installations/new","retry":{"action":"cloud.repo.add","args":{"session":"chat","repo":"repo"}}}),
        json!({"code":"repo.ambiguous","choices":[{"fullName":"a/repo"},{"fullName":"b/repo"}]}),
    ] {
        let output = result(value.clone());
        assert_eq!(output["isError"], false);
        assert_eq!(output["structuredContent"], value);
    }
    assert_eq!(
        result(json!({"code":"seed.disk_full","message":"Free disk space and retry."}))["isError"],
        true
    );
}
