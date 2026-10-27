//! One sequence of git work items per client: a connection's git requests
//! run one at a time, in arrival order, as they did on its request thread
//! (a commit then a push pushes the new commit), and a flood from one
//! client holds at most one lane slot. Chrome posts a resource's work to a
//! `SequencedTaskRunner` (base/task/sequenced_task_runner.h): each turn is
//! its own task, so other sequences and higher priorities run between
//! turns.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};

use cmux_threads::work::{Lane, Priority, Shutdown};
use serde_json::Value;

use crate::Mux;
use crate::panic_free::RecoverPoison;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;
use crate::work_reply::WorkReply;

/// Git requests one client may have queued behind its running one.
pub(crate) const MAX_QUEUED: usize = 64;

/// Sends a git request's answer to its client.
pub(crate) type Reply = Box<dyn FnOnce(Result<Value, ResourceError>) + Send>;

/// One git request of a client and where its answer goes.
pub(super) struct Turn {
    pub request: ParsedResourceRequest,
    pub reply: Reply,
}

/// The git sequences of a daemon, keyed by client.
#[derive(Default)]
pub(crate) struct Sequences {
    // Lock carve-out: a short critical section over the per-client queues;
    // no git, no item body and no post runs under it.
    queued: Mutex<HashMap<u64, VecDeque<Turn>>>,
}

impl Sequences {
    /// Runs `turn` after the client's earlier turns, or posts it now when
    /// the client has none. Gives its reply back, to answer the refusal,
    /// when the client already has [`MAX_QUEUED`] turns waiting.
    pub(super) fn submit(mux: &Arc<Mux>, client: u64, turn: Turn) -> Result<(), Reply> {
        let mut queued = mux.git_sequences.queued.lock().recover_poison();
        match queued.get_mut(&client) {
            Some(waiting) if waiting.len() >= MAX_QUEUED => Err(turn.reply),
            Some(waiting) => {
                waiting.push_back(turn);
                Ok(())
            }
            None => {
                queued.insert(client, VecDeque::new());
                drop(queued);
                post(mux, client, turn);
                Ok(())
            }
        }
    }

    /// Ends the client's running turn: posts its next, or ends its sequence.
    fn advance(mux: &Arc<Mux>, client: u64) {
        let mut queued = mux.git_sequences.queued.lock().recover_poison();
        let next = queued.get_mut(&client).and_then(VecDeque::pop_front);
        if next.is_none() {
            queued.remove(&client);
        }
        drop(queued);
        if let Some(turn) = next {
            post(mux, client, turn);
        }
    }

    /// Clients with a running sequence (tests).
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
fn post(mux: &Arc<Mux>, client: u64, turn: Turn) {
    let Turn { request, reply } = turn;
    let operation = request.envelope.operation;
    let priority =
        if super::writes(operation) { Priority::UserVisible } else { Priority::UserBlocking };
    let reply = WorkReply::new(move |answer| {
        reply(answer.unwrap_or_else(|why| Err(super::unanswered(operation, why))));
    });
    let running = Running { mux: Arc::clone(mux), client };
    let item_mux = Arc::clone(mux);
    // A refused item is dropped here: `reply` answers and `running` advances.
    let _ = mux.work.post(priority, Lane::System, Shutdown::ContinueOnShutdown, move || {
        let _running = running;
        reply.run(|| crate::resource_router::handle_parsed_resource_request(&item_mux, request));
    });
}

struct Running {
    mux: Arc<Mux>,
    client: u64,
}

impl Drop for Running {
    fn drop(&mut self) {
        Sequences::advance(&self.mux, self.client);
    }
}
