//! `terminal.list` with no scope when its lock-free read can not give the
//! list (the two late review items of #40709).
//!
//! The list reads the stored rows on the registry's read-only connection and
//! the live terminals under the state lock: two cuts, with no registry lock.
//! Two things can go wrong there, and the list must still answer: the read of
//! the rows fails (the read-only connection is one more SQLite connection: it
//! can be busy in a checkpoint or lose its file), or a terminal ends between
//! the two cuts. Then the list reads the two as one cut under the registry and
//! state locks, as the session snapshot does. Each such list is counted
//! (`server-stats` `registry_reads`); when the read under the locks fails
//! too, the list answers `operation.failed`.

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use serde_json::{Value, json};

use super::*;

/// The whole response of a `terminal.list` with no scope.
fn terminal_list(mux: &Arc<Mux>) -> Value {
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":"terminal.list",
        "operation":"terminal.list","params":{"machine":"current","session":"current"}});
    crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap()
}

/// The ids a list response names, in its order.
fn listed_ids(response: &Value) -> Vec<Value> {
    response["result"]
        .as_array()
        .map(|rows| rows.iter().map(|row| row["id"].clone()).collect())
        .unwrap_or_default()
}

/// Refuses each read of the terminal rows (`terminal_hosts`) and allows each
/// other statement: the first read of a terminal list fails, and no other
/// read of the request does.
fn no_terminal_rows(context: AuthContext<'_>) -> Authorization {
    match context.action {
        AuthAction::Read { table_name: "terminal_hosts", .. } => Authorization::Deny,
        _ => Authorization::Allow,
    }
}

/// Make the registry's read-only connection fail each read of the terminal
/// rows (`refuse`), or read them again.
fn refuse_terminal_rows_on_the_reader(mux: &Mux, refuse: bool) {
    mux.registry_connection
        .read_committed(|connection| {
            if refuse {
                connection.authorizer(Some(no_terminal_rows))?;
            } else {
                connection.authorizer(None::<fn(AuthContext<'_>) -> Authorization>)?;
            }
            Ok(())
        })
        .expect("a file registry has a reader")
        .unwrap();
}

/// Make the registry's own connection fail each read of the terminal rows
/// (`refuse`), or read them again. On an in-memory registry it is the one
/// connection: the lock-free read and the read under the locks both use it.
fn refuse_terminal_rows_on_the_registry_connection(mux: &Mux, refuse: bool) {
    let connection = mux.registry_connection.get();
    if refuse {
        connection.authorizer(Some(no_terminal_rows)).unwrap();
    } else {
        connection.authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    }
}

/// Review of #40709: an error of the committed read went to the client as the
/// list's answer, with no read under the locks. The registry's own
/// connection still reads the rows, so the list has an answer to give. The
/// daemon counts that list: it waited for the registry lock.
#[test]
fn a_terminal_list_answers_when_its_committed_read_fails() {
    let (mux, root) = persistent_mux("list-fallback-read");
    mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let clean = terminal_list(&mux);
    assert_eq!(clean["ok"], true, "{clean}");
    assert_eq!(listed_ids(&clean).len(), 2, "the session has two terminals: {clean}");
    let before = mux.registry_read_stats();

    refuse_terminal_rows_on_the_reader(&mux, true);
    let answered = terminal_list(&mux);
    refuse_terminal_rows_on_the_reader(&mux, false);

    assert_eq!(
        answered["ok"], true,
        "terminal.list failed when only its lock-free read failed: {answered}"
    );
    // The shells keep committing (directory, progress), so compare what
    // those commits do not change: the listed ids.
    assert_eq!(listed_ids(&answered), listed_ids(&clean), "the list names the same terminals");
    let after = mux.registry_read_stats();
    assert_eq!(
        (
            after.list_fallbacks - before.list_fallbacks,
            after.committed_read_failures - before.committed_read_failures,
            after.fallback_failures - before.fallback_failures,
        ),
        (1, 1, 0),
        "one fallback, for a failed committed read, that answered: {before:?} then {after:?}"
    );

    // The reader reads again: the next list takes no lock and counts nothing.
    let again = terminal_list(&mux);
    assert_eq!(again["ok"], true, "{again}");
    assert_eq!(mux.registry_read_stats(), after, "a lock-free list is not a fallback");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// When the read under the locks fails too, the list has no answer: the
/// client gets the error of that read in the shape the protocol gives each
/// error (`code`, `message`, `details`, `retryable`), and the daemon counts
/// it. Nothing panics, and the next list answers.
#[test]
fn a_terminal_list_that_no_connection_can_read_answers_operation_failed() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let clean = terminal_list(&mux);
    assert_eq!(clean["ok"], true, "{clean}");
    let before = mux.registry_read_stats();

    refuse_terminal_rows_on_the_registry_connection(&mux, true);
    let refused = terminal_list(&mux);
    refuse_terminal_rows_on_the_registry_connection(&mux, false);

    assert_eq!(refused["ok"], false, "{refused}");
    let error = &refused["error"];
    assert_eq!(error["code"], "operation.failed", "{refused}");
    assert_eq!(error["retryable"], false, "{refused}");
    assert_eq!(error["details"]["operation"], "resource.runtime", "{refused}");
    assert!(error["message"].as_str().is_some_and(|message| !message.is_empty()), "{refused}");
    assert_eq!(error["details"]["reason"], error["message"], "{refused}");
    let after = mux.registry_read_stats();
    assert_eq!(
        (
            after.list_fallbacks - before.list_fallbacks,
            after.committed_read_failures - before.committed_read_failures,
            after.fallback_failures - before.fallback_failures,
        ),
        (1, 1, 1),
        "one fallback, for a failed committed read, that failed too: {before:?} then {after:?}"
    );

    let again = terminal_list(&mux);
    assert_eq!(again["ok"], true, "{again}");
    assert_eq!(listed_ids(&again), listed_ids(&clean), "the list names the same terminals");
}

/// The rows and the live terminals are two cuts. A close removes a terminal
/// from the live catalog under the state lock and gives up its durable
/// identity after it released that lock, so a list can hold the handle of a
/// terminal that has no identity any more: the builder refuses it. The hook
/// does those two memory steps of a close between the two cuts (it does not
/// change the stored rows). The list then reads one cut under the locks,
/// where the terminal has no live surface, and answers: the stored row
/// still shows. The daemon counts the fallback, and no failed read.
#[test]
fn a_terminal_list_answers_when_a_terminal_ends_between_its_two_cuts() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let terminal_id = first.terminal_public_id().cloned().expect("a terminal has a public id");
    let clean = terminal_list(&mux);
    assert_eq!(clean["ok"], true, "{clean}");
    assert_eq!(listed_ids(&clean).len(), 2, "the session has two terminals: {clean}");
    let before = mux.registry_read_stats();

    let ending = mux.clone();
    crate::resource_api::set_terminal_list_between_cuts_hook(move || {
        let runtime = ending
            .remove_terminal_catalog_for_test(&terminal_id)
            .expect("the terminal was in the live catalog");
        let runtime_id = runtime.terminal_runtime_id().expect("a terminal runtime has an id");
        ending
            .reserved_in_process_terminals
            .lock()
            .unwrap()
            .remove(&runtime_id)
            .expect("an in-process terminal keeps its durable identity in the mux");
    });
    let answered = terminal_list(&mux);

    assert_eq!(
        answered["ok"], true,
        "terminal.list failed when a terminal ended between its two cuts: {answered}"
    );
    assert_eq!(listed_ids(&answered), listed_ids(&clean), "the stored rows still list it");
    let after = mux.registry_read_stats();
    assert_eq!(
        (
            after.list_fallbacks - before.list_fallbacks,
            after.committed_read_failures - before.committed_read_failures,
            after.fallback_failures - before.fallback_failures,
        ),
        (1, 0, 0),
        "one fallback, with no failed read, that answered: {before:?} then {after:?}"
    );
}
