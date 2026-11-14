use super::*;
use std::path::{Path, PathBuf};

/// A Claude store with chat session `s1` in project `-work`.
fn store(name: &str) -> PathBuf {
    let home = std::env::temp_dir()
        .join(format!("acpmux-subagent-transcript-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let project = home.join("projects/-work");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join("s1.jsonl"), "{}\n").unwrap();
    home
}

fn write(dir: &Path, agent: &str, lines: usize) {
    std::fs::create_dir_all(dir).unwrap();
    let mut text = String::new();
    text.push_str(&json!({"type": "user", "message": {"content": "Review PR #1"}}).to_string());
    text.push('\n');
    text.push_str(&json!({"type": "attachment"}).to_string());
    text.push('\n');
    for n in 1..lines {
        let line = json!({"type": "assistant", "message": {"content": [{"type": "text", "text": format!("step {n}")}]}});
        text.push_str(&line.to_string());
        text.push('\n');
    }
    std::fs::write(dir.join(format!("agent-{agent}.jsonl")), text).unwrap();
}

#[test]
fn a_workflow_agent_is_read_only_under_the_chats_session() {
    let home = store("where");
    let project = home.join("projects/-work");
    write(&project.join("s1/subagents/workflows/wf_new"), "a01", 3);
    write(&project.join("s0/subagents/workflows/wf_old"), "a02", 2);
    write(&project.join("s1/subagents"), "b01", 2);
    // Every line counts (the attachment too); only messages are replayed.
    assert_eq!(
        read(&[(home.clone(), "s1".into())], Some("wf_new"), "a01").unwrap().0.lines.len(),
        4
    );
    assert!(read(&[(home.clone(), "s1".into())], Some("wf_old"), "a02").is_err());
    assert_eq!(read(&[(home.clone(), "s1".into())], None, "b01").unwrap().0.lines.len(), 3);
    // A background agent is the chat's own: never another session's.
    write(&project.join("s0/subagents"), "b02", 2);
    assert!(read(&[(home.clone(), "s1".into())], None, "b02").is_err());
    let _ = std::fs::remove_dir_all(home);
}

/// Reads through the real session/profile resolution, never a directory supplied by a caller.
fn transcript_hub(home: &Path) -> std::sync::Arc<Hub> {
    let cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["claude"],
            "env": {"CLAUDE_CONFIG_DIR": home}}},
        "defaultHarness": "claude", "store": {"mode": "memory"}
    }))
    .unwrap();
    let store = crate::store::open(&cfg.store, home).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat",
        "harness": "claude", "cwd": home, "status": "idle",
        "createdAt": 1, "updatedAt": 1, "agentSessionId": "s1"
    }))
    .unwrap();
    store.save(&meta).unwrap();
    Hub::new(cfg, store)
}

fn replace_meta(hub: &Hub, id: &str, changes: Value) {
    let session = hub.resolve("chat").unwrap();
    let mut value = serde_json::to_value(session.meta()).unwrap();
    value["id"] = json!(id);
    value["name"] = json!(id);
    for (key, value_changed) in changes.as_object().unwrap() {
        value[key] = value_changed.clone();
    }
    if value["parentId"].is_string() && value.get("forkParentVerified").is_none() {
        value["forkParentVerified"] = json!(true);
    }
    let meta = serde_json::from_value(value).unwrap();
    hub.store.save(&meta).unwrap();
    if id == "chat" {
        *session.meta.lock().unwrap() = meta;
    } else {
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(id.into(), session);
    }
}

#[tokio::test]
async fn fork_transcript_reads_earlier_claude_id_of_the_same_chat() {
    let home = scoped_store("same-chat-fork");
    let hub = transcript_hub(&home);
    {
        let chat = hub.resolve("chat").unwrap();
        let mut meta = chat.meta.lock().unwrap();
        // The harness reported s1 before replacing it during a same-chat fork.
        meta.set_agent_session_id(Some("s1".into()), "claude");
        meta.set_agent_session_id(Some("new-session".into()), "claude");
    }
    let page = handle(&hub, &transcript_request("wf_own")).await.unwrap();
    assert_eq!(page["lines"], 4);
    let absent = handle(&hub, &transcript_request("wf_missing")).await.unwrap_err();
    let sibling = handle(&hub, &transcript_request("wf_other")).await.unwrap_err();
    assert_eq!(serde_json::to_vec(&sibling).unwrap(), serde_json::to_vec(&absent).unwrap());
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn fork_transcript_reads_parent_and_terminates_a_cycle() {
    let home = scoped_store("parent-cycle");
    let hub = transcript_hub(&home);
    replace_meta(&hub, "parent", json!({"parentId": "chat", "forkSeq": 1}));
    replace_meta(
        &hub,
        "chat",
        json!({
            "agentSessionId": "child-session", "parentId": "parent", "forkSeq": 1
        }),
    );
    let page = handle(&hub, &transcript_request("wf_own")).await.unwrap();
    assert_eq!(page["lines"], 4);
    let absent = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        handle(&hub, &transcript_request("wf_missing")),
    )
    .await
    .unwrap()
    .unwrap_err();
    let sibling = handle(&hub, &transcript_request("wf_other")).await.unwrap_err();
    assert_eq!(serde_json::to_vec(&sibling).unwrap(), serde_json::to_vec(&absent).unwrap());
    let _ = std::fs::remove_dir_all(home);
}

fn transcript_request(run: &str) -> Value {
    json!({"sessionId": "chat", "runId": run, "agentId": "a01"})
}

fn scoped_store(name: &str) -> PathBuf {
    let home = store(name);
    let project = home.join("projects/-work");
    write(&project.join("s1/subagents/workflows/wf_own"), "a01", 3);
    write(&project.join("sibling/subagents/workflows/wf_other"), "a01", 3);
    home
}

#[tokio::test]
async fn handle_reads_own_run_and_hides_a_siblings_run_as_missing() {
    let home = scoped_store("scope");
    let hub = transcript_hub(&home);
    let own = handle(&hub, &transcript_request("wf_own")).await.unwrap();
    assert_eq!(own["lines"], 4);
    assert!(!own["updates"].as_array().unwrap().is_empty());
    let absent = handle(&hub, &transcript_request("wf_missing")).await.unwrap_err();
    let sibling = handle(&hub, &transcript_request("wf_other")).await.unwrap_err();
    assert_eq!(serde_json::to_vec(&sibling).unwrap(), serde_json::to_vec(&absent).unwrap());
    assert_eq!(absent.data.unwrap()["reason"], "transcript.missing");
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn peer_and_paired_device_read_only_readable_fork_ancestors() {
    use crate::server::{ConnAuth, Origin, serve_connection_authed};
    let home = scoped_store("peer-scope");
    let hub = transcript_hub(&home);
    // The immediate ancestor is local and readable. Its own parent is only a cached
    // session on another peer: neither its native ID nor its parent may grant a folder.
    replace_meta(
        &hub,
        "parent",
        json!({
            "agentSessionId": "parent-new", "previousAgentSessionIds": ["s1"],
            "parentId": "remote-parent", "forkSeq": 1
        }),
    );
    replace_meta(
        &hub,
        "chat",
        json!({
            "agentSessionId": "child-new", "parentId": "parent", "forkSeq": 1
        }),
    );
    let (notices, _recv) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("other", "ws://127.0.0.1:1", None, None, notices);
    hub.peers.lock().unwrap().insert("other".into(), peer.clone());
    hub.apply_peer_notice(
        "other",
        peer.generation,
        crate::peer::PeerNotice::sessions_from_values(vec![
            json!({"sessionId": "remote-parent", "name": "remote-parent", "status": "idle",
                "agentSessionId": "sibling", "updatedAt": 1}),
        ]),
    );
    std::fs::write(home.join("projects/-work/sibling.jsonl"), "{}\n").unwrap();
    assert!(hub.resolve_remote("other/remote-parent").is_some());
    for auth in [ConnAuth::PeerToken, ConnAuth::Device] {
        let (send, inbound) = tokio::sync::mpsc::channel(8);
        let (out, mut recv) = tokio::sync::mpsc::channel(64);
        let server =
            tokio::spawn(serve_connection_authed(hub.clone(), inbound, out, Origin::Peer, auth));
        let requests = [
            ("initialize", json!({"protocolVersion": 1})),
            ("_acpmux/resolve", json!({"query": "chat"})),
            ("_acpmux/subagent_transcript", transcript_request("wf_own")),
            ("_acpmux/subagent_transcript", transcript_request("wf_missing")),
            ("_acpmux/subagent_transcript", transcript_request("wf_other")),
        ];
        let mut replies = Vec::new();
        for (id, (method, params)) in requests.into_iter().enumerate() {
            send.send(crate::rpc::Message::request(id as i64, method, params).to_line())
                .await
                .unwrap();
            loop {
                let line = tokio::time::timeout(std::time::Duration::from_secs(10), recv.recv())
                    .await
                    .unwrap()
                    .unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply.get("id") == Some(&json!(id)) {
                    replies.push(reply);
                    break;
                }
            }
        }
        assert_eq!(replies[1]["result"]["session"]["sessionId"], "chat", "{replies:?}");
        assert_eq!(replies[2]["result"]["lines"], 4, "{replies:?}");
        assert_eq!(replies[3]["error"]["data"]["reason"], "transcript.missing");
        assert_eq!(
            serde_json::to_vec(&replies[3]["error"]).unwrap(),
            serde_json::to_vec(&replies[4]["error"]).unwrap()
        );
        drop(send);
        server.await.unwrap();
    }
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn fork_transcript_parent_id_is_never_a_name_or_prefix() {
    let home = scoped_store("parent-exact");
    let hub = transcript_hub(&home);
    replace_meta(&hub, "parent-long-id", json!({"name": "parent"}));
    replace_meta(
        &hub,
        "chat",
        json!({
            "agentSessionId": "child-new", "parentId": "parent", "forkSeq": 1
        }),
    );
    assert!(hub.resolve("parent").is_ok(), "normal lookup permits the name");
    let missing = handle(&hub, &transcript_request("wf_missing")).await.unwrap_err();
    let sibling = handle(&hub, &transcript_request("wf_own")).await.unwrap_err();
    assert_eq!(serde_json::to_vec(&sibling).unwrap(), serde_json::to_vec(&missing).unwrap());
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn fork_transcript_legacy_links_need_both_local_journals_and_no_later_import() {
    for (name, receipt, child_import, parent_import) in [
        ("legacy-local", true, false, false),
        ("legacy-forged", false, false, false),
        ("legacy-child-import", true, true, false),
        ("legacy-parent-import", true, false, true),
    ] {
        let home = scoped_store(name);
        let hub = transcript_hub(&home);
        replace_meta(&hub, "parent", json!({}));
        replace_meta(
            &hub,
            "chat",
            json!({
                "agentSessionId": "child-new", "parentId": "parent", "forkSeq": 0,
                "forkParentVerified": null
            }),
        );
        let child = hub.resolve("chat").unwrap();
        let parent = hub.resolve("parent").unwrap();
        hub.append(&child, "mux", "forked", json!({"parentId": "parent", "forkSeq": 0}));
        if receipt {
            hub.append(&parent, "mux", "fork_child", json!({"childId": "chat"}));
        }
        if child_import {
            hub.append(&child, "mux", "imported", json!({}));
        }
        if parent_import {
            hub.append(&parent, "mux", "imported", json!({}));
        }
        let allowed = receipt && !child_import && !parent_import;
        let page = handle(&hub, &transcript_request("wf_own")).await;
        assert_eq!(page.is_ok(), allowed, "{name}: {page:?}");
        if !allowed {
            let missing = handle(&hub, &transcript_request("wf_missing")).await.unwrap_err();
            assert_eq!(
                serde_json::to_vec(&page.unwrap_err()).unwrap(),
                serde_json::to_vec(&missing).unwrap()
            );
        }
        assert_eq!(hub.store.load("chat").unwrap().unwrap().fork_parent_verified, Some(allowed));
        let _ = std::fs::remove_dir_all(home);
    }
}

#[tokio::test]
async fn fork_transcript_imported_history_and_parent_never_grant_local_access() {
    let home = scoped_store("import-authority");
    let hub = transcript_hub(&home);
    let mut meta = serde_json::to_value(hub.resolve("chat").unwrap().meta()).unwrap();
    meta["id"] = json!("imported");
    meta["name"] = json!("imported");
    meta["agentSessionId"] = json!("imported-native");
    meta["previousAgentSessionIds"] = json!(["s1"]);
    meta["parentId"] = json!("chat");
    meta["forkSeq"] = json!(1);
    let bundle = home.join("bundle");
    std::fs::create_dir_all(&bundle).unwrap();
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    hub.import(&bundle, None).await.unwrap();
    let mut request = transcript_request("wf_own");
    request["sessionId"] = json!("imported");
    let imported = handle(&hub, &request).await.unwrap_err();
    request["runId"] = json!("wf_missing");
    let missing = handle(&hub, &request).await.unwrap_err();
    assert_eq!(serde_json::to_vec(&imported).unwrap(), serde_json::to_vec(&missing).unwrap());
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn fork_transcript_ancestry_has_a_depth_limit() {
    let home = scoped_store("depth");
    let hub = transcript_hub(&home);
    for n in 0..70 {
        replace_meta(
            &hub,
            &format!("ancestor-{n}"),
            json!({
                "agentSessionId": if n == 69 { "s1" } else { "empty" },
                "parentId": format!("ancestor-{}", n + 1), "forkSeq": 1
            }),
        );
    }
    replace_meta(
        &hub,
        "chat",
        json!({
            "agentSessionId": "child-new", "parentId": "ancestor-0", "forkSeq": 1
        }),
    );
    let missing = handle(&hub, &transcript_request("wf_missing")).await.unwrap_err();
    let too_deep = handle(&hub, &transcript_request("wf_own")).await.unwrap_err();
    assert_eq!(serde_json::to_vec(&too_deep).unwrap(), serde_json::to_vec(&missing).unwrap());
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn fork_transcript_skips_unreadable_ancestor_and_uses_each_ancestors_store() {
    let home = scoped_store("own-profile");
    let ancestor_home = scoped_store("ancestor-profile");
    let hub = transcript_hub(&home);
    replace_meta(&hub, "grandparent", json!({"harness": "ancestor-profile"}));
    replace_meta(
        &hub,
        "parent",
        json!({
            "harness": "unknown-profile", "parentId": "grandparent", "forkSeq": 1
        }),
    );
    replace_meta(
        &hub,
        "chat",
        json!({
            "agentSessionId": "child-new", "parentId": "parent", "forkSeq": 1
        }),
    );
    let mut profile = hub.config.read().await.harnesses["claude"].clone();
    profile.env.insert("CLAUDE_CONFIG_DIR".into(), ancestor_home.to_string_lossy().into());
    hub.config.write().await.harnesses.insert("ancestor-profile".into(), profile);
    write(&ancestor_home.join("projects/-work/s1/subagents/workflows/wf_grandparent"), "a01", 2);
    let page = handle(&hub, &transcript_request("wf_grandparent")).await.unwrap();
    assert_eq!(page["lines"], 3);
    let _ = std::fs::remove_dir_all(home);
    let _ = std::fs::remove_dir_all(ancestor_home);
}

#[cfg(unix)]
#[tokio::test]
async fn fork_transcript_ancestor_symlinks_are_refused_as_missing() {
    let home = scoped_store("ancestor-links");
    let hub = transcript_hub(&home);
    replace_meta(&hub, "parent", json!({}));
    replace_meta(
        &hub,
        "chat",
        json!({
            "agentSessionId": "child-new", "parentId": "parent", "forkSeq": 1
        }),
    );
    let workflows = home.join("projects/-work/s1/subagents/workflows");
    std::os::unix::fs::symlink(workflows.join("wf_own"), workflows.join("wf_link")).unwrap();
    let missing = handle(&hub, &transcript_request("wf_missing")).await.unwrap_err();
    let linked = handle(&hub, &transcript_request("wf_link")).await.unwrap_err();
    assert_eq!(serde_json::to_vec(&linked).unwrap(), serde_json::to_vec(&missing).unwrap());
    let _ = std::fs::remove_dir_all(home);
}

#[cfg(unix)]
#[test]
fn a_link_in_the_store_is_never_followed() {
    let home = store("links");
    let project = home.join("projects/-work");
    write(&home.join("elsewhere"), "a01", 2);
    let runs = project.join("s1/subagents/workflows/wf_x");
    std::fs::create_dir_all(&runs).unwrap();
    std::os::unix::fs::symlink(
        home.join("elsewhere/agent-a01.jsonl"),
        runs.join("agent-a01.jsonl"),
    )
    .unwrap();
    std::os::unix::fs::symlink(home.join("elsewhere"), project.join("s1/subagents/workflows/wf_y"))
        .unwrap();
    assert!(read(&[(home.clone(), "s1".into())], Some("wf_x"), "a01").is_err());
    assert!(read(&[(home.clone(), "s1".into())], Some("wf_y"), "a01").is_err());
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn ids_are_plain_names() {
    for bad in ["", "..", "a/b", "a.b", "a\\b", &"x".repeat(129)] {
        assert!(!plain_id(bad), "{bad}");
    }
    assert!(plain_id("a013d7b1c450e54d3") && plain_id("01a16c41-5f18-7b41"));
}

#[test]
fn pages_walk_back_and_forward_without_skipping_a_line() {
    assert_eq!(window(10, 4, None, None), (6, 10));
    assert_eq!(window(10, 4, Some(6), None), (2, 6));
    assert_eq!(window(10, 4, Some(2), None), (0, 2));
    assert_eq!(window(10, 4, None, Some(8)), (8, 10));
    assert_eq!(window(10, 4, None, Some(12)), (10, 10));
    let big = |n: usize| vec![json!({"text": "x".repeat(n)})];
    let lines = vec![big(3 << 20), big(3 << 20), big(10)];
    // Read back: the newest lines that fit; the older one is the next page's.
    let (start, end, updates) = fit(lines.clone(), 4, 7, false);
    assert_eq!((start, end, updates.len()), (5, 7, 2));
    // Read forward: the oldest lines that fit; the next read starts where this one ended.
    let (start, end, updates) = fit(lines, 4, 7, true);
    assert_eq!((start, end, updates.len()), (4, 5, 1));
}

#[test]
fn a_long_transcript_is_read_from_its_end() {
    let home = store("long");
    let dir = home.join("projects/-work/s1/subagents");
    std::fs::create_dir_all(&dir).unwrap();
    let line = json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "x".repeat(1 << 20)}]}}).to_string();
    let text: String = (0..40).map(|_| format!("{line}\n")).collect();
    std::fs::write(dir.join("agent-b09.jsonl"), text).unwrap();
    let (text, truncated) = read(&[(home.clone(), "s1".into())], None, "b09").unwrap();
    assert!(truncated);
    assert!(text.lines.len() < 40 && text.lines.len() >= 30, "{}", text.lines.len());
    let _ = std::fs::remove_dir_all(home);
}

/// A cut that falls just before a line keeps that line whole.
#[test]
fn a_cut_at_a_line_start_keeps_the_line() {
    let home = store("cut");
    let dir = home.join("projects/-work/s1/subagents");
    std::fs::create_dir_all(&dir).unwrap();
    // 40 lines of exactly 1 MiB each, newline included: the last 32 MiB start at a line.
    let head = r#"{"type":"assistant","message":{"content":[{"type":"text","text":""#;
    let tail = r#""}]}}"#;
    let pad = (1 << 20) - 1 - head.len() - tail.len();
    let line = format!("{head}{}{tail}\n", "x".repeat(pad));
    assert_eq!(line.len(), 1 << 20);
    std::fs::write(dir.join("agent-b10.jsonl"), line.repeat(40)).unwrap();
    let (text, truncated) = read(&[(home.clone(), "s1".into())], None, "b10").unwrap();
    assert!(truncated);
    assert_eq!(text.lines.len(), 32);
    assert!(text.message(0).is_object(), "the first line is whole");
    let _ = std::fs::remove_dir_all(home);
}

/// A line too large for any reply goes as a stub saying so, and the cursors move past it.
#[test]
fn a_line_too_large_for_a_reply_goes_as_a_stub() {
    let huge =
        vec![json!({"sessionUpdate": "tool_call_update", "text": "x".repeat(PAGE_BYTES + 10)})];
    let small = vec![json!({"sessionUpdate": "agent_message_chunk"})];
    let (start, end, updates) = fit(vec![huge, small], 7, 9, true);
    assert_eq!((start, end, updates.len()), (7, 9, 2));
    assert_eq!(updates[0]["sessionUpdate"], "omitted");
    assert_eq!(updates[0]["_meta"]["acpmux"]["omitted"]["reason"], "too_large");
}

/// The source parsed for a page is bounded: the page itself, then the lines replayed before it.
#[test]
fn a_page_parses_a_bounded_amount_of_the_transcript() {
    let mb: u32 = 1 << 20;
    let text =
        Text { bytes: Vec::new(), lines: (0..40u32).map(|n| (n * 6 * mb, 6 * mb - 1)).collect() };
    // Back from the end: three 6 MiB lines fit 16 MiB, so the page keeps its last two and
    // nothing more is replayed.
    let (start, end, from) = text.bounded(30, 40, false);
    assert_eq!((start, end, from), (38, 40, 38));
    let small = Text { bytes: Vec::new(), lines: (0..2000u32).map(|n| (n * 10, 9)).collect() };
    let (start, end, from) = small.bounded(1500, 1700, false);
    assert_eq!((start, end, from), (1500, 1700, 1500 - REPLAY_BEFORE));
}

/// One line bigger than a page is never parsed: it reads as nothing, and goes as a stub.
#[test]
fn a_huge_line_is_never_parsed() {
    let line = format!(
        r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":"{}"}}]}}}}"#,
        "x".repeat(PAGE_BYTES)
    );
    let text =
        Text { lines: vec![(0, u32::try_from(line.len()).unwrap())], bytes: line.into_bytes() };
    assert_eq!(text.message(0), Value::Null);
}

/// A file of very many short lines keeps only its last `INDEXED_LINES` lines, and says it.
#[test]
fn the_line_index_is_bounded() {
    let home = store("many");
    let dir = home.join("projects/-work/s1/subagents");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("agent-b11.jsonl"), "{}\n".repeat(INDEXED_LINES + 5)).unwrap();
    let (text, truncated) = read(&[(home.clone(), "s1".into())], None, "b11").unwrap();
    assert!(truncated);
    assert_eq!(text.lines.len(), INDEXED_LINES);
    let _ = std::fs::remove_dir_all(home);
}
