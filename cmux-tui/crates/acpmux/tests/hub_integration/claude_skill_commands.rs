//! Claude Code skills in the slash command list: the pane's picker labels a
//! command "Skill" when its `available_commands_update` entry carries
//! `_meta.kind: "skill"` (codex-acp's convention). Claude Code names its
//! skills in system/init (`skills`), so acpmux tags those entries.

use super::*;

/// A skill's entry is tagged and a built-in command's is not, and a turn's
/// system/init that changes nothing sends no new list.
#[tokio::test]
async fn claude_skills_are_tagged_in_the_command_list() {
    let root = std::env::temp_dir().join(format!("acpmux-skills-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[("FAKE_CLAUDE_SKILLS", "1")]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "second"] {
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    }
    let lists: Vec<Value> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "available_commands_update")
        .filter_map(|e| e.msg.pointer("/params/update/availableCommands").cloned())
        .collect();
    let entry = |list: &Value, name: &str| {
        list.as_array()
            .and_then(|l| l.iter().find(|c| c["name"] == name).cloned())
            .unwrap_or_else(|| panic!("no {name} in {list}"))
    };
    let tagged: Vec<&Value> =
        lists.iter().filter(|l| entry(l, "demo-skill")["_meta"]["kind"] == "skill").collect();
    assert_eq!(tagged.len(), 1, "one tagged list across both turns: {lists:?}");
    let last = lists.last().unwrap();
    assert_eq!(entry(last, "demo-skill")["_meta"]["kind"], "skill", "{last}");
    assert_eq!(entry(last, "demo-skill")["description"], "A demo skill (user)", "{last}");
    assert!(entry(last, "compact").get("_meta").is_none(), "{last}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}
