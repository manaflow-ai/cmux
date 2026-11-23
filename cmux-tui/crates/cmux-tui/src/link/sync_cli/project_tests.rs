use super::*;
use std::io::{BufRead as _, Write as _};

#[test]
fn the_manifest_holds_what_a_copy_sends_and_never_a_secret() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(root.join("README.md"), "# hi\n").unwrap();
    std::fs::write(root.join(".env"), "TOKEN=secret\n").unwrap();
    std::fs::create_dir_all(root.join("node_modules/x")).unwrap();
    std::fs::write(root.join("node_modules/x/index.js"), "x\n").unwrap();

    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let manifest = &listed.manifest;
    let main = manifest.resolve("src/main.rs").expect("src/main.rs is in the manifest");
    assert_eq!(manifest.entry(main).unwrap().size, 13);
    assert!(manifest.resolve("README.md").is_some());
    assert_eq!(manifest.resolve(".env"), None, "a secret never reaches the manifest");
    assert_eq!(manifest.resolve("node_modules"), None, "a heavy folder stays here");

    // Reads are answered from the file the manifest named; an edit since is `changed`.
    assert_eq!(Source::whole(&listed, main), Part::ok(b"fn main() {}\n".to_vec()));
    assert_eq!(Source::read(&listed, main, 3, 4), Part::ok(b"main".to_vec()));
    std::fs::write(root.join("src/main.rs"), "fn main() { edited(); }\n").unwrap();
    assert_eq!(Source::whole(&listed, main).status, wire::CHANGED);
    // Anything that is not a file of the manifest is refused.
    assert_eq!(Source::whole(&listed, 0).status, wire::REFUSED);
    assert_eq!(Source::whole(&listed, 9999).status, wire::REFUSED);
}

#[test]
fn each_chat_folder_has_its_own_projection_name() {
    assert_eq!(name_of("/home/cmux/work/a"), name_of("/home/cmux/work/a"));
    assert_ne!(name_of("/home/cmux/work/a"), name_of("/home/cmux/work/b"));
    assert!(name_of("/x").bytes().all(|byte| byte.is_ascii_alphanumeric()));
}

#[test]
fn each_chat_has_its_own_projection_and_its_name_is_one_the_machine_takes() {
    let one = chat_name("0c6f2c1e-6a4e-4d8e-9a59-1f7d3c2b9e10");
    let two = chat_name("5b0a9d7e-2f43-4c1b-8e6d-3a9c7f1e2d40");
    assert_ne!(one, two);
    assert_eq!(one, chat_name("0c6f2c1e-6a4e-4d8e-9a59-1f7d3c2b9e10"));
    // The daemon's rule (cmux-tui-core projection.rs): 1-64 letters, digits, - or _.
    assert!(one.len() <= 64);
    assert!(one.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)));
}

#[test]
fn each_move_has_its_own_projection_and_its_name_is_one_the_machine_takes() {
    let one = chat_name(&move_key("/home/cmux/work/api"));
    std::thread::sleep(Duration::from_millis(1));
    // A later move of the same folder never mounts an earlier move's edits.
    assert_ne!(one, chat_name(&move_key("/home/cmux/work/api")));
    assert!(one.starts_with(&chat_name(&format!("move-{}", name_of("/home/cmux/work/api")))));
    // The daemon's rule (cmux-tui-core projection.rs): 1-64 letters, digits, - or _.
    assert!(one.len() <= 64);
    assert!(one.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)));
}

#[test]
fn what_a_server_serves_reads_back_as_written() {
    let served = ServerRecord {
        machine: "m-7f3a".into(),
        chat: "move-p0123456789abcdef-1".into(),
        local: PathBuf::from("/Users/leo/Projects/with\nnewline"),
    };
    assert_eq!(ServerRecord::decode(&served.encode()), Some(served.clone()));
    assert_eq!(ServerRecord::decode(b"no separator"), None);
    assert_eq!(ServerRecord::decode(b"m\0\0/no/chat"), None);
    // A machine that answers no id is recorded as none, and matches only itself.
    let unnamed = ServerRecord { machine: String::new(), ..served };
    assert_eq!(ServerRecord::decode(&unnamed.encode()), Some(unnamed));
}

/// A stand-in machine socket at `path`: each dial's ask is counted, then answered `ok`.
fn answering(path: &Path) -> std::sync::Arc<std::sync::atomic::AtomicUsize> {
    use std::sync::atomic::Ordering;
    let listener = std::os::unix::net::UnixListener::bind(path).unwrap();
    let dials = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = dials.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                continue;
            }
            counted.fetch_add(1, Ordering::SeqCst);
            let _ = reader.get_mut().write_all(b"{\"ok\":true,\"data\":{}}\n");
        }
    });
    dials
}

#[test]
fn a_redial_prefers_the_quiet_socket_and_falls_back_when_there_is_none() {
    use std::sync::atomic::Ordering;
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("carrier.sock");
    let main = answering(&socket);

    // No quiet socket (an older carrier serve, or a daemon's own socket): the main one.
    assert_eq!(quiet_socket(&socket), None);
    let (dialed, quiet) = redial(&socket, "p1", "/w", &[]);
    assert!(ok(&dialed.unwrap().1));
    assert!(!quiet, "no quiet socket: the main one, as before");
    assert_eq!(main.load(Ordering::SeqCst), 1);

    // A file at the quiet path that is not a socket is no quiet socket.
    let quiet_path = dir.path().join("carrier.sock.quiet");
    std::fs::write(&quiet_path, "").unwrap();
    assert_eq!(quiet_socket(&socket), None);
    let (dialed, quiet) = redial(&socket, "p1", "/w", &[]);
    assert!(ok(&dialed.unwrap().1) && !quiet);
    assert_eq!(main.load(Ordering::SeqCst), 2);
    std::fs::remove_file(&quiet_path).unwrap();

    // A stale quiet socket (nothing accepts on it): the main one.
    drop(std::os::unix::net::UnixListener::bind(&quiet_path).unwrap());
    assert_eq!(quiet_socket(&socket), Some(quiet_path.clone()));
    let (dialed, quiet) = redial(&socket, "p1", "/w", &[]);
    assert!(ok(&dialed.unwrap().1) && !quiet);
    assert_eq!(main.load(Ordering::SeqCst), 3);
    std::fs::remove_file(&quiet_path).unwrap();

    // A live quiet socket: every redial goes there and none to the main one.
    let hushed = answering(&quiet_path);
    for n in 1..=2 {
        let (dialed, quiet) = redial(&socket, "p1", "/w", &[]);
        assert!(ok(&dialed.unwrap().1));
        assert!(quiet, "the quiet socket is preferred");
        assert_eq!(hushed.load(Ordering::SeqCst), n);
    }
    assert_eq!(main.load(Ordering::SeqCst), 3, "no redial reached the main socket");
}

#[test]
fn a_quiet_refusal_is_a_failed_dial_and_the_redial_waits_half_a_second_flat() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("carrier.sock");
    let quiet_path = dir.path().join("carrier.sock.quiet");
    let quiet = std::os::unix::net::UnixListener::bind(&quiet_path).unwrap();
    // The quiet socket closes the dial unanswered, as carrier serve does while the machine sleeps.
    std::thread::spawn(move || {
        for stream in quiet.incoming() {
            drop(stream);
        }
    });
    let (dialed, went_quiet) = redial(&socket, "p1", "/w", &[]);
    assert!(went_quiet);
    let error = format!("{:#}", dialed.err().expect("an unanswered dial fails"));
    assert!(error.contains("without answering"), "{error}");

    let mut backoff = Duration::from_millis(200);
    for _ in 0..10 {
        assert_eq!(retry_wait(true, &mut backoff), QUIET_RETRY);
    }
    assert_eq!(QUIET_RETRY, Duration::from_millis(500));
    let waits: Vec<_> = (0..8).map(|_| retry_wait(false, &mut backoff).as_millis()).collect();
    assert_eq!(
        waits,
        [200, 400, 800, 1600, 3200, 6400, 10_000, 10_000],
        "the main socket backs off"
    );
}
