//! A panic while a thread held the agent roster (or its fold lock) poisons
//! the lock. The roster is a cache of the journal, so the daemon keeps it:
//! readers and the terminal close path recover the guard
//! (`PoisonError::into_inner`) as the rest of the daemon does, instead of
//! panicking on every later `cmux agent list` or terminal close (#32243
//! review).

use super::*;

fn poison<T: Send>(mutex: &Mutex<T>) {
    std::thread::scope(|scope| {
        let _ = scope
            .spawn(|| {
                let _guard = mutex.lock().unwrap_or_else(PoisonError::into_inner);
                // crash-allow: test-only panic to poison the lock under test.
                panic!("poison the lock under test");
            })
            .join();
    });
    assert!(mutex.is_poisoned(), "the lock is poisoned");
}

#[test]
fn a_poisoned_roster_does_not_break_agent_list_or_terminal_close() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    poison(&mux.agent_roster);
    poison(&mux.agent_roster_fold);

    let listed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        mux.list_agents(None, None).len()
    }));
    assert!(listed.is_ok(), "list_agents panicked on a poisoned roster lock");

    let terminal = TerminalPublicId::parse(format!("term_{:032x}", 7)).unwrap();
    let purged = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        mux.purge_terminal_side_tables(&terminal);
    }));
    assert!(purged.is_ok(), "a terminal close panicked on a poisoned roster lock");
}
