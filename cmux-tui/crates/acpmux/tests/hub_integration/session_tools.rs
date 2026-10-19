//! The session tools of the `cmux-sessions` MCP server (`session_mcp.rs`): an agent in one
//! chat starts another (in a new worktree), reads its reply, lists it as its own and sends it
//! a message, all over the real `acpmux offer-mcp` process on a daemon socket.

use super::*;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{ChildStdin, ChildStdout};

/// `hub` on a unix socket of its own; its path.
async fn listen(hub: &Arc<Hub>) -> std::path::PathBuf {
    let nonce = &uuid::Uuid::now_v7().simple().to_string()[20..];
    let path = std::path::PathBuf::from("/tmp").join(format!("acpmux-stools-{nonce}.sock"));
    let listener = acpmux::server::bind_unix(&path).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    path
}

struct Mcp {
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    next: i64,
    _process: tokio::process::Child,
}

/// The real `acpmux offer-mcp` of session `session`, with only the session tools.
fn spawn_mcp(scratch: &std::path::Path, socket: &std::path::Path, session: &str) -> Mcp {
    let mut child = crate::daemon_env::tokio_command(scratch, crate::daemon_env::Agents::Deny)
        .arg("offer-mcp")
        .env("PATH", crate::daemon_env::bare_path(&["git"]))
        .env("ACPMUX_SOCKET", socket)
        .env("ACPMUX_OFFER_SESSION", session)
        .env("ACPMUX_SESSION_TOOLS", "1")
        .env("ACPMUX_OFFER_TOOLS", "0")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    Mcp {
        stdin: child.stdin.take().unwrap(),
        lines: BufReader::new(child.stdout.take().unwrap()).lines(),
        next: 0,
        _process: child,
    }
}

/// Whether the chat `id` shows an unread mark.
fn unread(hub: &Hub, id: &str) -> bool {
    hub.session_summary(&hub.resolve(id).unwrap())["unread"] == json!(true)
}

/// A new chat of the person in `cwd`, and its id.
async fn new_chat(person: &mut TestClient, cwd: &str) -> String {
    person.request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": []})).await.unwrap()
        ["sessionId"]
        .as_str()
        .unwrap()
        .to_owned()
}

impl Mcp {
    async fn request(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.stdin.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.lines.next_line())
                .await
                .expect("offer-mcp timed out")
                .unwrap()
                .expect("offer-mcp closed");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                return reply["result"].clone();
            }
        }
    }

    async fn call(&mut self, name: &str, arguments: Value) -> Value {
        self.request("tools/call", json!({"name": name, "arguments": arguments})).await
    }
}

fn git(dir: &std::path::Path, args: &[&str]) {
    let ok = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .status()
        .unwrap()
        .success();
    assert!(ok, "git {args:?}");
}

#[cfg(unix)]
#[tokio::test]
async fn an_agent_starts_reads_lists_and_messages_another_session() {
    let (hub, mut person) = setup(PermissionPolicy::ApproveAll).await;
    let scratch = std::env::temp_dir().join(format!("amx-stools-{}", uuid::Uuid::now_v7()));
    let repo = scratch.join("Shop App");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
    let repo_path = repo.to_string_lossy().into_owned();
    // A hook the agent could write in its own repository: making the worktree never runs it.
    let ran = scratch.join("hook-ran");
    let hook = repo.join(".git/hooks/post-checkout");
    std::fs::create_dir_all(hook.parent().unwrap()).unwrap();
    std::fs::write(&hook, format!("#!/bin/sh\ntouch '{}'\n", ran.display())).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let parent = person
        .request(method::SESSION_NEW, json!({"cwd": repo_path, "mcpServers": []}))
        .await
        .unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let socket = listen(&hub).await;
    let mut mcp = spawn_mcp(&scratch, &socket, &parent);

    // The server names its rules once, and lists only the session tools while offers are off.
    let init = mcp.request("initialize", json!({"protocolVersion": "2025-06-18"})).await;
    let rules = init["instructions"].as_str().unwrap();
    assert!(rules.contains("start_session only when the user asked"), "{rules}");
    assert!(!rules.contains("offer_session"), "offers are off: {rules}");
    let tools = mcp.request("tools/list", json!({})).await;
    let names: Vec<&str> =
        tools["tools"].as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    assert_eq!(names, ["start_session", "list_sessions", "read_session", "send_to_session"]);

    // start_session: a new chat in its own worktree, its brief as an agent's message.
    let started = mcp
        .call(
            "start_session",
            json!({"prompt": "hello child", "title": "Child task", "worktree": true, "cwd": repo_path}),
        )
        .await;
    assert_eq!(started["isError"], false, "{started}");
    let child_id = started["structuredContent"]["sessionId"].as_str().unwrap().to_owned();
    let root = crate::daemon_env::home(&scratch).join(".cmux/worktrees/shop-app/child-task");
    assert_eq!(started["structuredContent"]["worktree"]["root"], json!(root), "{started}");
    assert_eq!(started["structuredContent"]["worktree"]["branch"], "cmux/child-task");
    let child_cwd = started["structuredContent"]["cwd"].as_str().unwrap();
    let canonical = |p: &std::path::Path| std::fs::canonicalize(p).unwrap();
    assert_eq!(canonical(child_cwd.as_ref()), canonical(&root), "{started}");
    let base = std::process::Command::new("git")
        .arg("-C")
        .arg(&repo)
        .args(["config", "branch.cmux/child-task.cmuxBase"])
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&base.stdout).trim(), "main");
    assert!(!ran.exists(), "the repository's post-checkout hook ran outside the agent's sandbox");

    // read_session waits for the turn and reads the reply.
    let read = mcp.call("read_session", json!({"session": child_id, "wait_seconds": 30})).await;
    assert_eq!(read["isError"], false, "{read}");
    assert!(
        read["structuredContent"]["replies"].to_string().contains("echo: hello child"),
        "{read}"
    );
    // Nobody looked at the child: starting it and reading it leave its turn unread.
    assert!(unread(&hub, &child_id), "start_session or read_session marked the child seen");

    let events = hub.events(&child_id, 0, 10_000).unwrap();
    let prompts: Vec<&Value> = events
        .iter()
        .filter(|e| e.kind == "user_message" && !e.msg["_meta"]["provenance"].is_null())
        .map(|e| &e.msg)
        .collect();
    assert_eq!(prompts.len(), 1, "the brief is one agent message: {prompts:?}");
    let provenance = &prompts[0]["_meta"]["provenance"];
    assert_eq!(provenance["kind"], "agent_message", "{prompts:?}");
    assert_eq!(provenance["from"], json!(parent), "{prompts:?}");

    // list_sessions: the child is this chat's, and this chat is not listed.
    let listed = mcp.call("list_sessions", json!({"mine": true})).await;
    let rows = listed["structuredContent"]["sessions"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "{listed}");
    assert_eq!(rows[0]["sessionId"], json!(child_id));
    assert_eq!(rows[0]["spawnedBy"], json!(parent), "{listed}");
    let all = mcp.call("list_sessions", json!({})).await;
    let all = all["structuredContent"]["sessions"].as_array().unwrap();
    assert!(all.iter().all(|s| s["sessionId"] != json!(parent)), "{all:?}");

    // send_to_session: the next prompt, read back.
    let sent = mcp.call("send_to_session", json!({"session": child_id, "text": "again"})).await;
    assert_eq!(sent["isError"], false, "{sent}");
    let read = mcp.call("read_session", json!({"session": child_id, "wait_seconds": 30})).await;
    assert!(read["structuredContent"]["replies"].to_string().contains("echo: again"), "{read}");
    assert!(unread(&hub, &child_id), "send_to_session or read_session marked the child seen");

    // A long reply comes back cut to 16 KiB, the cut marked.
    let long = "word ".repeat(6 * 1024);
    let sent = mcp.call("send_to_session", json!({"session": child_id, "text": long})).await;
    assert_eq!(sent["isError"], false, "{sent}");
    let read = mcp.call("read_session", json!({"session": child_id, "wait_seconds": 30})).await;
    let replies = read["structuredContent"]["replies"].as_array().unwrap();
    let last = replies.last().unwrap().as_str().unwrap();
    assert!(last.len() <= 16 * 1024 + 200, "a {} byte reply came back whole", last.len());
    assert!(last.contains("cut"), "the cut is not marked: {}", &last[..200.min(last.len())]);

    // The child messages the chat that started it; the parent's turn stays unread too.
    person.request("_acpmux/view", json!({"sessionId": parent, "visible": false})).await.unwrap();
    let mut child_mcp = spawn_mcp(&scratch, &socket, &child_id);
    child_mcp.request("initialize", json!({"protocolVersion": "2025-06-18"})).await;
    let up = child_mcp.call("send_to_session", json!({"session": parent, "text": "done"})).await;
    assert_eq!(up["isError"], false, "{up}");
    let read = child_mcp.call("read_session", json!({"session": parent, "wait_seconds": 30})).await;
    assert!(read["structuredContent"]["replies"].to_string().contains("echo: done"), "{read}");
    assert!(unread(&hub, &parent), "send_to_session or read_session marked the parent seen");

    // A key in another chat's text comes back masked from both reads.
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let sent = mcp
        .call("send_to_session", json!({"session": child_id, "text": format!("use {key}")}))
        .await;
    assert_eq!(sent["isError"], false, "{sent}");
    let read = mcp.call("read_session", json!({"session": child_id, "wait_seconds": 30})).await;
    let shown = read.to_string();
    assert!(shown.contains("[AWS access key]") && !shown.contains(&key), "{read}");
    let listed = mcp.call("list_sessions", json!({"mine": true})).await.to_string();
    assert!(!listed.contains(&key), "{listed}");

    // Refusals: this chat itself, a chat it did not start, a worktree on another host, a
    // missing brief.
    let other = new_chat(&mut person, &cwd()).await;
    let unrelated = mcp.call("send_to_session", json!({"session": other, "text": "hi"})).await;
    assert_eq!(unrelated["isError"], true, "{unrelated}");
    let own = mcp.call("send_to_session", json!({"session": parent, "text": "hi"})).await;
    assert_eq!(own["isError"], true, "{own}");
    let own = mcp.call("read_session", json!({"session": parent})).await;
    assert_eq!(own["isError"], true, "{own}");
    let remote = mcp
        .call("start_session", json!({"prompt": "x", "host": "big-red", "worktree": true}))
        .await;
    assert_eq!(remote["isError"], true, "{remote}");
    let empty = mcp.call("start_session", json!({"prompt": "  "})).await;
    assert_eq!(empty["isError"], true, "{empty}");
    let before = hub.all_session_summaries().len();
    assert_eq!(before, 3, "a refused start or send made no session");
    assert!(
        hub.events(&other, 0, 10_000).unwrap().iter().all(|e| e.kind != "user_message"),
        "the refused send reached no chat"
    );

    // Another chat's replies are not this chat's to read, and its preview is not listed.
    let words = "the stranger's private words";
    person
        .request(method::SESSION_PROMPT, json!({"sessionId": other, "text": words}))
        .await
        .unwrap();
    let theirs = mcp.call("read_session", json!({"session": other})).await;
    assert_eq!(theirs["isError"], true, "{theirs}");
    assert!(!theirs.to_string().contains(words), "{theirs}");
    let listed = mcp.call("list_sessions", json!({})).await;
    let row = listed["structuredContent"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == json!(other))
        .cloned()
        .unwrap_or_else(|| panic!("the other chat is listed: {listed}"));
    assert!(row["lastMessage"].is_null(), "{row}");
    assert!(!listed.to_string().contains(words), "{listed}");
    let mine = listed["structuredContent"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == json!(child_id))
        .cloned()
        .unwrap();
    assert!(!mine["lastMessage"].is_null(), "this chat's own child keeps its preview: {mine}");

    drop(mcp);
    drop(child_mcp);
    let _ = std::fs::remove_file(&socket);
    let _ = std::fs::remove_dir_all(&scratch);
}

/// A daemon with the trust gate's files in `scratch`, a chat of the person in `scratch/chat`,
/// and that chat's `offer-mcp`.
async fn chat_with_tools(scratch: &std::path::Path) -> (Arc<Hub>, TestClient, String, Mcp) {
    let (hub, mut person) = setup(PermissionPolicy::ApproveAll).await;
    let chat = scratch.join("chat");
    std::fs::create_dir_all(&chat).unwrap();
    hub.set_trust_gate(Some(acpmux::trust::Paths {
        claude_json: scratch.join("claude.json"),
        codex_config: scratch.join("codex.toml"),
        record: scratch.join("trust.json"),
        agent_home: None,
    }));
    let parent = new_chat(&mut person, &chat.to_string_lossy()).await;
    let socket = listen(&hub).await;
    let mut mcp = spawn_mcp(scratch, &socket, &parent);
    mcp.request("initialize", json!({"protocolVersion": "2025-06-18"})).await;
    (hub, person, parent, mcp)
}

/// The trust record's levels, keyed by each folder's canonical path.
fn record_trust(scratch: &std::path::Path, levels: &[(&std::path::Path, &str)]) {
    let record: serde_json::Map<String, Value> = levels
        .iter()
        .map(|(dir, level)| {
            let key = std::fs::canonicalize(dir).unwrap().to_string_lossy().into_owned();
            (key, json!(level))
        })
        .collect();
    std::fs::write(scratch.join("trust.json"), Value::Object(record).to_string()).unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn start_session_runs_only_where_the_person_trusts_and_never_laxer_than_the_caller() {
    let scratch = std::env::temp_dir().join(format!("amx-strust-{}", uuid::Uuid::now_v7()));
    let (hub, _person, _parent, mut mcp) = chat_with_tools(&scratch).await;
    let chat = scratch.join("chat");
    let elsewhere = scratch.join("elsewhere");
    let trusted = scratch.join("trusted");
    let marked = chat.join("marked");
    for dir in [&elsewhere, &trusted.join("deep"), &marked] {
        std::fs::create_dir_all(dir).unwrap();
    }
    record_trust(&scratch, &[(&trusted, "trusted"), (&marked, "untrusted")]);
    let start = |cwd: &std::path::Path| json!({"prompt": "hi", "cwd": cwd});

    // A folder outside this chat's that nobody trusted: the agent asks the person.
    let out = mcp.call("start_session", start(&elsewhere)).await;
    assert_eq!(out["isError"], true, "{out}");
    assert!(out.to_string().contains("Ask the user"), "{out}");
    // Inside this chat's folder, and inside a folder the person trusts: it starts.
    let inside = mcp.call("start_session", start(&chat)).await;
    assert_eq!(inside["isError"], false, "{inside}");
    let deep = mcp.call("start_session", start(&trusted.join("deep"))).await;
    assert_eq!(deep["isError"], false, "{deep}");
    // A folder the person marked untrusted, even inside this chat's.
    let out = mcp.call("start_session", start(&marked)).await;
    assert_eq!(out["isError"], true, "{out}");
    assert_eq!(hub.all_session_summaries().len(), 3, "a refused folder made no session");

    // A harness profile that skips every permission, from a chat that asks: refused.
    {
        let mut cfg = hub.config.write().await;
        let mut yolo = cfg.harnesses["fake"].clone();
        yolo.argv.push("--dangerously-skip-permissions".into());
        cfg.harnesses.insert("fake-yolo".into(), yolo);
    }
    let out = mcp.call("start_session", json!({"prompt": "hi", "harness": "fake-yolo"})).await;
    assert_eq!(out["isError"], true, "{out}");
    assert!(out.to_string().contains("full access"), "{out}");
    assert_eq!(hub.all_session_summaries().len(), 3, "the laxer harness left no session");

    // A trust record that cannot be read is no answer: nothing starts, even here.
    std::fs::write(scratch.join("trust.json"), "{not json").unwrap();
    let out = mcp.call("start_session", start(&chat)).await;
    assert_eq!(out["isError"], true, "{out}");
    assert_eq!(hub.all_session_summaries().len(), 3, "a damaged record made no session");

    drop(mcp);
    let _ = std::fs::remove_dir_all(&scratch);
}

#[cfg(unix)]
#[tokio::test]
async fn read_session_waits_at_most_fifty_seconds_a_call() {
    let scratch = std::env::temp_dir().join(format!("amx-swait-{}", uuid::Uuid::now_v7()));
    let (_hub, _person, _parent, mut mcp) = chat_with_tools(&scratch).await;
    let started = mcp.call("start_session", json!({"prompt": "hang"})).await;
    assert_eq!(started["isError"], false, "{started}");
    let child = started["structuredContent"]["sessionId"].as_str().unwrap().to_owned();
    // A harness's MCP client gives up on a call after about a minute (Codex: 60 s).
    let asked = std::time::Instant::now();
    let read = mcp.call("read_session", json!({"session": child, "wait_seconds": 600})).await;
    let took = asked.elapsed();
    assert!(took < Duration::from_secs(58), "one call waited {took:?}");
    assert_eq!(read["structuredContent"]["timedOut"], true, "{read}");
    assert!(read.to_string().contains("call read_session again"), "{read}");
    drop(mcp);
    let _ = std::fs::remove_dir_all(&scratch);
}
