use super::*;
use std::cell::{Cell, RefCell};

fn asking(dialog: &str) -> Value {
    json!({ "result": {
        "pending": true, "ask_again_joins": true, "waiting_for": "person", "dialog_id": dialog,
        "source_machine_id": "vm_src"
    } })
}

fn running() -> Value {
    json!({ "result": { "pending": true, "ask_again_joins": true, "source_machine_id": "vm_src" } })
}

/// The answers the app gives each ask again, in order, and the notes heard.
fn joined(
    first: Value,
    answers: Vec<Result<Value, Value>>,
    clock: &[u64],
) -> (Result<Result<Value, Value>, Value>, Vec<String>, usize) {
    let answers = RefCell::new(answers.into_iter());
    let asks = Cell::new(0);
    let ticks = Cell::new(0usize);
    let start = Instant::now();
    let mut notes = Vec::new();
    let end = join(
        first,
        Duration::from_secs(600),
        || {
            let at = clock.get(ticks.get()).copied().unwrap_or(0);
            ticks.set(ticks.get() + 1);
            start + Duration::from_secs(at)
        },
        |answer| notes.push(note(answer)),
        || {
            asks.set(asks.get() + 1);
            Ok(answers.borrow_mut().next().expect("no more answers"))
        },
    );
    (end, notes, asks.get())
}

/// A fork the person allowed answers at once that it waits for the dialog, then the new machine.
#[test]
fn an_allowed_fork_says_it_waits_then_answers_the_new_machine() {
    let forked = json!({ "result": { "machine_id": "vm_new", "source_machine_id": "vm_src",
                                     "snapshot_id": "snap_1", "target": "machine:vm_new" } });
    let (end, notes, asks) =
        joined(asking("7"), vec![Ok(asking("7")), Ok(running()), Ok(forked.clone())], &[]);
    assert_eq!(end, Ok(Ok(forked)));
    assert_eq!(asks, 3);
    assert_eq!(notes.len(), 2, "one note per state, not per ask: {notes:?}");
    assert!(notes[0].contains("dialog 7"), "{}", notes[0]);
    assert!(notes[1].contains("allowed"), "{}", notes[1]);
}

/// Don't Allow ends the run refused: the CLI reports the refusal (exit 1), never pending.
#[test]
fn a_declined_change_is_the_apps_refusal() {
    let refused = json!({ "code": "unavailable",
                          "message": "Don't Allow was chosen in the cmux window; nothing changed." });
    let (end, _, _) = joined(asking("3"), vec![Err(refused.clone())], &[]);
    assert_eq!(end, Ok(Err(refused)));
}

/// Nobody answered within the limit: an error naming the dialog, not a pending success.
#[test]
fn an_unanswered_change_is_an_error_naming_its_dialog() {
    let (end, _, asks) = joined(asking("9"), vec![Ok(asking("9"))], &[0, 0, 700]);
    let Ok(Err(error)) = end else { panic!("expected an error, got {end:?}") };
    assert_eq!(error["code"], "cloud.change.unanswered");
    assert!(error["message"].as_str().unwrap().contains("dialog 9"), "{error}");
    assert_eq!(asks, 1);
}

/// An answer that is not a joinable pending (a person's own run, any other action) is kept as is.
#[test]
fn an_answer_that_does_not_join_is_returned_as_is() {
    let plain = json!({ "result": { "pending": true, "machine_id": "vm_a" } });
    let (end, notes, asks) = joined(plain.clone(), vec![], &[]);
    assert_eq!(end, Ok(Ok(plain)));
    assert!(notes.is_empty());
    assert_eq!(asks, 0);
}
