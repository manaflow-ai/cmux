use super::*;

fn made_by(created_by: Option<Creator>) -> Candidate {
    Candidate { created_by, ..Candidate::default() }
}

#[test]
fn a_script_session_that_is_no_subagent_folds_by_default() {
    assert_eq!(verdict(&made_by(Some(Creator::Script))), Verdict::Automatic);
    let request =
        Request { candidates: vec![made_by(Some(Creator::Script))], show_automatic: false };
    assert_eq!(plan(&request).automatic, vec![0]);
}

#[test]
fn the_setting_shows_every_automatic_session() {
    let request =
        Request { candidates: vec![made_by(Some(Creator::Script))], show_automatic: true };
    assert_eq!(plan(&request), Plan::default());
}

#[test]
fn person_started_rows_always_show() {
    assert_eq!(verdict(&made_by(None)), Verdict::Person);
    assert_eq!(verdict(&made_by(Some(Creator::Person))), Verdict::Person);
}

#[test]
fn subagents_always_show() {
    assert_eq!(verdict(&made_by(Some(Creator::Agent))), Verdict::Subagent);
    let asks = Candidate { needs_input: true, ..made_by(Some(Creator::Agent)) };
    assert_eq!(verdict(&asks), Verdict::Subagent);
}

#[test]
fn an_automatic_row_that_asks_or_is_pinned_shows() {
    let asks = Candidate { needs_input: true, ..made_by(Some(Creator::Script)) };
    assert_eq!(verdict(&asks), Verdict::NeedsInput);
    let pinned = Candidate { pinned: true, ..made_by(Some(Creator::Script)) };
    assert_eq!(verdict(&pinned), Verdict::Pinned);
}

#[test]
fn done_and_archived_rows_keep_their_own_folds() {
    let done = Candidate { marked_done: true, ..made_by(Some(Creator::Script)) };
    assert_eq!(verdict(&done), Verdict::MarkedDone);
    let archived = Candidate { archived: true, ..made_by(Some(Creator::Script)) };
    assert_eq!(verdict(&archived), Verdict::Archived);
}

#[test]
fn the_plan_names_only_automatic_rows_in_order() {
    let request = Request {
        candidates: vec![
            made_by(None),
            made_by(Some(Creator::Script)),
            made_by(Some(Creator::Agent)),
            Candidate { needs_input: true, ..made_by(Some(Creator::Script)) },
            made_by(Some(Creator::Script)),
        ],
        show_automatic: false,
    };
    assert_eq!(plan(&request).automatic, vec![1, 4]);
}

#[test]
fn the_wire_reads_snake_case_and_defaults() {
    let request: Request = serde_json::from_str(
        r#"{"candidates":[{"created_by":"script"},{},{"created_by":"agent"}]}"#,
    )
    .unwrap();
    assert_eq!(plan(&request).automatic, vec![0]);
}
