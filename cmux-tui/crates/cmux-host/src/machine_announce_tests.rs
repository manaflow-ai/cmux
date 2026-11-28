//! The periodic gratuitous ARP announce stops after [`ANNOUNCE_REPEATS`], so
//! an idle VM goes quiet and the provider's idle timeout can pause it.

use super::*;

fn bound(id: &str) -> Observation {
    Observation {
        instance_id: Some(id.into()),
        bake_id: None,
        bound_id: Some(id.into()),
        clone_signal: false,
    }
}

/// Runs the loop until it stops re-arming; returns how many announces ran.
fn run_loop(m: &mut Machine) -> u32 {
    let mut n = 0;
    loop {
        let out = m.step(Input::AnnounceTick);
        assert_eq!(out, [Action::Announce], "tick {n}");
        n += 1;
        let out = m.step(Input::AnnounceDone);
        if !out.contains(&Action::ArmAnnounce) {
            assert_eq!(out, [], "after announce {n}");
            return n;
        }
        assert!(n <= ANNOUNCE_REPEATS, "the loop ran past its bound");
    }
}

#[test]
fn the_periodic_announce_stops_so_an_idle_vm_can_pause() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: false });
    let out = m.step(Input::Observed(bound("a")));
    assert!(out.contains(&Action::ArmAnnounce), "{out:?}");
    assert_eq!(run_loop(&mut m), ANNOUNCE_REPEATS);
    // Nothing re-arms it while the machine stays idle.
    assert_eq!(m.step(Input::AnnounceDone), []);
}

#[test]
fn a_resume_announces_and_restarts_the_bounded_loop() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: false });
    m.step(Input::Observed(bound("a")));
    run_loop(&mut m);
    let out = m.step(Input::ResumeSignal);
    assert!(out.contains(&Action::Announce), "{out:?}");
    let out = m.step(Input::AnnounceDone);
    assert!(out.contains(&Action::ArmAnnounce), "{out:?}");
    assert_eq!(run_loop(&mut m), ANNOUNCE_REPEATS);
}

#[test]
fn the_bound_leaves_room_before_the_provider_idle_timeout() {
    // 300 s is the staging VMs' idleTimeoutSeconds; the loop's last announce
    // must leave most of it quiet.
    let loop_s = u64::from(ANNOUNCE_REPEATS) * crate::config::DEFAULT_ANNOUNCE_INTERVAL.as_secs();
    assert!(loop_s <= 150, "{loop_s} s of announces");
}
