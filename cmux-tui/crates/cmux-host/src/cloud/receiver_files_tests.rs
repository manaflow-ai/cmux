use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};
use x25519_dalek::{PublicKey, StaticSecret};

use super::receiver_files::load;
use super::wire::{BOUND_FILE, Bound, Env, INSTALL_KEY_FILE, STATE_DIR, WG_KEY_FILE};
use crate::config::Paths;

fn saved() -> (tempfile::TempDir, Paths) {
    let root = tempfile::tempdir().unwrap();
    let paths = Paths::new(root.path());
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    let private = [7u8; 32];
    let public = PublicKey::from(&StaticSecret::from(private));
    let bound = Bound {
        machine: "vm_00000000000000000004".into(),
        team: "team_00000000000000000001".into(),
        host: "host_00000000000000000004".into(),
        epoch: 4,
        install: "inst_00000000000000000004".into(),
        user: "user_00000000000000000004".into(),
        grant: "grant_00000000000000000004".into(),
        env: Env::Dev,
        api_origin: Env::Dev.api_origin().into(),
        keyset: Value::Null,
        bound_at: 1,
    };
    for (name, value) in [
        (BOUND_FILE, serde_json::to_value(bound).unwrap()),
        (INSTALL_KEY_FILE, json!({"instance_id":"instance-a","pkcs8":key.pkcs8_base64url()})),
        (
            WG_KEY_FILE,
            json!({"instance_id":"instance-a","private_key":STANDARD.encode(private),"public_key":STANDARD.encode(public.as_bytes())}),
        ),
    ] {
        let file = paths.at(name);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, value.to_string()).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
    }
    fs::set_permissions(paths.at(STATE_DIR), fs::Permissions::from_mode(0o700)).unwrap();
    (root, paths)
}

#[test]
fn vm_receiver_client_files_load_original_per_clone_identity() {
    let (_root, paths) = saved();
    let identity = load(&paths, "instance-a").unwrap();
    assert_eq!(identity.bound.epoch, 4);
    assert_eq!(identity.install_public_jwk["crv"], "P-256");
    assert!(load(&paths, "instance-b").is_err(), "another clone reused the original private keys");
}

#[test]
fn vm_receiver_client_files_refuse_public_or_writable_identity_files() {
    for name in [BOUND_FILE, INSTALL_KEY_FILE, WG_KEY_FILE] {
        for mode in [0o644, 0o660, 0o666, 0o4600] {
            let (_root, paths) = saved();
            fs::set_permissions(paths.at(name), fs::Permissions::from_mode(mode)).unwrap();
            assert!(load(&paths, "instance-a").is_err(), "accepted {name} mode {mode:o}");
            assert_eq!(
                fs::metadata(paths.at(name)).unwrap().permissions().mode() & 0o7777,
                mode,
                "read repaired permissions"
            );
        }
    }
}

#[test]
fn vm_receiver_client_files_refuse_symlink_files_and_directories() {
    for name in
        [BOUND_FILE, INSTALL_KEY_FILE, WG_KEY_FILE, "/var/lib/cmux/install", "/var/lib/cmux/wg"]
    {
        let (_root, paths) = saved();
        let path = paths.at(name);
        let target = path.with_extension("moved");
        fs::rename(&path, &target).unwrap();
        symlink(&target, &path).unwrap();
        assert!(load(&paths, "instance-a").is_err(), "followed {name}");
    }
}

#[test]
fn vm_receiver_client_files_refuse_writable_ancestors_and_unprotected_state() {
    for (name, mode) in
        [("/var", 0o777), ("/var/lib", 0o775), (STATE_DIR, 0o755), ("/var/lib/cmux/install", 0o777)]
    {
        let (_root, paths) = saved();
        fs::set_permissions(paths.at(name), fs::Permissions::from_mode(mode)).unwrap();
        assert!(load(&paths, "instance-a").is_err(), "accepted {name} mode {mode:o}");
    }
}

#[test]
fn vm_receiver_client_files_refuse_hard_links_and_oversized_files() {
    let (_root, paths) = saved();
    fs::hard_link(paths.at(INSTALL_KEY_FILE), paths.at("/var/lib/cmux/install/other.json"))
        .unwrap();
    assert!(load(&paths, "instance-a").is_err());
    let (_root, paths) = saved();
    fs::write(paths.at(BOUND_FILE), vec![b' '; 65537]).unwrap();
    assert!(load(&paths, "instance-a").is_err());
}

#[test]
fn vm_receiver_client_files_refuse_mismatched_wg_key_without_rotation() {
    let (_root, paths) = saved();
    let path = paths.at(WG_KEY_FILE);
    let mut wg: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    wg["public_key"] = STANDARD.encode([9u8; 32]).into();
    let text = wg.to_string();
    fs::write(&path, &text).unwrap();
    assert!(load(&paths, "instance-a").is_err());
    assert_eq!(fs::read_to_string(path).unwrap(), text);
}
