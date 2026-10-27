//! `process_priority::set_self` on this test process, alone in its binary:
//! a process other tests start while it is best-effort would inherit it.
#![cfg(unix)]

use cmux_tui_platform::process_priority::{
    PriorityError, ProcessPriority, is_background, reversible, set_self,
};

#[test]
fn process_priority_set_self_reads_back_and_comes_back() {
    let me = std::process::id();
    if !reversible() {
        assert_eq!(set_self(ProcessPriority::BestEffort), Err(PriorityError::NotReversible));
        assert_eq!(is_background(me), Ok(false));
        return;
    }
    // A second thread exists while the change is made: every thread changes.
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    let other = std::thread::spawn(move || rx.recv());
    set_self(ProcessPriority::BestEffort).unwrap();
    assert_eq!(is_background(me), Ok(true));
    set_self(ProcessPriority::UserVisible).unwrap();
    assert_eq!(is_background(me), Ok(false));
    tx.send(()).unwrap();
    other.join().unwrap().unwrap();
}
