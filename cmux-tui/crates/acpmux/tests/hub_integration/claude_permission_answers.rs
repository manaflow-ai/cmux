//! The person's answer to Claude Code's `can_use_tool` ask, as Claude Code
//! receives it (cx-gakp): a one-time allow never widens into a rule, "always"
//! returns Claude's own permission_suggestions as `updatedPermissions` (the
//! only way Claude installs them), and a reject is Claude's "No, and tell
//! Claude what to do differently": a deny that interrupts the turn, so Claude
//! waits for the person instead of carrying on.

use super::*;

/// Claude Code's suggestion for the fake's Bash ask, byte for byte.
fn suggestions() -> Value {
    json!([{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm test"}],
            "behavior": "allow", "destination": "localSettings"}])
}

/// Prompt "permission-ask", answer its ask with `option`, and return the
/// control response Claude Code got for it.
async fn answer(
    hub: &Arc<Hub>,
    c: &mut TestClient,
    id: &str,
    answers: &std::path::Path,
    option: &str,
) -> Value {
    let before = std::fs::read_to_string(answers).unwrap_or_default().lines().count();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "permission-ask"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let mut asked = None;
    for _ in 0..100 {
        asked = hub
            .events(id, 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == "permission_request")
            .nth(before);
        if asked.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let asked = asked.unwrap_or_else(|| panic!("ask {} never reached the person", before + 1));
    let offered: Vec<&str> = asked.msg["request"]["options"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|o| o["optionId"].as_str())
        .collect();
    assert_eq!(offered, ["allow_once", "allow_always", "reject_once"], "{}", asked.msg);
    let pid = asked.msg["permissionId"].as_str().unwrap().to_owned();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": option}),
    )
    .await
    .unwrap();
    for _ in 0..100 {
        let got = std::fs::read_to_string(answers).unwrap_or_default();
        if let Some(line) = got.lines().nth(before) {
            let response: Value = serde_json::from_str(line).unwrap();
            assert_eq!(response["request_id"], format!("perm-{}", before + 1), "{response}");
            return response["response"].clone();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("Claude Code never got the {option} answer");
}

#[tokio::test]
async fn claude_gets_the_persons_permission_answer_as_claude_code_defines_it() {
    let root = std::env::temp_dir().join(format!("acpmux-perm-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let answers = root.join("answers.jsonl");
    let answers_env = answers.to_string_lossy().into_owned();
    let (hub, mut c) = claude_person_setup(&claude, &[("FAKE_CLAUDE_ANSWERS", &answers_env)]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    hub.set_policy(&hub.resolve(&id).unwrap(), PermissionPolicy::Ask).await;

    // Allow once: the tool runs, and no rule is installed.
    let once = answer(&hub, &mut c, &id, &answers, "allow_once").await;
    assert_eq!(once["behavior"], "allow", "{once}");
    assert!(once.get("updatedPermissions").is_none(), "{once}");

    // Allow always: Claude's own suggestions come back as its rule update.
    let always = answer(&hub, &mut c, &id, &answers, "allow_always").await;
    assert_eq!(always["behavior"], "allow", "{always}");
    assert_eq!(always["updatedPermissions"], suggestions(), "{always}");

    // Reject: Claude's "No, and tell Claude what to do differently" denies
    // and interrupts, so the turn stops for the person's next message.
    let no = answer(&hub, &mut c, &id, &answers, "reject_once").await;
    assert_eq!(no["behavior"], "deny", "{no}");
    assert_eq!(no["interrupt"], true, "{no}");
    assert!(no.get("updatedPermissions").is_none(), "{no}");
    let _ = std::fs::remove_dir_all(root);
}
