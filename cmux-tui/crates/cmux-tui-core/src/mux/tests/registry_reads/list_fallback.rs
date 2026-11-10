//! `terminal.list` with no scope when its lock-free read can not give the
//! list (the two late review items of #40709).
//!
//! The list reads the stored rows on the registry's read-only connection and
//! the live terminals under the state lock: two cuts, with no registry lock.
//! Two things can go wrong there, and the list must still answer: the read of
//! the rows fails (the read-only connection is one more SQLite connection: it
//! can be busy in a checkpoint or lose its file), or a terminal ends between
//! the two cuts. Then the list reads the two as one cut under the registry and
//! state locks, as the session snapshot does.

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

/// Review of #40709: an error of the committed read went to the client as the
/// list's answer, with no read under the locks. The registry's own
/// connection still reads the rows, so the list has an answer to give.
#[test]
fn a_terminal_list_answers_when_its_committed_read_fails() {
    let (mux, root) = persistent_mux("list-fallback-read");
    mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let clean = terminal_list(&mux);
    assert_eq!(clean["ok"], true, "{clean}");
    assert_eq!(listed_ids(&clean).len(), 2, "the session has two terminals: {clean}");

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
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}
