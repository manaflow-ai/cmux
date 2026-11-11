//! A client's `$/cancel_request` of its own running `session/prompt` (review F1 of #41361): the
//! request is answered cancelled at once, and the turn still settles as a finished one does
//! (`Hub::finish_turn`, the prompt's outcome to its waiters). Before, the cancel dropped the
//! prompt's future: the turn stayed "running" for good, every later prompt queued behind it, and a
//! retry of the cancelled prompt id waited forever.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(15);
const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A hub on the stand-in agent.
fn hub() -> Arc<Hub> {
    let cfg = json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    });
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

pub(super) struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    seen: Vec<Value>,
}

impl Client {
    pub(super) fn connect(hub: &Arc<Hub>) -> Self {
        let (tx, incoming) = mpsc::channel(64);
        let (output, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
        Self { tx, rx, seen: Vec::new() }
    }

    pub(super) async fn send(&self, msg: Message) {
        self.tx.send(msg.to_line()).await.unwrap();
    }

    fn answer_to(&self, id: i64) -> Option<&Value> {
        self.seen.iter().find(|v| v["id"] == json!(id) && v.get("method").is_none())
    }

    /// Reads until `id` is answered, within `within`; None when it was not.
    pub(super) async fn answer(&mut self, id: i64, within: Duration) -> Option<Value> {
        let deadline = tokio::time::Instant::now() + within;
        while self.answer_to(id).is_none() {
            let line = tokio::time::timeout_at(deadline, self.rx.recv()).await.ok()??;
            self.seen.push(serde_json::from_str(&line).unwrap());
        }
        self.answer_to(id).cloned()
    }

    pub(super) async fn call(&mut self, id: i64, m: &str, params: Value) -> Value {
        self.send(Message::request(id, m, params)).await;
        let what = format!("no answer to {m} {id}");
        self.answer(id, WAIT).await.expect(&what)
    }
}

/// `cond` within [`WAIT`], checked every 20 ms.
pub(super) async fn until(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !cond() {
        assert!(tokio::time::Instant::now() < deadline, "{what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

pub(super) fn prompt(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({
        "sessionId": session,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    })
}

/// Review F1 of #41361: cancel a running prompt's request, then the session ends idle, the next
/// prompt runs, and a resend of the cancelled prompt id is answered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cancelled_prompt_settles_its_turn_and_the_next_prompt_runs() {
    let hub = hub();
    let mut c = Client::connect(&hub);
    let new =
        c.call(1, "session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let sid = new["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{new}")).to_owned();
    let s = hub.resolve(&sid).unwrap();

    // A turn that runs until the agent hears a Stop (`fake_agent.py` "until-cancel").
    c.send(Message::request(10, "session/prompt", prompt(&sid, "until-cancel", "p-cancelled")))
        .await;
    let deadline = tokio::time::Instant::now() + WAIT;
    while hub.agent_pending_requests(&sid).await != Some(1) {
        assert!(tokio::time::Instant::now() < deadline, "the prompt never reached its agent");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(s.turn().is_some(), "the prompt's turn runs");

    c.send(Message::notification(method::CANCEL_REQUEST, json!({"requestId": 10}))).await;
    let cancelled = c.answer(10, WAIT).await.expect("the cancel answered the prompt");
    assert_eq!(
        cancelled["error"]["code"],
        json!(crate::request_cancel::REQUEST_CANCELLED),
        "{cancelled}"
    );

    // The turn settles as a finished one does: no turn left running.
    until("the cancelled prompt's turn is still running", || s.turn().is_none()).await;

    // The next prompt runs, rather than queueing behind a turn that never ends.
    let next = c.call(11, "session/prompt", prompt(&sid, "hello", "p-next")).await;
    assert_eq!(next["result"]["stopReason"], json!("end_turn"), "{next}");

    // A resend of the cancelled prompt id is answered with that prompt's outcome.
    let mut again = prompt(&sid, "until-cancel", "p-cancelled");
    again["_meta"]["acpmux"]["resend"] = json!(true);
    c.send(Message::request(12, "session/prompt", again)).await;
    let retried = c.answer(12, WAIT).await.expect("the resend of the cancelled prompt waits");
    assert!(
        retried.get("result").is_some() || retried.get("error").is_some(),
        "the resend got an answer: {retried}"
    );
    assert!(s.turn().is_none(), "the resend ran no turn of its own");
    assert_eq!(s.queued(), 0, "nothing waits in the queue");
}

/// Where in a prompt's life its request is cancelled (the detector of the class "a cancel path
/// skips the cleanup the normal finish takes"): one seam per await stage of a prompt.
#[derive(Debug, Clone, Copy)]
enum Stage {
    /// Read and admitted, held before it is routed (`RequestStage::Dispatch`).
    Dispatch,
    /// Admitted to its chat, before its turn is installed (`prompt_start_seam`).
    Admitted,
    /// Its turn shows, before its last check and its acceptance (`turn_shown_seam`).
    Shown,
    /// Its turn runs at the agent.
    Running,
    /// Queued behind another prompt's running turn.
    Queued,
    /// Its turn is taken and ending (`finish_seam`).
    Ending,
}

const STAGES: [Stage; 6] =
    [Stage::Dispatch, Stage::Admitted, Stage::Shown, Stage::Running, Stage::Queued, Stage::Ending];

/// A test's pause at one seam: `arrived` once the prompt is there, `release` lets it go on.
struct Pause {
    arrived: tokio::sync::oneshot::Receiver<()>,
    release: tokio::sync::oneshot::Sender<()>,
}

/// A seam of the hub's (`full_access_bound::WriteSeam`).
type Seam =
    StdMutex<Option<(tokio::sync::oneshot::Sender<()>, tokio::sync::oneshot::Receiver<()>)>>;

fn pause_at(seam: &Seam) -> Pause {
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *seam.lock().unwrap() = Some((arrived_tx, release_rx));
    Pause { arrived, release }
}

/// Holds `session/prompt` `id` at its dispatch until the pause is released.
fn hold_dispatch(hub: &Arc<Hub>, id: i64) -> Pause {
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel::<()>();
    let (release, release_rx) = tokio::sync::oneshot::channel::<()>();
    let gate = Arc::new(StdMutex::new(Some((arrived_tx, release_rx))));
    hub.hold_requests_for_tests(Arc::new(move |stage, m: &str, held: &Value| {
        let ours = stage == crate::hub::RequestStage::Dispatch
            && m == method::SESSION_PROMPT
            && *held == json!(id);
        let taken = if ours { gate.lock().unwrap().take() } else { None };
        let hold: std::pin::Pin<Box<dyn Future<Output = ()> + Send>> = Box::pin(async move {
            if let Some((arrived, release)) = taken {
                let _ = arrived.send(());
                let _ = release.await;
            }
        });
        hold
    }));
    Pause { arrived, release }
}

async fn agent_holds(hub: &Hub, sid: &str, n: usize) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while hub.agent_pending_requests(sid).await != Some(n) {
        assert!(tokio::time::Instant::now() < deadline, "the agent never held {n} prompts");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Cancels a prompt's request at `stage`; then the request is answered cancelled, the session
/// ends idle with nothing queued, a resend of every prompt id is answered, and a next prompt runs.
async fn cancel_at(stage: Stage) {
    let hub = hub();
    let mut c = Client::connect(&hub);
    let new =
        c.call(1, "session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let sid = new["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{new}")).to_owned();
    let s = hub.resolve(&sid).unwrap();
    const ID: i64 = 10;
    // Another prompt's turn the cancelled one queues behind (Queued only).
    const AHEAD: i64 = 9;
    let pause = match stage {
        Stage::Dispatch => Some(hold_dispatch(&hub, ID)),
        Stage::Admitted => Some(pause_at(&hub.prompt_start_seam)),
        Stage::Shown => Some(pause_at(&hub.turn_shown_seam)),
        Stage::Ending => Some(pause_at(&hub.finish_seam)),
        Stage::Running | Stage::Queued => None,
    };
    if matches!(stage, Stage::Queued) {
        c.send(Message::request(AHEAD, "session/prompt", prompt(&sid, "until-cancel", "p-ahead")))
            .await;
        agent_holds(&hub, &sid, 1).await;
    }
    // Ending: a turn that ends by itself, held once its end took it.
    let text = if matches!(stage, Stage::Ending) { "hello" } else { "until-cancel" };
    c.send(Message::request(ID, "session/prompt", prompt(&sid, text, "p-cancelled"))).await;
    let mut pause = pause;
    if let Some(p) = pause.as_mut() {
        tokio::time::timeout(WAIT, &mut p.arrived)
            .await
            .unwrap_or_else(|_| panic!("{stage:?}: the prompt never reached its seam"))
            .unwrap();
    }
    match stage {
        Stage::Running => agent_holds(&hub, &sid, 1).await,
        Stage::Queued => until("the prompt never queued", || s.queued() == 1).await,
        _ => {}
    }
    c.send(Message::notification(method::CANCEL_REQUEST, json!({"requestId": ID}))).await;
    let answer = c.answer(ID, WAIT).await.unwrap_or_else(|| panic!("{stage:?}: no answer"));
    assert_eq!(
        answer["error"]["code"],
        json!(crate::request_cancel::REQUEST_CANCELLED),
        "{stage:?}: {answer}"
    );
    if let Some(p) = pause {
        let _ = p.release.send(());
    }
    if matches!(stage, Stage::Queued) {
        // The turn ahead is the client's to stop too.
        c.send(Message::notification(method::CANCEL_REQUEST, json!({"requestId": AHEAD}))).await;
        c.answer(AHEAD, WAIT).await.unwrap_or_else(|| panic!("{stage:?}: the turn ahead"));
    }
    let what = format!("{stage:?}: the session never ended idle");
    until(&what, || s.turn().is_none() && s.queued() == 0).await;
    // Every waiter on each prompt id is answered: a resend gets the outcome of the prompt's run,
    // or, when the chat never took it, runs it now.
    let ids: &[&str] =
        if matches!(stage, Stage::Queued) { &["p-cancelled", "p-ahead"] } else { &["p-cancelled"] };
    for (n, prompt_id) in ids.iter().enumerate() {
        let mut again = prompt(&sid, "hello", prompt_id);
        again["_meta"]["acpmux"]["resend"] = json!(true);
        let id = 20 + n as i64;
        c.send(Message::request(id, "session/prompt", again)).await;
        let retried = c
            .answer(id, WAIT)
            .await
            .unwrap_or_else(|| panic!("{stage:?}: a resend of {prompt_id} waits for good"));
        assert!(
            retried.get("result").is_some() || retried.get("error").is_some(),
            "{stage:?}: {retried}"
        );
    }
    let next = c.call(30, "session/prompt", prompt(&sid, "hello", "p-next")).await;
    assert_eq!(next["result"]["stopReason"], json!("end_turn"), "{stage:?}: {next}");
    until(&what, || s.turn().is_none() && s.queued() == 0).await;
}

/// The detector: a cancel at every await stage of a prompt leaves the session idle with every
/// waiter answered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_cancelled_at_any_stage_leaves_the_session_idle_and_every_waiter_answered() {
    for stage in STAGES {
        cancel_at(stage).await;
    }
}
