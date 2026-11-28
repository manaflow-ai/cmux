use super::*;

fn reason(e: &RpcError) -> (String, String) {
    let d = e.data.as_ref().unwrap();
    (d["reason"].as_str().unwrap().into(), d["limit"].as_str().unwrap().into())
}

#[test]
fn one_caller_never_holds_every_slot_and_others_still_run() {
    let b = Budget::default();
    let held: Vec<_> = (0..CALLER_RUNNING).map(|_| b.take("loop", 0).unwrap()).collect();
    let e = b.take("loop", 0).err().unwrap();
    assert_eq!(reason(&e), ("github.budget".into(), "running".into()));
    assert!(CALLER_RUNNING < crate::github_broker::OWNER_SLOTS);
    let _other = b.take("pusher", 0).unwrap();
    drop(held);
    b.take("loop", 1).unwrap();
}

#[test]
fn a_loop_is_stopped_within_the_window_and_let_go_after_it() {
    let b = Budget::default();
    for i in 0..CALLER_RATE as u64 {
        drop(b.take("loop", i).unwrap());
    }
    let e = b.take("loop", 100).err().unwrap();
    assert_eq!(reason(&e), ("github.budget".into(), "rate".into()));
    assert_eq!(e.data.as_ref().unwrap()["retryAfterMs"], CALLER_WINDOW_MS - 100);
    assert!(b.take("other", 100).is_ok());
    assert!(b.take("loop", CALLER_WINDOW_MS).is_ok());
}

#[test]
fn idle_callers_go_once_the_map_is_full() {
    let b = Budget::default();
    for i in 0..CALLERS_MAX {
        drop(b.take(&format!("s{i}"), 0).unwrap());
    }
    let _busy = b.take("s0", 1).unwrap();
    b.take("new", CALLER_WINDOW_MS + 1).unwrap();
    assert!(b.callers() <= 3);
}
