//! A comment from every surface (the diff view, the browser pane, a terminal
//! selection) round-trips to the agent and back, end to end with real
//! processes: a headless cmux-tui daemon and its own acpmux running the test
//! agent (`acpmux/tests/fake_agent.py`), driven over their sockets.
//!
//! For each surface, the comment saved as its page saves it goes to the chat
//! as one `diff.comments.send` with `keep`: the chat gets exactly one user
//! turn whose text is the prompt, the comment stays with a `sent` thread
//! naming that prompt, and `diff.comments.list` then brings the agent's
//! answer back into the same comment's thread. A resend under the same key
//! adds no turn. A delete resolves the thread.
#![cfg(unix)]

mod journey_support;

mod comment_threads_journey {
    use std::fs;
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::os::unix::net::UnixStream;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use super::journey_support::*;
    use serde_json::{Value, json};

    const ROOT: &str = "/work/app";

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

        fn list(&mut self) -> Vec<Value> {
            let listed = self.request("diff.comments.list", json!({"root": ROOT}), None);
            assert_eq!(listed["ok"], true, "{listed}");
            listed["result"]["comments"].as_array().unwrap().clone()
        }
    }

    fn scratch() -> (PathBuf, Cleanup) {
        let stamp =
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        let root = PathBuf::from("/tmp").join(format!("ctj-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        (root.clone(), Cleanup(root))
    }

    /// Each surface's comment as its page saves it, and the prompt it sends.
    fn surfaces() -> Vec<(&'static str, Value, String)> {
        vec![
            (
                "diff",
                json!({"surface": "diff", "filePath": "src/lib.rs", "side": "additions",
                       "startLine": 3, "endLine": 3, "lineText": "let x = 1;",
                       "message": "rename x to count"}),
                "Review comment on src/lib.rs line 3 (new version):\n\nrename x to count\n".into(),
            ),
            (
                "browser",
                json!({"surface": "browser", "url": "http://localhost:5173/settings",
                       "title": "Settings", "selector": "main > button.save",
                       "quote": "Save", "message": "this button is clipped on narrow windows"}),
                "Comment on http://localhost:5173/settings (main > button.save, \"Save\"):\n\n\
                 this button is clipped on narrow windows\n"
                    .into(),
            ),
            (
                "terminal",
                json!({"surface": "terminal",
                       "terminal": {"id": "t1", "title": "cargo test", "cwd": "/work/app"},
                       "quote": "error[E0425]: cannot find value `count`",
                       "message": "why does this fail?"}),
                "Comment on terminal output (cargo test, /work/app):\n\n```\nerror[E0425]: cannot \
                 find value `count`\n```\n\nwhy does this fail?\n"
                    .into(),
            ),
        ]
    }

    #[test]
    fn comment_threads_journey_every_surface_gets_the_agents_reply_in_its_thread() {
        let (root, _cleanup) = scratch();
        let mac = Machine::start(&root, "mac", Vec::new());
        let identity = mac.rpc(json!({"id": 1, "cmd": "identify"}));
        let capabilities = identity["data"]["capabilities"].as_array().unwrap();
        assert!(capabilities.iter().any(|value| value == "comment-threads-v1"), "{identity}");

        let mut acpmux = mac.acpmux();
        let created =
            acpmux.call("session/new", json!({"cwd": mac.home().join("work"), "mcpServers": []}));
        let session = created["sessionId"].as_str().unwrap().to_owned();
        let mut client = Client::connect(&mac.socket);

        for (surface, comment, text) in surfaces() {
            let key = format!("comment-threads-journey-{surface}");
            let saved = client.ok(
                "diff.comments.save",
                json!({"root": ROOT, "comment": comment}),
                &format!("save-{surface}"),
            );
            let saved = saved["value"]["comment"].clone();
            let id = saved["id"].as_str().unwrap().to_owned();
            let send = json!({
                "root": ROOT,
                "acp_session": session,
                "text": text,
                "ids": [id],
                "versions": {id.clone(): saved["updatedAt"]},
                "keep": true,
            });
            let sent = client.ok("diff.comments.send", send.clone(), &key);
            assert_eq!(
                sent["value"],
                json!({"sent": 1, "cleared": [], "threaded": [id]}),
                "{surface}: {sent}"
            );

            // The comment stays, its thread naming the prompt it went out as.
            let listed = client.list();
            let mine = listed.iter().find(|c| c["id"] == json!(id)).unwrap();
            assert_eq!(mine["surface"], json!(surface), "{mine}");
            assert_eq!(mine["thread"]["promptId"], json!(key), "{mine}");
            assert_eq!(mine["updatedAt"], saved["updatedAt"], "a thread is not an edit: {mine}");

            // The agent's answer comes back to that same thread.
            let answered = wait_until(30, &format!("the {surface} thread's reply"), || {
                let listed = client.list();
                let mine = listed.iter().find(|c| c["id"] == json!(id))?.clone();
                (mine["thread"]["state"] != "sent").then_some(mine)
            });
            assert_eq!(answered["thread"]["state"], "answered", "{surface}: {answered}");
            let answer = format!("echo: {text}");
            assert_eq!(
                answered["thread"]["reply"]["text"],
                json!(answer.trim()),
                "{surface}: {answered}"
            );

            // One turn for the prompt, also after a resend under its key.
            let resent = client.ok("diff.comments.send", send, &key);
            assert_eq!(resent["replayed"], true, "{surface}: {resent}");
            let events = acpmux.events(&session);
            assert_eq!(count(&events, "user_message", USER_TEXT, &text), 1, "{surface}");

            // Resolving the thread is a delete.
            let resolved = client.ok(
                "diff.comments.delete",
                json!({"root": ROOT, "ids": [id]}),
                &format!("resolve-{surface}"),
            );
            assert_eq!(resolved["value"]["ids"], json!([id]), "{surface}: {resolved}");
            assert!(client.list().iter().all(|c| c["id"] != json!(id)), "{surface}");
        }
    }
}
