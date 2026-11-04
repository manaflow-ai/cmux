//! The host's tests: questions, saved approvals, the local dialog and reload.

use super::*;
use crate::approval::{Question as Ask, Target};

fn core() -> Arc<HostCore> {
    let scratch = std::env::temp_dir().join(format!("cmux-rh-core-{}", std::process::id()));
    let bootstrap = Bootstrap::parse(&json!({"supervisor_secret": "00".repeat(32)})).unwrap();
    HostCore::new(bootstrap, Layout { dir: scratch.join("rh") }, scratch.join("state"), None)
}

#[tokio::test]
async fn with_no_collector_a_question_is_answered_unavailable_and_forgotten() {
    let core = core();
    let request = ApprovalRequest::new(
        Ask {
            client: "c".into(),
            machine: "m".into(),
            session: "s".into(),
            agent: "a".into(),
            workspace: "w".into(),
            target: Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() },
            tool: "click".into(),
            risk: "R1".into(),
        },
        crate::approval::now_ms(),
    )
    .unwrap();
    core.worker_asked(1, &json!({"type": "app_approval", "id": 7, "request": request.to_value()}));
    for _ in 0..10 {
        tokio::task::yield_now().await;
    }
    assert!(lock(&core.questions).is_empty(), "the unanswerable question is delivered, not leaked");
}

/// A core with its own state, so tests do not share a saved list.
fn core_named(name: &str) -> Arc<HostCore> {
    let scratch = std::env::temp_dir().join(format!("cmux-rh-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    let bootstrap = Bootstrap::parse(&json!({"supervisor_secret": "00".repeat(32)})).unwrap();
    HostCore::new(bootstrap, Layout { dir: scratch.join("rh") }, scratch.join("state"), None)
}

fn request_for(executable: &str) -> ApprovalRequest {
    let name = executable.rsplit('/').next().unwrap_or(executable).to_owned();
    ApprovalRequest::new(
        Ask {
            client: "c".into(),
            machine: "m".into(),
            session: "s".into(),
            agent: "a".into(),
            workspace: "w".into(),
            target: Target { bundle_id: None, executable: Some(executable.into()), name },
            tool: "click".into(),
            risk: "R1".into(),
        },
        crate::approval::now_ms(),
    )
    .unwrap()
}

/// A question the host routes, without collectors running for it.
fn pending(core: &HostCore, id: u64, executable: &str) -> ApprovalRequest {
    let request = request_for(executable);
    lock(&core.questions).insert(id, Question { request: request.clone(), generation: 1, task: None });
    request
}

/// A revoke-all and an Always that race must never bring back an app the
/// revoke removed (each reads, changes and writes the whole saved list).
#[test]
fn a_revoke_all_is_never_undone_by_a_concurrent_always() {
    let core = core_named("revoke-race");
    let old = Target { bundle_id: None, executable: Some("/usr/bin/old-app".into()), name: "old-app".into() };
    for round in 0..300_u64 {
        core.write_saved(std::slice::from_ref(&old));
        let request = pending(&core, round, "/usr/bin/gedit");
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let always = std::thread::spawn({
            let (core, barrier) = (Arc::clone(&core), Arc::clone(&barrier));
            move || {
                barrier.wait();
                let answer = ApproverDecision { decision: Decision::Always, digest: request.digest, via: "polkit".into() };
                core.deliver(round, Some(answer));
            }
        });
        let revoke = std::thread::spawn({
            let (core, barrier) = (Arc::clone(&core), Arc::clone(&barrier));
            move || {
                barrier.wait();
                core.revoke(&Value::Null, &json!({"all": true}))
            }
        });
        always.join().unwrap();
        revoke.join().unwrap();
        let saved = core.saved_apps();
        assert!(!saved.iter().any(|app| app.key() == old.key()), "round {round}: the revoke-all was undone: {saved:?}");
    }
}

/// Records what each prompt offered; the person never answers.
#[derive(Default)]
struct Offers(Mutex<Vec<Decision>>);

#[async_trait::async_trait]
impl crate::approver::LocalCollector for Offers {
    fn name(&self) -> &'static str {
        "offers"
    }
    async fn ask(&self, _request: &ApprovalRequest, offered: Decision) -> Option<ApproverDecision> {
        lock(&self.0).push(offered);
        None
    }
}

/// `computer_use.approvals.prompt` is open to any local caller: it never
/// lets the caller choose Always (only the dialog's own choices), and one
/// question is shown at most once per cooldown.
#[tokio::test(start_paused = true)]
async fn a_prompt_never_offers_always_and_cools_down_per_question() {
    let core = core_named("prompt");
    let offers = Arc::new(Offers::default());
    lock(&core.collectors).local = Some(offers.clone());
    let request = pending(&core, 3, "/usr/bin/gedit");
    let id = short_id(&request.digest);
    let prompt = |params: Value| {
        let core = Arc::clone(&core);
        async move { core.handle(&json!(1), "computer_use.approvals.prompt", &params).await }
    };
    let always = prompt(json!({"id": id, "decision": "always"})).await;
    assert_eq!(always["ok"], false, "{always}");
    assert!(lock(&offers.0).is_empty(), "the caller cannot offer always: {:?}", lock(&offers.0));

    prompt(json!({"id": id})).await;
    assert_eq!(lock(&offers.0).as_slice(), &[Decision::Session]);
    let again = prompt(json!({"id": id})).await;
    assert_eq!(again.pointer("/error/code"), Some(&json!("cooldown")), "{again}");
    assert_eq!(lock(&offers.0).len(), 1);

    tokio::time::advance(Duration::from_secs(11)).await;
    prompt(json!({"id": id, "decision": "once"})).await;
    assert_eq!(lock(&offers.0).as_slice(), &[Decision::Session, Decision::Once]);
}

#[test]
fn a_windows_supervisor_must_be_the_daemon_process_not_just_its_image() {
    use crate::platform::ProcessStamp;
    let bootstrap = Bootstrap::parse(&json!({"supervisor_secret": "00".repeat(32), "daemon_pid": 40, "daemon_start": 777})).unwrap();
    let daemon = ProcessStamp { pid: 40, start: 777 };
    assert!(windows_daemon_peer(&bootstrap, true, Some(daemon), false));
    // Another process running the same executable.
    assert!(!windows_daemon_peer(&bootstrap, true, Some(ProcessStamp { pid: 41, start: 900 }), false));
    // The daemon's pid, reused by a later process.
    assert!(!windows_daemon_peer(&bootstrap, true, Some(ProcessStamp { pid: 40, start: 778 }), false));
    // The right process but another image, or a gone process.
    assert!(!windows_daemon_peer(&bootstrap, false, Some(daemon), false));
    assert!(!windows_daemon_peer(&bootstrap, true, None, true));
    // A handoff's new daemon serves the daemon socket.
    assert!(windows_daemon_peer(&bootstrap, true, Some(ProcessStamp { pid: 41, start: 900 }), true));
    // An old daemon's bootstrap without the pid: only the socket's server.
    let old = Bootstrap::parse(&json!({"supervisor_secret": "00".repeat(32)})).unwrap();
    assert!(!windows_daemon_peer(&old, true, Some(daemon), false));
}

#[tokio::test]
async fn a_forged_request_is_refused_without_asking() {
    let core = core();
    core.worker_asked(1, &json!({"type": "app_approval", "id": 8, "request": {"v": 1, "digest": "00"}}));
    assert!(lock(&core.questions).is_empty());
}
