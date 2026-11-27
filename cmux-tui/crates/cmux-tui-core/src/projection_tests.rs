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

#[test]
fn a_revision_the_machine_cannot_fetch_is_refused_with_its_own_code() {
    let reference = |origin: &str| RevisionRef {
        root: "0".repeat(64),
        origin: origin.into(),
        grant: "csg_x".into(),
    };
    // Not https: the machine never sends the grant over it.
    assert_eq!(
        fetch_revision(&reference("http://store.example")).err().unwrap().0,
        "projection.revision_unavailable"
    );
    // A store that does not answer.
    assert_eq!(
        fetch_revision(&reference("http://127.0.0.1:1")).err().unwrap().0,
        "projection.revision_unavailable"
    );
}

#[test]
fn a_revision_in_the_store_is_fetched_and_assembled() {
    use std::io::{BufRead as _, Write as _};

    use cmux_projection::manifest::{Item, Kind, Manifest};

    let items: Vec<Item> = (0..3000)
        .map(|n| Item {
            path: format!("d{:02}/s{}/file-{n:05}-with-a-long-enough-name.rs", n % 40, n % 3),
            kind: Kind::File,
            mode: 0o644,
            size: n,
            mtime_ns: 5,
            link: None,
        })
        .collect();
    let manifest = Manifest::build(1, items).unwrap();
    let split = cmux_projection::revision::split(&manifest).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let pieces: HashMap<String, Vec<u8>> =
        split.pieces.iter().map(|piece| (piece.sha256.clone(), piece.bytes.clone())).collect();
    let served = std::thread::spawn(move || {
        // One request per connection, until the test drops the last reference.
        for conn in listener.incoming().flatten() {
            let mut reader = std::io::BufReader::new(conn.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap_or(0);
            let sha =
                line.split_whitespace().nth(1).and_then(|p| p.rsplit('/').next()).unwrap_or("");
            let mut authed = false;
            loop {
                let mut header = String::new();
                if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
                    break;
                }
                authed |= header.to_ascii_lowercase().starts_with("authorization:")
                    && header.contains("csg_good");
            }
            let mut conn = conn;
            let _ = match pieces.get(sha) {
                Some(bytes) if authed => {
                    let mut out = format!(
                        "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                        bytes.len()
                    )
                    .into_bytes();
                    out.extend_from_slice(bytes);
                    conn.write_all(&out)
                }
                _ => conn.write_all(
                    b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                ),
            };
        }
    });
    let origin = format!("http://127.0.0.1:{port}");
    let fetched = fetch_revision(&RevisionRef {
        root: split.root.clone(),
        origin: origin.clone(),
        grant: "csg_good".into(),
    })
    .ok()
    .unwrap();
    assert_eq!(fetched, manifest);
    // A grant the store refuses is the same refusal, not a hang or a panic.
    let refused =
        fetch_revision(&RevisionRef { root: split.root, origin, grant: "csg_bad".into() });
    assert_eq!(refused.err().unwrap().0, "projection.revision_unavailable");
    drop(served);
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
fn binary_lines_come_back_whole_mixed_with_base64_ones() {
    // Every byte value, newlines and escapes among them, on both sides of a line's cut.
    let bytes: Vec<u8> =
        (0..2_500_000u32).map(|n| (n.wrapping_mul(2_654_435_761) >> 11) as u8).collect();
    let mut sent = Vec::new();
    {
        let mut writer = LineWriter::new(&mut sent);
        writer.write_all(b"head\n").unwrap();
    }
    {
        let mut writer = LineWriter::binary(&mut sent);
        writer.write_all(&bytes).unwrap();
        writer.write_all(b"\n\\n\\").unwrap();
        writer.flush().unwrap();
    }
    let lines: Vec<&[u8]> =
        sent.split(|byte| *byte == b'\n').filter(|line| !line.is_empty()).collect();
    assert_eq!(lines.first().and_then(|line| line.first()), Some(&LINE_MARK));
    assert!(
        lines
            .iter()
            .skip(1)
            .all(|line| { line.first() == Some(&BINARY_MARK) && line.len() <= LINE_BYTES * 2 + 1 })
    );
    // About 1/128 of noise is escaped: far under base64's third.
    let binary: usize = lines.iter().skip(1).map(|line| line.len() + 1).sum();
    assert!(binary < bytes.len() + bytes.len() / 50, "{binary}");
    let mut back = Vec::new();
    LineReader::new(std::io::Cursor::new(sent)).read_to_end(&mut back).unwrap();
    assert_eq!(back.get(..5), Some(&b"head\n"[..]));
    assert_eq!(back.get(5..5 + bytes.len()), Some(bytes.as_slice()));
    assert_eq!(back.get(5 + bytes.len()..), Some(&b"\n\\n\\"[..]));
}

#[test]
fn a_binary_line_with_a_bad_escape_is_refused() {
    let mut back = Vec::new();
    let error = LineReader::new(std::io::Cursor::new(b"!ab\\x\n".to_vec())).read_to_end(&mut back);
    assert_eq!(error.unwrap_err().kind(), std::io::ErrorKind::InvalidData);
}

#[test]
fn only_a_serve_dial_that_says_wire_2_gets_binary_lines_and_packed_answers() {
    assert!(wants_wire(
        r#"{"id":1,"cmd":"projection.serve","name":"a","at":"/x","lines":true,"wire":2}"#
    ));
    assert!(!wants_wire(r#"{"id":1,"cmd":"projection.serve","name":"a","at":"/x","lines":true}"#));
    assert!(!wants_wire(r#"{"id":1,"cmd":"projection.layer","name":"a","at":"/x","wire":2}"#));
}

/// The bytes a projection's answers cost on the carrier, before (plain answers in base64 lines)
/// and after (packed answers in binary lines), for every file of this crate's source folder.
#[test]
fn packed_answers_in_binary_lines_cost_less_than_base64_ones() {
    use cmux_projection::wire::{Part, read_answer, write_answer, write_packed_answer};
    let folder = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files: Vec<Vec<u8>> = Vec::new();
    let mut stack = vec![folder];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                stack.push(path);
            } else {
                files.push(std::fs::read(path).unwrap());
            }
        }
    }
    let raw: usize = files.iter().map(Vec::len).sum();
    let (mut before, mut after) = (Vec::new(), Vec::new());
    for (ask, file) in files.iter().enumerate() {
        let parts = [Part::ok(file.clone())];
        let ask = u32::try_from(ask).unwrap();
        // As the Mac answers: through a 1 MiB buffer, flushed after each answer.
        let mut plain = std::io::BufWriter::with_capacity(1 << 20, LineWriter::new(&mut before));
        write_answer(&mut plain, ask, &parts).unwrap();
        plain.flush().unwrap();
        drop(plain);
        let mut packed = std::io::BufWriter::with_capacity(1 << 20, LineWriter::binary(&mut after));
        write_packed_answer(&mut packed, ask, &parts).unwrap();
        packed.flush().unwrap();
    }
    eprintln!(
        "{} files, {raw} bytes: base64 plain {} bytes, binary packed {} bytes ({:.2}x)",
        files.len(),
        before.len(),
        after.len(),
        before.len() as f64 / after.len() as f64
    );
    assert!(after.len() * 2 < before.len());
    let mut reader = LineReader::new(std::io::Cursor::new(after));
    for file in &files {
        let (_, parts) = read_answer(&mut reader).unwrap().unwrap();
        assert_eq!(&parts[0].bytes, file);
    }
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
                .env("GIT_CONFIG_GLOBAL", home.join(".gitconfig"))
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

/// RFD 0007: the agent is told once that the Mac is away and which reads failed; the notice names
/// the folder, says the Mac is away, and lists the failed paths, at most a cap, with a count.
#[test]
fn the_away_notice_names_the_folder_the_mac_and_the_failed_reads() {
    use cmux_projection::away::Report;
    let at = Path::new("/home/cmux/work/chat");
    let report = Report {
        episode: 1,
        paths: vec!["README.md".into(), "src/main.rs".into()],
        failed: 2,
        back: false,
    };
    let (title, body) = away_notice(at, &report);
    assert_eq!(
        away_prompt(&title, &body),
        "[notice from cmux · WARN] The Mac is away: 2 reads in a projected folder failed\n\
         The Mac that projects /home/cmux/work/chat is asleep or offline. A read of a file not \
         fetched from it yet waits 5 s, then fails with EHOSTDOWN (\"Host is down\"); files \
         already read keep working. Nothing retries on its own: read these again once the Mac is \
         back.\n\
         Reads that failed (2):\n\
         - README.md\n\
         - src/main.rs"
    );
    let capped = Report { paths: vec!["a".into()], failed: 9, ..report };
    let (title, body) = away_notice(at, &capped);
    assert_eq!(title, "The Mac is away: 9 reads in a projected folder failed");
    assert!(body.ends_with("Reads that failed (9):\n- a\n- and 8 more"), "{body}");
    let back = Report { back: true, failed: 1, paths: vec!["a".into()], ..report };
    let (title, body) = away_notice(at, &back);
    assert_eq!(title, "The Mac was away: 1 read in a projected folder failed");
    assert!(body.contains("is back now"), "{body}");
}

#[test]
fn brought_back_and_release_are_projection_frames() {
    for op in [BROUGHT_BACK, RELEASE, LAYER, FILES, DROP, PIN, UNPIN, PINS, WARM, UNSYNCED] {
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
        prune: false,
        paths: Vec::new(),
        prune: false,
    }
}

/// `projection.unsynced`: what Bring Back would carry and what stays on the machine, counted.
#[test]
fn unsynced_counts_the_changes_and_what_stays_on_the_machine() {
    let home = cmux_unix_socket::short_test_dir("proj");
    let (state, _) = projected_state(home.path(), "p-count");
    std::fs::create_dir_all(state.join("upper/node_modules/x")).unwrap();
    std::fs::write(state.join("upper/node_modules/x/i.js"), b"1;").unwrap();
    std::fs::write(state.join("upper/node_modules/x/package.json"), b"{}").unwrap();
    assert_eq!(
        unsynced(&state, true).unwrap(),
        json!({"files": 1, "bytes": 23, "deleted": 1,
               "kept_on_machine": {"folders": 1, "files": 2, "bytes": 4,
                                   "paths": ["node_modules"]}})
    );
    // Unpruned (the caller's manifest holds `node_modules`): its edits count.
    assert_eq!(unsynced(&state, false).unwrap(), json!({"files": 3, "bytes": 27, "deleted": 1}));
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
        digest: AtomicU64::new(0),
        at: home.path().join("at"),
        mounted: Mutex::new(None),
        overlay: Arc::new(overlay),
        ext: Mutex::new(None),
        barrier: Mutex::new(None),
        away: cmux_projection::away::Away::new(|_| {}),
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

/// A head dial leaves the folder's sync barrier at HeadReady, an extend makes it Ready, a
/// non-superset extend is refused and leaves the barrier and the mount alone, and a dial without
/// `head` takes no barrier.
#[cfg(target_os = "linux")]
#[test]
fn a_head_dial_holds_the_barrier_at_head_ready_until_the_extend() {
    use cmux_git::sync_barrier::{Probe, probe};
    use cmux_projection::manifest::{Item, Kind, Manifest};

    if !Path::new("/dev/fuse").exists()
        || std::process::Command::new("fusermount3").arg("-V").output().is_err()
    {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let item = |path: &str| Item {
        path: path.into(),
        kind: Kind::File,
        mode: 0o644,
        size: 3,
        mtime_ns: 1,
        link: None,
    };
    let home = cmux_unix_socket::short_test_dir("projx");
    let roots = vec![std::fs::canonicalize(home.path()).unwrap()];
    let at = roots[0].join("work").join("chat");
    let head = Manifest::build(1, vec![item("README.md")]).unwrap().encode().unwrap();
    let full =
        Manifest::build(1, vec![item("README.md"), item("tail/x.txt")]).unwrap().encode().unwrap();
    let wrong = Manifest::build(1, vec![item("other.txt")]).unwrap().encode().unwrap();

    // One dial: send `first` and the manifest, read the answer, and keep the stream open.
    let dial = |extra: Value, manifest: Vec<u8>| {
        let (machine, mac) = UnixStream::pair().unwrap();
        let mut line = json!({
            "id": 1,
            "cmd": SERVE,
            "name": "test-extend",
            "at": at,
            "manifest_bytes": manifest.len(),
        });
        for (key, value) in extra.as_object().unwrap() {
            line[key] = value.clone();
        }
        let first = line.to_string();
        let roots = roots.clone();
        let served = std::thread::spawn(move || serve(&machine, &first, manifest, &roots));
        let mut answer = String::new();
        let mut reader = std::io::BufReader::new(mac.try_clone().unwrap());
        std::io::BufRead::read_line(&mut reader, &mut answer).unwrap();
        (serde_json::from_str::<Value>(&answer).unwrap(), mac, served)
    };

    let (answer, head_mac, head_served) = dial(json!({"head": true}), head);
    if answer["error_code"] == "projection.mount_failed" {
        eprintln!("skipping: FUSE refused the mount here: {}", answer["error"]);
        return;
    }
    assert_eq!(answer["ok"], true, "{answer}");
    assert!(matches!(probe(&at).unwrap(), Probe::HeadReady));
    assert!(!at.join("tail").exists());

    let (answer, wrong_mac, wrong_served) = dial(json!({"extend": true}), wrong);
    assert_eq!(answer["error_code"], "projection.extend_not_superset", "{answer}");
    assert!(matches!(probe(&at).unwrap(), Probe::HeadReady));
    assert!(at.join("README.md").exists());
    wrong_mac.shutdown(std::net::Shutdown::Both).unwrap();
    wrong_served.join().unwrap();

    let (answer, full_mac, full_served) = dial(json!({"extend": true}), full);
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["data"]["extended"], true);
    assert!(matches!(probe(&at).unwrap(), Probe::Ready(_)));
    assert!(at.join("tail/x.txt").exists());

    for (mac, served) in [(head_mac, head_served), (full_mac, full_served)] {
        mac.shutdown(std::net::Shutdown::Both).unwrap();
        served.join().unwrap();
    }
    let projected = projections().lock().unwrap().remove("test-extend").unwrap();
    if let Some(mounted) = projected.mounted.lock().unwrap().take() {
        mounted.unmount();
    }
    let state =
        crate::platform::workspace_state_dir().unwrap().join("projections").join("test-extend");
    let _ = std::fs::remove_dir_all(&state);
}

#[cfg(target_os = "linux")]
#[test]
fn a_swap_link_out_of_the_served_home_keeps_the_projected_git() {
    let home = Path::new("/h/me");
    let at = Path::new("/h/me/work/chats/c/app");
    // The default state folder is under HOME: fs-v1 follows the link.
    assert!(swap_link_served(
        at,
        Path::new("/h/me/.local/state/cmux-tui/projections/c"),
        Some(home)
    ));
    // A state folder outside HOME: fs-v1 would refuse `.git/cmux-sync.json`, so no swap.
    assert!(!swap_link_served(at, Path::new("/var/state/projections/c"), Some(home)));
    // A folder fs-v1 does not serve, or no HOME: nothing to refuse.
    assert!(swap_link_served(Path::new("/srv/app"), Path::new("/var/state/p"), Some(home)));
    assert!(swap_link_served(at, Path::new("/var/state/p"), None));
}
