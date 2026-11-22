//! A push's copy as it goes: folders made with one question each, progress against the
//! totals, a retry after a cut, and a machine without room.
use super::*;

/// A copy into a folder the machine does not have yet makes each of its folders with one
/// `fs.mkdir` and asks nothing else about them: a folder this push made holds nothing of
/// the machine's. RED before: three to five `fs.stat`/`fs.list`/`fs.mkdir` questions one
/// after another for every folder before the first write, so a cmux checkout's 4,706
/// folders sat at "0 of 46,516 files" for over twenty minutes on a Cloud link.
#[test]
fn a_copy_into_a_new_folder_asks_nothing_about_the_folders_it_makes() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    let mut folders = 0;
    for top in ["app", "docs", "lib"] {
        folders += 1;
        for mid in 0..10 {
            folders += 1;
            std::fs::create_dir_all(folder.join(format!("{top}/m{mid}"))).unwrap();
            std::fs::write(folder.join(format!("{top}/m{mid}/a.txt")), format!("{top}{mid}\n"))
                .unwrap();
            for leaf in 0..3 {
                folders += 1;
                let leaf = folder.join(format!("{top}/m{mid}/l{leaf}/deep"));
                folders += 1;
                std::fs::create_dir_all(&leaf).unwrap();
                std::fs::write(leaf.join("b.txt"), "b\n").unwrap();
            }
        }
    }
    let (_sockets, socket, home) = machine_home(&root);
    let asked: &'static Mutex<Vec<String>> = Box::leak(Box::default());
    serve_fs_asked(
        &socket,
        &home,
        &["fs-v1", "fs-symlink-v1", "fs-write-deflate-v1", "fs-write-nofollow-v1"],
        asked,
    );
    let remote = home.join("work/site");
    let (ok, summary, progress) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");
    assert_eq!(summary["written"], json!(3 * 10 * (1 + 3)), "{summary}");
    for top in ["app", "docs", "lib"] {
        assert_eq!(
            std::fs::read_to_string(remote.join(format!("{top}/m9/l2/deep/b.txt"))).unwrap(),
            "b\n"
        );
    }
    let asked = asked.lock().unwrap().clone();
    let count = |cmd: &str| asked.iter().filter(|asked| *asked == cmd).count();
    // The folder itself and each of its folders, once.
    assert_eq!(count("fs.mkdir"), 1 + folders, "{asked:?}");
    // A few questions about the folder and its three top folders, none about the rest.
    let questions = count("fs.stat") + count("fs.list");
    assert!(questions <= 24, "{questions} fs.stat/fs.list for {folders} new folders: {asked:?}");
    // Every progress line is one the card reads: the copy's files, or a step before them.
    for line in &progress {
        let step = &line["progress"];
        assert!(
            step.get("files_total").is_some()
                || matches!(step["phase"].as_str(), Some("prepare" | "folders")),
            "{line}"
        );
    }
}

/// Progress goes to stderr as JSON lines: the totals before anything is
/// written, and the last line at the totals.
#[test]
fn a_push_reports_its_progress_against_the_totals() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("notes");
    std::fs::create_dir_all(&folder).unwrap();
    let mut bytes = 0u64;
    for index in 0..30u64 {
        let text = "x".repeat(usize::try_from(index * 7).unwrap());
        bytes += text.len() as u64;
        std::fs::write(folder.join(format!("n{index}.txt")), text).unwrap();
    }
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);

    let (ok, summary, lines) = push_output(&socket, &folder, &home.join("work/notes"));
    assert!(ok, "{summary}");
    assert!(lines.len() >= 2, "{lines:?}");
    let totals = json!({"files_done": 0, "files_total": 30, "bytes_done": 0, "bytes_total": bytes});
    assert_eq!(lines[0]["progress"], totals);
    let done =
        json!({"files_done": 30, "files_total": 30, "bytes_done": bytes, "bytes_total": bytes});
    assert_eq!(lines.last().unwrap()["progress"], done);
    // The answer line keeps its shape.
    assert_eq!(summary["ok"], json!(true));
    assert_eq!(summary["written"], json!(30));
}

/// A push cut off partway saves what landed as it goes: its retry writes
/// only what the record did not hold yet.
#[test]
fn a_retry_of_an_interrupted_push_writes_only_what_had_not_landed() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("many");
    std::fs::create_dir_all(&folder).unwrap();
    for index in 0..1200 {
        std::fs::write(folder.join(format!("f{index:04}.txt")), format!("{index}\n")).unwrap();
    }
    let (_sockets, socket, home) = machine_home(&root);
    let remote = home.join("work/many");
    serve_fs_refusing_writes(&socket, &home, 700, "fs.failure");
    let (ok, failed, _) = push_output(&socket, &folder, &remote);
    assert!(!ok, "{failed}");
    assert_eq!(failed["error_code"], json!("fs.failure"), "{failed}");

    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs(&socket, &home);
    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");
    // The record was saved at 500 files; the 200 after it are written again.
    assert_eq!(summary["unchanged"], json!(500), "{summary}");
    assert_eq!(summary["written"], json!(700), "{summary}");
    assert_eq!(files_below(&remote).len(), 1201);
}

/// The machine's full disk answers in plain words.
#[test]
fn a_full_disk_on_the_machine_answers_disk_full() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("small");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("a.txt"), "a").unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs_refusing_writes(&socket, &home, 0, "fs.no_space");
    let (ok, answer, _) = push_output(&socket, &folder, &home.join("work/small"));
    assert!(!ok);
    assert_eq!(answer["error_code"], json!("disk_full"), "{answer}");
    assert_eq!(answer["error"], json!("The Cloud machine's disk is full"));
}

/// Serves `fs.*` like [`serve_fs`], but its `fs.stat` of a folder says the
/// machine has `free` bytes left, and it counts the `fs.write`s of files.
fn serve_fs_with_free(
    socket: &Path,
    home: &Path,
    free: u64,
) -> &'static std::sync::atomic::AtomicUsize {
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    let writes: &'static std::sync::atomic::AtomicUsize = Box::leak(Box::default());
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let path = request["path"].as_str().unwrap_or_default().to_string();
                    if cmd == "fs.write" && !path.ends_with("cmux-sync.json") {
                        writes.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    }
                    let mut reply = stream::answer(&id, service.call("local", &cmd, request));
                    if cmd == "fs.stat" && reply["data"]["kind"] == json!("dir") {
                        reply["data"]["available_bytes"] = json!(free);
                    }
                    let mut text = reply.to_string();
                    text.push('\n');
                    if writer.write_all(text.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
    writes
}

/// A folder bigger than the machine's free space is refused in plain words
/// before any file goes. RED before the push asked: a 12.8 GB folder copy
/// into a 16 GB machine streamed until the machine dropped the connection,
/// and the person saw "Broken pipe (os error 32)". A machine with room
/// takes it, and a retry counts only what the machine does not hold yet.
#[test]
fn a_folder_bigger_than_the_machines_free_space_is_refused_before_it_goes() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("big");
    std::fs::create_dir_all(&folder).unwrap();
    for index in 0..3 {
        std::fs::write(folder.join(format!("f{index}.bin")), vec![b'x'; 4000]).unwrap();
    }
    let (_sockets, socket, home) = machine_home(&root);
    let remote = home.join("work/big");
    let writes = serve_fs_with_free(&socket, &home, 10_000);
    let (ok, answer, _) = push_output(&socket, &folder, &remote);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], json!("folder_too_big"), "{answer}");
    let error = answer["error"].as_str().unwrap();
    assert!(error.contains("12 kB") && error.contains("10 kB free"), "{error}");
    assert_eq!(writes.load(std::sync::atomic::Ordering::SeqCst), 0, "a file went");

    // Room enough: it goes.
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs_with_free(&socket, &home, 12_000);
    let (ok, answer, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{answer}");

    // A new file next to the three already there needs only its own room.
    std::fs::write(folder.join("f3.bin"), vec![b'y'; 4000]).unwrap();
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs_with_free(&socket, &home, 5_000);
    let (ok, answer, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{answer}");
    assert_eq!(answer["written"], json!(1), "{answer}");
}
