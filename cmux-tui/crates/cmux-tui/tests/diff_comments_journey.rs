//! Diff review comments go to the agent, end to end with real processes: a
//! headless cmux-tui daemon and its own acpmux running the test agent
//! (`acpmux/tests/fake_agent.py`), driven over their sockets.
//!
//! Two comments saved on a worktree root as the diff page saves them, the
//! second edited after the page read it, go to the chat as one
//! `diff.comments.send`: the chat gets exactly one user turn whose text is
//! the page's prompt, and the agent answers it; the comment still at its
//! read version is cleared, the edited one stays. The same send again under
//! its key replays the first answer and the chat still has one such turn. A
//! second daemon session sending another review to the same chat under the
//! same key delivers its own turn. A send to a session acpmux does not run is
//! refused and keeps the comments.
#![cfg(unix)]

mod journey_support;

/// One module, so `cargo test diff_comments_journey` selects these tests.
mod diff_comments_journey {
    use std::fs;
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::os::unix::net::UnixStream;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use super::journey_support::*;
    use serde_json::{Value, json};

    const ROOT: &str = "/work/app";
    const SEND_KEY: &str = "diff-comments-journey-send";

    /// The page's submission block for one comment (`commentSubmissionText`
    /// in webviews/src/comments/format.ts): the file and line, the quoted
    /// diff lines and the comment.
    fn submission(file: &str, line: u32, diff: &str, message: &str) -> String {
        format!(
            "Review comment on {file} line {line} (new version):\n\n```diff\n{diff}\n```\n\n{message}\n"
        )
    }

    /// The page's one prompt for a send (`commentsPromptText`): every block
    /// by file and line, trimmed, a blank line between.
    fn prompt_text(blocks: &[&str]) -> String {
        let blocks: Vec<_> = blocks.iter().map(|block| block.trim_end()).collect();
        format!("{}\n", blocks.join("\n\n"))
    }

    /// The prompt ids of the chat's finished turns, oldest first.
    fn turn_prompt_ids(events: &[Value]) -> Vec<String> {
        events
            .iter()
            .filter(|e| e["kind"] == "turn_result")
            .filter_map(|e| e["msg"]["promptId"].as_str().map(str::to_owned))
            .collect()
    }

    /// The diff page's comment (`DiffCommentSaveInput` in
    /// webviews/src/comments/types.ts).
    fn page_comment(file: &str, line: u32, text: &str, message: &str, diff: &str) -> Value {
        json!({
            "filePath": file,
            "side": "additions",
            "startLine": line,
            "endLine": line,
            "lineText": text,
            "message": message,
            "submissionText": submission(file, line, diff, message),
        })
    }

    /// A resource protocol v2 connection to the daemon's socket.
    struct Client {
        stream: BufReader<UnixStream>,
        next: u64,
    }

    impl Client {
        fn connect(socket: &Path) -> Self {
            let stream = UnixStream::connect(socket).unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
            Self { stream: BufReader::new(stream), next: 0 }
        }

        /// One request; a mutation goes under `key`.
        fn request(&mut self, operation: &str, mut params: Value, key: Option<&str>) -> Value {
            self.next += 1;
            let id = format!("r{}", self.next);
            params["machine"] = json!("current");
            params["session"] = json!("current");
            let mut request = json!({
                "protocol": "cmux.protocol/2",
                "type": "request",
                "id": id,
                "operation": operation,
                "params": params,
            });
            if let Some(key) = key {
                request["idempotency_key"] = json!(key);
            }
            writeln!(self.stream.get_mut(), "{request}").unwrap();
            loop {
                let mut line = String::new();
                assert_ne!(self.stream.read_line(&mut line).unwrap(), 0, "closed before {id}");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    return reply;
                }
            }
        }

        fn ok(&mut self, operation: &str, params: Value, key: &str) -> Value {
            let reply = self.request(operation, params, Some(key));
            assert_eq!(reply["ok"], true, "{operation} failed: {reply}");
            reply["result"].clone()
        }

        fn save(&mut self, comment: Value, key: &str) -> Value {
            let saved =
                self.ok("diff.comments.save", json!({"root": ROOT, "comment": comment}), key);
            saved["value"]["comment"].clone()
        }

        fn list(&mut self) -> Vec<Value> {
            let listed = self.request("diff.comments.list", json!({"root": ROOT}), None);
            assert_eq!(listed["ok"], true, "{listed}");
            listed["result"]["comments"].as_array().unwrap().clone()
        }
    }

    fn scratch() -> (PathBuf, Cleanup) {
        // A socket path must stay under SUN_LEN: a short folder under /tmp.
        let stamp =
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        let root = PathBuf::from("/tmp").join(format!("dcj-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        (root.clone(), Cleanup(root))
    }

    #[test]
    fn diff_comments_journey_sends_comments_to_the_agent_as_one_turn() {
        let (root, _cleanup) = scratch();
        let mac = Machine::start(&root, "mac", Vec::new());
        let identity = mac.rpc(json!({"id": 1, "cmd": "identify"}));
        let capabilities = identity["data"]["capabilities"].as_array().unwrap();
        assert!(capabilities.iter().any(|value| value == "diff-comments-send-v1"), "{identity}");

        let mut acpmux = mac.acpmux();
        let created =
            acpmux.call("session/new", json!({"cwd": mac.home().join("work"), "mcpServers": []}));
        let session = created["sessionId"].as_str().unwrap().to_owned();
        let mut client = Client::connect(&mac.socket);

        // Two comments, as the page saves them.
        let first = client.save(
            page_comment("src/lib.rs", 3, "let x = 1;", "rename x to count", "+let x = 1;"),
            "save-first",
        );
        let second = client.save(
            page_comment("src/main.rs", 10, "run();", "handle the error", "-run()\n+run();"),
            "save-second",
        );
        let (first_id, second_id) =
            (first["id"].as_str().unwrap().to_owned(), second["id"].as_str().unwrap().to_owned());

        // The page reads them, writes its prompt and keeps each version.
        let read = client.list();
        assert_eq!(read.len(), 2, "{read:?}");
        let blocks: Vec<&str> =
            read.iter().map(|comment| comment["submissionText"].as_str().unwrap()).collect();
        let text = prompt_text(&blocks);
        assert!(
            text.starts_with("Review comment on src/lib.rs line 3 (new version):\n\n```diff\n")
        );
        let versions: serde_json::Map<String, Value> = read
            .iter()
            .map(|comment| {
                (comment["id"].as_str().unwrap().to_owned(), comment["updatedAt"].clone())
            })
            .collect();

        // The second comment is edited after the page read it.
        std::thread::sleep(Duration::from_millis(5));
        let mut edit = page_comment("src/main.rs", 10, "run();", "handle it here", "+run();");
        edit["id"] = json!(second_id);
        let edited = client.save(edit, "save-second-edit");
        assert_ne!(edited["updatedAt"], versions[&second_id], "{edited}");

        // One send: one user turn in the chat, whose text is the prompt.
        let send = json!({
            "root": ROOT,
            "acp_session": session,
            "text": text,
            "ids": [first_id, second_id],
            "versions": versions,
        });
        let sent = client.ok("diff.comments.send", send.clone(), SEND_KEY);
        assert_eq!(sent["replayed"], false, "{sent}");
        assert_eq!(sent["value"], json!({"sent": 2, "cleared": [first_id]}), "{sent}");
        let events = wait_until(30, "the agent's answer to the review", || {
            let events = acpmux.events(&session);
            (!turn_prompt_ids(&events).is_empty()).then_some(events)
        });
        // The prompt id is the daemon's, derived from its session and the key, never the key.
        let prompt_ids = turn_prompt_ids(&events);
        assert_eq!(prompt_ids.len(), 1, "{events:?}");
        let prompt_id = prompt_ids[0].clone();
        assert!(prompt_id.starts_with("dcs_") && prompt_id != SEND_KEY, "{prompt_id}");
        assert_eq!(count(&events, "user_message", USER_TEXT, &text), 1, "{events:?}");
        let answer = format!("echo: {text}");
        assert_eq!(count(&events, "agent_message_chunk", AGENT_TEXT, &answer), 1, "{events:?}");

        // The edited comment stays, with its edit.
        let left = client.list();
        assert_eq!(left.len(), 1, "{left:?}");
        assert_eq!(left[0]["id"], json!(second_id));
        assert_eq!(left[0]["message"], "handle it here");

        // The same send again replays its first answer and sends nothing.
        let again = client.ok("diff.comments.send", send, SEND_KEY);
        assert_eq!(again["replayed"], true, "{again}");
        assert_eq!(again["value"], sent["value"], "{again}");
        // acpmux itself runs a prompt id once: a send whose answer was lost before the ledger
        // kept it is retried under the same key, and acpmux gets the same prompt id again.
        let mut resend = prompt(&session, &text, &prompt_id);
        resend["_meta"]["acpmux"]["resend"] = json!(true);
        acpmux.call("session/prompt", resend);
        let events = acpmux.events(&session);
        assert_eq!(count(&events, "user_message", USER_TEXT, &text), 1, "{events:?}");
        assert_eq!(turn_prompt_ids(&events), [prompt_id.as_str()], "the review's turns: {events:?}");

        // Another daemon session on this machine, with its own comments,
        // sends another review to the same chat under the same key: its
        // prompt id is its own, so acpmux runs it rather than answering it
        // as a duplicate, and its comments clear only because it arrived.
        let other = Machine {
            dir: mac.dir.clone(),
            socket: mac.dir.join("other.sock"),
            session: "diff-comments-journey-other".to_owned(),
            env: Vec::new(),
        };
        let ensured = other.server("ensure").output().unwrap();
        assert!(ensured.status.success(), "ensure: {}", String::from_utf8_lossy(&ensured.stderr));
        let mut other_client = Client::connect(&other.socket);
        let theirs = other_client.save(
            page_comment("src/other.rs", 7, "go();", "check the result", "+go();"),
            "save-other",
        );
        let theirs_id = theirs["id"].as_str().unwrap().to_owned();
        let other_read = other_client.list();
        let other_blocks: Vec<&str> =
            other_read.iter().map(|comment| comment["submissionText"].as_str().unwrap()).collect();
        let other_text = prompt_text(&other_blocks);
        assert_ne!(other_text, text);
        let other_send = json!({
            "root": ROOT,
            "acp_session": session,
            "text": other_text,
            "ids": [theirs_id],
        });
        let other_sent = other_client.ok("diff.comments.send", other_send, SEND_KEY);
        assert_eq!(other_sent["value"], json!({"sent": 1, "cleared": [theirs_id]}), "{other_sent}");
        let events = wait_until(30, "the agent's answer to the other session's review", || {
            let events = acpmux.events(&session);
            (turn_prompt_ids(&events).len() == 2).then_some(events)
        });
        let prompt_ids = turn_prompt_ids(&events);
        assert_ne!(prompt_ids[1], prompt_id, "each session's prompt id is its own: {events:?}");
        assert_eq!(count(&events, "user_message", USER_TEXT, &other_text), 1, "{events:?}");
        assert_eq!(count(&events, "user_message", USER_TEXT, &text), 1, "{events:?}");
        assert!(other_client.list().is_empty());
        let stopped = other.server("stop").output().unwrap();
        assert!(stopped.status.success(), "stop: {}", String::from_utf8_lossy(&stopped.stderr));
        std::mem::forget(other);

        // A session acpmux does not run gets nothing, and the comment stays.
        let elsewhere = json!({
            "root": ROOT,
            "acp_session": "fake-session-not-running",
            "text": "Review comment on src/main.rs line 10 (new version):\n\nhandle it here\n",
            "ids": [second_id],
        });
        let refused = client.request("diff.comments.send", elsewhere, Some("send-nowhere"));
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(refused["error"]["code"], "operation.failed", "{refused}");
        assert_eq!(refused["error"]["details"]["reason"], "no_session", "{refused}");
        let kept = client.list();
        assert_eq!(kept.len(), 1, "{kept:?}");
        assert_eq!(kept[0]["id"], json!(second_id));
    }
}
