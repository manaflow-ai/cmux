//! M20: a chat whose machine is paused reads and writes files with no resume
//! (`writeJournal.enabled`, `hub/paused_fs.rs`).

use super::*;
use acpmux::write_journal::paused::MachineResume;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};

#[derive(Default)]
struct CountingResume(AtomicUsize);

impl MachineResume for CountingResume {
    fn resume<'a>(
        &'a self,
        _: &'a str,
    ) -> Pin<Box<dyn Future<Output = std::io::Result<()>> + Send + 'a>> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { Ok(()) })
    }
}

async fn setup_journal() -> (Arc<Hub>, TestClient) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveEdits;
    cfg.write_journal.enabled = true;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client.become_person().await;
    (hub, client)
}

async fn say(hub: &Hub, c: &mut TestClient, id: &str, text: &str) -> String {
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
    )
    .await
    .unwrap();
    hub.session_summary(&hub.resolve(id).unwrap())["preview"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

#[tokio::test]
async fn a_paused_machine_answers_fs_reads_and_journals_writes_with_no_resume() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    std::fs::write(root.join("r.txt"), "one\ntwo\n").unwrap();
    let (hub, mut c) = setup_journal().await;
    let s = c
        .request(method::SESSION_NEW, json!({"cwd": root.to_string_lossy(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let resume = Arc::new(CountingResume::default());
    let report = hub.pause_machine("m1", &root, resume.clone()).await.unwrap();
    assert_eq!(report.files, 1);

    // The read comes from the replica: no resume.
    assert_eq!(say(&hub, &mut c, &id, "fsread: r.txt").await, "read: one two");
    // The write is journaled: the machine's folder does not have it yet, the agent reads it back.
    assert_eq!(say(&hub, &mut c, &id, "fswrite: a.txt").await, "wrote");
    assert!(!root.join("a.txt").exists());
    assert_eq!(say(&hub, &mut c, &id, "fsread: a.txt").await, "read: ok");
    assert_eq!(resume.0.load(Ordering::SeqCst), 0, "nothing resumed the machine");

    // On resume the journal is applied on the machine.
    let flushed = hub.machine_resumed_fs("m1").await.unwrap().unwrap();
    assert!(flushed.is_clean(), "{flushed:?}");
    assert_eq!(std::fs::read_to_string(root.join("a.txt")).unwrap(), "ok\n");
    // Running again: reads go to the machine's folder as before.
    std::fs::write(root.join("r.txt"), "three\n").unwrap();
    assert_eq!(say(&hub, &mut c, &id, "fsread: r.txt").await, "read: three");

    // A conflict at the next resume is the next file call's answer, once.
    hub.pause_machine("m1", &root, resume.clone()).await.unwrap();
    assert_eq!(say(&hub, &mut c, &id, "fswrite: r.txt").await, "wrote");
    std::fs::write(root.join("r.txt"), "saved on the machine\n").unwrap();
    let flushed = hub.machine_resumed_fs("m1").await.unwrap().unwrap();
    assert_eq!(flushed.conflicts.len(), 1);
    let told = say(&hub, &mut c, &id, "fsread: r.txt").await;
    assert!(told.starts_with("rejected:") && told.contains("changed on the machine"), "{told}");
    assert_eq!(say(&hub, &mut c, &id, "fsread: r.txt").await, "read: saved on the machine");
}

#[tokio::test]
async fn a_read_only_the_machine_can_answer_resumes_it_first() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_path_buf();
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::write(root.join(".git/HEAD"), "ref: main\n").unwrap();
    let (hub, mut c) = setup_journal().await;
    let s = c
        .request(method::SESSION_NEW, json!({"cwd": root.to_string_lossy(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let resume = Arc::new(CountingResume::default());
    hub.pause_machine("m1", &root, resume.clone()).await.unwrap();
    assert_eq!(say(&hub, &mut c, &id, "fsread: .git/HEAD").await, "read: ref: main");
    assert_eq!(resume.0.load(Ordering::SeqCst), 1);
    assert!(!hub.paused_fs().unwrap().is_paused("m1"));
}
