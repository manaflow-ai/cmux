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

#[test]
fn bytes_sent_as_lines_come_back_whole_and_every_line_is_marked() {
    let bytes: Vec<u8> = (0..3_000_000u32).map(|n| (n % 251) as u8).collect();
    let mut sent = Vec::new();
    {
        let mut writer = LineWriter::new(&mut sent);
        writer.write_all(&bytes).unwrap();
        writer.write_all(b"\n tail").unwrap();
        writer.flush().unwrap();
    }
    assert!(
        sent.split(|byte| *byte == b'\n').filter(|line| !line.is_empty()).all(|line| {
            line.first() == Some(&LINE_MARK) && line.len() <= LINE_BYTES / 3 * 4 + 8
        })
    );
    let mut back = Vec::new();
    LineReader::new(std::io::Cursor::new(sent)).read_to_end(&mut back).unwrap();
    assert_eq!(back.len(), bytes.len() + 6);
    assert_eq!(back.get(..bytes.len()), Some(bytes.as_slice()));
    assert_eq!(back.get(bytes.len()..), Some(&b"\n tail"[..]));
}

#[test]
fn a_line_without_the_mark_is_refused() {
    let mut back = Vec::new();
    let error =
        LineReader::new(std::io::Cursor::new(b"{\"id\":1}\n".to_vec())).read_to_end(&mut back);
    assert_eq!(error.unwrap_err().kind(), std::io::ErrorKind::InvalidData);
}

#[test]
fn only_a_dial_that_says_lines_gets_lines() {
    assert!(wants_lines(r#"{"id":1,"cmd":"projection.serve","name":"a","at":"/x","lines":true}"#));
    assert!(!wants_lines(r#"{"id":1,"cmd":"projection.serve","name":"a","at":"/x"}"#));
}

#[test]
fn a_mount_makes_git_check_only_size_and_mtime_there_and_keeps_it_once() {
    let dir = cmux_unix_socket::short_test_dir("pgit");
    let (state, home) = (dir.path().join("projections"), dir.path().join("home"));
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join(".gitconfig"), "[user]\n\tname = t").unwrap();
    for at in ["/w/a", "/w/b", "/w/a"] {
        git_stat::keep(&state, &home, Path::new(at)).unwrap();
    }
    let global = std::fs::read_to_string(home.join(".gitconfig")).unwrap();
    assert!(global.starts_with("[user]\n\tname = t\n[include]"), "{global}");
    assert_eq!(global.matches("[include]").count(), 1);
    let mounts = std::fs::read_to_string(state.join(git_stat::MOUNTS)).unwrap();
    assert_eq!(mounts.matches("gitdir:/w/a/").count(), 1);
    assert_eq!(mounts.matches("gitdir:/w/b/").count(), 1);
    let stat = std::fs::read_to_string(state.join(git_stat::STAT)).unwrap();
    assert!(stat.contains("checkStat = minimal") && stat.contains("trustctime = false"));
}

#[test]
fn git_takes_the_settings_in_a_mount_and_below_it_only() {
    if std::process::Command::new("git").arg("--version").output().is_err() {
        return;
    }
    let dir = cmux_unix_socket::short_test_dir("pgit");
    let base = std::fs::canonicalize(dir.path()).unwrap();
    let (state, home, at, other) = (base.join("p"), base.join("h"), base.join("m"), base.join("o"));
    for folder in [&state, &home, &at.join("repo"), &other] {
        std::fs::create_dir_all(folder).unwrap();
    }
    git_stat::keep(&state, &home, &at).unwrap();
    let check = |repo: &Path| {
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .env("HOME", &home)
                // A fleet job sets GIT_CONFIG_GLOBAL=/dev/null; git would skip `home`.
                .env_remove("GIT_CONFIG_GLOBAL")
                .env_remove("XDG_CONFIG_HOME")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .arg("-C")
                .arg(repo)
                .args(args)
                .output()
                .unwrap()
        };
        assert!(git(&["init", "-q"]).status.success());
        String::from_utf8_lossy(&git(&["config", "core.checkStat"]).stdout).trim().to_owned()
    };
    assert_eq!(check(&at.join("repo")), "minimal");
    assert_eq!(check(&other), "");
}

#[test]
fn brought_back_and_release_are_projection_frames() {
    for op in [BROUGHT_BACK, RELEASE, LAYER, FILES, DROP, PIN, UNPIN, PINS] {
        let line = json!({"id": 1, "cmd": op, "name": "a"}).to_string();
        assert_eq!(frame_command(&line), Some(op));
    }
    assert_eq!(frame_command(r#"{"id":1,"cmd":"projection.unknown_op","name":"a"}"#), None);
}

/// A projection's state folder as a mount leaves it: an upper layer with an edit, whiteouts, a
/// cache, and its record naming `at`.
fn projected_state(home: &Path, name: &str) -> (PathBuf, PathBuf) {
    let state = home.join("projections").join(name);
    let at = home.join("work").join(name);
    std::fs::create_dir_all(state.join("upper/src")).unwrap();
    std::fs::create_dir_all(state.join("cache")).unwrap();
    std::fs::create_dir_all(&at).unwrap();
    std::fs::write(state.join("upper/src/a.rs"), b"fn a() { /* edited */ }").unwrap();
    std::fs::write(state.join("whiteouts"), b"src/b.rs\0").unwrap();
    std::fs::write(state.join("cache/7"), vec![0; 4096]).unwrap();
    cmux_projection::state::update(&state, &at, |record| record.created_ms = 1).unwrap();
    (state, at)
}

fn control_line(name: &str, mark: Option<&str>, why: Option<&str>) -> WayBackLine {
    WayBackLine {
        name: name.into(),
        paths_bytes: 0,
        mark: mark.map(str::to_owned),
        why: why.map(str::to_owned),
        path: None,
    }
}

/// RFD 0007: Bring Back's upper layer is "brought back at the mark it read
/// (`projection.brought_back`), and it is freed"; one written since stays whole.
#[test]
fn brought_back_at_its_mark_frees_the_state_and_an_edit_since_keeps_it() {
    let home = cmux_unix_socket::short_test_dir("proj");
    let (state, at) = projected_state(home.path(), "p-back");
    let read = cmux_projection::state::mark(&state).unwrap();
    std::fs::write(state.join("upper/late.txt"), b"written after Bring Back read it").unwrap();
    let line = control_line("p-back", Some(&read), None);
    let refused = free(BROUGHT_BACK, &line, &state).unwrap_err();
    assert_eq!(refused.0, "projection.edited_since");
    assert!(state.join("upper/late.txt").exists(), "an edit made after Bring Back read went");
    assert!(cmux_projection::state::read(&state).unwrap().brought_back.is_none());

    let read = cmux_projection::state::mark(&state).unwrap();
    let line = control_line("p-back", Some(&read), None);
    let answer = free(BROUGHT_BACK, &line, &state).unwrap();
    assert!(!state.exists(), "a brought-back projection's state stayed: {answer}");
    assert!(answer["freed_bytes"].as_u64().unwrap() >= 4096, "{answer}");
    assert!(at.exists(), "Bring Back removed the chat's folder; the chat may go on there");
    let line = control_line("p-back", None, None);
    assert_eq!(free(BROUGHT_BACK, &line, &state).unwrap_err().0, "projection.params_invalid");
}

/// An archived or deleted chat's projection goes whole, its empty mount point with it.
#[test]
fn release_frees_the_state_and_its_empty_mount_point() {
    let home = cmux_unix_socket::short_test_dir("proj");
    let (state, at) = projected_state(home.path(), "p-gone");
    let line = control_line("p-gone", None, Some("deleted"));
    let answer = free(RELEASE, &line, &state).unwrap();
    assert!(!state.exists() && !at.exists(), "a deleted chat's projection outlived it");
    assert!(answer["freed_bytes"].as_u64().unwrap() > 0);
    // Again, with nothing left: nothing to free, no error.
    assert_eq!(free(RELEASE, &line, &state).unwrap()["freed_bytes"], 0);
    let line = control_line("p-gone", None, Some("lost"));
    assert_eq!(free(RELEASE, &line, &state).unwrap_err().0, "projection.params_invalid");
}

fn pin_line(name: &str, path: Option<&str>) -> WayBackLine {
    WayBackLine { path: path.map(str::to_owned), ..control_line(name, None, None) }
}

#[test]
fn a_pin_of_a_projection_not_mounted_here_is_refused_as_unknown() {
    for cmd in [PIN, UNPIN, PINS] {
        let refused = pin_answer(cmd, &pin_line("never-mounted-pin", Some("src"))).unwrap_err();
        assert_eq!(refused.0, "projection.unknown", "{cmd}");
    }
}

#[test]
fn pin_refusals_name_the_path_and_their_code() {
    assert_eq!(pin_refusal(libc::ENOENT, "src", "not pinned").0, "projection.not_found");
    assert!(pin_refusal(libc::ENOENT, "src", "not pinned").1.contains("src: not pinned"));
    assert_eq!(pin_refusal(libc::ENOSPC, "", "x").0, "projection.no_space");
    assert!(pin_refusal(libc::ENOSPC, "", "x").1.starts_with("the whole folder"));
    assert_eq!(pin_refusal(libc::EINVAL, "../x", "x").0, "projection.params_invalid");
    assert_eq!(pin_refusal(libc::EIO, "a", "x").0, "projection.io");
}

/// `projection.pin`, `unpin` and `pins` against a projection in the table (no FUSE mount: the
/// overlay is what they read and change). Only folders and nothing to fetch, so no Mac is needed.
#[cfg(target_os = "linux")]
#[test]
fn pin_unpin_and_pins_answer_the_mounted_overlay_and_its_status() {
    use cmux_projection::manifest::{Item, Kind, Manifest};
    let home = cmux_unix_socket::short_test_dir("proj");
    let state = home.path().join("state");
    std::fs::create_dir_all(&state).unwrap();
    let dir = |path: &str| Item {
        path: path.into(),
        kind: Kind::Dir,
        mode: 0o755,
        size: 0,
        mtime_ns: 1,
        link: None,
    };
    let manifest = Manifest::build(1, vec![dir("docs"), dir("docs/empty")]).unwrap();
    let link = Arc::new(cmux_projection::link::Link::default());
    let fetch: Arc<dyn cmux_projection::Fetch> = link.clone();
    let overlay =
        cmux_projection::overlay::Overlay::open(Arc::new(manifest), &state, fetch, (0, 0))
            .unwrap()
            .with_pin_reserve(0);
    let name = "pin-answer-test";
    let projected = Arc::new(Projected {
        link,
        digest: 0,
        at: home.path().join("at"),
        mounted: Mutex::new(None),
        overlay: Arc::new(overlay),
    });
    projections().lock().unwrap().insert(name.into(), projected.clone());

    let pinned = pin_answer(PIN, &pin_line(name, Some("docs"))).unwrap();
    assert_eq!(pinned["path"], "docs");
    assert_eq!((pinned["files"].as_u64(), pinned["away"].as_bool()), (Some(0), Some(false)));
    assert_eq!(pinned["pins"][0]["path"], "docs");
    assert_eq!(pinned["pins"][0]["complete"], true);
    assert_eq!(pinned["pinned_bytes"], 0);

    let listed = pin_answer(PINS, &pin_line(name, None)).unwrap();
    assert_eq!(listed["pins"].as_array().map(Vec::len), Some(1));
    // A mount's answer carries the same status.
    let data = with_pins(json!({"at": "/x"}), &projected);
    assert_eq!(data["pins"], listed["pins"]);
    assert_eq!(data["at"], "/x");

    assert_eq!(
        pin_answer(PIN, &pin_line(name, Some("nope"))).unwrap_err().0,
        "projection.not_found"
    );
    assert_eq!(pin_answer(PIN, &pin_line(name, None)).unwrap_err().0, "projection.params_invalid");
    let unpinned = pin_answer(UNPIN, &pin_line(name, Some("docs"))).unwrap();
    assert_eq!(unpinned["unpinned"], true);
    assert_eq!(unpinned["pins"].as_array().map(Vec::len), Some(0));
    let again = pin_answer(UNPIN, &pin_line(name, Some("docs"))).unwrap_err();
    assert_eq!(again.0, "projection.not_found");
    projections().lock().unwrap().remove(name);
}
