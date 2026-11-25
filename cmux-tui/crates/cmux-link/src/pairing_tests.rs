use super::*;

fn record(install: &str, key_byte: u8) -> PairingRecord {
    PairingRecord {
        install: install.into(),
        user: "user_1".into(),
        team: "team_1".into(),
        public_key: STANDARD.encode([key_byte; 32]),
        endpoint: Some("192.168.1.20:51820".parse().unwrap()),
    }
}

#[test]
fn pairings_are_unique_by_install_and_by_key_and_survive_a_reload() {
    let directory = cmux_unix_socket::short_test_dir("pair");
    let path = directory.path().join("peers.json");
    let mut pairings = Pairings::load(&path).unwrap();
    pairings.upsert(record("inst_a", 1)).unwrap();
    pairings.upsert(record("inst_b", 2)).unwrap();
    pairings.upsert(record("inst_c", 1)).unwrap();
    assert!(pairings.by_install("inst_a").is_none(), "same key replaces the old install");
    assert_eq!(pairings.by_key(&[1; 32]).unwrap().install, "inst_c");
    pairings.save(&path).unwrap();
    assert_eq!(Pairings::load(&path).unwrap(), pairings);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
    assert!(pairings.remove("inst_b"));
    assert!(!pairings.remove("inst_b"));
}

#[test]
fn a_record_with_a_bad_key_or_id_is_refused() {
    let mut pairings = Pairings::default();
    let mut short = record("inst_a", 1);
    short.public_key = STANDARD.encode([1u8; 16]);
    assert!(pairings.upsert(short).is_err());
    assert!(pairings.upsert(record("../a", 1)).is_err());
}

#[test]
fn a_rekey_moves_only_its_own_record_and_never_takes_another_key() {
    let mut pairings = Pairings::default();
    pairings.upsert(record("inst_a", 1)).unwrap();
    pairings.upsert(record("inst_b", 2)).unwrap();
    assert!(pairings.rekey("inst_a", &[3; 32]).unwrap());
    assert_eq!(pairings.by_install("inst_a").unwrap().key(), Some([3; 32]));
    assert!(!pairings.rekey("inst_a", &[3; 32]).unwrap(), "already on that key");
    let taken = pairings.rekey("inst_a", &[2; 32]).unwrap_err();
    assert_eq!(taken.kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(pairings.by_install("inst_b").unwrap().key(), Some([2; 32]));
    assert_eq!(pairings.rekey("inst_c", &[4; 32]).unwrap_err().kind(), io::ErrorKind::NotFound);
}

/// A save is durable only once its directory is synced: when the directory
/// cannot be opened to sync it, the save reports failure even though the
/// rename happened, so nothing is acknowledged on a rename a crash could undo.
#[cfg(unix)]
#[test]
fn a_save_whose_directory_cannot_be_synced_fails() {
    use std::os::unix::fs::PermissionsExt;
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } == 0 {
        return; // root opens any directory; the failure cannot be staged.
    }
    let directory = cmux_unix_socket::short_test_dir("pairsync");
    let dir = directory.path().join("d");
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("peers.json");
    let mut pairings = Pairings::default();
    pairings.upsert(record("inst_a", 1)).unwrap();
    pairings.save(&path).unwrap();
    // Writable and searchable, not readable: create and rename work, opening it does not.
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o300)).unwrap();
    pairings.upsert(record("inst_b", 2)).unwrap();
    let saved = pairings.save(&path);
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(saved.map_err(|error| error.kind()), Err(io::ErrorKind::PermissionDenied));
}
