//! #35971: a store call that blocks on the disk never runs on a runtime worker: the syncs of
//! `Store::flush_session`, and the log read of a `session/load` replay. Each test runs its
//! caller on a runtime with one worker and holds the call at the store's seam
//! (`test_store_seam.rs`). A second task on the runtime must run while the call is held; with
//! the call on the worker, it never does.

use super::*;
use crate::mesh::{Ack, Heartbeat, HeartbeatReply, HubError, InMessage, OutMessage, Receipt};
use crate::test_store_seam::{Call, Seam, SeamStore, assert_off_worker, one_worker};
use futures::future::BoxFuture;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A hub whose agent is the stand-in, as profile `harness` with `env`; its store is held at the
/// seam, and team messaging is on.
fn hub(harness: &str, env: Value) -> (Arc<Hub>, Seam) {
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {harness: {"argv": ["python3", FAKE], "env": env}},
        "defaultHarness": harness,
        "meshRelay": {"url": "https://hub.invalid", "tokenCommand": ["false"], "teamMessaging": true},
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let (store, seam) = SeamStore::new();
    (Hub::new(config, Box::new(store)), seam)
}

/// A hub as [`hub`], with one open chat.
async fn open_chat(harness: &str, env: Value) -> (Arc<Hub>, Seam, Arc<Session>) {
    let (hub, seam) = hub(harness, env);
    let request = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let chat = hub.new_session(request).await.unwrap();
    (hub, seam, chat)
}

/// One turn of the person's prompt `text`, with `text` as its prompt id.
async fn turn(hub: &Arc<Hub>, chat: &Arc<Session>, text: &str) {
    let opts = PromptOptions { prompt_id: Some(text.to_owned()), ..PromptOptions::default() };
    let blocks = vec![json!({"type": "text", "text": text})];
    hub.prompt_with(chat, blocks, "test", false, opts).await.unwrap();
}

/// A team message from the relay for `to`; `start_work` is the hub's decision.
fn team_message(to: &Session, id: &str, start_work: &str) -> InMessage {
    serde_json::from_value(json!({
        "messageId": id, "kind": "prompt", "mode": "turn-end", "body": "report status",
        "to": {"sessionId": to.id, "teamAddress": "@team/coordinator"},
        "from": {"teamAddress": "@alice/coordinator"}, "startWork": start_work,
    }))
    .unwrap()
}

/// An exact stop (`cancel_prompt`) syncs its boundary to disk before it stops anything
/// (`stop_prompt_retry`).
#[test]
fn cancel_prompt_syncs_its_stop_boundary_off_the_runtime_worker() {
    let runtime = one_worker();
    let (hub, seam, chat) = runtime.block_on(open_chat("fake", json!({})));
    let (owner, stopped) = (hub.clone(), chat.clone());
    let stop = async move { owner.cancel_prompt(&stopped, "workflow").await };
    let (held, stop) = assert_off_worker(&runtime, &seam, Call::Flush, 0, "cancel_prompt", stop);
    assert_eq!(held, chat.id);
    stop.unwrap();
    runtime.block_on(hub.shutdown_all());
}

/// Edit and Resend (`fork_before`) sync three times before they answer: the parent's
/// reservation of the child, then the child's journal and its ready mark
/// (`fork_with_boundary`). Each sync is held in turn.
#[test]
fn fork_before_syncs_off_the_runtime_worker() {
    let runtime = one_worker();
    // A Codex chat: Edit and Resend need a harness that forks at a turn (`config::turn_cut`).
    let codex = cmux_unix_socket::short_test_dir("acpmux-fork-sync");
    let env = json!({"CODEX_HOME": codex.path(), "FAKE_CODEX_STORE": "1"});
    let (hub, seam, parent) = runtime.block_on(async {
        let (hub, seam, parent) = open_chat("codex", env).await;
        turn(&hub, &parent, "first").await;
        (hub, seam, parent)
    });
    let syncs = [(0, "the reservation"), (1, "the child's journal"), (2, "the child's ready mark")];
    for (pass, sync) in syncs {
        let (owner, source, request) = (hub.clone(), parent.clone(), format!("edit-{pass}"));
        let fork = async move {
            let ask = super::admission::Ask {
                force: false,
                can_force: false,
                person: true,
                name: None,
                who: "test",
                local: true,
                peers: false,
            };
            let (child, _) = owner.fork_before(&source, "first", &request, ask).await.unwrap();
            child.id.clone()
        };
        let what = format!("fork_before, {sync}");
        let (held, child) = assert_off_worker(&runtime, &seam, Call::Flush, pass, &what, fork);
        assert_eq!(held, if pass == 0 { parent.id.clone() } else { child }, "{sync}");
    }
    runtime.block_on(hub.shutdown_all());
}

/// The daemon a chat moves to syncs its `transferred_in` record before it answers
/// (`transfer_finish`).
#[test]
fn transfer_finish_syncs_its_receipt_off_the_runtime_worker() {
    let runtime = one_worker();
    let (source, target, seam, id, finish) = runtime.block_on(async {
        let (source, _, moved) = open_chat("fake", json!({})).await;
        turn(&source, &moved, "hi").await;
        // Stopped, as `acpmux session stop` leaves it: no agent runs while it moves.
        source.kill(&moved, false).await.unwrap();
        let begin = json!({"sessionId": moved.id});
        let begin = source.transfer_request("_acpmux/transfer_begin", &begin).await.unwrap();
        let (target, seam) = hub("fake", json!({}));
        let receive = json!({"manifest": begin});
        let received = target.transfer_request("_acpmux/transfer_receive", &receive).await.unwrap();
        let epoch = begin["epoch"].as_u64().unwrap_or(0);
        for file in begin["files"].as_array().unwrap() {
            let mut offset = 0;
            loop {
                let read = json!({"transferId": begin["transferId"], "path": file["path"],
                    "offset": offset, "limit": 4096, "epoch": epoch});
                let part = source.transfer_request("_acpmux/transfer_read", &read).await.unwrap();
                let write = json!({"receiveId": received["receiveId"], "path": file["path"],
                    "offset": offset, "data": part["data"], "epoch": epoch});
                target.transfer_request("_acpmux/transfer_write", &write).await.unwrap();
                offset = part["next"].as_u64().unwrap();
                if part["eof"] == true {
                    break;
                }
            }
        }
        let finish = json!({"receiveId": received["receiveId"], "epoch": begin["epoch"]});
        (source, target, seam, moved.id.clone(), finish)
    });
    let owner = target.clone();
    let finish = async move { owner.transfer_request("_acpmux/transfer_finish", &finish).await };
    let (held, moved) =
        assert_off_worker(&runtime, &seam, Call::Flush, 0, "transfer_finish", finish);
    assert_eq!(held, id);
    assert_eq!(moved.unwrap()["sessionId"], id.as_str());
    runtime.block_on(async {
        source.shutdown_all().await;
        target.shutdown_all().await;
    });
}

/// `session/load` replays the chat's log, read from its files, before it answers.
#[test]
fn session_load_replays_the_log_off_the_runtime_worker() {
    let runtime = one_worker();
    let (hub, seam, chat) = runtime.block_on(async {
        let (hub, seam, chat) = open_chat("fake", json!({})).await;
        turn(&hub, &chat, "hi").await;
        (hub, seam, chat)
    });
    let (owner, id) = (hub.clone(), chat.id.clone());
    let load = async move {
        let (input, inbound) = mpsc::channel(8);
        let (out, mut lines) = mpsc::channel(4096);
        let local = crate::server::Origin::Local;
        tokio::spawn(crate::server::serve_connection_with(owner, inbound, out, local));
        let load = json!({"sessionId": id, "cwd": std::env::temp_dir(), "mcpServers": []});
        input.send(Message::request(1, method::SESSION_LOAD, load).to_line()).await.unwrap();
        let mut replayed = 0;
        loop {
            let line: Value = serde_json::from_str(&lines.recv().await.unwrap()).unwrap();
            if line["id"] == 1 {
                break (replayed, line);
            }
            let replay = line.pointer("/params/_meta/acpmux/replay");
            replayed += usize::from(replay == Some(&json!(true)));
        }
    };
    let (held, (replayed, answer)) =
        assert_off_worker(&runtime, &seam, Call::Scan, 0, "session/load", load);
    assert_eq!(held, chat.id);
    assert!(answer.get("error").is_none(), "{answer}");
    assert!(replayed > 0, "the replay comes before the answer: {answer}");
    runtime.block_on(hub.shutdown_all());
}

/// A read receipt the team hub took is logged and synced (`flush_team_read_receipts`, in the
/// relay's heartbeat).
#[test]
fn a_team_read_receipt_is_synced_off_the_runtime_worker() {
    let runtime = one_worker();
    let (hub, seam, chat) = runtime.block_on(async {
        let (hub, seam, chat) = open_chat("fake", json!({})).await;
        assert!(hub.receive_team_information(&chat, "m1", "@alice/coordinator", "ready"));
        // A turn took the notice: its read receipt waits for the hub.
        hub.mark_team_messages(&chat, &hub.take_team_messages(&chat));
        (hub, seam, chat)
    });
    let owner = hub.clone();
    let read = async move { owner.flush_team_read_receipts(&ReadsAll).await };
    let (held, ()) = assert_off_worker(&runtime, &seam, Call::Flush, 0, "read receipts", read);
    assert_eq!(held, chat.id);
    runtime.block_on(hub.shutdown_all());
}

/// Team information the relay delivers is logged and synced before its ack
/// (`receive_team_information`).
#[test]
fn delivered_team_information_is_synced_off_the_runtime_worker() {
    let runtime = one_worker();
    let (hub, seam, chat) = runtime.block_on(open_chat("fake", json!({})));
    let (owner, message) = (hub.clone(), team_message(&chat, "m1", "information"));
    let deliver = async move {
        let refuse = crate::mesh::RefuseControl;
        crate::server::mesh_relay::deliver(&owner, &message, &refuse, None).await
    };
    let what = "deliver, information";
    let (held, ack) = assert_off_worker(&runtime, &seam, Call::Flush, 0, what, deliver);
    assert_eq!(held, chat.id);
    assert_eq!(ack.unwrap().state, crate::mesh::AckState::Delivered);
    runtime.block_on(hub.shutdown_all());
}

/// Team work the hub allowed is registered and synced before its prompt is sent
/// (`register_team_work`).
#[test]
fn delivered_team_work_is_registered_off_the_runtime_worker() {
    let runtime = one_worker();
    let (hub, seam, chat) = runtime.block_on(open_chat("fake", json!({})));
    let (owner, message) = (hub.clone(), team_message(&chat, "work1", "allowed"));
    let deliver = async move {
        let refuse = crate::mesh::RefuseControl;
        crate::server::mesh_relay::deliver(&owner, &message, &refuse, None).await
    };
    let what = "deliver, work";
    let (held, ack) = assert_off_worker(&runtime, &seam, Call::Flush, 0, what, deliver);
    assert_eq!(held, chat.id);
    assert_eq!(ack.unwrap().state, crate::mesh::AckState::Delivered);
    runtime.block_on(hub.shutdown_all());
}

/// A turn that carries a team notice logs and syncs that it took it once the harness wrote its
/// prompt (`mark_team_messages`, from the harness writer's callback).
#[test]
fn a_turn_marks_its_team_messages_off_the_runtime_worker() {
    let runtime = one_worker();
    let (hub, seam, chat) = runtime.block_on(async {
        let (hub, seam, chat) = open_chat("fake", json!({})).await;
        assert!(hub.receive_team_information(&chat, "m1", "@alice/coordinator", "ready"));
        (hub, seam, chat)
    });
    let (owner, prompted) = (hub.clone(), chat.clone());
    let prompt = async move { turn(&owner, &prompted, "hello").await };
    let what = "the turn's team marks";
    let (held, ()) = assert_off_worker(&runtime, &seam, Call::Flush, 0, what, prompt);
    assert_eq!(held, chat.id);
    assert!(hub.take_team_messages(&chat).is_empty(), "the turn took the notice");
    runtime.block_on(hub.shutdown_all());
}

/// A team hub that takes every read receipt; nothing else is asked of it here.
struct ReadsAll;

impl crate::mesh::MeshHub for ReadsAll {
    fn read<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        let receipt = json!({"messageId": id, "state": "read"});
        Box::pin(async move { Ok(serde_json::from_value(receipt).unwrap()) })
    }
    fn inbox(
        &self,
        _: std::time::Duration,
        _: usize,
    ) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        unreachable!("no inbox read")
    }
    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        unreachable!("no delivery ack")
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        unreachable!("no heartbeat")
    }
    fn send<'a>(&'a self, _: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        unreachable!("no send")
    }
    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        unreachable!("no receipt")
    }
}
