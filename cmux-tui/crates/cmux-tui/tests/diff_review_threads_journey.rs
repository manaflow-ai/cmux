//! A whole review round trip in threads, end to end with real processes: a
//! headless cmux-tui daemon and its own acpmux running the test agent
//! (`acpmux/tests/fake_agent.py`), which answers a review as the prompt asks,
//! with `cmux git comments reply` in each thread.
//!
//! Three comments on two files (one on a range of lines), as the diff page
//! saves them, go to the chat as one threaded `diff.comments.send`: the chat
//! gets exactly one user turn naming every thread, and the agent's answer
//! lands in each thread, beside the comment. The reviewer then replies in one
//! thread and resolves another: the next threaded send of all three is again
//! one turn, carrying only what is new (the reply, and the resolve as needing
//! no answer), and the agent answers only the thread that asked. The same
//! send again under its key adds no turn, a send with nothing new sends
//! nothing, and the page saving a comment again keeps its thread.
#![cfg(unix)]

mod journey_support;

/// One module, so `cargo test diff_review_threads_journey` selects these tests. Its `cmux_next_` prefix puts them in
/// every push's `cmux_next_ daemon tests` (cmux-tui-artifacts.yml), not only the daily probe.
mod cmux_next_diff_review_threads_journey {
    use std::fs;
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::os::unix::net::UnixStream;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use super::journey_support::*;
    use serde_json::{Value, json};

    const ROOT: &str = "/work/app";
    const FIRST_SEND: &str = "diff-review-threads-send-1";
    const SECOND_SEND: &str = "diff-review-threads-send-2";

    /// The diff page's comment (`DiffCommentSaveInput` in
    /// webviews/src/comments/types.ts) on lines `start`..=`end`.
    fn page_comment(file: &str, start: u32, end: u32, text: &str, message: &str) -> Value {
        let place =
            if start == end { format!("line {start}") } else { format!("lines {start}-{end}") };
        json!({
            "filePath": file,
            "side": "additions",
            "startLine": start,
            "endLine": end,
            "lineText": text,
            "message": message,
            "submissionText": format!(
                "Review comment on {file} {place} (new version):\n\n```diff\n+{text}\n```\n\n{message}\n"
            ),
        })
    }

    /// The prompt ids of the chat's finished turns, oldest first.
    fn turn_prompt_ids(events: &[Value]) -> Vec<String> {
        events
            .iter()
            .filter(|e| e["kind"] == "turn_result")
            .filter_map(|e| e["msg"]["promptId"].as_str().map(str::to_owned))
            .collect()
    }

    /// The text of each user turn of the chat, oldest first.
    fn user_texts(events: &[Value]) -> Vec<String> {
        events
            .iter()
            .filter(|e| e["kind"] == "user_message")
            .filter_map(|e| e["msg"].pointer(USER_TEXT).and_then(Value::as_str).map(str::to_owned))
            .collect()
    }

    /// The thread's replies as `(author, text)`, oldest first.
    fn replies(comment: &Value) -> Vec<(String, String)> {
        comment["replies"]
            .as_array()
            .map(|replies| {
                replies
                    .iter()
                    .map(|reply| {
                        (
                            reply["author"].as_str().unwrap_or_default().to_owned(),
                            reply["text"].as_str().unwrap_or_default().to_owned(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default()
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

        fn save(&mut self, comment: Value, key: &str) -> String {
            let saved =
                self.ok("diff.comments.save", json!({"root": ROOT, "comment": comment}), key);
            saved["value"]["comment"]["id"].as_str().unwrap().to_owned()
        }

        /// The root's comments by id.
        fn threads(&mut self) -> serde_json::Map<String, Value> {
            let listed = self.request("diff.comments.list", json!({"root": ROOT}), None);
            assert_eq!(listed["ok"], true, "{listed}");
            listed["result"]["comments"]
                .as_array()
                .unwrap()
                .iter()
                .map(|comment| (comment["id"].as_str().unwrap().to_owned(), comment.clone()))
                .collect()
        }
    }

    fn scratch() -> (PathBuf, Cleanup) {
        // A socket path must stay under SUN_LEN: a short folder under /tmp.
        let stamp =
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        let root = PathBuf::from("/tmp").join(format!("drt-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        (root.clone(), Cleanup(root))
    }

    #[test]
    fn diff_review_threads_journey_round_trips_a_review_in_its_threads() {
        let (root, _cleanup) = scratch();
        // The agent answers through this daemon, with the cmux CLI under test.
        let socket = root.join("mac").join("mux.sock");
        let env = vec![
            ("FAKE_REVIEW_CMUX", bin().to_owned()),
            ("FAKE_REVIEW_SOCKET", socket.to_string_lossy().into_owned()),
        ];
        let mac = Machine::start(&root, "mac", env);
        let identity = mac.rpc(json!({"id": 1, "cmd": "identify"}));
        let capabilities = identity["data"]["capabilities"].as_array().unwrap();
        assert!(capabilities.iter().any(|value| value == "diff-comments-threads-v1"), "{identity}");

        let mut acpmux = mac.acpmux();
        let created =
            acpmux.call("session/new", json!({"cwd": mac.home().join("work"), "mcpServers": []}));
        let session = created["sessionId"].as_str().unwrap().to_owned();
        let mut client = Client::connect(&mac.socket);

        // A review across two files and several lines, as the page saves it.
        let range = client.save(
            page_comment("src/lib.rs", 5, 8, "fn parse() {", "split this function"),
            "save-range",
        );
        let line = client
            .save(page_comment("src/lib.rs", 3, 3, "let x = 1;", "rename x to count"), "save-line");
        let other = client
            .save(page_comment("src/main.rs", 10, 10, "run();", "handle the error"), "save-other");
        let all = [range.clone(), line.clone(), other.clone()];

        // One threaded send: one user turn naming every thread.
        let send = json!({"root": ROOT, "acp_session": session, "ids": all, "threads": true});
        let sent = client.ok("diff.comments.send", send.clone(), FIRST_SEND);
        assert_eq!(sent["replayed"], false, "{sent}");
        assert_eq!(sent["value"]["sent"], 3, "{sent}");
        assert_eq!(sent["value"]["cleared"], json!([]), "nothing is removed: {sent}");
        let events = wait_until(60, "the agent's answer to the review", || {
            let events = acpmux.events(&session);
            (turn_prompt_ids(&events).len() == 1).then_some(events)
        });
        assert_eq!(turn_prompt_ids(&events), [FIRST_SEND], "{events:?}");
        let turns = user_texts(&events);
        assert_eq!(turns.len(), 1, "one review, one turn: {turns:?}");
        let review = &turns[0];
        assert!(
            review.starts_with("Code review of /work/app: 3 threads across 2 files."),
            "{review}"
        );
        for id in &all {
            assert!(review.contains(&format!("## Thread {id}: ")), "{id} missing: {review}");
        }
        assert!(review.contains("src/lib.rs lines 5-8 (new version)"), "{review}");
        assert!(review.contains("split this function"), "{review}");

        // The agent's answer came back to each thread, beside its comment.
        let threads = client.threads();
        assert_eq!(threads.len(), 3, "{threads:?}");
        for id in &all {
            let thread = &threads[id];
            assert_eq!(
                replies(thread),
                [("agent".to_owned(), format!("answered {id}"))],
                "the agent's answer in {id}: {thread}"
            );
            assert_eq!(thread["sentIn"], FIRST_SEND, "{thread}");
        }

        // The reviewer answers back in one thread and resolves another.
        let reply = json!({"root": ROOT, "id": range, "reply": "still too long"});
        let replied = client.ok("diff.comments.thread", reply, "reviewer-reply");
        let after = replies(&replied["value"]["comment"]);
        assert_eq!(after.last().unwrap(), &("reviewer".to_owned(), "still too long".to_owned()));
        let resolve = json!({"root": ROOT, "id": line, "resolved": true});
        let resolved = client.ok("diff.comments.thread", resolve, "reviewer-resolve");
        assert_eq!(resolved["value"]["comment"]["resolved"], true, "{resolved}");

        // The next send of the whole review is one turn with only what is new.
        let next = json!({"root": ROOT, "acp_session": session, "ids": all, "threads": true});
        let sent = client.ok("diff.comments.send", next.clone(), SECOND_SEND);
        assert_eq!(sent["value"]["sent"], 2, "the reply and the resolve: {sent}");
        let events = wait_until(60, "the agent's answer to the follow-up", || {
            let events = acpmux.events(&session);
            (turn_prompt_ids(&events).len() == 2).then_some(events)
        });
        assert_eq!(turn_prompt_ids(&events), [FIRST_SEND, SECOND_SEND], "{events:?}");
        let turns = user_texts(&events);
        assert_eq!(turns.len(), 2, "{turns:?}");
        let follow_up = &turns[1];
        assert!(follow_up.starts_with("Code review of /work/app: 2 threads across 1 file."));
        assert!(follow_up.contains(&format!("## Thread {range}: ")), "{follow_up}");
        assert!(follow_up.contains("still too long"), "{follow_up}");
        assert!(follow_up.contains(&format!("answered {range}")), "its history: {follow_up}");
        assert!(follow_up.contains("it needs no answer"), "{follow_up}");
        assert!(!follow_up.contains(&format!("## Thread {other}")), "nothing new: {follow_up}");
        let threads = client.threads();
        let answered: Vec<_> = replies(&threads[&range]).into_iter().map(|(a, _)| a).collect();
        assert_eq!(answered, ["agent", "reviewer", "agent"], "{:?}", threads[&range]);
        assert_eq!(replies(&threads[&line]).len(), 1, "a resolve needs no answer");
        assert_eq!(replies(&threads[&other]).len(), 1, "{:?}", threads[&other]);

        // The same send again replays its answer and adds no turn.
        let again = client.ok("diff.comments.send", next, SECOND_SEND);
        assert_eq!(again["replayed"], true, "{again}");
        assert_eq!(again["value"], sent["value"], "{again}");
        // A send with nothing new for the agent sends nothing.
        let idle = json!({"root": ROOT, "acp_session": session, "ids": all, "threads": true});
        let refused = client.request("diff.comments.send", idle, Some("diff-review-threads-idle"));
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(refused["error"]["details"]["reason"], "nothing_to_send", "{refused}");
        std::thread::sleep(Duration::from_millis(500));
        let events = acpmux.events(&session);
        assert_eq!(turn_prompt_ids(&events).len(), 2, "{events:?}");
        assert_eq!(user_texts(&events).len(), 2, "{events:?}");

        // The page saving a comment again (it knows no replies) keeps its thread.
        let mut edit = page_comment("src/main.rs", 10, 10, "run();", "handle the error");
        edit["id"] = json!(other);
        client.save(edit, "save-other-again");
        let threads = client.threads();
        assert_eq!(replies(&threads[&other]).len(), 1, "{:?}", threads[&other]);
        assert_eq!(threads[&other]["sentIn"], FIRST_SEND, "{:?}", threads[&other]);
    }
}
