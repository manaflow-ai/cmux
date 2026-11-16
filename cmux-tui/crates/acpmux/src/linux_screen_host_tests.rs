use super::*;

fn archive(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    {
        let mut tar = tar::Builder::new(&mut gz);
        for (path, bytes) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o755);
            header.set_cksum();
            tar.append_data(&mut header, path, *bytes).unwrap();
        }
        tar.finish().unwrap();
    }
    gz.finish().unwrap()
}

#[test]
fn the_binary_comes_only_from_an_archive_with_the_pinned_sha256() {
    let tarball = archive(&[("LICENSE", b"GPL"), ("bin/cmux-rd", b"\x7fELF host")]);
    let sha = sha256_hex(&tarball);
    assert_eq!(unpack(&tarball, &sha).unwrap(), b"\x7fELF host");
    let other = "0".repeat(64);
    let error = unpack(&tarball, &other).unwrap_err().to_string();
    assert!(error.contains("sha256"), "{error}");
    // The release's top folder is allowed.
    let nested = archive(&[("cmux-rd-0.2.6/bin/cmux-rd", b"nested")]);
    assert_eq!(unpack(&nested, &sha256_hex(&nested)).unwrap(), b"nested");
    let empty = archive(&[("README", b"x")]);
    assert!(unpack(&empty, &sha256_hex(&empty)).is_err());
}

#[test]
fn set_up_runs_once_per_version_until_it_installs_the_host() {
    let release = Release { version: "0.2.6", url: "https://x", sha256: "s" };
    let done = |version: &str, installed| Outcome {
        version: version.into(),
        installed,
        lines: Vec::new(),
        at_ms: 0,
    };
    assert!(needs_set_up(None, &release));
    assert!(!needs_set_up(Some(&done("0.2.6", true)), &release));
    assert!(needs_set_up(Some(&done("0.2.6", false)), &release), "retried until it installs");
    assert!(needs_set_up(Some(&done("0.2.5", true)), &release), "a new release sets up again");
}

#[test]
fn enable_says_whether_it_installed_the_host() {
    assert!(enable_installed(
        "no graphical session on this machine; shares use a virtual display at :99, started when one is needed\nThis desktop is shared as \"vm\" (id), view and control; the host runs as cmux-screen-host.service.\n"
    ));
    assert!(!enable_installed(
        "not_installed: screen sharing is set up on this machine but not signed in\n"
    ));
}

#[test]
fn the_binary_is_written_where_the_host_unit_runs_it_and_only_when_it_changed() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = std::env::temp_dir().join(format!("acpmux-linux-screen-host-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let path = binary_path(&dir);
    assert!(path.ends_with(".local/bin/cmux-rd"));
    assert!(install_binary(&path, b"one").unwrap());
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o755);
    assert!(!install_binary(&path, b"one").unwrap());
    assert!(install_binary(&path, b"two").unwrap());
    assert_eq!(std::fs::read(&path).unwrap(), b"two");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_outcome_round_trips_beside_the_daemon_state() {
    let home =
        std::env::temp_dir().join(format!("acpmux-linux-screen-outcome-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let outcome =
        Outcome { version: "0.2.6".into(), installed: true, lines: vec!["ok".into()], at_ms: 7 };
    outcome.save(&home).unwrap();
    assert_eq!(Outcome::load(&home), Some(outcome));
    let text = std::fs::read_to_string(Outcome::path(&home)).unwrap();
    assert!(text.contains("\"atMs\": 7"), "{text}");
    let _ = std::fs::remove_dir_all(&home);
}
