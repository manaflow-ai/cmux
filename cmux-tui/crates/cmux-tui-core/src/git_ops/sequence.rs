//! Two sequences of git work items per client, one for its reads and one
//! for its writes. A connection's writes run one at a time in arrival order
//! (a commit then a push pushes the new commit), and so do its reads; a
//! read never waits behind a write's hook or remote (up to 120 s), so a
//! client sends both on one connection ([`SHARED_CONNECTION_CAPABILITY`]).
//! A flood from one client holds at most two lane slots. Chrome posts a
//! resource's work to a `SequencedTaskRunner`
//! (base/task/sequenced_task_runner.h): each turn is its own task, so other
//! sequences and higher priorities run between turns.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};

use cmux_threads::work::{Lane, Priority, Shutdown};
use serde_json::Value;

use crate::Mux;
use crate::panic_free::RecoverPoison;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;
use crate::work_reply::WorkReply;

/// Git requests one sequence may have queued behind its running one.
pub(crate) const MAX_QUEUED: usize = 64;

/// Advertised in identify: git requests run off the request thread, and a
/// connection's reads run in a sequence apart from its writes, so a client
/// sends its git reads and writes on its control connection.
pub(crate) const SHARED_CONNECTION_CAPABILITY: &str = "git-shared-connection-v1";

/// Sends a git request's answer to its client.
pub(crate) type Reply = Box<dyn FnOnce(Result<Value, ResourceError>) + Send>;

/// One git request of a client and where its answer goes.
pub(super) struct Turn {
    pub request: ParsedResourceRequest,
    pub reply: Reply,
}

/// One of a client's two git sequences: its reads or its writes.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct Key {
    client: u64,
    writes: bool,
}

/// The git sequences of a daemon, keyed by client and by reads or writes.
#[derive(Default)]
pub(crate) struct Sequences {
    // Lock carve-out: a short critical section over the per-client queues;
    // no git, no item body and no post runs under it.
    queued: Mutex<HashMap<Key, VecDeque<Turn>>>,
}

impl Sequences {
    /// Runs `turn` after the earlier turns of the client's sequence for it
    /// (reads or writes), or posts it now when that sequence has none.
    /// Gives its reply back, to answer the refusal, when that sequence
    /// already has [`MAX_QUEUED`] turns waiting.
    pub(super) fn submit(mux: &Arc<Mux>, client: u64, turn: Turn) -> Result<(), Reply> {
        let key = Key { client, writes: super::writes(turn.request.envelope.operation) };
        let mut queued = mux.git_sequences.queued.lock().recover_poison();
        match queued.get_mut(&key) {
            Some(waiting) if waiting.len() >= MAX_QUEUED => Err(turn.reply),
            Some(waiting) => {
                waiting.push_back(turn);
                Ok(())
            }
            None => {
                queued.insert(key, VecDeque::new());
                drop(queued);
                post(mux, key, turn);
                Ok(())
            }
        }
    }

    /// Ends the sequence's running turn: posts its next, or ends it.
    fn advance(mux: &Arc<Mux>, key: Key) {
        let mut queued = mux.git_sequences.queued.lock().recover_poison();
        let next = queued.get_mut(&key).and_then(VecDeque::pop_front);
        if next.is_none() {
            queued.remove(&key);
        }
        drop(queued);
        if let Some(turn) = next {
            post(mux, key, turn);
        }
    }

    /// Running sequences (tests).
    #[cfg(test)]
    pub(crate) fn active(&self) -> usize {
        self.queued.lock().recover_poison().len()
    }
}

/// Posts `turn` as one System-lane work item. Reads are what a view waits
/// on: UserBlocking. Writes run hooks and reach remotes: UserVisible, and
/// their long waits leave the lane's count (`will_block` in `user_run`).
///
/// Every git item is `ContinueOnShutdown`: a read left half done is
/// harmless, and a write's half-done state is what a daemon killed mid-run
/// leaves too, which the attempt journal (`journal`) and the atomic
/// checkpoint store already recover. So shutdown never waits for git.
///
/// `Running` advances the sequence when the body returns, panics, or is
/// dropped unrun (shutdown refused or dropped the item), so a sequence
/// never stalls, and `WorkReply` answers every case.
fn post(mux: &Arc<Mux>, key: Key, turn: Turn) {
    let Turn { request, reply } = turn;
    let operation = request.envelope.operation;
    let priority = if key.writes { Priority::UserVisible } else { Priority::UserBlocking };
    let reply = WorkReply::new(move |answer| {
        reply(answer.unwrap_or_else(|why| Err(super::unanswered(operation, why))));
    });
    let running = Running { mux: Arc::clone(mux), key };
    let item_mux = Arc::clone(mux);
    // A refused item is dropped here: `reply` answers and `running` advances.
    let _ = mux.work.post(priority, Lane::System, Shutdown::ContinueOnShutdown, move || {
        let _running = running;
        reply.run(|| crate::resource_router::handle_parsed_resource_request(&item_mux, request));
    });
}

struct Running {
    mux: Arc<Mux>,
    key: Key,
}

impl Drop for Running {
    fn drop(&mut self) {
        Sequences::advance(&self.mux, self.key);
    }
}
