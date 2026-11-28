//! start_fault.rs: `CMUX_CLOUD_FAULT` names every class of the recovery table, and each injected error is read
//! back as its own class, so the probe's per-class run measures that class's row. Leo,
//! goals/cloud-errors-self-recover: "Fix the cause".

use super::super::recover::{Class, classify};
use super::super::start_fault::{class_named, error, parse};
use super::*;

#[test]
fn every_class_is_named_and_its_injected_error_is_read_back_as_it() {
    assert_eq!(Class::NAMES.len(), Class::ALL.len());
    for (&name, &class) in Class::NAMES.iter().zip(Class::ALL) {
        assert_eq!(class_named(name), Some(class), "{name}");
        for asked in [request(&[]), request(&["--name", "dev"]), request(&["--target", "vm:vm-1"])]
        {
            let Outcome::Failed { error, exit } = error(class, &asked) else {
                panic!("{name} failed")
            };
            assert_eq!(exit, 1);
            assert_eq!(classify(&error), Some(class), "{name}: {error}");
            assert_eq!(error["details"]["injected"], true, "{name}");
        }
    }
}

#[test]
fn names_fold_case_and_separators_and_unknown_names_are_dropped() {
    let classes: Vec<Class> =
        parse("machine_stuck, StartPending,list-unread,,nope,MACHINE_STUCK").into_iter().collect();
    assert_eq!(
        classes,
        vec![Class::MachineStuck, Class::StartPending, Class::ListUnread, Class::MachineStuck]
    );
    assert!(parse("").is_empty());
}

/// A pending start keeps the machine the person named, and a new-machine run's names one no machine has, so the
/// table's rerun never lands on a machine nobody asked for.
#[test]
fn a_pending_start_names_the_requested_machine_or_a_fresh_one() {
    let Outcome::Failed { error: named, .. } =
        error(Class::StartPending, &request(&["--name", "dev"]))
    else {
        panic!()
    };
    assert_eq!(named["details"]["machine_name"], "dev");
    let Outcome::Failed { error: target, .. } =
        error(Class::StartPending, &request(&["--target", "vm:vm-1"]))
    else {
        panic!()
    };
    assert_eq!(target["details"]["machine_id"], "vm-1");
    let Outcome::Failed { error: cap, .. } = error(Class::MachineCap, &request(&["--make-room"]))
    else {
        panic!()
    };
    // The offered delete names an id no machine has, never one of the account's.
    let offered = &cap["details"]["make_room"];
    assert_eq!(offered["how"], "delete");
    assert!(offered["machine_id"].as_str().unwrap().starts_with("vm_drill"), "{offered}");
}
