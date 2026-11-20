//! `PersonGate::provision`: the VM provisioning exec's key for the running daemon
//! (`daemon/provision.rs`).
use super::*;

const KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const NEXT: &str = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd";

#[test]
fn a_provisioned_key_is_held_and_proves_like_a_spawn_key() {
    let gate = PersonGate::default();
    assert!(!gate.has_key());
    let reply = gate.provision(KEY).unwrap();
    assert_eq!(reply["via"], "provisioner");
    assert_eq!(reply["personInstance"], gate.instance());
    assert!(gate.has_key());
    assert!(gate.matches(KEY));
    // The app's own enroll of the same key verifies as a spawn key would; another key does not.
    assert_eq!(gate.enroll(KEY, false).unwrap()["via"], "spawn");
    assert!(gate.enroll(NEXT, false).is_err());
}

#[test]
fn the_provisioner_replaces_the_key_of_a_new_app_launch_and_the_run_keeps_its_instance() {
    let gate = PersonGate::default();
    gate.provision(KEY).unwrap();
    let instance = gate.instance().to_owned();
    gate.provision(NEXT).unwrap();
    assert!(gate.matches(NEXT));
    assert!(!gate.matches(KEY));
    assert_eq!(gate.instance(), instance);
    // Only the provisioner replaces a key: the spawn path still takes none once one is held.
    assert!(gate.install_spawn_key(KEY).is_err());
}

#[test]
fn a_malformed_key_is_refused_and_changes_nothing() {
    let gate = PersonGate::default();
    assert!(gate.provision("short").is_err());
    assert!(gate.provision(&KEY.to_uppercase()).is_err());
    assert!(!gate.has_key());
}
