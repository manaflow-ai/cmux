use super::*;

fn policy(timed: i64, socket: i64) -> CmuxRetryPolicy {
    CmuxRetryPolicy::new(250_000_000, 30_000_000_000, timed, socket, false)
}

#[test]
fn spacing_doubles_to_the_cap_with_no_jitter_at_the_middle_draw() {
    let p = policy(10, 3);
    let spaced: Vec<u64> = (0..10).map(|a| p.spacing_ns(a, 0.5)).collect();
    assert_eq!(
        spaced,
        vec![
            250_000_000,
            500_000_000,
            1_000_000_000,
            2_000_000_000,
            4_000_000_000,
            8_000_000_000,
            16_000_000_000,
            30_000_000_000,
            30_000_000_000,
            30_000_000_000
        ]
    );
    // The floor: 80 % of initial; the ceiling: the cap.
    assert_eq!(p.spacing_ns(0, 0.0), 200_000_000);
    assert_eq!(p.spacing_ns(20, 1.0), 30_000_000_000);
}

/// A loop that is not `keeps_trying` says it waits for an event, with its
/// reason, once its timed budget is spent, instead of reading as still
/// connecting; it arms no timer. A `keeps_trying` loop keeps one timed
/// attempt per cap and never reports it.
#[test]
fn past_its_timed_budget_a_loop_reports_waiting_for_an_event_with_its_reason() {
    for preset in Preset::ALL {
        let policy = preset.policy();
        let mut pacer = CmuxRetryPacer::new(policy);
        let mut armed = 0;
        for _ in 0..policy.timed_retries {
            assert_eq!(pacer.wait(), RetryWait::Timed, "{}", preset.name());
            armed += usize::from(pacer.failed(0.5).is_some());
        }
        assert_eq!(armed, usize::try_from(policy.timed_retries).unwrap());
        let after = pacer.failed(0.5);
        if policy.keeps_trying {
            assert_eq!(after, Some(policy.maximum_ns), "{}", preset.name());
            assert_eq!(pacer.wait(), RetryWait::Timed, "{}", preset.name());
            continue;
        }
        assert_eq!(after, None, "{}: no timer is added", preset.name());
        let wait = pacer.wait();
        assert_eq!(wait, RetryWait::ForEvent(WaitReason::TimedBudgetSpent), "{}", preset.name());
        assert_eq!(
            (wait.state(), wait.reason()),
            ("waiting-for-event", Some("timed-budget-spent"))
        );
        // An event starts the loop again; its report follows.
        pacer.reset();
        assert_eq!(pacer.wait().state(), "retrying");
    }
}

/// A daemon that keeps replacing its socket and dying spends the socket
/// wakeups too: only an explicit event wakes the loop, and it says so.
#[test]
fn a_crash_loop_reports_that_only_an_event_wakes_it() {
    let mut pacer = CmuxRetryPacer::new(policy(1, 2));
    assert!(pacer.failed_at(1, 1, 0.5).is_some());
    assert_eq!(pacer.failed_at(1, 1, 0.5), None);
    assert_eq!(pacer.wait(), RetryWait::ForEvent(WaitReason::TimedBudgetSpent));
    for inode in 2..=3 {
        pacer.woke(WakeCause::Socket);
        let _ = pacer.failed_at(1, inode, 0.5);
        let _ = pacer.failed_at(1, inode, 0.5);
    }
    assert!(!pacer.wakes_on_socket());
    assert_eq!(pacer.wait(), RetryWait::ForEvent(WaitReason::CrashLoop));
    assert_eq!(pacer.wait().reason(), Some("crash-loop"));
}

#[test]
fn a_zero_initial_is_corrected() {
    let p = CmuxRetryPolicy::new(0, 0, 1, 3, false);
    assert_eq!((p.initial_ns, p.maximum_ns), (100_000_000, 100_000_000));
}
