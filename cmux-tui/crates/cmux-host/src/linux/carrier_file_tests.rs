use std::os::unix::fs::PermissionsExt;

use super::{carrier_args, trusted_text};
use crate::carrier_entry::{CARRIER_FILE, GRANT_CONFIG_FILE};
use crate::config::Paths;

/// With carrier.json, the session host's flags name its grant config,
/// written first with only the public fields (0644); without it, no
/// flags and no file.
fn carrier(kid: &str) -> serde_json::Value {
    serde_json::json!({
        "relay": "relay+do://relay.cmux.dev",
        "machine": "vm_0123456789abcdefghij",
        "slot": "AAAAAAAAAAAAAAAAAAAAAA",
        "team": "team_0123456789abcdefghij",
        "issuer": "cmux:cloud:production",
        "keyset": {"version": "0123456789abcdef", "keys": {kid: {
            "kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid,
            "x": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        }}},
    })
}

fn write_carrier(paths: &Paths, carrier: &serde_json::Value) {
    let file = paths.at(CARRIER_FILE);
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, carrier.to_string()).unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
}

fn grant_config(paths: &Paths) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(paths.at(GRANT_CONFIG_FILE)).unwrap()).unwrap()
}

#[test]
fn the_carrier_flags_come_with_a_public_grant_config() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let bin = &["/opt/cmux/current/bin/cmux".to_owned(), "host".to_owned()][..];
    assert!(carrier_args(&paths, bin).is_empty());
    assert!(!paths.at(GRANT_CONFIG_FILE).exists());
    let carrier = carrier("k1");
    write_carrier(&paths, &carrier);
    let args = carrier_args(&paths, bin);
    let grant = paths.at(GRANT_CONFIG_FILE);
    let at = args.iter().position(|arg| arg == "--carrier-grant-config").unwrap();
    assert_eq!(args[at + 1], grant.display().to_string());
    assert_eq!(
        grant_config(&paths),
        serde_json::json!({
            "issuer": carrier["issuer"], "machine": carrier["machine"],
            "team": carrier["team"], "keyset": carrier["keyset"],
        })
    );
    assert_eq!(std::fs::metadata(&grant).unwrap().permissions().mode() & 0o777, 0o644);
}

/// A rotated keyset in carrier.json rewrites the grant config the running
/// host's verifier re-reads, with the same flags: no respawn.
#[test]
fn a_rotated_keyset_rewrites_the_grant_config_with_the_same_flags() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let bin = &["/opt/cmux/current/bin/cmux".to_owned(), "host".to_owned()][..];
    write_carrier(&paths, &carrier("k1"));
    let before = carrier_args(&paths, bin);
    let rotated = carrier("k2");
    write_carrier(&paths, &rotated);
    assert_eq!(carrier_args(&paths, bin), before);
    assert_eq!(grant_config(&paths)["keyset"], rotated["keyset"]);
}

/// Removing carrier.json wakes the supervisor's watch (it is a change
/// of route, to none) and leaves no carrier flags for the respawn.
#[test]
fn a_removed_carrier_json_wakes_the_watch_and_drops_the_flags() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let bin = &["/opt/cmux/current/bin/cmux".to_owned(), "host".to_owned()][..];
    write_carrier(&paths, &carrier("k1"));
    assert!(!carrier_args(&paths, bin).is_empty());
    let inotify = crate::linux::fds::Inotify::new().unwrap();
    let state = paths.at(CARRIER_FILE).parent().unwrap().to_path_buf();
    let wd = inotify.watch_dir_with_removals(&state).unwrap();
    std::fs::remove_file(paths.at(CARRIER_FILE)).unwrap();
    let events = inotify.read_events().unwrap();
    assert!(
        events.iter().any(|e| e.wd == wd
            && e.name == crate::carrier_entry::CARRIER_FILE_NAME
            && e.mask & libc::IN_DELETE != 0),
        "no removal event"
    );
    assert!(carrier_args(&paths, bin).is_empty());
}

/// carrier.json counts only as a regular file owned by the agent's uid
/// that neither group nor others may write.
#[test]
fn carrier_json_is_refused_unless_owner_only_writable() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("carrier.json");
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    assert_eq!(trusted_text(&file, "carrier.json", euid), Ok(None));
    std::fs::write(&file, "{}").unwrap();
    for (mode, ok) in [(0o600, true), (0o644, true), (0o620, false), (0o602, false)] {
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(mode)).unwrap();
        let read = trusted_text(&file, "carrier.json", euid);
        assert_eq!(read.is_ok(), ok, "{mode:o}: {read:?}");
        if let Err(why) = read {
            assert!(why.starts_with("carrier.json mode"), "{why}");
        }
    }
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    let other = trusted_text(&file, "carrier.json", euid.wrapping_add(1)).unwrap_err();
    assert!(other.starts_with("carrier.json is owned by uid"), "{other}");
    let link = dir.path().join("link.json");
    std::os::unix::fs::symlink(&file, &link).unwrap();
    assert!(trusted_text(&link, "carrier.json", euid).is_err());
}
