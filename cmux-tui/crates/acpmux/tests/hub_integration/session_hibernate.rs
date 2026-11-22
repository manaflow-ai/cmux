//! An idle session hibernates (`hub/idle.rs`). Leo's ask (2026-10-21): "An idle Claude/Codex
//! session (no turn running, nothing queued) hibernates after 2 minutes. Its process and its MCP
//! sidecars exit, its state is checkpointed, and it wakes on the next prompt or click within
//! about 1 s."
//!
//! The fake harness runs under a shell that starts a stand-in MCP server (a `sleep` in the
//! harness's process group, as a harness's stdio MCP servers are) and records both pids, so a
//! test can see both exit. Its family's config (Codex's `config.toml` in the rig's own
//! `CODEX_HOME`) names that server, so the idle census (`hub/idle_census.rs`) knows it is one.
//! All on the hub's injected clock.

use super::*;
use acpmux::clock::ManualClock;
use std::path::{Path, PathBuf};

/// Leo's 2 minutes, the default (`hub::IDLE_CHILD`).
const IDLE: Duration = acpmux::hub::IDLE_CHILD;

/// The fake harness under a shell: `$dir/broken` makes its start fail (exit 3); `$dir/slow_exit`
/// makes the harness ignore SIGTERM, so each stop waits out its grace, while its stand-in MCP
/// server (started before the trap) still ends at the SIGTERM; else it appends its own pid to
/// `$dir/harness` and its stand-in MCP server's to `$dir/sidecar`.
const HARNESS: &str = r#"d=$1; f=$2
[ -e "$d/broken" ] && exit 3
echo $$ >> "$d/harness"
sleep 100000 </dev/null >/dev/null 2>&1 &
echo $! >> "$d/sidecar"
[ -e "$d/slow_exit" ] && trap '' TERM
exec python3 "$f""#;

pub(super) struct Rig {
    pub(super) hub: Arc<Hub>,
    pub(super) c: TestClient,
    clock: Arc<ManualClock>,
    pub(super) dir: PathBuf,
    /// What a restart opens again (`Rig::restart`).
    cfg: Config,
}

pub(super) async fn rig(policy: PermissionPolicy) -> Rig {
    rig_in(policy, false, &[]).await
}

/// A rig whose fake harness keeps Codex's own conversation store (fake_agent.py's
/// FAKE_CODEX_STORE): `session/load` finds the stored conversation by its id or fails, and
/// "history-probe" answers with the prompts and session ids it holds.
pub(super) async fn rig_with_store(policy: PermissionPolicy) -> Rig {
    rig_in(policy, false, &[("FAKE_CODEX_STORE", "1")]).await
}

/// A rig whose store is on disk, so `Rig::restart` brings its chats back in a new daemon.
pub(super) async fn rig_on_disk(policy: PermissionPolicy) -> Rig {
    rig_in(policy, true, &[]).await
}

async fn rig_in(policy: PermissionPolicy, on_disk: bool, env: &[(&str, &str)]) -> Rig {
    let dir = std::env::temp_dir().join(format!("acpmux-hibernate-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let argv = ["sh", "-c", HARNESS, "sh", &dir.to_string_lossy(), fake];
    // The stand-in server, as the harness's config names it.
    let server = "[mcp_servers.side]\ncommand = \"sleep\"\nargs = [\"100000\"]\n";
    std::fs::write(dir.join("config.toml"), server).unwrap();
    let profile = HarnessProfile {
        kind: Default::default(),
        argv: argv.iter().map(|a| a.to_string()).collect(),
        env: [("CODEX_HOME".to_owned(), dir.to_string_lossy().into_owned())]
            .into_iter()
            .chain(env.iter().map(|(k, v)| (k.to_string(), v.to_string())))
            .collect(),
        description: None,
        fallback: None,
        family: Some("codex".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("fake".to_owned(), profile)]),
        default_harness: Some("fake".into()),
        ..Default::default()
    };
    cfg.store.mode = if on_disk { StoreMode::Local } else { StoreMode::Memory };
    cfg.permission_policy = policy;
    let (hub, clock) = start_hub(&cfg, &dir);
    let c = connect(&hub).await;
    Rig { hub, c, clock, dir, cfg }
}

/// A daemon on `cfg`'s store (a memory one, or `$dir/state`), on its own manual clock.
fn start_hub(cfg: &Config, dir: &Path) -> (Arc<Hub>, Arc<ManualClock>) {
    let state = match cfg.store.mode {
        StoreMode::Memory => PathBuf::from("/nonexistent"),
        _ => dir.join("state"),
    };
    let store = acpmux::store::open(&cfg.store, &state).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let clock = ManualClock::new();
    hub.set_clock(clock.clone());
    // The default, as the daemon runs it.
    hub.set_idle_child(Some(IDLE));
    (hub, clock)
}

impl Rig {
    pub(super) fn status(&self, id: &str) -> Value {
        self.hub.session_summary(&self.hub.resolve(id).unwrap())["status"].clone()
    }

    /// The pids `$dir/<file>` recorded, oldest first.
    pub(super) fn pids(&self, file: &str) -> Vec<u32> {
        let text = std::fs::read_to_string(self.dir.join(file)).unwrap_or_default();
        text.lines().filter_map(|l| l.trim().parse().ok()).collect()
    }

    pub(super) async fn until(&self, what: &str, done: impl Fn() -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        while !done() {
            assert!(std::time::Instant::now() < deadline, "{what}");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// Idles `id` past its 2 minutes and waits until its harness and MCP server are gone.
    pub(super) async fn hibernate(&self, id: &str) {
        self.clock.advance(IDLE + Duration::from_secs(1));
        self.hibernated(id).await;
    }

    /// Waits until `id` hibernated: its newest harness and MCP server are gone.
    async fn hibernated(&self, id: &str) {
        let (harness, sidecar) =
            (*self.pids("harness").last().unwrap(), *self.pids("sidecar").last().unwrap());
        self.until("the idle session never hibernated", || self.status(id) == "idle").await;
        self.until("the harness outlived its hibernation", || !alive(harness)).await;
        self.until("the MCP server outlived its hibernation", || !alive(sidecar)).await;
    }

    /// The daemon restarts on the same store (`rig_on_disk`): this one stops, a new one opens
    /// the store again with `ids` back in it, and the rig's client connects to the new one.
    pub(super) async fn restart(&mut self, ids: &[String]) {
        self.hub.shutdown_all().await;
        let (hub, clock) = start_hub(&self.cfg, &self.dir);
        (self.hub, self.clock) = (hub, clock);
        self.c = connect(&self.hub).await;
        self.until("a chat did not come back after the restart", || {
            ids.iter().all(|id| self.hub.resolve(id).is_ok())
        })
        .await;
    }

    pub(super) fn texts(&self, id: &str, kind: &str) -> Vec<String> {
        let events = self.hub.events(id, 0, 10_000).unwrap();
        events
            .iter()
            .filter(|e| e.kind == kind)
            .map(|e| e.msg["text"].as_str().unwrap_or("").to_owned())
            .collect()
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Whether `pid` runs (a zombie, ended but not reaped yet, does not).
pub(super) fn alive(pid: u32) -> bool {
    let out = std::process::Command::new("ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    let stat = String::from_utf8_lossy(&out.stdout);
    !stat.trim().is_empty() && !stat.trim_start().starts_with('Z')
}

fn settle() -> tokio::time::Sleep {
    tokio::time::sleep(Duration::from_millis(200))
}

/// After 2 idle minutes the harness and its MCP server exit, the chat shown on screen included
/// (this connection is attached and shows it); before them both run. The transcript gets no row.
#[tokio::test]
async fn an_idle_session_hibernates_after_two_minutes_even_while_shown() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "shown").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    let (harness, sidecar) = (r.pids("harness")[0], r.pids("sidecar")[0]);
    let before = r.hub.events(&id, 0, 10_000).unwrap().len();
    r.clock.advance(IDLE - Duration::from_secs(1));
    settle().await;
    assert_eq!(r.status(&id), "ready", "hibernated before its 2 minutes");
    assert!(alive(harness) && alive(sidecar));
    // 2 minutes and 1 second after the turn.
    r.clock.advance(Duration::from_secs(2));
    r.hibernated(&id).await;
    // The exit is marked a hibernation, which the transcript draws no row for (`transcript.rs`).
    let exits = || {
        let after = r.hub.events(&id, 0, 10_000).unwrap();
        let exits: Vec<Value> = after[before..]
            .iter()
            .filter(|e| e.kind == "stopped" || e.kind == "exited")
            .map(|e| e.msg.clone())
            .collect();
        exits
    };
    r.until("the hibernation logged no exit", || !exits().is_empty()).await;
    for e in exits() {
        assert_eq!(e["hibernated"], true, "{e}");
    }
    let after = r.hub.events(&id, 0, 10_000).unwrap();
    let new: Vec<&str> = after[before..].iter().map(|e| e.kind.as_str()).collect();
    assert!(new.iter().all(|k| ["status", "stopped"].contains(k)), "{new:?}");
}

/// Idle sessions whose harnesses are slow to end hibernate together, not one after another: the
/// idle pass ended them serially, so at 1,000 idle agents it took minutes and most stayed live
/// (cmux#43143). Each harness here ignores SIGTERM, so its stop waits out the 300 ms grace before
/// the SIGKILL; its stand-in MCP server ends at the SIGTERM. One after another, each harness ends
/// before the next one is told to stop; together, the stops are told while the first harness
/// still waits out its grace. Read from that order, not from wall time: a loaded suite stretches
/// the pass's own reads (`ps`) and this test's polling (2.09 s for 8 in a full run, 0.83 s alone),
/// never the order.
#[cfg(unix)]
#[tokio::test]
async fn idle_sessions_hibernate_at_once_not_one_after_another() {
    const N: usize = 8;
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    std::fs::write(r.dir.join("slow_exit"), "").unwrap();
    let mut ids = Vec::new();
    for i in 0..N {
        let id = new_session(&mut r.c, &format!("slow {i}")).await;
        r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
        ids.push(id);
    }
    r.until("every harness started", || r.pids("harness").len() == N).await;
    let (harnesses, sidecars) = (r.pids("harness"), r.pids("sidecar"));
    assert_eq!(sidecars.len(), N);
    let began = std::time::Instant::now();
    r.clock.advance(IDLE + Duration::from_secs(1));
    // When each process was first seen ended: a server at its SIGTERM, a harness at its SIGKILL.
    let mut told: Vec<Option<Duration>> = vec![None; N];
    let mut ended: Vec<Option<Duration>> = vec![None; N];
    let deadline = began + Duration::from_secs(20);
    while ended.iter().any(Option::is_none) {
        assert!(std::time::Instant::now() < deadline, "a harness outlived its hibernation");
        let all: Vec<u32> = sidecars.iter().chain(&harnesses).copied().collect();
        let running = tokio::task::spawn_blocking(move || running_of(&all)).await.unwrap();
        let at = began.elapsed();
        for (seen, pids) in [(&mut told, &sidecars), (&mut ended, &harnesses)] {
            for (slot, pid) in seen.iter_mut().zip(pids) {
                if slot.is_none() && !running.contains(pid) {
                    *slot = Some(at);
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let first_end = ended.iter().flatten().min().copied().unwrap();
    let told_in_grace = told.iter().flatten().filter(|t| **t < first_end).count();
    eprintln!(
        "{N} slow harnesses: told {told:?}, ended {ended:?}; {told_in_grace} told before the \
         first ended at {first_end:?}"
    );
    // One after another, no stop is told before the harness before it ended: one at most. Most
    // of them, not all: under a loaded suite the pass's reads spread the stops (602 to 813 ms in
    // a full run, the first end at 985 ms), and a pass two or four at a time still fails here.
    assert!(
        told_in_grace > N / 2,
        "{told_in_grace} of {N} slow harnesses were told to stop before the first one ended \
         (at {first_end:?}): they stop one after another (told {told:?}, ended {ended:?})"
    );
    r.until("an idle session never hibernated", || ids.iter().all(|id| r.status(id) == "idle"))
        .await;
}

/// Which of `pids` run, in one `ps` (a zombie, ended but not reaped yet, does not).
#[cfg(unix)]
fn running_of(pids: &[u32]) -> Vec<u32> {
    let list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
    let out = std::process::Command::new("ps").args(["-o", "pid=,stat=", "-p", &list]).output();
    let out = out.unwrap();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut words = line.split_whitespace();
            let pid = words.next()?.parse().ok()?;
            (!words.next()?.starts_with('Z')).then_some(pid)
        })
        .collect()
}

/// A running turn (its tool call included), a queued prompt and a pending permission each keep
/// the session awake past any idle period; once they are done it hibernates 2 minutes later.
#[cfg(unix)]
#[tokio::test]
async fn a_turn_a_queued_prompt_or_a_pending_permission_keeps_a_session_awake() {
    let mut r = rig(PermissionPolicy::Ask).await;
    let gate = r.dir.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let id = new_session(&mut r.c, "busy").await;
    // A turn with a running tool call, and a prompt queued behind it.
    let turn = format!("work-gate: {}", gate.display());
    let first = r.c.send(method::SESSION_PROMPT, prompt_with_id(&id, &turn, "p-turn", false)).await;
    r.c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-turn").await;
    let second =
        r.c.send(method::SESSION_PROMPT, prompt_with_id(&id, "queued", "p-queued", false)).await;
    let queued = r.c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-queued").await;
    assert_eq!(queued["queued"], true);
    r.clock.advance(IDLE * 10);
    settle().await;
    assert_eq!(r.status(&id), "running", "a running turn hibernated");
    assert!(alive(r.pids("harness")[0]));
    let open = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(open, b"open")).await.unwrap().unwrap();
    r.c.response(first).await.0.unwrap();
    r.c.response(second).await.0.unwrap();
    // A pending permission (a question waiting on the person).
    let ask = r.c.send(method::SESSION_PROMPT, prompt(&id, "ask: rm -rf build", None)).await;
    let pending = r.c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    r.clock.advance(IDLE * 10);
    settle().await;
    assert_eq!(r.status(&id), "waiting", "a session waiting on a permission hibernated");
    assert!(alive(r.pids("harness")[0]));
    let answer =
        json!({"sessionId": id, "permissionId": pending["permissionId"], "optionId": "yes"});
    r.c.request(method::MUX_PERMISSION_RESPOND, answer).await.unwrap();
    assert_eq!(r.c.response(ask).await.0.unwrap()["stopReason"], "end_turn");
    r.hibernate(&id).await;
    assert_eq!(r.pids("harness").len(), 1, "a busy session's harness was started again");
}

/// A prompt wakes a hibernated session: its agent resumes the conversation and gets the prompt
/// exactly once.
#[tokio::test]
async fn a_prompt_wakes_a_hibernated_session_and_reaches_its_agent_once() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "wake").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    r.hibernate(&id).await;
    let reply =
        r.c.request(method::SESSION_PROMPT, prompt(&id, "after-sleep", None)).await.unwrap();
    assert_eq!(reply["stopReason"], "end_turn");
    assert_eq!(r.pids("harness").len(), 2, "the wake started one new harness");
    assert_eq!(r.texts(&id, "user_message").iter().filter(|t| *t == "after-sleep").count(), 1);
    let echoed = r.hub.events(&id, 0, 10_000).unwrap();
    let echoed = echoed
        .iter()
        .filter(|e| e.dir == "out" && e.kind == method::SESSION_PROMPT)
        .filter(|e| e.msg.to_string().contains("after-sleep"));
    assert_eq!(echoed.count(), 1, "the prompt did not reach the agent exactly once");
    let kinds: Vec<String> =
        r.hub.events(&id, 0, 10_000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(
        kinds.iter().any(|k| k == "resumed"),
        "the wake did not resume the conversation: {kinds:?}"
    );
    assert_eq!(r.status(&id), "ready");
    let events = r.hub.events(&id, 0, 10_000).unwrap();
    let resumed = events.iter().rev().find(|e| e.kind == "resumed").unwrap();
    assert_eq!(resumed.msg["wake"], true, "{}", resumed.msg);
}

/// Typing into a hibernated chat wakes it before the prompt is sent, so the prompt finds its
/// agent up and starts none.
#[tokio::test]
async fn typing_into_a_hibernated_chat_wakes_it_before_the_prompt() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "typing").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    r.hibernate(&id).await;
    r.c.request(method::MUX_TYPING, json!({"sessionId": id, "on": true})).await.unwrap();
    r.until("typing did not wake the session", || r.status(&id) == "ready").await;
    assert_eq!(r.pids("harness").len(), 2);
    r.c.request(method::SESSION_PROMPT, prompt(&id, "typed", None)).await.unwrap();
    assert_eq!(r.pids("harness").len(), 2, "the prompt started a second agent");
    assert_eq!(r.texts(&id, "user_message").iter().filter(|t| *t == "typed").count(), 1);
    // Typing into a session that is awake starts nothing, and is use: a person still typing
    // near the end of the 2 minutes keeps the agent.
    r.clock.advance(IDLE - Duration::from_secs(10));
    r.c.request(method::MUX_TYPING, json!({"sessionId": id, "on": true})).await.unwrap();
    r.clock.advance(Duration::from_secs(30));
    settle().await;
    assert_eq!(r.status(&id), "ready", "hibernated while being typed into");
    assert_eq!(r.pids("harness").len(), 2);
}

/// A wake that fails fails its prompt the way the chat shows with Retry (a failed
/// `turn_result` with the error), and the retry wakes the session.
#[tokio::test]
async fn a_failed_wake_fails_its_prompt_with_its_error_and_a_retry_wakes_it() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "fails").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    r.hibernate(&id).await;
    std::fs::write(r.dir.join("broken"), b"").unwrap();
    let failed =
        r.c.request(method::SESSION_PROMPT, prompt_with_id(&id, "again", "p-again", false)).await;
    assert!(failed.is_err(), "{failed:?}");
    let events = r.hub.events(&id, 0, 10_000).unwrap();
    let result = events.iter().rev().find(|e| e.kind == "turn_result").unwrap();
    assert_eq!(result.msg["status"], "failed", "{}", result.msg);
    assert_eq!(result.msg["promptId"], "p-again");
    assert!(result.msg["error"].as_str().is_some_and(|e| !e.is_empty()), "{}", result.msg);
    std::fs::remove_file(r.dir.join("broken")).unwrap();
    let retried =
        r.c.request(method::SESSION_PROMPT, prompt_with_id(&id, "again", "p-retry", false))
            .await
            .unwrap();
    assert_eq!(retried["stopReason"], "end_turn");
}

/// Opening a chat this daemon hibernated on screen (a click: `_acpmux/view` visible, or an attach
/// that shows it) wakes it; one attached hidden does not. One an earlier daemon hibernated does
/// not (`a_daemon_restart_wakes_no_hibernated_chat_when_viewers_open_them_again`).
#[tokio::test]
async fn opening_a_hibernated_chat_wakes_it_and_a_hidden_attach_does_not() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "click").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    r.hibernate(&id).await;
    let mut hidden = connect(&r.hub).await;
    hidden
        .request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0, "visible": false}))
        .await
        .unwrap();
    settle().await;
    assert_eq!(r.status(&id), "idle", "a hidden attach woke the chat");
    assert_eq!(r.pids("harness").len(), 1);
    r.c.request(method::MUX_VIEW, json!({"sessionId": id, "visible": true})).await.unwrap();
    r.until("showing the chat did not wake it", || r.status(&id) == "ready").await;
    assert_eq!(r.pids("harness").len(), 2);
    r.hibernate(&id).await;
    let mut shown = connect(&r.hub).await;
    shown.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    r.until("opening the chat did not wake it", || r.status(&id) == "ready").await;
    assert_eq!(r.pids("harness").len(), 3);
}

/// A Stop right after typing into a hibernated chat leaves it stopped: the wake typing began
/// never reopens it.
#[tokio::test]
async fn a_stop_after_typing_into_a_hibernated_chat_stays_stopped() {
    let mut r = rig(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut r.c, "stopped").await;
    r.c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    r.hibernate(&id).await;
    // The wake is queued, then the Stop runs before this test yields to it (the test's runtime
    // is one thread): the wake reads the stop count it was asked under, never the Stop's.
    let session = r.hub.resolve(&id).unwrap();
    r.hub.wake_for(&session, false, "typing");
    r.hub.kill(&session, false).await.unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(r.status(&id), "closed", "the typing wake reopened a stopped chat");
    let newest = *r.pids("harness").last().unwrap();
    r.until("the stopped chat's agent kept running", || !alive(newest)).await;
}

/// A Claude chat hibernated before its first turn wakes as a fresh conversation with nothing to
/// restore: no `resume_failed` row and no restored transcript in its first prompt.
#[tokio::test]
async fn an_untouched_claude_chat_wakes_with_no_row_and_nothing_restored() {
    let root = std::env::temp_dir().join(format!("acpmux-hib-claude-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    // Claude Code says `system/init` when a turn starts, not on `initialize`: an untouched chat
    // runs no turn of its own (`Session::harness_turn`).
    let (hub, mut c) =
        super::fork_through::claude_setup(&claude, &[("FAKE_CLAUDE_INIT_ON_TURN", "1")]).await;
    let clock = ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(IDLE));
    let id = new_session(&mut c, "untouched").await;
    let status = || hub.session_summary(&hub.resolve(&id).unwrap())["status"].clone();
    // Its start may still hold a lease (its first mode write) at the first deadline, which
    // starts a full idle period again: each period that ends unused hibernates it.
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while status() != "idle" {
        assert!(std::time::Instant::now() < deadline, "the untouched chat never hibernated");
        clock.advance(IDLE + Duration::from_secs(1));
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let reply = c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    assert_eq!(reply["stopReason"], "end_turn");
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(!events.iter().any(|e| e.kind == "resume_failed"), "a resume_failed row");
    let sent = events.iter().filter(|e| e.dir == "out").map(|e| e.msg.to_string());
    assert!(!sent.into_iter().any(|m| m.contains("restored_transcript")), "a transcript restored");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// `n` chats that each ran a turn ("before-restart") and then hibernated together.
async fn hibernated_chats(r: &mut Rig, n: usize) -> Vec<String> {
    let mut ids = Vec::new();
    for i in 0..n {
        let id = new_session(&mut r.c, &format!("restart {i}")).await;
        r.c.request(method::SESSION_PROMPT, prompt(&id, "before-restart", None)).await.unwrap();
        ids.push(id);
    }
    r.until("every harness started", || r.pids("harness").len() == n).await;
    r.clock.advance(IDLE + Duration::from_secs(1));
    r.until("a chat never hibernated", || ids.iter().all(|id| r.status(id) == "idle")).await;
    for pid in r.pids("harness").into_iter().chain(r.pids("sidecar")) {
        r.until("a harness outlived its hibernation", || !alive(pid)).await;
    }
    ids
}

/// The coordinator's ask (2026-11-15): "a daemon restart shouldn't wake hibernated sessions at
/// all. After a restart, acpmux should start a session's harness only when that session gets a
/// turn". On a 2-vCPU host, each of ten restarts woke about 8 old hibernated chats at once,
/// because the viewers attach and show every chat they had open again (`cause="click"`): load 20.
/// Here N chats hibernate, the daemon restarts on the same store, and a viewer attaches (held and
/// paged), and shows each one: N harnesses ran before the restart, none starts after it, and
/// each chat still shows its transcript.
#[cfg(unix)]
#[tokio::test]
async fn a_daemon_restart_wakes_no_hibernated_chat_when_viewers_open_them_again() {
    const N: usize = 4;
    let mut r = rig_on_disk(PermissionPolicy::ApproveAll).await;
    let ids = hibernated_chats(&mut r, N).await;
    assert_eq!(r.pids("harness").len(), N, "each chat ran one harness before the restart");
    r.restart(&ids).await;
    let mut viewer = connect(&r.hub).await;
    for id in &ids {
        let held = json!({"sessionId": id, "hold": true, "eventStream": true, "kinds": ["status"]});
        viewer.request(method::MUX_ATTACH, held).await.unwrap();
        let page = viewer.request(method::MUX_ATTACH, json!({"sessionId": id})).await.unwrap();
        let shown = page["events"].as_array().unwrap();
        assert!(
            shown.iter().any(|e| e.to_string().contains("before-restart")),
            "a hibernated chat opened after the restart shows no transcript: {page}"
        );
        viewer.request(method::MUX_VIEW, json!({"sessionId": id, "visible": true})).await.unwrap();
    }
    // Long enough for a wake each open began to start its harness.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let started = r.pids("harness").len() - N;
    assert_eq!(
        started, 0,
        "opening {N} hibernated chats after a restart started {started} harnesses"
    );
    for id in &ids {
        assert_eq!(r.status(id), "idle", "a hibernated chat woke on an open after the restart");
    }
}

/// After a restart a hibernated chat still wakes for its turn: a prompt to it starts exactly its
/// own harness, which gets the prompt once.
#[cfg(unix)]
#[tokio::test]
async fn a_prompt_after_a_daemon_restart_starts_its_hibernated_chats_harness() {
    const N: usize = 3;
    let mut r = rig_on_disk(PermissionPolicy::ApproveAll).await;
    let ids = hibernated_chats(&mut r, N).await;
    r.restart(&ids).await;
    let mut viewer = connect(&r.hub).await;
    for id in &ids {
        viewer.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    }
    let reply =
        r.c.request(method::SESSION_PROMPT, prompt(&ids[0], "after-restart", None)).await.unwrap();
    assert_eq!(reply["stopReason"], "end_turn");
    assert_eq!(r.pids("harness").len(), N + 1, "the prompt started one harness, its chat's");
    assert_eq!(r.status(&ids[0]), "ready");
    assert_eq!(
        r.texts(&ids[0], "user_message").iter().filter(|t| *t == "after-restart").count(),
        1
    );
    for id in &ids[1..] {
        assert_eq!(r.status(id), "idle", "a chat with no turn woke");
    }
}
