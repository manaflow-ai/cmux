use super::*;

fn chat(lifecycle: Lifecycle) -> Candidate {
    Candidate { chat: true, lifecycle, has_activity: true, ..Candidate::default() }
}

#[test]
fn a_seen_finished_chat_settles() {
    assert_eq!(verdict(&chat(Lifecycle::Finished)), Verdict::Settled);
    assert_eq!(verdict(&chat(Lifecycle::Idle)), Verdict::Settled);
}

#[test]
fn an_unread_answer_is_not_settled() {
    let candidate = Candidate { unread: true, ..chat(Lifecycle::Finished) };
    assert_eq!(verdict(&candidate), Verdict::Unread);
}

#[test]
fn working_and_asking_chats_stay() {
    assert_eq!(verdict(&chat(Lifecycle::Working)), Verdict::Working);
    assert_eq!(verdict(&chat(Lifecycle::NeedsInput)), Verdict::NeedsInput);
    assert_eq!(verdict(&chat(Lifecycle::Failed)), Verdict::Failed);
    assert_eq!(verdict(&chat(Lifecycle::Lost)), Verdict::Lost);
    assert_eq!(verdict(&chat(Lifecycle::CiFailing)), Verdict::CiFailing);
}

#[test]
fn other_folds_and_pins_own_their_rows() {
    let archived = Candidate { archived: true, ..chat(Lifecycle::Finished) };
    let done = Candidate { marked_done: true, ..chat(Lifecycle::Finished) };
    let pinned = Candidate { pinned: true, ..chat(Lifecycle::Finished) };
    assert_eq!(verdict(&archived), Verdict::Archived);
    assert_eq!(verdict(&done), Verdict::MarkedDone);
    assert_eq!(verdict(&pinned), Verdict::Pinned);
}

#[test]
fn rows_that_are_not_chats_or_never_ran_never_settle() {
    let terminal = Candidate { chat: false, ..chat(Lifecycle::Idle) };
    let fresh = Candidate { has_activity: false, ..chat(Lifecycle::Idle) };
    assert_eq!(verdict(&terminal), Verdict::NotChat);
    assert_eq!(verdict(&fresh), Verdict::NoTurnYet);
}

#[test]
fn a_new_turn_or_a_question_unsettles_a_chat() {
    let mut candidate = chat(Lifecycle::Finished);
    assert_eq!(verdict(&candidate), Verdict::Settled);
    candidate.lifecycle = Lifecycle::Working;
    assert_eq!(verdict(&candidate), Verdict::Working);
    candidate.lifecycle = Lifecycle::NeedsInput;
    assert_eq!(verdict(&candidate), Verdict::NeedsInput);
    candidate.lifecycle = Lifecycle::Finished;
    candidate.unread = true;
    assert_eq!(verdict(&candidate), Verdict::Unread);
}

#[test]
fn layout_plan_lists_only_settled_rows() {
    let request = Request {
        candidates: vec![
            chat(Lifecycle::Working),
            chat(Lifecycle::Finished),
            Candidate { unread: true, ..chat(Lifecycle::Finished) },
            chat(Lifecycle::Idle),
        ],
        trigger: Trigger::Layout,
    };
    assert_eq!(plan(&request), Plan { settled: vec![1, 3], kept: Kept::default() });
}

#[test]
fn archive_plan_names_unread_failed_and_lost_explicitly() {
    let request = Request {
        candidates: vec![
            chat(Lifecycle::Finished),
            Candidate { unread: true, ..chat(Lifecycle::Finished) },
            chat(Lifecycle::Failed),
            chat(Lifecycle::Lost),
            chat(Lifecycle::Working),
            chat(Lifecycle::NeedsInput),
            Candidate { archived: true, ..chat(Lifecycle::Finished) },
            Candidate { chat: false, ..Candidate::default() },
        ],
        trigger: Trigger::Archive,
    };
    let plan = plan(&request);
    assert_eq!(plan.settled, vec![0]);
    assert_eq!(
        plan.kept,
        Kept { unread: vec![1], failed: vec![2], lost: vec![3], busy: vec![4, 5] }
    );
}

#[test]
fn the_wire_reads_snake_case_and_defaults() {
    let request: Request = serde_json::from_str(
        r#"{"candidates":[{"chat":true,"lifecycle":"finished","has_activity":true},{}],"trigger":"archive"}"#,
    )
    .unwrap();
    assert_eq!(plan(&request).settled, vec![0]);
}
