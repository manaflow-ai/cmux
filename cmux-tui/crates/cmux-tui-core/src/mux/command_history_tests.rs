//! The command history worker's pass class under `daemonRequestQos`:
//! a store or expiry pass runs at utility, except while a
//! client waits for a delete queued behind it. The worker runs on the test
//! thread, so `request_qos::tests::take_entered` sees the classes it entered.

use std::sync::{Arc, Mutex};

use cmux_threads::ThreadQos;

use super::{CommandHistoryMessage, CommandHistoryQueue, Worker};
use crate::request_qos::tests::take_entered;
use crate::resource::TerminalPublicId;
use crate::shell_history::FinishedCommand;
use crate::state::command_history_store::CommandDeletion;
use crate::{Mux, SurfaceOptions};

fn append() -> CommandHistoryMessage {
    let terminal = TerminalPublicId::parse("term_00000000000000000000000000000001").unwrap();
    CommandHistoryMessage::Append(
        terminal,
        FinishedCommand {
            command: Some("true".to_owned()),
            cwd: None,
            exit_code: Some(0),
            started_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap(),
            duration_ms: 1,
        },
    )
}

/// Runs a worker on this thread over `messages`, all queued before it
/// starts; it returns when the queue is empty.
fn run_worker(mux: &Arc<Mux>, queue: &CommandHistoryQueue, messages: Vec<CommandHistoryMessage>) {
    let (sender, receiver) = std::sync::mpsc::sync_channel(messages.len().max(1));
    for message in messages {
        sender.send(message).unwrap();
    }
    drop(sender);
    let worker = Worker {
        mux: Arc::downgrade(mux),
        checkpoint_pending: false,
        deletes_waiting: Arc::clone(&queue.deletes_waiting),
    };
    worker.run(receiver, None);
}

fn feature_on_mux(name: &str) -> (Arc<Mux>, CommandHistoryQueue) {
    let mux = Mux::new_for_test(name, SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    mux.set_terminal_command_history(true, None).expect("the switch is stored");
    let (sender, _receiver) = std::sync::mpsc::sync_channel(1);
    (mux, CommandHistoryQueue::new(sender))
}

/// A store pass nobody waits for runs at utility.
#[test]
fn command_history_store_pass_runs_at_utility_with_the_feature_on() {
    let (mux, queue) = feature_on_mux("history-pass-utility");
    let _ = take_entered();
    run_worker(&mux, &queue, vec![append()]);
    assert_eq!(take_entered(), vec![ThreadQos::Utility]);
    mux.shutdown();
}

/// A delete queued behind an append: the worker takes both, and the append
/// pass it runs first stays at the declared class, since the client waits
/// on its answer and no lock can raise the pass for it. After the answer,
/// the expiry pass runs at utility again.
#[test]
fn command_history_pass_before_a_waiting_delete_is_not_lowered() {
    let (mux, queue) = feature_on_mux("history-pass-delete");
    let before_answer: Arc<Mutex<Option<Vec<ThreadQos>>>> = Arc::default();
    let seen = Arc::clone(&before_answer);
    let delete = queue.delete(CommandDeletion::All, move |deleted| {
        assert!(deleted.is_ok(), "{deleted:?}");
        *seen.lock().unwrap() = Some(take_entered());
    });
    let _ = take_entered();
    run_worker(&mux, &queue, vec![append(), delete]);
    let before_answer = before_answer.lock().unwrap().take();
    assert_eq!(before_answer, Some(Vec::new()), "a utility pass ran while the delete waited");
    assert_eq!(take_entered(), vec![ThreadQos::Utility], "the expiry pass after the answer");
    assert_eq!(queue.deletes_waiting.load(std::sync::atomic::Ordering::Acquire), 0);
    mux.shutdown();
}
