use super::*;

fn dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "supervise-record-{tag}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn a_claim_grows_the_epoch_and_names_this_process() {
    let dir = dir("claim");
    let path = dir.join("owner.json");
    assert!(matches!(load(&path), Loaded::Missing));
    assert_eq!(owner_liveness(&path), Liveness::Dead);
    let first = claim_current(&path).unwrap();
    assert_eq!(first.epoch, 1);
    assert!(first.is_current());
    let second = claim_current(&path).unwrap();
    assert_eq!(second.epoch, 2);
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    assert_eq!(owner_liveness(&path), Liveness::Alive);
    assert!(std::fs::read_dir(&dir).unwrap().count() == 1, "no temporary file is left");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_record_keeps_the_program_and_never_an_argument() {
    // A flag value, a value after `=`, a lowercase positional, and a value that looks like
    // a flag: none can be told from a non-secret from outside.
    let argv: Vec<String> = [
        "/opt/cmux/acpmux",
        "daemon",
        "run",
        "--token",
        "s3cret",
        "--listen=0.0.0.0:47811",
        "lowersecret",
        "--password",
        "-dashsecret",
    ]
    .map(String::from)
    .to_vec();
    let who = identity::current().unwrap_or(Identity {
        pid: 1,
        start_time: 0,
        pgid: 1,
        boot_id: String::new(),
    });
    let record = OwnerRecord::new(who, None, argv);
    assert_eq!(record.argv, ["/opt/cmux/acpmux"]);
    let json = serde_json::to_string(&record).unwrap();
    for secret in ["s3cret", "47811", "lowersecret", "dashsecret"] {
        assert!(!json.contains(secret), "{secret} in {json}");
    }
    assert!(redact(&[]).is_empty());
}

#[test]
fn writers_on_two_threads_never_share_a_temporary_file() {
    let dir = dir("threads");
    let path = dir.join("owner.json");
    std::thread::scope(|s| {
        for t in 0..8u8 {
            let path = &path;
            s.spawn(move || {
                for _ in 0..50 {
                    write_file(path, &[t; 64]).unwrap();
                }
            });
        }
    });
    assert_eq!(std::fs::read(&path).unwrap().len(), 64);
    assert!(std::fs::read_dir(&dir).unwrap().count() == 1, "no temporary file is left");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_torn_or_foreign_file_is_unknown_never_dead() {
    let dir = dir("torn");
    let path = dir.join("owner.json");
    std::fs::write(&path, b"{\"pid\": 12").unwrap();
    assert!(matches!(load(&path), Loaded::Unreadable(_)));
    assert_eq!(owner_liveness(&path), Liveness::Unknown);
    let _ = std::fs::remove_dir_all(&dir);
}
