use super::*;

#[test]
fn only_a_projection_serve_line_is_a_projection_frame() {
    assert_eq!(
        frame_command(r#"{"id":1,"cmd":"projection.serve","name":"a","at":"/x"}"#),
        Some(SERVE)
    );
    assert_eq!(frame_command(r#"{"id":1,"cmd":"fs.read","path":"projection.serve"}"#), None);
    assert_eq!(
        frame_command(r#"{"id":1,"cmd":"projection.serve","protocol":"x","name":"a","at":"/x"}"#),
        None
    );
}

#[test]
fn a_mount_point_outside_the_roots_or_not_plain_is_refused() {
    let home = cmux_unix_socket::short_test_dir("proj");
    let roots = vec![home.path().to_path_buf()];
    let inside = home.path().join("work").join("chat");
    assert!(mount_point(inside.to_str().unwrap(), &roots).is_ok());
    assert!(mount_point("/etc/cmux-projection-test", &roots).is_err());
    assert!(mount_point("relative/path", &roots).is_err());
    let dotted = format!("{}/work/../../escape", home.path().display());
    assert!(mount_point(&dotted, &roots).is_err());
}

#[test]
fn a_rejected_mount_does_not_create_parent_directories() {
    let root = cmux_unix_socket::short_test_dir("proj-root");
    let outside = cmux_unix_socket::short_test_dir("proj-outside");
    let missing = outside.path().join("never-created").join("chat");
    assert!(mount_point(missing.to_str().unwrap(), &[root.path().to_path_buf()]).is_err());
    assert!(!outside.path().join("never-created").exists());
}

#[cfg(unix)]
#[test]
fn a_mount_point_symlink_cannot_escape_the_roots() {
    use std::os::unix::fs::symlink;

    let home = cmux_unix_socket::short_test_dir("proj-symlink");
    let roots = vec![home.path().to_path_buf()];
    let outside = cmux_unix_socket::short_test_dir("proj-outside");
    let link = home.path().join("link");
    symlink(outside.path(), &link).unwrap();
    assert!(mount_point(link.to_str().unwrap(), &roots).is_err());
}

#[test]
fn a_bad_name_or_an_unknown_reattach_is_refused_with_its_code() {
    let home = cmux_unix_socket::short_test_dir("proj");
    let roots = vec![home.path().to_path_buf()];
    let at = home.path().join("p");
    let line = |name: &str| {
        json!({"id": 1, "cmd": SERVE, "name": name, "at": at, "manifest_bytes": 0}).to_string()
    };
    let refused = |line: String| attach(&line, &mut std::io::empty(), &roots).err().unwrap().0;
    assert_eq!(refused(line("../x")), "projection.params_invalid");
    assert_eq!(refused(line("never-mounted")), "projection.unknown");
}

/// The whole path on a machine with FUSE: a dial with a manifest mounts it, the mount lists what
/// the manifest has without asking the Mac, a read asks the Mac over the same dial, and a write
/// stays on the machine.
#[cfg(target_os = "linux")]
#[test]
fn a_dial_mounts_its_manifest_and_reads_ask_the_mac() {
    use cmux_projection::link::{Source, answer_asks};
    use cmux_projection::manifest::{Item, Kind, Manifest};
    use cmux_projection::wire::Part;

    if !Path::new("/dev/fuse").exists()
        || std::process::Command::new("fusermount3").arg("-V").output().is_err()
    {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let home = cmux_unix_socket::short_test_dir("proj");
    let roots = vec![std::fs::canonicalize(home.path()).unwrap()];
    let at = roots[0].join("work").join("chat");
    let items = vec![
        Item {
            path: "README.md".into(),
            kind: Kind::File,
            mode: 0o644,
            size: 5,
            mtime_ns: 1,
            link: None,
        },
        Item {
            path: "src/lib.rs".into(),
            kind: Kind::File,
            mode: 0o644,
            size: 3,
            mtime_ns: 1,
            link: None,
        },
    ];
    let manifest = Manifest::build(1, items).unwrap();
    let readme = manifest.resolve("README.md").unwrap();
    let encoded = manifest.encode().unwrap();

    struct Mac {
        readme: u32,
    }
    impl Source for Mac {
        fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
            let whole = self.whole(entry).bytes;
            let start = (offset as usize).min(whole.len());
            let end = (start + len as usize).min(whole.len());
            Part::ok(whole[start..end].to_vec())
        }
        fn whole(&self, entry: u32) -> Part {
            Part::ok(if entry == self.readme { b"hello".to_vec() } else { b"lib".to_vec() })
        }
    }

    let (machine, mac) = UnixStream::pair().unwrap();
    let first = json!({
        "id": 7,
        "cmd": SERVE,
        "name": "test-chat",
        "at": at,
        "manifest_bytes": encoded.len(),
    })
    .to_string();
    let served = std::thread::spawn(move || serve(&machine, &first, encoded, &roots));
    let mut answer = String::new();
    let mut reader = std::io::BufReader::new(mac.try_clone().unwrap());
    std::io::BufRead::read_line(&mut reader, &mut answer).unwrap();
    let answer: Value = serde_json::from_str(&answer).unwrap();
    if answer["error_code"] == "projection.mount_failed" {
        eprintln!("skipping: FUSE refused the mount here: {}", answer["error"]);
        return;
    }
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["data"]["files"], 2);
    let writer = mac.try_clone().unwrap();
    let answering = std::thread::spawn(move || answer_asks(reader, writer, &Mac { readme }));

    let mut names: Vec<String> = std::fs::read_dir(&at)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["README.md", "src"]);
    assert_eq!(std::fs::read_to_string(at.join("README.md")).unwrap(), "hello");
    std::fs::write(at.join("src/new.rs"), "new").unwrap();
    assert_eq!(std::fs::read_to_string(at.join("src/new.rs")).unwrap(), "new");

    mac.shutdown(std::net::Shutdown::Both).unwrap();
    served.join().unwrap();
    let _ = answering.join();
    let projected = projections().lock().unwrap().remove("test-chat").unwrap();
    if let Some(mounted) = projected.mounted.lock().unwrap().take() {
        mounted.unmount();
    }
    // The edit outlives the mount, in the daemon's own state folder.
    let state =
        crate::platform::workspace_state_dir().unwrap().join("projections").join("test-chat");
    assert_eq!(std::fs::read_to_string(state.join("upper/src/new.rs")).unwrap(), "new");
    let _ = std::fs::remove_dir_all(&state);
}
