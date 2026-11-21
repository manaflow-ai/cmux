//! Who else works on these files (`touched.rs`), against two sessions of the fake agent in two
//! worktrees of one repository: each one's tool calls build its index, `_acpmux/who_else` finds
//! the other by the file they share, and an edit of a file the other edits steers a notice into
//! the other's running turn.

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

struct Fixture {
    hub: Arc<Hub>,
    dir: std::path::PathBuf,
    /// Two worktrees of one repository (origin `github.com/o/r`).
    main: std::path::PathBuf,
    linked: std::path::PathBuf,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

async fn fixture() -> Fixture {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", fake]}},
        "defaultHarness": "fake",
        // The inbox on, as a daemon has it by default: the gated turn is then the person's own,
        // which takes no other agent's steer but takes acpmux's own notice (`touched.rs`).
        "agentInbox": true,
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let dir = std::env::temp_dir().join(format!("acpmux-who-else-{}", uuid::Uuid::now_v7()));
    let main = dir.join("main");
    let common = main.join(".git");
    std::fs::create_dir_all(common.join("worktrees/linked")).unwrap();
    std::fs::write(common.join("config"), "[remote \"origin\"]\n\turl = git@github.com:o/r.git\n")
        .unwrap();
    std::fs::write(common.join("HEAD"), "ref: refs/heads/main\n").unwrap();
    std::fs::write(common.join("worktrees/linked/commondir"), "../..\n").unwrap();
    std::fs::write(common.join("worktrees/linked/HEAD"), "ref: refs/heads/lane/x\n").unwrap();
    let linked = dir.join("linked");
    std::fs::create_dir_all(linked.join("src")).unwrap();
    std::fs::create_dir_all(main.join("src")).unwrap();
    std::fs::write(
        linked.join(".git"),
        format!("gitdir: {}\n", common.join("worktrees/linked").display()),
    )
    .unwrap();
    for root in [&main, &linked] {
        std::fs::write(root.join("src/a.rs"), "fn a() {}\n").unwrap();
        std::fs::write(root.join("src/b.rs"), "fn b() {}\n").unwrap();
    }
    Fixture { hub, dir, main, linked }
}

impl Fixture {
    async fn session(&self, cwd: &std::path::Path) -> Arc<Session> {
        self.hub
            .new_session(NewRequest { cwd: Some(cwd.to_path_buf()), ..Default::default() })
            .await
            .unwrap()
    }

    /// A tool call of `session`'s agent, as the inbound loop applies it.
    fn tool_call(&self, session: &Arc<Session>, id: &str, kind: &str, path: &std::path::Path) {
        let params = json!({"sessionId": "agent", "update": {
            "sessionUpdate": "tool_call", "toolCallId": id, "kind": kind, "status": "completed",
            "locations": [{"path": path.to_str().unwrap()}],
        }});
        self.hub.on_update(session, Some(&params), false);
        self.hub.notice_overlaps(session);
    }

    fn diff_call(
        &self,
        session: &Arc<Session>,
        id: &str,
        path: &std::path::Path,
        start: u32,
        text: &str,
    ) {
        let path = path.to_str().unwrap();
        let params = json!({"sessionId": "agent", "update": {
            "sessionUpdate": "tool_call", "toolCallId": id, "kind": "edit", "status": "completed",
            "locations": [{"path": path}],
            "content": [{"type": "diff", "path": path, "newStart": start, "newText": text}],
        }});
        self.hub.on_update(session, Some(&params), false);
        self.hub.notice_overlaps(session);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn who_else_finds_the_session_that_edits_the_same_file_in_another_worktree() {
    let f = fixture().await;
    let a = f.session(&f.main).await;
    let b = f.session(&f.linked).await;
    f.tool_call(&b, "t1", "edit", &f.linked.join("src/a.rs"));
    f.tool_call(&b, "t2", "read", &f.linked.join("src/b.rs"));
    f.tool_call(&a, "t3", "read", &f.main.join("src/a.rs"));

    let b_files = b.meta().touched_files;
    assert_eq!(b_files.len(), 2);
    assert!(b_files.iter().any(|t| t.repo == "github.com/o/r" && t.path == "src/a.rs" && t.edited));

    // A asks with nothing named: its own recent files.
    let answer = f.hub.who_else(&json!({"sessionId": a.id}), true, false).await.unwrap();
    let rows = answer["sessions"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "{answer:#}");
    assert_eq!(rows[0]["sessionId"], json!(b.id));
    assert_eq!(rows[0]["editedInCommon"], 1);
    assert_eq!(rows[0]["files"][0]["path"], "src/a.rs");
    assert_eq!(rows[0]["branch"], "lane/x");

    // Raw files from the local socket, and keyed ones from anyone; a raw path from a remote
    // caller is refused, even beside a session whose own files would answer.
    let raw = json!({"files": [f.main.join("src/b.rs").to_str().unwrap()]});
    let local = f.hub.who_else(&raw, true, false).await.unwrap();
    assert_eq!(local["sessions"][0]["sessionId"], json!(b.id));
    let refused = f.hub.who_else(&raw, false, false).await.unwrap_err();
    assert!(refused.message.contains("name keys"), "{}", refused.message);
    let beside = json!({"sessionId": a.id, "files": raw["files"]});
    assert!(f.hub.who_else(&beside, false, false).await.is_err());
    let cwd = json!({"cwd": f.main.to_str().unwrap()});
    assert!(f.hub.who_else(&cwd, false, false).await.is_err());
    // A query beside a raw path does not let the path through unread.
    let with_query = json!({"files": raw["files"], "query": {"files": []}});
    assert!(f.hub.who_else(&with_query, false, false).await.is_err());
    let keyed = json!({"keys": [{"repo": "github.com/o/r", "path": "src/b.rs"}]});
    let remote = f.hub.who_else(&keyed, false, false).await.unwrap();
    assert_eq!(remote["sessions"][0]["sessionId"], json!(b.id));
    // A peer's forward is the query alone, and is answered.
    let forward = json!({"query": {"files": keyed["keys"]}, "peers": false});
    let answered = f.hub.who_else(&forward, false, true).await.unwrap();
    assert_eq!(answered["sessions"][0]["sessionId"], json!(b.id));
    // B is not someone else to itself.
    let own = json!({"sessionId": b.id, "keys": keyed["keys"]});
    assert_eq!(f.hub.who_else(&own, false, false).await.unwrap()["sessions"], json!([]));
}

#[tokio::test(flavor = "multi_thread")]
async fn overlapping_hunks_emit_one_durable_pair_event_and_ignore_other_ranges() {
    let f = fixture().await;
    let a = f.session(&f.main).await;
    let b = f.session(&f.linked).await;
    let mut events = f.hub.subscribe();

    // Same file, disjoint hunks: the index sees the shared file, but conflict radar stays quiet.
    f.diff_call(&b, "b-a-1", &f.linked.join("src/a.rs"), 10, "one\ntwo\n");
    f.diff_call(&a, "a-a-1", &f.main.join("src/a.rs"), 20, "three\n");
    // A different file is also not an overlap.
    f.diff_call(&a, "a-b-1", &f.main.join("src/b.rs"), 10, "four\n");
    while let Ok(event) = events.try_recv() {
        assert_ne!(event.record.kind, "worktree_overlap", "disjoint edits must stay quiet");
    }

    // The second edit intersects B's 10..11 hunk. Each session receives one durable record.
    f.diff_call(&a, "a-a-2", &f.main.join("src/a.rs"), 11, "five\n");
    let mut overlaps = Vec::new();
    while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_millis(200), events.recv()).await
    {
        if event.record.kind == "worktree_overlap" {
            overlaps.push(event);
            if overlaps.len() == 2 {
                break;
            }
        }
    }
    assert_eq!(overlaps.len(), 2, "expected one record per side: {overlaps:?}");
    assert!(overlaps.iter().all(|event| event.record.msg["files"][0]["path"] == "src/a.rs"));
    assert!(
        overlaps
            .iter()
            .all(|event| event.record.msg["files"][0]["ranges"][0]["mine"]["start"] == 11
                || event.record.msg["files"][0]["ranges"][0]["theirs"]["start"] == 11)
    );

    // Further edits in the same pair do not create a stream of duplicate chips.
    f.diff_call(&a, "a-a-3", &f.main.join("src/a.rs"), 11, "six\n");
    while let Ok(event) = events.try_recv() {
        assert_ne!(event.record.kind, "worktree_overlap", "a pair gets one durable event");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn file_only_edits_report_unknown_ranges_and_still_overlap_known_edits() {
    let f = fixture().await;
    let a = f.session(&f.main).await;
    let b = f.session(&f.linked).await;
    let mut events = f.hub.subscribe();

    // A path-only edit has no trustworthy line metadata. It must still overlap a known edit,
    // while the event keeps the unknown side explicit instead of fabricating line 1.
    f.tool_call(&b, "b-a-1", "edit", &f.linked.join("src/a.rs"));
    f.diff_call(&a, "a-a-1", &f.main.join("src/a.rs"), 20, "known\n");

    let mut overlaps = Vec::new();
    while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_millis(200), events.recv()).await
    {
        if event.record.kind == "worktree_overlap" {
            overlaps.push(event);
            if overlaps.len() == 2 {
                break;
            }
        }
    }
    assert_eq!(overlaps.len(), 2, "expected one record per side: {overlaps:?}");
    assert!(overlaps.iter().all(|event| {
        let range = &event.record.msg["files"][0]["ranges"][0];
        range["mine"] == json!(null) || range["theirs"] == json!(null)
    }));
}

#[tokio::test(flavor = "multi_thread")]
async fn two_file_only_edits_report_file_level_overlap() {
    let f = fixture().await;
    let a = f.session(&f.main).await;
    let b = f.session(&f.linked).await;
    let mut events = f.hub.subscribe();

    f.tool_call(&b, "b-a-1", "edit", &f.linked.join("src/a.rs"));
    f.tool_call(&a, "a-a-1", "edit", &f.main.join("src/a.rs"));

    let mut overlaps = Vec::new();
    while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_millis(200), events.recv()).await
    {
        if event.record.kind == "worktree_overlap" {
            overlaps.push(event);
            if overlaps.len() == 2 {
                break;
            }
        }
    }
    assert_eq!(overlaps.len(), 2, "expected one record per side: {overlaps:?}");
    assert!(overlaps.iter().all(|event| {
        let range = &event.record.msg["files"][0]["ranges"][0];
        range["mine"] == json!(null) && range["theirs"] == json!(null)
    }));
}

/// Waits until session `id` streams text containing `want`, and answers with that text.
#[cfg(unix)]
async fn said(
    events: &mut tokio::sync::broadcast::Receiver<HubEvent>,
    id: &str,
    want: &str,
) -> String {
    tokio::time::timeout(WAIT, async {
        loop {
            let e = events.recv().await.unwrap();
            let text = e.record.msg["params"]["update"]["content"]["text"].as_str();
            if e.session_id == id && text.is_some_and(|t| t.contains(want)) {
                return text.unwrap().to_owned();
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{id} never said {want:?}"))
}

// The turn waits on a FIFO gate (mkfifo is Unix-only).
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn an_edit_of_a_file_another_running_session_edits_steers_one_notice_into_its_turn() {
    let f = fixture().await;
    let a = f.session(&f.main).await;
    let b = f.session(&f.linked).await;
    let mut events = f.hub.subscribe();
    // B runs a turn until its gate opens.
    let fifo = f.dir.join("gate");
    let path = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let (hub, session) = (f.hub.clone(), b.clone());
    let text = format!("gate: {}", fifo.display());
    let turn = tokio::spawn(async move {
        hub.prompt(&session, vec![json!({"type": "text", "text": text})], "test", false).await
    });
    said(&mut events, &b.id, "before-gate").await;

    f.tool_call(&b, "t1", "edit", &f.linked.join("src/a.rs"));
    // A reads it: no notice, reading is not editing.
    f.tool_call(&a, "t2", "read", &f.main.join("src/a.rs"));
    assert!(b.overlaps_told.lock().unwrap().is_empty());
    // A edits it: B, whose turn runs, hears about A once.
    f.tool_call(&a, "t3", "edit", &f.main.join("src/a.rs"));
    let steer = said(&mut events, &b.id, "steer: [notice from acpmux who-else]").await;
    assert!(steer.contains("also edits a.rs"), "{steer}");
    assert!(steer.contains("acpmux send"), "{steer}");
    f.tool_call(&a, "t4", "edit", &f.main.join("src/a.rs"));
    assert_eq!(b.overlaps_told.lock().unwrap().len(), 1);
    // A ran no turn: it was told nothing, and hears at its next edit while it runs one.
    assert!(a.overlaps_told.lock().unwrap().is_empty());

    let fifo = f.dir.join("gate");
    tokio::task::spawn_blocking(move || std::fs::write(fifo, b"go")).await.unwrap().unwrap();
    turn.await.unwrap().unwrap();
}

// The turn waits on a FIFO gate (mkfifo is Unix-only).
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn a_notice_for_a_turn_that_ended_is_refused_not_steered_into_the_next() {
    let f = fixture().await;
    let b = f.session(&f.linked).await;
    let mut events = f.hub.subscribe();
    let fifo = f.dir.join("gate");
    let path = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let (hub, session) = (f.hub.clone(), b.clone());
    let text = format!("gate: {}", fifo.display());
    let turn = tokio::spawn(async move {
        hub.prompt(&session, vec![json!({"type": "text", "text": text})], "test", false).await
    });
    said(&mut events, &b.id, "before-gate").await;
    let notice = |turn_id: &str| {
        let mut provenance = crate::prompt_provenance::notice(
            &json!({"sender": NOTICE_SENDER, "severity": "info", "title": "t"}),
            &b.id,
        );
        set(&mut provenance, "kind", json!(NOTICE_KIND));
        notice_options(turn_id, "other", provenance)
    };
    let blocks = || vec![json!({"type": "text", "text": "[notice from acpmux who-else] t"})];

    // Built for a turn that has ended: the turn running now is another one, so it is refused.
    let stale = f.hub.prompt_with(&b, blocks(), "acpmux", true, notice("ended")).await;
    assert!(stale.is_err(), "{stale:?}");
    // Built for the running turn: steered into it.
    let running = b.turn().unwrap().turn_id;
    f.hub.prompt_with(&b, blocks(), "acpmux", true, notice(&running)).await.unwrap();
    said(&mut events, &b.id, "steer: [notice from acpmux who-else]").await;

    tokio::task::spawn_blocking(move || std::fs::write(fifo, b"go")).await.unwrap().unwrap();
    turn.await.unwrap().unwrap();
}
