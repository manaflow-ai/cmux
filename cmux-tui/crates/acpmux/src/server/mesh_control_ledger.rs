//! A durable execution fence for leased controls. A pending entry is written before dispatch;
//! only a known RPC outcome becomes an acknowledgement. After a crash a pending entry remains
//! indeterminate, never re-executed. Completed entries survive lost acknowledgements and restart.

use crate::mesh::{Ack, InMessage};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::watch;

// The hub expires messages seven days after enqueue. Retain completed records longer than
// that after execution; unresolved records cannot safely be evicted, even after that horizon.
const RETENTION_MS: u64 = 8 * 24 * 60 * 60 * 1000;
const MAX_RECORDS: usize = 16_384;

#[derive(Clone, Serialize, Deserialize)]
struct Record {
    digest: String,
    started_at: u64,
    ack: Option<Ack>,
}

#[derive(Default)]
struct State {
    records: BTreeMap<String, Record>,
    live: HashMap<String, watch::Sender<Option<Ack>>>,
    failed: bool,
}

pub(super) enum Claim {
    New { key: String, receiver: watch::Receiver<Option<Ack>> },
    Waiting(watch::Receiver<Option<Ack>>),
    Done(Ack),
    Unknown,
    Conflict,
}

#[derive(Clone)]
pub(super) struct ControlLedger {
    path: Option<PathBuf>,
    state: Arc<Mutex<State>>,
}

impl ControlLedger {
    pub(super) fn open(path: Option<PathBuf>) -> Self {
        let mut state = State::default();
        if let Some(path) = &path {
            let read = match std::fs::read(path) {
                Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| ()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(BTreeMap::new()),
                Err(_) => Err(()),
            };
            match read {
                Ok(records) => state.records = records,
                Err(()) => {
                    state.failed = true;
                    tracing::error!(
                        "mesh control ledger is unreadable; controls remain unacknowledged"
                    );
                }
            }
        }
        Self { path, state: Arc::new(Mutex::new(state)) }
    }

    /// `sender` was authorized by the caller before this lookup. Bind both identity and payload
    /// so neither a different daemon nor a changed operation can replay another result.
    pub(super) fn claim(&self, sender: &str, message: &InMessage, can_start: bool) -> Claim {
        let key =
            crate::sha256::sha256_hex(json!([sender, message.message_id]).to_string().as_bytes());
        let digest = crate::sha256::sha256_hex(
            json!([message.kind, message.op, message.to, message.body, message.mode])
                .to_string()
                .as_bytes(),
        );
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.failed {
            return Claim::Unknown;
        }
        if let Some(record) = state.records.get(&key) {
            return if record.digest != digest {
                Claim::Conflict
            } else if let Some(ack) = &record.ack {
                Claim::Done(ack.clone())
            } else if let Some(sender) = state.live.get(&key) {
                Claim::Waiting(sender.subscribe())
            } else {
                // A previous daemon may have acted before it stopped. There is no safe
                // inference from a timeout or a missing result: never execute this id again.
                Claim::Unknown
            };
        }
        if !can_start {
            return Claim::Unknown;
        }
        let now = crate::store::now_ms();
        state.records.retain(|_, record| {
            record.ack.is_none() || now.saturating_sub(record.started_at) <= RETENTION_MS
        });
        if state.records.len() >= MAX_RECORDS {
            tracing::warn!("mesh control ledger is full; new controls remain unacknowledged");
            return Claim::Unknown;
        }
        state.records.insert(key.clone(), Record { digest, started_at: now, ack: None });
        if !self.save(&mut state) {
            return Claim::Unknown;
        }
        let (sender, receiver) = watch::channel(None);
        state.live.insert(key.clone(), sender);
        Claim::New { key, receiver }
    }

    /// An execution owns its live waiters. Cancellation, shutdown or a lost response drops
    /// this guard, ending live waits while leaving the durable pending fence untouched.
    pub(super) fn execution(&self, key: String) -> Execution {
        Execution { ledger: self.clone(), key }
    }

    /// Persist before publishing a terminal outcome. On disk errors even this process retains
    /// an indeterminate fence and exposes no successful receipt that restart could forget.
    pub(super) fn finish(&self, key: &str, ack: Ack) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.failed || !state.records.contains_key(key) {
            return;
        }
        if let Some(record) = state.records.get_mut(key) {
            record.ack = Some(ack.clone());
        }
        if self.save(&mut state)
            && let Some(sender) = state.live.remove(key)
        {
            sender.send_replace(Some(ack));
        }
    }

    fn save(&self, state: &mut State) -> bool {
        let Some(path) = &self.path else { return true };
        let saved = (|| -> anyhow::Result<()> {
            if let Some(parent) = path.parent() {
                let existed = parent.is_dir();
                std::fs::create_dir_all(parent)?;
                // A newly made parent must survive a crash too, or a durable file inside it
                // could disappear with the directory entry and allow the operation to repeat.
                #[cfg(unix)]
                if !existed {
                    for directory in parent.ancestors().filter(|p| !p.as_os_str().is_empty()) {
                        std::fs::File::open(directory)?.sync_all()?;
                    }
                }
                #[cfg(not(unix))]
                let _ = existed;
            }
            crate::config::write_atomic(path, &serde_json::to_vec(&state.records)?)?;
            // write_atomic syncs the file; require the directory sync too for this fence.
            #[cfg(unix)]
            if let Some(parent) = path.parent() {
                std::fs::File::open(parent)?.sync_all()?;
            }
            Ok(())
        })();
        if saved.is_err() {
            state.failed = true;
            state.live.clear();
            // Do not log the path, payload, or sender of a failed control.
            tracing::error!("mesh control ledger write failed; controls remain unacknowledged");
        }
        saved.is_ok()
    }
}

pub(super) struct Execution {
    ledger: ControlLedger,
    key: String,
}

impl Execution {
    pub(super) fn finish(&self, ack: Ack) {
        self.ledger.finish(&self.key, ack);
    }
}

impl Drop for Execution {
    fn drop(&mut self) {
        self.ledger.state.lock().unwrap_or_else(|e| e.into_inner()).live.remove(&self.key);
    }
}

use serde_json::json;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mesh::{Kind, Mode, Sender, Target};

    fn message() -> InMessage {
        InMessage {
            message_id: "message-1".into(),
            kind: Kind::Control,
            op: Some("start".into()),
            mode: Mode::Now,
            to: Target::default(),
            from: Sender::default(),
            body: r#"{"version":1,"params":{}}"#.into(),
            attempt: 1,
            start_work: None,
            state: None,
            subject: None,
        }
    }

    #[test]
    fn pending_claims_survive_restart_and_finished_results_replay() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ledger.json");
        let ledger = ControlLedger::open(Some(path.clone()));
        let message = message();
        let Claim::New { key, .. } = ledger.claim("sender", &message, true) else {
            panic!("new claim")
        };
        assert!(matches!(ledger.claim("sender", &message, true), Claim::Waiting(_)));
        let restarted = ControlLedger::open(Some(path.clone()));
        assert!(matches!(restarted.claim("sender", &message, true), Claim::Unknown));
        let ack = Ack::delivered("message-1", Some("stable-session-id".into()));
        ledger.finish(&key, ack.clone());
        let restarted = ControlLedger::open(Some(path));
        assert!(
            matches!(restarted.claim("sender", &message, true), Claim::Done(replayed) if replayed == ack)
        );
    }

    #[test]
    fn replay_is_bound_to_sender_and_payload() {
        let ledger = ControlLedger::open(None);
        let mut message = message();
        let Claim::New { key, .. } = ledger.claim("sender", &message, true) else {
            panic!("new claim")
        };
        ledger.finish(&key, Ack::delivered("message-1", None));
        assert!(matches!(ledger.claim("other", &message, true), Claim::New { .. }));
        message.op = Some("stop".into());
        assert!(matches!(ledger.claim("sender", &message, true), Claim::Conflict));
    }

    #[test]
    fn corrupt_or_unwritable_ledger_never_admits_execution() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ledger.json");
        std::fs::write(&path, b"not json").unwrap();
        assert!(matches!(
            ControlLedger::open(Some(path.clone())).claim("sender", &message(), true),
            Claim::Unknown
        ));
        let unwritable = ControlLedger::open(Some(path.join("inside-a-file.json")));
        assert!(matches!(unwritable.claim("sender", &message(), true), Claim::Unknown));
        assert!(matches!(unwritable.claim("sender", &message(), true), Claim::Unknown));
    }

    #[test]
    fn indeterminate_execution_ends_waiters_but_retains_its_fence() {
        let ledger = ControlLedger::open(None);
        let Claim::New { key, receiver } = ledger.claim("sender", &message(), true) else {
            panic!("new claim")
        };
        let execution = ledger.execution(key);
        drop(execution);
        assert!(receiver.has_changed().is_err(), "no operation remains to answer these waiters");
        assert!(matches!(ledger.claim("sender", &message(), true), Claim::Unknown));
    }

    #[test]
    fn capacity_does_not_fence_new_messages_or_block_replay() {
        let ledger = ControlLedger::open(None);
        assert!(matches!(ledger.claim("sender", &message(), false), Claim::Unknown));
        let Claim::New { key, .. } = ledger.claim("sender", &message(), true) else {
            panic!("no pending fence should be written when execution had no capacity")
        };
        ledger.finish(&key, Ack::delivered("message-1", None));
        assert!(matches!(ledger.claim("sender", &message(), false), Claim::Done(_)));
    }

    #[test]
    fn failed_result_persistence_leaves_the_durable_pending_fence() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ledger.json");
        let mut ledger = ControlLedger::open(Some(path.clone()));
        let Claim::New { key, receiver } = ledger.claim("sender", &message(), true) else {
            panic!("new claim")
        };
        ledger.path = Some(path.join("inside-a-file.json"));
        ledger.finish(&key, Ack::delivered("message-1", None));
        assert!(receiver.borrow().is_none());
        assert!(matches!(
            ControlLedger::open(Some(path)).claim("sender", &message(), true),
            Claim::Unknown
        ));
    }
}
