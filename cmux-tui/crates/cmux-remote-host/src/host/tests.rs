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
    lock(&core.questions).insert(id, Question::new(request.clone(), 1));
    request
}

/// What the worker's saved list becomes from the host's control lines, in order.
fn apply_to_worker(view: &mut Vec<String>, message: &Value, always_target: &Target) {
    match message["type"].as_str() {
        Some("approved_apps") => {
            *view = message["apps"].as_array().unwrap().iter().filter_map(Target::from_app_entry).map(|app| app.key()).collect();
        }
        Some("revoke") if message["scope"] == "all" => view.clear(),
        Some("revoke") => {
            let app = Target::from_app_entry(&message["app"]).unwrap();
            view.retain(|key| *key != app.key());
        }
        Some("app_approval") if message["decision"] == "always" && !view.contains(&always_target.key()) => {
            view.push(always_target.key());
        }
        _ => {}
    }
}

/// A revoke-all and an Always that race must never bring back an app the
/// revoke removed (each reads, changes and writes the whole saved list), and
/// the worker must end with the list the file has: each change is told to it
/// in the order it reached the file.
#[test]
fn a_revoke_all_is_never_undone_by_a_concurrent_always() {
    let core = core_named("revoke-race");
    let mut to_worker = core.worker.attach_for_test(1);
    let old = Target { bundle_id: None, executable: Some("/usr/bin/old-app".into()), name: "old-app".into() };
    let gedit = Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() };
    for round in 0..300_u64 {
        core.write_saved(std::slice::from_ref(&old));
        while to_worker.try_recv().is_ok() {}
        let mut worker_view = vec![old.key()];
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
        while let Ok(message) = to_worker.try_recv() {
            apply_to_worker(&mut worker_view, &message, &gedit);
        }
        let file: Vec<String> = saved.iter().map(Target::key).collect();
        assert_eq!(worker_view, file, "round {round}: the worker's list is not the file's");
    }
}

/// The worker that starts gets the saved list as it is under the lock.
#[test]
fn a_starting_worker_gets_the_saved_list() {
    let core = core_named("ready");
    let mut to_worker = core.worker.attach_for_test(4);
    let gedit = Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() };
    core.write_saved(std::slice::from_ref(&gedit));
    core.worker.dispatch(&core, 4, &[0; 16], 0, json!({"type": "ready", "socket": "/nowhere"}));
    let first = to_worker.try_recv().unwrap();
    assert_eq!(first["type"], "approved_apps");
    assert_eq!(first["apps"][0]["executable"], "/usr/bin/gedit");
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

/// A local collector whose dialog stays up until the question ends: it
/// records which question each dialog showed and when each closed.
#[derive(Default)]
struct Dialogs {
    shown: Mutex<Vec<String>>,
    closed: Mutex<Vec<String>>,
    open: std::sync::atomic::AtomicUsize,
    most_open: std::sync::atomic::AtomicUsize,
}

struct Closes<'a>(&'a Dialogs, String);

impl Drop for Closes<'_> {
    fn drop(&mut self) {
        self.0.open.fetch_sub(1, Ordering::SeqCst);
        lock(&self.0.closed).push(std::mem::take(&mut self.1));
    }
}

#[async_trait::async_trait]
impl crate::approver::LocalCollector for Dialogs {
    fn name(&self) -> &'static str {
        "dialogs"
    }
    async fn ask(&self, request: &ApprovalRequest, _offered: Decision) -> Option<ApproverDecision> {
        lock(&self.shown).push(request.digest.clone());
        let open = self.open.fetch_add(1, Ordering::SeqCst) + 1;
        self.most_open.fetch_max(open, Ordering::SeqCst);
        let _closes = Closes(self, request.digest.clone());
        std::future::pending::<()>().await;
        None
    }
}

async fn settle() {
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
}

/// polkit's dialog cannot name the question: the host shows one at a time,
/// `pending` marks the one on screen, `prompt` is refused while it is up, and
/// a question that ends closes its dialog so the next one shows.
#[tokio::test]
async fn one_local_dialog_at_a_time_and_pending_marks_it() {
    let core = core_named("one-dialog");
    let dialogs = Arc::new(Dialogs::default());
    lock(&core.collectors).local = Some(dialogs.clone());
    let first = request_for("/usr/bin/gedit");
    let second = request_for("/usr/bin/xed");
    core.worker_asked(1, &json!({"type": "app_approval", "id": 1, "request": first.to_value()}));
    core.worker_asked(1, &json!({"type": "app_approval", "id": 2, "request": second.to_value()}));
    settle().await;
    assert_eq!(lock(&dialogs.shown).as_slice(), std::slice::from_ref(&first.digest), "only the first dialog is up");

    let pending = core.handle(&json!(1), "computer_use.approvals.pending", &json!({})).await;
    assert_eq!(pending["result"]["on_screen"], json!(short_id(&first.digest)), "{pending}");
    let marks: Vec<(String, bool)> = pending["result"]["pending"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| (entry["id"].as_str().unwrap().to_owned(), entry["on_screen"] == true))
        .collect();
    assert!(marks.contains(&(short_id(&first.digest), true)) && marks.contains(&(short_id(&second.digest), false)), "{marks:?}");

    let refused = core.handle(&json!(2), "computer_use.approvals.prompt", &json!({"id": short_id(&second.digest)})).await;
    assert_eq!(refused.pointer("/error/code"), Some(&json!("dialog_up")), "{refused}");

    // The first question ends (the worker withdrew it): its dialog closes, the next shows.
    core.worker_cancelled(&json!({"id": 1}));
    settle().await;
    assert_eq!(lock(&dialogs.closed).as_slice(), std::slice::from_ref(&first.digest));
    assert_eq!(lock(&dialogs.shown).as_slice(), &[first.digest.clone(), second.digest.clone()]);
    assert_eq!(dialogs.most_open.load(Ordering::SeqCst), 1, "never two dialogs at once");
    let pending = core.handle(&json!(3), "computer_use.approvals.pending", &json!({})).await;
    assert_eq!(pending["result"]["on_screen"], json!(short_id(&second.digest)), "{pending}");
}

/// A dialog `prompt` opened closes when its question ends meanwhile, and the
/// caller hears that it ended (its answer, if any, is ignored).
#[tokio::test]
async fn a_prompted_dialog_closes_when_its_question_ends() {
    let core = core_named("prompt-ends");
    let dialogs = Arc::new(Dialogs::default());
    lock(&core.collectors).local = Some(dialogs.clone());
    let request = pending(&core, 5, "/usr/bin/gedit");
    let prompting = tokio::spawn({
        let core = Arc::clone(&core);
        let id = short_id(&request.digest);
        async move { core.handle(&json!(1), "computer_use.approvals.prompt", &json!({"id": id})).await }
    });
    settle().await;
    assert_eq!(lock(&dialogs.shown).len(), 1, "the dialog is up");
    core.deliver(5, None);
    let answer = prompting.await.unwrap();
    assert_eq!(answer.pointer("/error/code"), Some(&json!("ended")), "{answer}");
    assert_eq!(lock(&dialogs.closed).as_slice(), std::slice::from_ref(&request.digest));
    assert!(lock(&core.collectors).dialog.showing().is_none());
}

/// A restarted worker numbers its questions from 1 again: the old ones'
/// prompt cooldowns must not hold its new questions back.
#[test]
fn a_restarted_worker_starts_with_no_prompt_cooldowns() {
    let core = core_named("cooldowns");
    pending(&core, 3, "/usr/bin/gedit");
    lock(&core.prompted).insert(3, tokio::time::Instant::now());
    core.worker_gone(1);
    assert!(lock(&core.prompted).is_empty());
}

/// Status reports the config in force, and whether the file differs; a
/// reload puts the file in force and ends the questions asked under the old one.
#[tokio::test]
async fn status_reports_the_config_in_force_until_a_reload() {
    let core = core_named("reload");
    *lock(&core.config) = Arc::new(Err("an older reading".into()));
    pending(&core, 9, "/usr/bin/gedit");
    let before = core.status();
    assert_eq!(before["computer_use"]["mode"], "invalid", "the reading in force, not the file: {before}");
    assert_eq!(before["computer_use"]["config_error"], "an older reading");
    let file = crate::config::load();
    assert_eq!(before["computer_use"]["pending_reload"], json!(file != Err("an older reading".to_owned())));

    let after = core.reload();
    assert_eq!(after["computer_use"]["pending_reload"], false, "{after}");
    assert_eq!(*core.config(), crate::config::load());
    assert!(lock(&core.questions).is_empty(), "questions asked under the old config end unanswered");
}

/// Without the daemon's secret, an elevated or root peer gets one thing: a reload.
#[tokio::test]
async fn an_elevated_peer_may_only_ask_for_a_reload() {
    use tokio::io::AsyncBufReadExt;
    for (line, reloaded) in [(r#"{"type":"reload"}"#, true), (r#"{"type":"hello","secret":"00"}"#, false), (r#"{"id":1,"method":"computer_use.approvals.revoke","params":{"all":true}}"#, false)] {
        let core = core_named("privileged");
        let (client, server) = tokio::io::duplex(4096);
        let serving = tokio::spawn({
            let core = Arc::clone(&core);
            async move { core.serve_privileged(server).await }
        });
        let (reader, mut writer) = tokio::io::split(client);
        writer.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        let mut answer = String::new();
        BufReader::new(reader).read_line(&mut answer).await.unwrap();
        serving.await.unwrap();
        let answer: Value = serde_json::from_str(&answer).unwrap();
        assert_eq!(answer["type"] == "reloaded", reloaded, "{line}: {answer}");
    }
}
