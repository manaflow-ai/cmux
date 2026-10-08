use std::fs;

use cmux_server_core::install_key::verify;
use serde_json::Value;

use super::enroll::{
    TEAM_BOUND_FILE, TEAM_KEY_FILE, TeamBound, bind_message, commit, enroll, load_bound,
    machine_instance,
};
use crate::cloud::wire::Env;
use crate::config::{BAKE_INSTANCE_FILE, BOUND_INSTANCE_FILE, Paths};

fn root() -> (tempfile::TempDir, Paths) {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    fs::create_dir_all(paths.at("/etc/cmux")).expect("etc");
    (dir, paths)
}

fn bound(paths: &Paths, id: &str) {
    fs::write(paths.at(BOUND_INSTANCE_FILE), format!("{id}\n")).expect("bound");
}

fn team_bound(instance: &str, epoch: u64) -> TeamBound {
    TeamBound {
        instance_id: instance.into(),
        team: "team_t".into(),
        epoch,
        user: "user_u".into(),
        install: "inst_i".into(),
        api_origin: Env::Stg.api_origin().into(),
        env: Env::Stg,
    }
}

#[test]
fn enroll_needs_a_bound_unparked_clone() {
    let (_d, paths) = root();
    assert!(machine_instance(&paths).is_err(), "not bound yet");
    bound(&paths, "vm-abc");
    assert_eq!(machine_instance(&paths).as_deref(), Ok("vm-abc"));
    fs::write(paths.at(BAKE_INSTANCE_FILE), "vm-abc\n").expect("bake");
    assert!(machine_instance(&paths).is_err(), "parked for a snapshot");
}

#[test]
fn the_proof_is_this_clones_key_over_team_epoch_instance_and_nonce() {
    let (_d, paths) = root();
    let proof = enroll(&paths, "vm-abc", "team_t", 3, "nonce_1").expect("enroll");
    assert_eq!(proof["instance_id"], "vm-abc");
    let sig = proof["signature"].as_str().expect("sig");
    let jwk = &proof["public_jwk"];
    assert!(verify(jwk, bind_message("team_t", 3, "vm-abc", "nonce_1").as_bytes(), sig));
    assert!(!verify(jwk, bind_message("team_t", 3, "vm-abc", "nonce_2").as_bytes(), sig));
    // The same clone keeps its key; a new clone (new instance id) gets a new one.
    let again = enroll(&paths, "vm-abc", "team_t", 3, "nonce_2").expect("enroll");
    assert_eq!(again["public_jwk"], proof["public_jwk"]);
    let fork = enroll(&paths, "vm-fork", "team_t", 4, "nonce_3").expect("enroll");
    assert_ne!(fork["public_jwk"], proof["public_jwk"]);
    let saved: Value =
        serde_json::from_str(&fs::read_to_string(paths.at(TEAM_KEY_FILE)).expect("key"))
            .expect("json");
    assert_eq!(saved["instance_id"], "vm-fork");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(paths.at(TEAM_KEY_FILE)).expect("meta").permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "the private key is root-only");
    }
    assert!(enroll(&paths, "vm-abc", "team t", 3, "n").is_err(), "unsafe team");
}

#[test]
fn commit_lands_only_for_the_last_enroll_of_this_clone_and_its_env_origin() {
    let (_d, paths) = root();
    assert!(commit(&paths, "vm-abc", &team_bound("vm-abc", 3)).is_err(), "no enroll yet");
    enroll(&paths, "vm-abc", "team_t", 3, "nonce_1").expect("enroll");
    assert!(commit(&paths, "vm-abc", &team_bound("vm-abc", 2)).is_err(), "another epoch");
    assert!(commit(&paths, "vm-abc", &team_bound("vm-other", 3)).is_err(), "another clone");
    let mut wrong_origin = team_bound("vm-abc", 3);
    wrong_origin.api_origin = "https://evil.example".into();
    assert!(commit(&paths, "vm-abc", &wrong_origin).is_err(), "foreign origin");
    assert!(!paths.at(TEAM_BOUND_FILE).exists());
    commit(&paths, "vm-abc", &team_bound("vm-abc", 3)).expect("commit");
    assert_eq!(load_bound(&paths, "vm-abc"), Some(team_bound("vm-abc", 3)));
    assert_eq!(load_bound(&paths, "vm-fork"), None, "a fork does not inherit the binding");
}

#[cfg(unix)]
#[test]
fn a_group_or_world_writable_state_dir_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let (_d, paths) = root();
    let dir = paths.at("/var/lib/cmux");
    fs::create_dir_all(&dir).expect("dir");
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o777)).expect("chmod");
    assert!(enroll(&paths, "vm-abc", "team_t", 3, "nonce_1").is_err());
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).expect("chmod");
    assert!(enroll(&paths, "vm-abc", "team_t", 3, "nonce_1").is_ok());
}
