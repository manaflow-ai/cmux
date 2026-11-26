//! A phone resends `_acpmux/archive` and `_acpmux/rename` when a reply is lost. With an `opId`
//! each op runs once: its retries spend one `listSeq` and leave the archive time as the first
//! run wrote it. Without one (the before), every resend runs again.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const SEED: u64 = 7;
/// A reply is lost this often (in 1/100): the phone resends the same request.
const DROP_PERCENT: u64 = 50;

fn hub_with_chats(n: usize) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    for i in 0..n {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": chat(i), "name": format!("chat-{i}"),
            "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 3, "updatedAt": 3,
        }))
        .unwrap();
        hub.insert_test_session(meta);
    }
    hub
}

fn chat(i: usize) -> String {
    format!("op-once-chat-{i}")
}

/// A seeded stream of numbers (no clock, no thread RNG): the same seed loses the same replies.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(32);
        let (output, outgoing) = mpsc::channel(256);
        tokio::spawn(super::super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::super::Origin::Local,
        ));
        let mut client = Self { input, outgoing, next: 1 };
        let hello =
            json!({"protocolVersion": 1, "clientInfo": {"name": "op-once", "version": "0"}});
        let init = client.call(method::INITIALIZE, hello).await;
        assert!(init.get("error").is_none(), "{init}");
        client
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = self.outgoing.recv().await.expect("connection remains open");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == json!(id) {
                    return reply;
                }
            }
        })
        .await
        .expect("request answers")
    }
}

fn archived_at(hub: &crate::hub::Hub, i: usize) -> Option<String> {
    let s = hub.resolve(&chat(i)).unwrap();
    s.meta().tags.get("archived").map(|t| t.value.clone())
}

#[derive(Debug, Default, PartialEq)]
struct Counts {
    ops: u64,
    sends: u64,
    list_seq_spent: u64,
    archive_restamped: u64,
}

/// Which ops a run sends: archives and renames by turns, or one kind only.
#[derive(Clone, Copy, PartialEq)]
enum Kinds {
    Mixed,
    Archives,
    Renames,
}

/// `ops` list ops (archive or rename, one chat each), each sent until a reply arrives, a reply
/// lost `drop_percent` of the time; `op_ids` gives each op an `opId`.
async fn retried_ops(ops: usize, op_ids: bool, drop_percent: u64) -> Counts {
    retried_kinds(ops, op_ids, drop_percent, Kinds::Mixed).await
}

async fn retried_kinds(ops: usize, op_ids: bool, drop_percent: u64, kinds: Kinds) -> Counts {
    let hub = hub_with_chats(ops);
    let mut client = Client::connect(&hub).await;
    let mut rng = Lcg(SEED);
    let mut counts = Counts { ops: ops as u64, ..Counts::default() };
    let head_before = hub.list_cursor().0;
    for i in 0..ops {
        let archive = match kinds {
            Kinds::Mixed => i % 2 == 0,
            Kinds::Archives => true,
            Kinds::Renames => false,
        };
        let (m, mut params) = if archive {
            (method::MUX_ARCHIVE, json!({"sessionId": chat(i), "archived": true}))
        } else {
            (method::MUX_RENAME, json!({"sessionId": chat(i), "newName": format!("renamed-{i}")}))
        };
        if op_ids {
            params["opId"] = json!(format!("phone-op-{i}"));
        }
        let mut first_when = None;
        loop {
            counts.sends += 1;
            let reply = client.call(m, params.clone()).await;
            assert!(reply.get("error").is_none(), "{reply}");
            assert_eq!(reply["result"]["sessionId"], chat(i), "{reply}");
            if archive {
                let when = archived_at(&hub, i).expect("archived");
                match &first_when {
                    None => first_when = Some(when),
                    Some(first) if *first != when => counts.archive_restamped += 1,
                    Some(_) => {}
                }
            }
            if rng.next() % 100 >= drop_percent {
                break;
            }
            // The resend comes a little later, so a second run would stamp another time.
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    }
    counts.list_seq_spent = hub.list_cursor().0 - head_before;
    counts
}

#[tokio::test]
async fn retries_across_lost_replies_spend_one_list_seq_and_keep_the_archive_time() {
    for (scale, ops) in [("1x", 20), ("10x", 200)] {
        let before = retried_ops(ops, false, DROP_PERCENT).await;
        let after = retried_ops(ops, true, DROP_PERCENT).await;
        // Each op sent once, no reply lost: what the ops themselves spend.
        let once = retried_ops(ops, false, 0).await;
        assert_eq!(once.sends, once.ops);
        // What one op of each kind spends with no reply lost (measured: an archive one, its tag
        // record; a rename two, its name and the title named from it), so the mix spends 1.5 per op.
        let archives = retried_kinds(ops, false, 0, Kinds::Archives).await;
        let renames = retried_kinds(ops, false, 0, Kinds::Renames).await;
        assert_eq!(
            once.list_seq_spent,
            (archives.list_seq_spent + renames.list_seq_spent) / 2,
            "the mix spends half of each"
        );
        // The same seed loses the same replies in both runs.
        assert_eq!(before.sends, after.sends);
        assert!(before.sends > before.ops, "the seed loses some replies: {before:?}");
        for (phase, c) in [("before", &before), ("after", &after)] {
            for (metric, value) in [
                ("list_ops", c.ops),
                ("sends", c.sends),
                ("list_seq_spent", c.list_seq_spent),
                ("archive_restamped", c.archive_restamped),
                // The same in both: a request with no `opId` sent once, no reply lost.
                ("list_seq_spent_no_loss", once.list_seq_spent),
                ("list_seq_per_archive_no_loss", archives.list_seq_spent / ops as u64),
                ("list_seq_per_rename_no_loss", renames.list_seq_spent / ops as u64),
            ] {
                println!(
                    "{phase} NETCOND {}",
                    json!({"surface": "list", "profile": "reply-loss-50pct@seed7",
                           "phase": "warm", "scale": scale, "metric": metric, "value": value,
                           "run": 0, "seed": SEED})
                );
            }
        }
        assert_eq!(after.list_seq_spent, once.list_seq_spent, "the retries spend no listSeq");
        assert_eq!(after.archive_restamped, 0);
        assert!(before.list_seq_spent > after.list_seq_spent, "{before:?}");
        // `set_archived` keeps the first archive time on a repeat (`hub/inactive_archive.rs`), so
        // the time holds with or without an `opId`; the gain is the listSeq a resend spends.
        assert_eq!(before.archive_restamped, 0, "{before:?}");
    }
}

/// An `opId` reused for another op is refused, and the first op's state stays.
#[tokio::test]
async fn an_op_id_reused_for_another_op_is_refused() {
    let hub = hub_with_chats(2);
    let mut client = Client::connect(&hub).await;
    let first = json!({"sessionId": chat(0), "archived": true, "opId": "x"});
    assert!(client.call(method::MUX_ARCHIVE, first).await.get("error").is_none());
    let when = archived_at(&hub, 0);
    let other = json!({"sessionId": chat(0), "archived": false, "opId": "x"});
    let reply = client.call(method::MUX_ARCHIVE, other).await;
    assert_eq!(reply["error"]["data"]["reason"], "op_id.reused", "{reply}");
    assert_eq!(archived_at(&hub, 0), when);
    // A new id is a new op.
    let unarchive = json!({"sessionId": chat(0), "archived": false, "opId": "y"});
    assert!(client.call(method::MUX_ARCHIVE, unarchive).await.get("error").is_none());
    assert_eq!(archived_at(&hub, 0), None);
}
