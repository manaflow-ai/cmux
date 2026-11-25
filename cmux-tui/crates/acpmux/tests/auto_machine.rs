//! Auto mode on a Cloud machine: the daemon reaches the store through its agent's socket,
//! imports a chat's copy, and handles what the store assigns it.
//!
//! The store is `FakeAutoCloud` (the real store's rules, in memory) behind a fake agent on a
//! real Unix socket ([`agent::FakeAgent`]), so every call crosses the same lines the real agent
//! reads and writes. The chats are real hub sessions on the stand-in agent (`fake_agent.py`),
//! and the folders real git repositories.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

#[path = "auto_machine/agent.rs"]
mod agent;
#[path = "auto_machine/assign.rs"]
mod assign;
#[path = "auto_machine/import.rs"]
mod import;
#[path = "auto_machine/repos.rs"]
mod repos;
#[path = "auto_machine/transport.rs"]
mod transport;

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::{Hub, NewRequest, PromptOptions, Session};
use acpmux::store::EventRecord;
use cmux_auto_session::chunks::name_of;
use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::consts::{EVENTS_MAX_PER_APPEND, LEASE_MS, MANIFEST_VERSION};
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{
    Cwd, EventsAppend, Fence, Holder, LeaseRequest, MachineSetting, Manifest, PutRequest,
    SeqRecord, SnapshotPost,
};
use serde_json::json;

pub const CHAT: &str = "chat_1";
pub const VM: &str = "vm_1";
pub const TEAM: &str = "team_0123456789abcdef0123";

pub fn mac() -> Holder {
    Holder::device("mac")
}

pub fn vm() -> Holder {
    Holder::vm(VM)
}

pub fn record(seq: u64) -> SeqRecord {
    SeqRecord { seq, record: json!({ "n": seq }) }
}

/// A manifest of `cwd` taken after event `last_seq`, with nothing queued and no open turn.
pub fn manifest_of(cwd: Cwd, last_seq: u64) -> Manifest {
    Manifest {
        v: MANIFEST_VERSION,
        at: 0,
        last_seq,
        harness: "fake".into(),
        harness_session_id: "h".into(),
        cwd,
        queue: Vec::new(),
        draft: String::new(),
        open_turn: None,
        native: Vec::new(),
    }
}

/// A folder's manifest: one tar of the chunks `tar`, taken after event `last_seq`.
pub fn folder_manifest(tar: &[String], last_seq: u64) -> Manifest {
    manifest_of(Cwd::Folder { tar: tar.to_vec() }, last_seq)
}

/// A store with the Auto machine `VM` and no chat.
pub async fn empty_store() -> FakeAutoCloud {
    let owner = FakeAutoCloud::new();
    let setting = MachineSetting { team: TEAM.into(), machine: VM.into() };
    owner.set_machine(&setting).await.expect("the Auto machine");
    owner
}

/// The chat `id` in `owner`'s store, held by the laptop `mac` at epoch 1 and at work.
pub async fn laptop_holds(owner: &FakeAutoCloud, id: &str) {
    let put = PutRequest {
        auto: true,
        title: "Fix the build".into(),
        harness: "fake".into(),
        device: "mac".into(),
        keep_in_cloud: None,
        repo: None,
    };
    owner.put(id, &put).await.expect("the chat");
    let renew = LeaseRequest { holder: mac(), epoch: 1, needs_run: true, standby: None };
    owner.lease(id, &renew).await.expect("the laptop's lease");
}

/// A store with the Auto machine `VM` and the chat `CHAT`, held by the laptop `mac` at epoch 1
/// and at work.
pub async fn store() -> FakeAutoCloud {
    let owner = empty_store().await;
    laptop_holds(&owner, CHAT).await;
    owner
}

/// `holder` appends `events` to the chat `id` at `epoch`, a request's worth at a time.
pub async fn append(
    cloud: &impl AutoCloud,
    id: &str,
    holder: &Holder,
    epoch: u64,
    events: &[SeqRecord],
) {
    for batch in events.chunks(EVENTS_MAX_PER_APPEND / 2) {
        let request = EventsAppend { holder: holder.clone(), epoch, events: batch.to_vec() };
        cloud.append_events(id, &request).await.expect("the events");
    }
}

/// `holder` stores `bytes` as one chunk of the chat `id`; its name.
pub async fn chunk(
    cloud: &impl AutoCloud,
    id: &str,
    holder: &Holder,
    epoch: u64,
    bytes: &[u8],
) -> String {
    let name = name_of(bytes);
    cloud.put_chunk(id, &name, bytes, &Fence::new(holder.clone(), epoch)).await.expect("a chunk");
    name
}

/// `holder` posts `manifest` as the chat's snapshot; its number.
pub async fn snapshot(
    cloud: &impl AutoCloud,
    id: &str,
    holder: &Holder,
    epoch: u64,
    manifest: Manifest,
) -> u64 {
    let post = SnapshotPost { holder: holder.clone(), epoch, manifest };
    cloud.post_snapshot(id, &post).await.expect("the snapshot")
}

/// The laptop's copy of `CHAT`: events 1 to `last_seq` and a snapshot of `folder` that covers
/// them.
pub async fn laptop_copy(owner: &FakeAutoCloud, last_seq: u64, folder: &[u8]) -> String {
    let events: Vec<SeqRecord> = (1..=last_seq).map(record).collect();
    append(owner, CHAT, &mac(), 1, &events).await;
    let name = chunk(owner, CHAT, &mac(), 1, folder).await;
    snapshot(owner, CHAT, &mac(), 1, folder_manifest(std::slice::from_ref(&name), last_seq)).await;
    name
}

/// The laptop goes away mid-work: its lease runs out and the store gives its chats to `VM` at
/// the next epoch, each with a takeover for it to ack.
pub fn laptop_goes_away(owner: &FakeAutoCloud) {
    owner.advance(LEASE_MS);
}

/// A daemon's hub on the stand-in agent, its store in memory.
pub fn hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A new chat of `hub` in the folder `cwd`.
pub async fn new_chat(hub: &Arc<Hub>, cwd: &Path) -> Arc<Session> {
    let request = NewRequest { cwd: Some(cwd.to_owned()), ..NewRequest::default() };
    hub.new_session(request).await.expect("a chat")
}

/// Sends `text` to the chat under `prompt_id` and returns once the hub has recorded it. The
/// turn runs on by itself.
pub async fn send(hub: &Arc<Hub>, session: &Arc<Session>, prompt_id: &str, text: &str) {
    let (recorded_tx, recorded) = tokio::sync::oneshot::channel();
    let options = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        on_accepted: Some(Box::new(move |_| {
            let _ = recorded_tx.send(());
        })),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({ "type": "text", "text": text })];
    let (hub, session) = (Arc::clone(hub), Arc::clone(session));
    tokio::spawn(async move { hub.prompt_with(&session, blocks, "test", false, options).await });
    let in_time = tokio::time::timeout(Duration::from_secs(30), recorded).await;
    in_time.expect("recorded in time").unwrap();
}

/// The chat's log once `done` holds of it. Panics when it does not within a minute.
pub async fn log_when(
    hub: &Arc<Hub>,
    id: &str,
    what: &str,
    done: impl Fn(&[EventRecord]) -> bool,
) -> Vec<EventRecord> {
    for _ in 0..1200 {
        let events = hub.events(id, 0, 100_000).unwrap_or_default();
        if done(&events) {
            return events;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let kinds: Vec<String> = hub
        .events(id, 0, 100_000)
        .unwrap_or_default()
        .iter()
        .map(|event| format!("{}:{}", event.kind, event.msg))
        .collect();
    panic!("{what} did not happen; the log: {kinds:#?}");
}

/// The texts of the person's and the daemon's prompts in a log, in order.
pub fn prompts(events: &[EventRecord]) -> Vec<String> {
    let texts = events.iter().filter(|event| event.kind == "user_message");
    texts.filter_map(|event| event.msg["text"].as_str().map(str::to_owned)).collect()
}

/// How many turns of a log have ended.
pub fn turns_ended(events: &[EventRecord]) -> usize {
    events.iter().filter(|event| event.kind == "turn_result").count()
}

/// A hub's log as the store's events: each record under its own seq.
pub fn as_events(log: &[EventRecord]) -> Vec<SeqRecord> {
    let record = |event: &EventRecord| serde_json::to_value(event).unwrap();
    log.iter().map(|event| SeqRecord { seq: event.seq, record: record(event) }).collect()
}
