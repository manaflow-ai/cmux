use super::*;

fn waiting(lifecycle: Lifecycle, background_waits: u32) -> Candidate {
    Candidate { chat: true, lifecycle, background_waits, ..Candidate::default() }
}

#[test]
fn a_seen_chat_waiting_on_background_work_is_shelved() {
    assert_eq!(verdict(&waiting(Lifecycle::Finished, 1)), Verdict::Shelved);
    assert_eq!(verdict(&waiting(Lifecycle::Idle, 3)), Verdict::Shelved);
}

#[test]
fn a_chat_with_nothing_running_stays() {
    assert_eq!(verdict(&waiting(Lifecycle::Finished, 0)), Verdict::NothingRunning);
}

#[test]
fn a_running_turn_is_working_not_waiting() {
    assert_eq!(verdict(&waiting(Lifecycle::Working, 2)), Verdict::Working);
}

#[test]
fn a_chat_that_needs_the_person_comes_back() {
    assert_eq!(verdict(&waiting(Lifecycle::NeedsInput, 1)), Verdict::NeedsInput);
    assert_eq!(verdict(&waiting(Lifecycle::Failed, 1)), Verdict::Failed);
    assert_eq!(verdict(&waiting(Lifecycle::Lost, 1)), Verdict::Lost);
    assert_eq!(verdict(&waiting(Lifecycle::CiFailing, 1)), Verdict::CiFailing);
    let unread = Candidate { unread: true, ..waiting(Lifecycle::Finished, 1) };
    assert_eq!(verdict(&unread), Verdict::Unread);
}

#[test]
fn other_folds_and_pins_own_their_rows() {
    let archived = Candidate { archived: true, ..waiting(Lifecycle::Idle, 1) };
    let done = Candidate { marked_done: true, ..waiting(Lifecycle::Idle, 1) };
    let pinned = Candidate { pinned: true, ..waiting(Lifecycle::Idle, 1) };
    let terminal = Candidate { chat: false, ..waiting(Lifecycle::Idle, 1) };
    assert_eq!(verdict(&archived), Verdict::Archived);
    assert_eq!(verdict(&done), Verdict::MarkedDone);
    assert_eq!(verdict(&pinned), Verdict::Pinned);
    assert_eq!(verdict(&terminal), Verdict::NotChat);
}

/// The done-when's flow: a chat starts a 60 s background job and ends its
/// turn (shelved); the job ends, acpmux sends the chat the end, a turn runs
/// (back in place), and its answer is unread (still in place).
#[test]
fn a_chat_waiting_on_a_background_job_folds_and_comes_back_when_it_ends() {
    let mut chat = waiting(Lifecycle::Working, 1);
    assert_eq!(verdict(&chat), Verdict::Working);
    chat.lifecycle = Lifecycle::Finished;
    assert_eq!(verdict(&chat), Verdict::Shelved);
    chat.background_waits = 0;
    chat.lifecycle = Lifecycle::Working;
    assert_eq!(verdict(&chat), Verdict::Working);
    chat.lifecycle = Lifecycle::Finished;
    chat.unread = true;
    assert_eq!(verdict(&chat), Verdict::Unread);
}

#[test]
fn plan_lists_only_shelved_rows_in_order() {
    let request = Request {
        candidates: vec![
            waiting(Lifecycle::Idle, 1),
            waiting(Lifecycle::Working, 1),
            waiting(Lifecycle::Idle, 0),
            waiting(Lifecycle::Finished, 2),
        ],
    };
    assert_eq!(plan(&request), Plan { shelved: vec![0, 3] });
}
