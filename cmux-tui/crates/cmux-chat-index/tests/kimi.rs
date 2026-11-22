mod common;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, write, write_jsonl};
use serde_json::json;

/// md5("/work/a") and md5("/work/b"): kimi-cli's bucket names.
const BUCKET_A: &str = "48f9cdb2ef9632fcdfddbfa4dcc18f69";
const BUCKET_B: &str = "17b0688a4c0a7dc8aa726b6e4cd0f7e0";

fn kimi_json(root: &std::path::Path) {
    write(
        &root.join("kimi.json"),
        &json!({"work_dirs": [
            {"path": "/work/a", "kaos": "local", "last_session_id": null},
            {"path": "/work/b", "kaos": "ssh"}
        ]})
        .to_string(),
    );
}

#[test]
fn kimi_cli_flat_sessions_before_v0_59_are_read_with_the_folder_from_kimi_json() {
    let dir = tempfile::tempdir().unwrap();
    kimi_json(dir.path());
    // Python json.dumps separators (`": "`) and compact ones both occur.
    write(
        &dir.path().join("sessions").join(BUCKET_A).join("flat-1.jsonl"),
        concat!(
            "{\"role\": \"_system_prompt\", \"content\": \"you are kimi\"}\n",
            "{\"role\": \"user\", \"content\": \"fix the flaky test\"}\n",
            "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}\n",
            "{\"role\": \"_usage\", \"token_count\": 12}\n",
            "{\"role\": \"_checkpoint\", \"id\": 1}\n",
        ),
    );
    let scan = scan(AdapterKind::KimiCli, dir.path());
    let chat = by_id(&scan).remove("flat-1").unwrap();
    assert_eq!(chat.message_count, Some(2));
    assert_eq!(
        (chat.title.as_deref(), chat.title_source),
        (Some("fix the flaky test"), Some(TitleSource::Prompt))
    );
    assert_eq!(chat.cwd.as_deref(), Some("/work/a"));
    assert_eq!(chat.resume, Resume::ReadOnly);
    assert!(!chat.archived);
}

#[test]
fn kimi_cli_session_dirs_take_titles_from_state_metadata_and_the_wire_log() {
    let dir = tempfile::tempdir().unwrap();
    kimi_json(dir.path());
    let named = dir.path().join("sessions").join(BUCKET_A).join("s-named");
    write_jsonl(
        &named.join("context.jsonl"),
        &[
            json!({"role":"user","content":"first prompt"}),
            json!({"role":"assistant","content":"ok"}),
        ],
    );
    write(
        &named.join("state.json"),
        &json!({"version":1,"custom_title":"Named","archived":true}).to_string(),
    );
    write(
        &named.join("wire.jsonl"),
        &[
            json!({"type":"metadata","protocol_version":"1.10"}).to_string(),
            json!({"timestamp":1_790_848_800.5,"message":{"type":"TurnBegin","payload":{"user_input":"wire prompt"}}})
                .to_string(),
            String::new(),
        ]
        .join("\n"),
    );
    // A remote kaos bucket and a pre-v1.14 metadata.json with the default title.
    let wired = dir.path().join("sessions").join(format!("ssh_{BUCKET_B}")).join("s-wired");
    write_jsonl(&wired.join("context.jsonl"), &[json!({"role":"user","content":"context prompt"})]);
    write(&wired.join("metadata.json"), &json!({"title":"Untitled","archived":false}).to_string());
    write(
        &wired.join("wire.jsonl"),
        &format!(
            "{}\n{}\n",
            json!({"type":"metadata","protocol_version":"1.9"}),
            json!({"timestamp":1_790_848_900,"message":{"type":"TurnBegin","payload":{"user_input":[{"type":"text","text":"typed on the wire"}]}}})
        ),
    );
    // A legacy metadata.json title still names the chat.
    let legacy = dir.path().join("sessions").join(BUCKET_A).join("s-legacy");
    write_jsonl(&legacy.join("context.jsonl"), &[json!({"role":"user","content":"x"})]);
    write(&legacy.join("metadata.json"), &json!({"title":"Old title","archived":true}).to_string());

    let scan = scan(AdapterKind::KimiCli, dir.path());
    assert_eq!(ids(&scan), ["s-named", "s-wired", "s-legacy"].map(String::from).into());
    let chats = by_id(&scan);
    let named = &chats["s-named"];
    assert_eq!(
        (named.title.as_deref(), named.title_source),
        (Some("Named"), Some(TitleSource::Custom))
    );
    assert!(named.archived);
    assert_eq!(named.created_ms, Some(1_790_848_800_500));
    assert_eq!(named.message_count, Some(2));
    assert_eq!(named.cwd.as_deref(), Some("/work/a"));
    let wired = &chats["s-wired"];
    assert_eq!(
        (wired.title.as_deref(), wired.title_source),
        (Some("typed on the wire"), Some(TitleSource::Prompt))
    );
    assert_eq!(wired.cwd.as_deref(), Some("/work/b"));
    assert_eq!(wired.created_ms, Some(1_790_848_900_000));
    let legacy = &chats["s-legacy"];
    assert_eq!(legacy.title.as_deref(), Some("Old title"));
    assert!(legacy.archived);
}

#[test]
fn kimi_cli_paths_classify() {
    let root = std::path::Path::new("/k");
    let role = |rel: &str| classify_path(AdapterKind::KimiCli, root, &root.join(rel));
    assert_eq!(role("sessions/b/s1/context.jsonl"), PathRole::Session);
    assert_eq!(role("sessions/b/s1.jsonl"), PathRole::Session);
    assert_eq!(role("sessions/b/s1/state.json"), PathRole::Store);
    assert_eq!(role("sessions/b/s1/wire.jsonl"), PathRole::Store);
    assert_eq!(role("kimi.json"), PathRole::Store);
    assert_eq!(role("logs/kimi.log"), PathRole::Ignore);
}

#[test]
fn kimi_code_state_files_and_the_session_index() {
    let dir = tempfile::tempdir().unwrap();
    let wd = dir.path().join("sessions/wd_app_0123456789ab");
    let state = |id: &str, value: serde_json::Value| {
        write(&wd.join(id).join("state.json"), &value.to_string());
        write(&wd.join(id).join("agents/main/wire.jsonl"), "");
    };
    state(
        "session_a",
        json!({"id":"session_a","version":2,"title":"Generated","titleKind":"generated",
               "createdAt":1_790_848_800_000_i64,"updatedAt":1_790_852_400_000_i64,"archived":false}),
    );
    state(
        "session_b",
        json!({"id":"session_b","version":2,"title":"Mine","titleKind":"custom",
               "createdAt":1,"updatedAt":2,"archived":true,"cwd":"/own"}),
    );
    state("session_c", json!({"id":"session_c","title":"Gone","createdAt":1,"updatedAt":2}));
    state(
        "session_d",
        json!({"id":"session_d","lastPrompt":"what changed?\nmore","createdAt":1,"updatedAt":3}),
    );
    let index = [
        json!({"sessionId":"session_a","sessionDir":wd.join("session_a"),"workDir":"/work/app"}),
        json!({"sessionId":"session_b","sessionDir":wd.join("session_b"),"workDir":"/ignored"}),
        json!({"sessionId":"session_c","sessionDir":wd.join("session_c"),"workDir":"/w"}),
        json!({"sessionId":"session_c","deleted":true}),
    ];
    write_jsonl(&dir.path().join("session_index.jsonl"), &index);

    let scan = scan(AdapterKind::KimiCode, dir.path());
    assert_eq!(ids(&scan), ["session_a", "session_b", "session_d"].map(String::from).into());
    let chats = by_id(&scan);
    let a = &chats["session_a"];
    assert_eq!((a.title.as_deref(), a.title_source), (Some("Generated"), Some(TitleSource::Ai)));
    assert_eq!(a.cwd.as_deref(), Some("/work/app"));
    assert_eq!((a.created_ms, a.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    let b = &chats["session_b"];
    assert_eq!(
        (b.title_source, b.cwd.as_deref(), b.archived),
        (Some(TitleSource::Custom), Some("/own"), true)
    );
    let d = &chats["session_d"];
    assert_eq!(
        (d.title.as_deref(), d.title_source),
        (Some("what changed?"), Some(TitleSource::Prompt))
    );
    let root = dir.path();
    assert_eq!(
        classify_path(AdapterKind::KimiCode, root, &root.join("session_index.jsonl")),
        PathRole::Store
    );
    assert_eq!(
        classify_path(AdapterKind::KimiCode, root, &wd.join("session_a/state.json")),
        PathRole::Session
    );
}
