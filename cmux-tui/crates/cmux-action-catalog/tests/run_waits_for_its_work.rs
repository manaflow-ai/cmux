//! An action whose run ends only when its work is done (a server round trip: pause, resume)
//! must say so with `waits_for_result` (or `waits_for_person`, `starts_terminal`), so the
//! control socket gives it a deadline sized to that work. Without the flag the app's 2 s
//! control-plane deadline answered `action.run did not finish within 1999 ms` while the
//! pause or resume was still in flight (`cmux vm pause`, 2026-11-11T00:01:47Z).
//!
//! Detector for the class: every description that promises "the run ends when" its work is
//! done is checked against the flags.

use cmux_action_catalog::{actions, find};

fn waits(action: &cmux_action_catalog::Action) -> bool {
    action.waits_for_result || action.waits_for_person || action.starts_terminal
}

#[test]
fn a_run_that_promises_to_end_with_its_work_waits_for_it() {
    let short: Vec<&str> = actions()
        .filter(|action| action.description.is_some_and(|text| text.contains("the run ends when")))
        .filter(|action| !waits(action))
        .map(|action| action.id)
        .collect();
    assert!(
        short.is_empty(),
        "these actions promise the run ends with their work but get the 2 s control-plane deadline; set waits_for_result: {short:?}"
    );
}

#[test]
fn pause_and_resume_wait_for_the_server() {
    for id in ["cloudPauseMachine", "cloudResumeMachine"] {
        let action = find(id).unwrap_or_else(|| panic!("{id} is in the catalog"));
        assert!(action.waits_for_result, "{id} must wait for the server's answer");
    }
}
