use super::*;

#[test]
fn a_miss_holds_a_machine_off_the_iroh_path() {
    let iroh = Iroh::default();
    assert!(!iroh.held_off("k"));
    iroh.miss("k");
    assert!(iroh.held_off("k"));
    assert!(!iroh.held_off("other"));
}

/// `irohDirect` unset: on exactly where `directPort` names a port (every lane VM), off elsewhere
/// (a Mac with no direct links); set, it wins either way.
#[test]
fn iroh_follows_direct_port_unless_set() {
    let on = |iroh_direct: Option<bool>, direct_port: Option<u16>| {
        crate::config::Config { iroh_direct, direct_port, ..Default::default() }.iroh_on()
    };
    assert!(!on(None, None), "the default stays off");
    assert!(!on(None, Some(0)), "directPort 0 means no direct path at all");
    assert!(on(None, Some(47791)));
    assert!(!on(Some(false), Some(47791)), "false turns it off where directPort is set");
    assert!(on(Some(true), None));
}
