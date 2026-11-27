use super::*;

#[test]
fn the_answer_comes_a_margin_before_each_installed_timeout() {
    let by = |seconds: u64| answer_by(Duration::from_secs(seconds));
    assert_eq!(by(3), Duration::from_millis(1500));
    assert_eq!(by(5), Duration::from_millis(3500));
    assert_eq!(by(10), Duration::from_millis(8500));
    assert_eq!(by(90), Duration::from_secs(85));
    assert_eq!(by(600), Duration::from_secs(595));
    assert_eq!(by(1), Duration::from_millis(500));
}

#[test]
fn unarmed_waits_keep_their_own_bound_and_answers_are_written() {
    // The daemon and the CLI read through the same code with no deadline.
    let before = Instant::now();
    let until = within(Duration::from_millis(1500));
    assert!(until >= before + Duration::from_millis(1500));
    let mut wrote = false;
    answer(|| wrote = true);
    assert!(wrote);
}

#[test]
fn a_held_repository_barrier_answers_its_denial_never_a_pass() {
    // A pre-tool hook still waiting on its repository fails closed at its
    // deadline, as its installed `||exit 2` does; once the barrier passes the
    // deadline answer is the plain no-decision again.
    EMPTY_OBJECT.store(true, Ordering::SeqCst);
    let denial = cmux_git::native_hook::denial("it did not finish inside the hook's timeout");
    hold_barrier(&denial.to_string());
    let held: serde_json::Value = serde_json::from_slice(due_answer().unwrap()).unwrap();
    assert_eq!(held["hookSpecificOutput"]["permissionDecision"], "deny");
    barrier_cleared();
    assert_eq!(due_answer(), Some(b"{}\n".as_slice()));
}
