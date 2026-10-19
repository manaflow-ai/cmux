//! The session tools of the `cmux-sessions` MCP server (`session_mcp.rs`): an agent in one
//! chat starts another (in a new worktree), reads its reply, lists it as its own and sends it
//! a message, all over the real `acpmux offer-mcp` process on a daemon socket.

use super::*;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{ChildStdin, ChildStdout};

/// `hub` on a unix socket of its own; its path.
async fn listen(hub: &Arc<Hub>) -> std::path::PathBuf {
    let path =
        std::path::PathBuf::from("/tmp").join(format!("acpmux-stools-{}.sock", std::process::id()));
    let listener = acpmux::server::bind_unix(&path).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    path
}

struct Mcp {
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    next: i64,
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
    let mut child = crate::daemon_env::tokio_command(&scratch, crate::daemon_env::Agents::Deny)
        .arg("offer-mcp")
        .env("PATH", crate::daemon_env::bare_path(&["git"]))
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_OFFER_SESSION", &parent)
        .env("ACPMUX_SESSION_TOOLS", "1")
        .env("ACPMUX_OFFER_TOOLS", "0")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut mcp = Mcp {
        stdin: child.stdin.take().unwrap(),
        lines: BufReader::new(child.stdout.take().unwrap()).lines(),
        next: 0,
    };

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

    // Refusals: this chat itself, a chat it did not start, a worktree on another host, a
    // missing brief.
    let other =
        person.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap()
            ["sessionId"]
            .as_str()
            .unwrap()
            .to_owned();
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

    drop(mcp);
    let _ = std::fs::remove_file(&socket);
    let _ = std::fs::remove_dir_all(&scratch);
}
