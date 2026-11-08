//! The shared Cloud repository daemon actions, also exposed by `cmux cloud repo`.

use serde_json::{Map, Value, json};

use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};
use crate::cli::cloud_repo;

pub(super) fn descriptors() -> [Value; 4] {
    [
        descriptor(
            "cloud_repo_attached",
            "List repositories attached to this Cloud chat, including their folders and cloned heads.",
            json!({}),
            &["session"],
            true,
        ),
        descriptor(
            "cloud_repo_list",
            "List repositories known to this Cloud chat, ranked from local folders, recent Cloud chats, and GitHub installations.",
            json!({"query":{"type":"string","minLength":1}}),
            &["session"],
            true,
        ),
        descriptor(
            "cloud_repo_add",
            "Attach a repository to a Cloud chat. A bare name resolves automatically; ambiguous names return choices. If GitHub needs connecting, the inline card waits and retries this add automatically without a new user message.",
            json!({"repo":{"type":"string","minLength":1},"ref":{"type":"string","minLength":1}}),
            &["session", "repo"],
            false,
        ),
        descriptor(
            "cloud_repo_wait_github",
            "Wait for GitHub to connect, then retry the same cloud_repo_add when connected is true. A bounded wait returning false can be resumed by the recovery card.",
            json!({"timeout_ms":{"type":"integer","minimum":0,"maximum":cloud_repo::MAX_WAIT_MS,"default":30000}}),
            &["session"],
            true,
        ),
    ]
}

fn descriptor(name: &str, description: &str, extra: Value, required: &[&str], read: bool) -> Value {
    let mut properties = extra.as_object().cloned().unwrap_or_default();
    properties.insert("session".into(), json!({"type":"string","minLength":1,"description":"The Cloud chat id, not a daemon routing selector."}));
    json!({"name":name,"description":description,
        "inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},
        "annotations":{"readOnlyHint":read,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true}})
}

pub(super) fn call(
    backend: &impl Backend,
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Value> {
    let action = match name {
        "cloud_repo_list" => "cloud.repo.list",
        "cloud_repo_attached" => "cloud.repo.attached",
        "cloud_repo_add" => "cloud.repo.add",
        "cloud_repo_wait_github" => "cloud.repo.wait_github",
        _ => return None,
    };
    Some(match cloud_repo::validate(action, arguments) {
        Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
        Ok(()) => match backend.cloud_repo(action, Value::Object(arguments.clone())) {
            Ok(value) => result(value),
            Err(failure) => failure_result(failure),
        },
    })
}

/// Recovery is an ordinary tool result. Terminal failures keep the typed
/// payload (including choices/install URL) rather than flattening it to text.
fn result(value: Value) -> Value {
    let code = value.get("code").and_then(Value::as_str);
    let error = code.is_some_and(|code| !matches!(code, "repo.needs_github" | "repo.ambiguous"));
    let mut output = success(value, false);
    if let Some(object) = output.as_object_mut() {
        object.insert("isError".into(), json!(error));
    }
    output
}

#[cfg(test)]
mod tests {
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
}
