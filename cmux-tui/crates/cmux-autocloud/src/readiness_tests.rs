use super::*;

#[test]
fn link_half_climbs_to_sixty() {
    let mut r = Readiness::default();
    let mut last = r.percent();
    for p in [Phase::SignedIn, Phase::Dialing, Phase::LinkUp, Phase::Initialized, Phase::ChatOpen] {
        r.advance(p);
        assert!(r.percent() > last, "{p:?} must raise the figure");
        assert!(r.percent() < 60);
        last = r.percent();
    }
}

#[test]
fn no_fill_reported_is_ready_at_replay() {
    let mut r = Readiness::default();
    r.advance(Phase::Replayed);
    assert_eq!(r.percent(), 100);
    assert_eq!(r.label(), "ready");
}

#[test]
fn fill_maps_onto_sixty_to_hundred() {
    let mut r = Readiness::default();
    r.advance(Phase::Replayed);
    r.set_fill(0);
    assert_eq!(r.percent(), 60);
    r.set_fill(50);
    assert_eq!(r.percent(), 80);
    r.set_fill(250);
    assert_eq!(r.percent(), 100);
}

#[test]
fn never_moves_back_except_on_a_drop() {
    let mut r = Readiness::default();
    r.advance(Phase::ChatOpen);
    r.advance(Phase::LinkUp);
    assert_eq!(r.phase, Phase::ChatOpen);
    r.set_fill(40);
    r.reset_link();
    assert_eq!(r.phase, Phase::Dialing);
    assert_eq!(r.fill, Some(40));
}
