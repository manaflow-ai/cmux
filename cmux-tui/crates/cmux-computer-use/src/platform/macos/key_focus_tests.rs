use super::*;

const OWN: i32 = 500;
const FRONT: i32 = 388;

#[test]
fn only_the_menus_theft_while_armed_is_released() {
    let owner = |pid: i32| pid == 986;
    let c = |ty, sub, thief: i64, armed| classify(ty, sub, thief, FRONT, OWN, armed, owner);
    assert_eq!(c(21, 0x4000, 986, true), Notice::ReleaseAndDrop(986));
    // Not armed: no call is opening a menu.
    assert_eq!(c(21, 0x4000, 986, false), Notice::Pass);
    // The person switching to another regular app passes.
    assert_eq!(c(21, 0x4000, 777, true), Notice::Pass);
    // The person's app itself, or this process: pass.
    assert_eq!(c(21, 0x4000, i64::from(FRONT), true), Notice::Pass);
    assert_eq!(c(21, 0x4000, i64::from(OWN), true), Notice::Pass);
    // Other notices (focus returned, another type) pass.
    assert_eq!(c(21, 0x8000, 986, true), Notice::Pass);
    assert_eq!(c(13, 0x4000, 986, true), Notice::Pass);
    assert_eq!(c(21, 0x4000, i64::MAX, true), Notice::Pass);
    assert_eq!(c(21, 0x4000, 0, true), Notice::Pass);
}

#[test]
fn the_menus_tap_drops_only_this_processs_notice_during_the_lookup() {
    assert!(drops_own_notice(21, 0x4000, i64::from(OWN), OWN, true));
    assert!(!drops_own_notice(21, 0x4000, i64::from(OWN), OWN, false));
    assert!(!drops_own_notice(21, 0x4000, 42, OWN, true));
    assert!(!drops_own_notice(21, 0x8000, i64::from(OWN), OWN, true));
}

#[test]
fn the_menus_theft_is_the_newest_live_id_below_this_processs() {
    // Ids 131 (the menu's) is live; 132 is this process's own.
    assert_eq!(release_below(132, |id| if id == 131 { 0 } else { -1 }), Some(131));
    // Another app stole in between: the menu's is two below.
    assert_eq!(release_below(132, |id| if id == 130 { 0 } else { -1 }), Some(130));
    // Nothing live within the slack.
    assert_eq!(release_below(132, |_| -1), None);
    // Never id 0 or below.
    assert_eq!(release_below(2, |_| 0), Some(1));
    assert_eq!(release_below(1, |_| 0), None);
}
