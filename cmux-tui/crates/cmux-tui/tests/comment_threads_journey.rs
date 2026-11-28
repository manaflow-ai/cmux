//! A comment from every surface (the diff view, the browser pane, a terminal
//! selection) round-trips to the agent and back in its thread, end to end with
//! real processes: a headless cmux-tui daemon and its own acpmux running the
//! test agent (`acpmux/tests/fake_agent.py`), which answers each thread with
//! `cmux git comments reply`. (The diff view's follow-ups and replies in depth:
//! `diff_review_threads_journey.rs`.)
//!
//! Each comment, saved as its surface saves it (the diff page's line comment;
//! the browser's and terminal's `surface`, `place` and quoted block as
//! `submissionText`), goes to the chat in one threaded `diff.comments.send`:
//! the chat gets one user turn naming every thread, the agent's answer lands
//! in each thread, a resend under the key adds no turn, and resolving a thread
//! deletes it. cmuxterm-hq's comment-threads-journey probe runs this test by
//! name and reads the failing surface from its assert messages.
#![cfg(unix)]

use crate::journey_support;

/// One module, so `cargo test comment_threads_journey` selects these tests. Its `cmux_next_` prefix puts them in
/// every push's `cmux_next_ daemon tests` (cmux-tui-artifacts.yml), not only the daily probe.
mod cmux_next_comment_threads_journey {
    use std::fs;
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::os::unix::net::UnixStream;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use super::journey_support::*;
    use serde_json::{Value, json};

    const ROOT: &str = "/work/app";
    const SEND: &str = "comment-threads-journey-send";

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
        let root = PathBuf::from("/tmp").join(format!("ctj-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        (root.clone(), Cleanup(root))
    }

    /// The diff page's comment (webviews/src/comments/types.ts), the browser
    /// pane's and the terminal's (BrowserCommentThreads.swift,
    /// CommentThreads.swift), as each surface saves it.
    fn surface_comments() -> [(&'static str, Value); 3] {
        [
            (
                "diff",
                json!({"filePath": "src/count.rs", "side": "additions", "startLine": 3, "endLine": 3,
                   "lineText": "let total = count + 1;", "message": "count is never declared",
                   "submissionText": "Review comment on src/count.rs line 3 (new version):\n\n```diff\n+let total = count + 1;\n```\n\ncount is never declared\n"}),
            ),
            (
                "browser",
                json!({"surface": "browser", "place": "http://localhost:5173/settings",
                   "url": "http://localhost:5173/settings", "selector": "main > button.save",
                   "quote": "Save", "message": "this button is clipped on narrow windows",
                   "submissionText": "> **Browser** · http://localhost:5173/settings\n> `main > button.save` \"Save\"\n\nthis button is clipped on narrow windows"}),
            ),
            (
                "terminal",
                json!({"surface": "terminal", "place": "cargo test (/work/app)",
                   "terminal": {"id": "t1", "title": "cargo test", "cwd": "/work/app"},
                   "quote": "error[E0425]: cannot find value `count`", "message": "why does this fail?",
                   "submissionText": "> **Terminal · cargo test** (`/work/app`)\n> error[E0425]: cannot find value `count`\n\nwhy does this fail?"}),
            ),
        ]
    }

    #[test]
    fn comment_threads_journey_every_surface_gets_the_agents_reply_in_its_thread() {
        let (root, _cleanup) = scratch();
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

        let saved: Vec<(&str, String)> = surface_comments()
            .into_iter()
            .map(|(surface, comment)| (surface, client.save(comment, &format!("save-{surface}"))))
            .collect();
        let id = |surface: &str| saved.iter().find(|(s, _)| *s == surface).unwrap().1.clone();
        let (diff, browser, terminal) = (id("diff"), id("browser"), id("terminal"));
        let ids: Vec<&String> = saved.iter().map(|(_, id)| id).collect();

        let send = json!({"root": ROOT, "acp_session": session, "ids": ids, "threads": true});
        let sent = client.ok("diff.comments.send", send.clone(), SEND);
        assert_eq!(sent["value"]["sent"], 3, "{sent}");
        assert_eq!(sent["value"]["cleared"], json!([]), "nothing is removed: {sent}");
        let events = wait_until(60, "the agent's answers", || {
            let events = acpmux.events(&session);
            (turn_prompt_ids(&events).len() == 1).then_some(events)
        });
        let turns = user_texts(&events);
        assert_eq!(turns.len(), 1, "one send, one turn: {turns:?}");
        let prompt = &turns[0];
        assert!(
            prompt.starts_with("Code review of /work/app: 3 threads across 3 places."),
            "{prompt}"
        );
        assert!(
            prompt.contains(&format!("## Thread {diff}: src/count.rs line 3 (new version)\n")),
            "diff: {prompt}"
        );
        assert!(prompt.contains("count is never declared"), "diff: {prompt}");
        assert!(
            prompt.contains(&format!(
                "## Thread {browser}: browser page http://localhost:5173/settings\n"
            )),
            "browser: {prompt}"
        );
        assert!(prompt.contains("this button is clipped on narrow windows"), "browser: {prompt}");
        assert!(
            prompt.contains(&format!("## Thread {terminal}: terminal cargo test (/work/app)\n")),
            "terminal: {prompt}"
        );
        assert!(prompt.contains("> error[E0425]: cannot find value `count`"), "terminal: {prompt}");
        assert!(!prompt.contains("(no file)"), "{prompt}");

        // The agent's answer came back to each surface's thread.
        let threads = client.threads();
        for (surface, id) in &saved {
            let thread = &threads[id];
            assert_eq!(
                replies(thread),
                [("agent".to_owned(), format!("answered {id}"))],
                "the {surface} thread's reply: {thread}"
            );
            assert_eq!(thread["sentIn"], SEND, "the {surface} thread's reply: {thread}");
        }
        assert_eq!(threads[&browser]["surface"], "browser");
        assert_eq!(threads[&terminal]["terminal"]["id"], "t1");

        // A resend under the key adds no turn.
        let again = client.ok("diff.comments.send", send, SEND);
        assert_eq!(again["replayed"], true, "{again}");
        std::thread::sleep(Duration::from_millis(500));
        assert_eq!(user_texts(&acpmux.events(&session)).len(), 1);

        // Resolving a surface's thread deletes it.
        for id in &ids {
            let resolved = client.ok(
                "diff.comments.delete",
                json!({"root": ROOT, "ids": [id]}),
                &format!("resolve-{id}"),
            );
            assert_eq!(resolved["value"]["ids"], json!([id]), "{resolved}");
        }
        assert!(client.threads().is_empty());
    }

    /// A comment from a surface past the first three (the iOS app, a Cloud
    /// machine's session, a pull request comment, a Slack thread), as that
    /// surface saves it: `surface`, `place`, the quote and `submissionText`.
    fn place_comment(surface: &str, place: &str, quote: &str, message: &str) -> Value {
        json!({"surface": surface, "place": place, "quote": quote, "message": message,
               "submissionText": format!("> **{surface}** · {place}\n> {quote}\n\n{message}")})
    }

    /// One surface's round trip: its comment, saved, goes to the chat in one
    /// threaded send under its surface's label, the agent's answer lands in
    /// its thread, and resolving it deletes it.
    fn surface_round_trip(surface: &str, label: &str, place: &str) {
        let (root, _cleanup) = scratch();
        let socket = root.join("mac").join("mux.sock");
        let env = vec![
            ("FAKE_REVIEW_CMUX", bin().to_owned()),
            ("FAKE_REVIEW_SOCKET", socket.to_string_lossy().into_owned()),
        ];
        let mac = Machine::start(&root, "mac", env);
        let mut acpmux = mac.acpmux();
        let created =
            acpmux.call("session/new", json!({"cwd": mac.home().join("work"), "mcpServers": []}));
        let session = created["sessionId"].as_str().unwrap().to_owned();
        let mut client = Client::connect(&mac.socket);

        let message = format!("the {surface} comment needs an answer");
        let comment = place_comment(surface, place, "Sign in failed", &message);
        let id = client.save(comment, &format!("save-{surface}"));
        let key = format!("{SEND}-{surface}");
        let send = json!({"root": ROOT, "acp_session": session, "ids": [id], "threads": true});
        let sent = client.ok("diff.comments.send", send, &key);
        assert_eq!(sent["value"]["sent"], 1, "{surface}: {sent}");
        let events = wait_until(60, &format!("the agent's answer to the {surface} thread"), || {
            let events = acpmux.events(&session);
            (turn_prompt_ids(&events).len() == 1).then_some(events)
        });
        let turns = user_texts(&events);
        assert_eq!(turns.len(), 1, "{surface}: one send, one turn: {turns:?}");
        let prompt = &turns[0];
        assert!(prompt.starts_with("Code review of /work/app:"), "{surface}: {prompt}");
        assert!(
            prompt.contains(&format!("## Thread {id}: {label} {place}\n")),
            "{surface}: the thread is under its surface's label: {prompt}"
        );
        assert!(prompt.contains(&message), "{surface}: {prompt}");
        assert!(!prompt.contains("(no file)"), "{surface}: {prompt}");

        let threads = client.threads();
        let thread = &threads[&id];
        assert_eq!(thread["surface"], surface, "{surface}: {thread}");
        assert_eq!(thread["place"], place, "{surface}: {thread}");
        assert_eq!(
            replies(thread),
            [("agent".to_owned(), format!("answered {id}"))],
            "{surface}: the agent's reply: {thread}"
        );
        assert_eq!(thread["sentIn"], key, "{surface}: {thread}");
        // The agent answered, so nothing chases it.
        assert!(thread.get("stalled").is_none(), "{surface}: {thread}");

        let resolved = client.ok(
            "diff.comments.delete",
            json!({"root": ROOT, "ids": [id]}),
            &format!("resolve-{surface}"),
        );
        assert_eq!(resolved["value"]["ids"], json!([id]), "{surface}: {resolved}");
        assert!(client.threads().is_empty(), "{surface}: resolved");
    }

    #[test]
    fn ios_round_trip() {
        surface_round_trip("ios", "iOS app", "Chat fix-login (iPhone)");
    }

    #[test]
    fn cloud_round_trip() {
        surface_round_trip("cloud", "Cloud machine session", "cmux-vm-3 cargo build (/work/app)");
    }

    #[test]
    fn pr_round_trip() {
        surface_round_trip(
            "pr",
            "pull request comment",
            "https://github.com/acme/app/pull/7#discussion_r101",
        );
    }

    #[test]
    fn slack_round_trip() {
        surface_round_trip("slack", "Slack thread", "#eng 1732800000.123400");
    }

    /// The chase: an agent that takes two threads and answers neither gets
    /// them back with no person relaying them. One answered by hand after the
    /// send is never chased; the other is chased, each wait twice the last,
    /// and after three chases it is `stalled` and chased no more.
    #[test]
    fn chase_round_trip() {
        const BOUND_MS: u64 = 1500;
        let (root, _cleanup) = scratch();
        // No FAKE_REVIEW_CMUX: this agent never answers a thread itself.
        let env = vec![("CMUX_COMMENT_CHASE_BOUND_MS", BOUND_MS.to_string())];
        let mac = Machine::start(&root, "mac", env);
        let mut acpmux = mac.acpmux();
        let created =
            acpmux.call("session/new", json!({"cwd": mac.home().join("work"), "mcpServers": []}));
        let session = created["sessionId"].as_str().unwrap().to_owned();
        let mut client = Client::connect(&mac.socket);

        let answered = client.save(
            place_comment("ios", "Chat fix-login (iPhone)", "Sign in failed", "answered by hand"),
            "save-answered",
        );
        let ignored = client.save(
            place_comment("slack", "#eng 1732800000.123400", "deploy is red", "never answered"),
            "save-ignored",
        );
        let key = format!("{SEND}-chase");
        let send = json!({"root": ROOT, "acp_session": session,
                          "ids": [answered, ignored], "threads": true});
        let sent = client.ok("diff.comments.send", send, &key);
        assert_eq!(sent["value"]["sent"], 2, "{sent}");
        let threads = client.threads();
        assert_eq!(threads[&ignored]["sentTo"], session.as_str(), "chase: {}", threads[&ignored]);

        // The agent's own CLI answers one thread inside the bound.
        let reply = mac
            .command()
            .env("CMUX_TUI_SOCKET", &mac.socket)
            .args(["git", "comments", "reply", &answered, "--root", ROOT])
            .args(["--text", "looking at it", "--json"])
            .output()
            .unwrap();
        assert!(reply.status.success(), "reply: {}", String::from_utf8_lossy(&reply.stderr));

        let chase_ids = |events: &[Value]| -> Vec<String> {
            turn_prompt_ids(events).into_iter().filter(|id| id.starts_with("dchase_")).collect()
        };
        // Three chases: at 1, 3 and 7 bounds after the send.
        let events = wait_until(120, "three chases of the unanswered thread", || {
            let events = acpmux.events(&session);
            (chase_ids(&events).len() >= 3).then_some(events)
        });
        let ids = chase_ids(&events);
        assert_eq!(ids.len(), 3, "chase: {ids:?}");
        let mut unique = ids.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), 3, "chase: each chase its own prompt: {ids:?}");
        let chases: Vec<String> = user_texts(&events)
            .into_iter()
            .filter(|text| text.contains("you took has no answer in it yet"))
            .collect();
        assert_eq!(chases.len(), 3, "chase: {chases:?}");
        for text in &chases {
            assert!(text.starts_with("1 review thread you took"), "chase: {text}");
            assert!(text.contains(&format!("- Thread {ignored} ")), "chase: {text}");
            assert!(text.contains("never answered"), "chase: {text}");
            assert!(!text.contains(&answered), "chase: an answered thread is not chased: {text}");
            assert!(text.contains("cmux git comments reply"), "chase: {text}");
        }

        let threads = wait_until(30, "the chased thread stalled", || {
            let threads = client.threads();
            (threads[&ignored]["stalled"] == true).then_some(threads)
        });
        assert_eq!(threads[&ignored]["chases"], 3, "chase: {}", threads[&ignored]);
        assert!(threads[&answered].get("stalled").is_none(), "chase: {}", threads[&answered]);
        // The send marks both awaiting (`chases: 0`); the answered one is never chased.
        assert_eq!(threads[&answered]["chases"], 0, "chase: {}", threads[&answered]);

        // A stalled thread is chased no more.
        std::thread::sleep(Duration::from_millis(2 * BOUND_MS));
        assert_eq!(chase_ids(&acpmux.events(&session)).len(), 3, "chase: no fourth chase");
    }
}
