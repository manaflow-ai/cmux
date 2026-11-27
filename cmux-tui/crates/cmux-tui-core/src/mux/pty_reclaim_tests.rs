use super::*;

const HOUR_MS: u64 = 60 * 60 * 1000;

fn sid(id: u64) -> SurfaceId {
    id
}

fn idle(surface: u64, since_ms: u64) -> ReclaimCandidate {
    ReclaimCandidate {
        surfaces: vec![sid(surface)],
        host: format!("host-{surface}"),
        pid: None,
        attach_epoch: 0,
        last_output_ms: Some(since_ms),
        facts: ParkFacts {
            saved_state_ready: true,
            prompt_since_ms: Some(since_ms),
            children: Some(false),
            used: true,
            shell: true,
            ..ParkFacts::default()
        },
    }
}

fn with(mut candidate: ReclaimCandidate, change: impl FnOnce(&mut ParkFacts)) -> ReclaimCandidate {
    change(&mut candidate.facts);
    candidate
}

#[test]
fn parks_only_idle_quiet_unwatched_unkept_shells_oldest_first() {
    let now = 200 * HOUR_MS;
    let busy = with(idle(2, 0), |f| f.prompt_since_ms = None);
    let watched = with(idle(3, 0), |f| f.attached = true);
    let kept = with(idle(4, 0), |f| f.kept = true);
    let agent = with(idle(5, 0), |f| f.program_reported = true);
    let printing = ReclaimCandidate { last_output_ms: Some(now - 1000), ..idle(6, 0) };
    let fresh = idle(7, now - 10 * 60 * 1000);
    let background_job = with(idle(9, 0), |f| f.children = Some(true));
    let unknown = with(idle(10, 0), |f| f.children = None);
    let resumable = with(idle(11, 0), |f| {
        f.resumable_agent = true;
        f.program_reported = true;
    });
    let candidates = [
        idle(1, 50 * HOUR_MS),
        busy,
        watched,
        kept,
        agent,
        printing,
        fresh,
        idle(8, HOUR_MS),
        background_job,
        unknown,
        resumable,
    ];
    assert_eq!(
        pick_reclaim(&candidates, now, 20),
        [sid(8), sid(1)],
        "the oldest prompt first; nothing busy, watched, kept, reporting, printing, fresh, \
         running a job, unread or an agent"
    );
    assert_eq!(pick_reclaim(&candidates, now, 1), [sid(8)]);
    assert!(pick_reclaim(&candidates, now, 0).is_empty());
}

#[test]
fn park_tabs_parks_only_idle_shells_and_names_the_rest() {
    let rules = ParkRules { agents: true, running_commands: false, unused_before_prompt: true };
    let watched = ReclaimCandidate {
        surfaces: vec![sid(2), sid(3)],
        ..with(idle(2, 0), |f| f.attached = true)
    };
    let kept = with(idle(4, 0), |f| f.kept = true);
    let busy = with(idle(5, 0), |f| {
        f.prompt_since_ms = None;
        f.command_running = true;
        f.children = Some(true);
    });
    let background_job = with(idle(6, 0), |f| f.children = Some(true));
    let agent = with(idle(7, 0), |f| {
        f.resumable_agent = true;
        f.program_reported = true;
        f.children = Some(true);
    });
    let candidates = [idle(1, 0), watched, kept, busy, background_job, agent];
    assert_eq!(
        split_parkable(
            &candidates,
            &[sid(1), sid(3), sid(4), sid(5), sid(6), sid(7), sid(9)],
            rules
        ),
        (
            vec![sid(1), sid(7), sid(9)],
            vec![
                (sid(3), ParkRefusal::Attached),
                (sid(4), ParkRefusal::Kept),
                (sid(5), ParkRefusal::CommandRunning),
                (sid(6), ParkRefusal::Children),
            ]
        ),
        "every view of an attached terminal stays; a resumable agent parks; a surface no \
         terminal shows is left to park_terminal_tabs"
    );
}

#[test]
fn reclaims_only_under_the_reserve_and_refills_past_it() {
    assert_eq!(reclaim_need(100, 511), 0);
    assert_eq!(reclaim_need(511 - PTY_RESERVE, 511), 0);
    assert_eq!(reclaim_need(511 - PTY_RESERVE + 1, 511), PTY_REFILL - PTY_RESERVE + 1);
    assert_eq!(reclaim_need(511, 511), PTY_REFILL);
    assert_eq!(reclaim_need(527, 511), PTY_REFILL, "more nodes than the limit");
    assert_eq!(reclaim_need(40, 50), 50 - 10, "a limit under the refill frees what it can");
}

#[test]
fn counts_only_numbered_pty_nodes() {
    assert!(is_pty_node("ttys000"));
    assert!(is_pty_node("ttys510"));
    assert!(!is_pty_node("ttys0"), "legacy node");
    assert!(!is_pty_node("ttysf"));
    assert!(!is_pty_node("ttyp000"));
}

#[test]
fn a_failed_launch_forces_the_next_pass() {
    let mut clock = ReclaimClock::default();
    let start = Instant::now();
    assert!(clock.due(start, false));
    assert!(!clock.due(start + Duration::from_millis(10), false));
    assert!(clock.due(start + Duration::from_millis(20), true));
    assert!(clock.due(start + RECLAIM_CHECK_EVERY * 2, false));
}
