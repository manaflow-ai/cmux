//! The drop of an owner after its release: the last
//! write of its output store, and the files of the session's registry.
//!
//! The lease is the last thing that an owner gives up. So an owner whose
//! output store still has its last write to make keeps the session, and
//! makes that write as the session's owner; an owner that gave the session
//! up writes no file of it at its drop.

use super::*;

const DROP_TERMINAL: &str = "0000000000004000800000000000007b";
const DROP_INCARNATION: &str = "1000000000004000800000000000007b";
/// The last line that the terminal of a row prints. It has no space: a
/// stored screen can hold a space as a cursor move.
const LAST_LINE: &str = "the-last-line-of-the-terminal";

/// What a file of a folder is at one moment.
struct FileNow {
    length: u64,
    changed: Option<std::time::SystemTime>,
    inode: u64,
    /// `None`: not a plain file (a socket, a link).
    bytes: Option<Vec<u8>>,
}

/// Each file below `folder`, by its path in `folder`. The time of a file can
/// have a coarse grain, so a write of the same length inside one grain shows
/// in the bytes, and a file that was replaced shows in the inode.
fn files_of(folder: &Path) -> std::collections::BTreeMap<std::path::PathBuf, FileNow> {
    let mut files = std::collections::BTreeMap::new();
    let mut folders = vec![folder.to_path_buf()];
    while let Some(next) = folders.pop() {
        for entry in std::fs::read_dir(&next).into_iter().flatten().flatten() {
            let path = entry.path();
            let Ok(metadata) = std::fs::symlink_metadata(&path) else { continue };
            if metadata.is_dir() {
                folders.push(path);
                continue;
            }
            let bytes = if metadata.is_file() { std::fs::read(&path).ok() } else { None };
            let file = FileNow {
                length: metadata.len(),
                changed: metadata.modified().ok(),
                inode: std::os::unix::fs::MetadataExt::ino(&metadata),
                bytes,
            };
            files.insert(path.strip_prefix(folder).unwrap_or(&path).to_path_buf(), file);
        }
    }
    files
}

/// The files that differ between two reads of [`files_of`], each with what
/// differs.
fn changed_files(
    before: &std::collections::BTreeMap<std::path::PathBuf, FileNow>,
    after: &std::collections::BTreeMap<std::path::PathBuf, FileNow>,
) -> Vec<String> {
    let mut said = Vec::new();
    for (path, was) in before {
        let Some(is) = after.get(path) else {
            said.push(format!("{}: removed", path.display()));
            continue;
        };
        let mut what = Vec::new();
        if was.length != is.length {
            what.push(format!("its length, {} to {} bytes", was.length, is.length));
        }
        if was.changed != is.changed {
            what.push("its time".to_string());
        }
        if was.inode != is.inode {
            what.push("its inode".to_string());
        }
        if was.bytes != is.bytes {
            what.push("its bytes".to_string());
        }
        if !what.is_empty() {
            said.push(format!("{}: {}", path.display(), what.join(", ")));
        }
    }
    for path in after.keys().filter(|path| !before.contains_key(*path)) {
        said.push(format!("{}: new", path.display()));
    }
    said
}

/// The folder of the owner's output store.
fn store_folder(owner: &Mux) -> std::path::PathBuf {
    owner
        .output_store
        .directory()
        .expect("setup: the owner's output store has no folder, so its stop does nothing")
        .to_path_buf()
}

/// Whether `files` has a file of `terminal` (its snapshot, its tail).
fn has_a_file_of(
    files: &std::collections::BTreeMap<std::path::PathBuf, FileNow>,
    terminal: &TerminalPublicId,
) -> bool {
    files.keys().any(|path| path.to_string_lossy().starts_with(terminal.as_str()))
}

/// An owner with one running terminal, that terminal's screen, and its id in
/// the output store.
fn open_owner_with_a_terminal(
    root: &Path,
    session: &str,
) -> (Arc<Mux>, Arc<Surface>, TerminalPublicId) {
    let mux = open_owner(root, session);
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    // A terminal that the session keeps after its program's end: the owner
    // after this one has it, and so the files of its output.
    let surface = mux
        .seed_running_terminal_with_on_exit_for_test(
            DROP_TERMINAL,
            DROP_INCARNATION,
            &workspace.key,
            TerminalOnExit::Keep,
        )
        .unwrap();
    let surface = mux.surface(surface).unwrap();
    let terminal = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_resource_id(DROP_TERMINAL)
        .unwrap()
        .unwrap();
    (mux, surface, terminal)
}

/// Prints `bytes` in the terminal as its reader does: on its screen and
/// into the output store.
fn print(owner: &Mux, surface: &Surface, terminal: &TerminalPublicId, bytes: &[u8]) {
    surface.apply_stream_output_for_test(bytes).expect("setup: the terminal has a screen");
    owner.output_store.append(terminal, &Arc::from(DROP_INCARNATION), bytes, None);
}

/// The stop of an owner went on without the writer of its output store,
/// which was in a pass: that stop made no last write of the store. The pass
/// ended before the release, so no thread of the owner lives at the release.
///
/// The stop here has no screen checkpoint: a stop with one makes the store's
/// last write a second time, after the store's stop, and waits for the pass
/// lock to do it. A stop that hands the terminals to the next daemon (an
/// update of the app, `server stop`) and a stop in the window of a teardown
/// have none. The row opens that window; a hand-over is not in it.
///
/// The store's last write is still to make, and the lease is the last thing
/// that an owner gives up: the release keeps the session and names the last
/// pass. The drop of the owner then makes that write as the session's
/// owner, and the owner after it reads the terminal's last line.
#[test]
fn an_owner_whose_output_store_made_no_last_write_keeps_its_session_for_that_write() {
    let root = std::env::temp_dir().join(format!(
        "cmux-session-release-last-pass-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let session = "release-last-pass";
    let (mux, surface, terminal) = open_owner_with_a_terminal(&root, session);
    let folder = session_folder(&mux);
    let store = store_folder(&mux);
    let (began, pass_began) = mpsc::sync_channel(1);
    let (end_the_pass, pass_runs) = mpsc::sync_channel::<()>(1);
    let writer_ended = crate::output_store::OutputStore::put_a_writer_in_a_pass(&mux, move || {
        let _ = began.send(());
        // Until the test drops its end of the channel.
        let _ = pass_runs.recv();
    });
    pass_began
        .recv_timeout(OWNER_CALL_WAIT)
        .expect("setup: the writer's thread did not begin its pass");
    // The store's own writer ended above and this pass writes nothing, so no
    // byte of these lines is in a file before the owner's last write.
    print(&mux, &surface, &terminal, format!("a first line\r\n{LAST_LINE}\r\n").as_bytes());
    // Open at the start of the stop: the stop makes no screen checkpoint.
    let teardown = mux.begin_terminal_teardown();
    let (said, shutdown_said) = mpsc::sync_channel(1);
    let stopping = Arc::clone(&mux);
    let stopper = std::thread::spawn(move || {
        stopping.shutdown();
        let _ = said.send(());
    });
    // The pass ends only after this line: a shutdown that the test has here
    // went on without the writer and made no last write of the store.
    let returned = shutdown_said.recv_timeout(OWNER_CALL_WAIT).is_ok();
    drop(end_the_pass);
    let _ = stopper.join();
    drop(teardown);
    // The writer's thread gives up the pass lock and its handle of the
    // owner: the channel closes then.
    let pass_ended = matches!(
        writer_ended.recv_timeout(OWNER_CALL_WAIT),
        Err(mpsc::RecvTimeoutError::Disconnected)
    );
    let release = mux.release_ownership(&root.join("control.sock"));
    let names = kept_names(Some(&release));
    let before = files_of(&store);
    drop(surface);
    // The drop runs here, on this thread, when this handle is the last one.
    let dropped = Arc::into_inner(mux).is_some();
    let changed = changed_files(&before, &files_of(&store));
    // The end of the owner before: the kernel frees a kept session then.
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let next = try_open_owner(&root, session);
    let next_said = next.as_ref().err().map(|error| format!("{error:#}"));
    let read_the_last_line = next
        .as_ref()
        .ok()
        .and_then(|next| next.output_store.previous_screen(&terminal))
        .is_some_and(|screen| {
            screen.bytes.windows(LAST_LINE.len()).any(|bytes| bytes == LAST_LINE.as_bytes())
        });
    if let Ok(next) = next {
        next.shutdown();
        next.release_ownership(&root.join("control.sock"));
    }
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let _ = std::fs::remove_dir_all(&root);
    eprintln!(
        "the release: {release:?}; the store's folder at the drop: {changed:?}; the next \
         owner's error: {next_said:?}; it read the last line: {read_the_last_line}"
    );
    assert!(
        returned && pass_ended,
        "setup: the owner's shutdown did not return while a pass of its output store writer \
         ran, or that pass did not end (returned: {returned}; the pass ended: {pass_ended})"
    );
    assert!(
        !has_a_file_of(&before, &terminal),
        "setup: the output store had a file of the terminal before the owner's last write"
    );
    assert!(
        names.contains(&LAST_PASS),
        "an owner whose output store made no last write gave its session up, so that write \
         is lost or lands in a session that the next owner has: its release: {release:?}"
    );
    assert!(
        dropped,
        "setup: the test's handle of the owner was not the last one, so the owner's drop did \
         not run before the next owner opened"
    );
    assert!(
        changed.iter().any(|file| file.starts_with(terminal.as_str())),
        "the drop of an owner that kept its session for the last write of its output store \
         wrote no file of the terminal: {changed:?}"
    );
    assert!(
        read_the_last_line,
        "the owner after one that kept its session for the last write of its output store \
         did not read the terminal's last line (its error at its open: {next_said:?})"
    );
}

/// A clean stop makes the whole last write of the output store. The release
/// then gives the session up, and the drop of the owner changes no file of
/// the store.
#[test]
fn a_drop_of_an_owner_after_a_whole_last_write_changes_no_file_of_its_output_store() {
    let root = std::env::temp_dir().join(format!(
        "cmux-session-release-whole-pass-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let (mux, surface, terminal) = open_owner_with_a_terminal(&root, "release-whole-pass");
    let folder = session_folder(&mux);
    let store = store_folder(&mux);
    print(&mux, &surface, &terminal, format!("a first line\r\n{LAST_LINE}\r\n").as_bytes());
    mux.shutdown();
    let release = mux.release_ownership(&root.join("control.sock"));
    let before = files_of(&store);
    drop(surface);
    // The drop runs here, on this thread, when this handle is the last one.
    let dropped = Arc::into_inner(mux).is_some();
    let changed = changed_files(&before, &files_of(&store));
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        release == lifecycle::OwnershipRelease::Released,
        "an owner whose stop made the whole last write of its output store did not give its \
         session up: its release: {release:?}"
    );
    assert!(
        has_a_file_of(&before, &terminal),
        "setup: the owner's stop wrote no file of the terminal, so the row has no last write"
    );
    assert!(
        changed.is_empty(),
        "after its release returned, the drop of the owner changed files of its output \
         store, which the next owner has from then on: {changed:?}"
    );
    assert!(
        dropped,
        "setup: the test's handle of the owner was not the last one, so the owner's drop did \
         not run between the two reads of the store's folder"
    );
}

/// A prune of the output store that became due after the owner's last write
/// does not run after the release: the drop removes no file. A prune that is
/// late by one start loses nothing.
#[test]
fn a_drop_of_an_owner_after_its_release_runs_no_prune_of_its_output_store() {
    let root = std::env::temp_dir().join(format!(
        "cmux-session-release-late-prune-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_owner(&root, "release-late-prune");
    let folder = session_folder(&mux);
    let store = store_folder(&mux);
    mux.shutdown();
    // After the owner's last write: a terminal leaves the store, so a prune
    // is due, and the store's folder has a file of a terminal that is not in
    // the session, which a prune removes.
    let gone = restore_terminal_id(0x5e);
    let generation = Arc::from("1000000000004000800000000000005e");
    mux.output_store.append(&gone, &generation, b"a line\r\n", None);
    mux.output_store.forget(&gone);
    let stray = std::path::PathBuf::from(format!("{}.snap", gone.as_str()));
    // The store makes its folder at its first write, and this owner made none.
    std::fs::create_dir_all(&store).unwrap();
    std::fs::write(store.join(&stray), b"a file of a terminal that is not in the session").unwrap();
    let release = mux.release_ownership(&root.join("control.sock"));
    let before = files_of(&store);
    // The drop runs here, on this thread, when this handle is the last one.
    let dropped = Arc::into_inner(mux).is_some();
    let changed = changed_files(&before, &files_of(&store));
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        release == lifecycle::OwnershipRelease::Released,
        "setup: an owner whose stop made its last write did not give its session up: its \
         release: {release:?}"
    );
    assert!(
        before.contains_key(&stray),
        "setup: the file of a terminal that is not in the session was not in the store's \
         folder when the release returned"
    );
    assert!(
        changed.is_empty(),
        "after its release returned, the drop of the owner ran a prune of its output store, \
         which the next owner has from then on: {changed:?}"
    );
    assert!(
        dropped,
        "setup: the test's handle of the owner was not the last one, so the owner's drop did \
         not run between the two reads of the store's folder"
    );
}

/// The drop of an owner closes its connection to the registry of the
/// session. After the release the next owner has that database: the close
/// changes no byte of its main file and leaves its write-ahead log, which
/// holds a commit that the main file does not have.
#[test]
fn a_drop_of_an_owner_after_its_release_leaves_the_registry_file_and_its_log() {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-release-close-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_owner(&root, "release-close");
    let folder = session_folder(&mux);
    let database = mux
        .workspace_registry
        .lock()
        .unwrap()
        .session_journal_database_path()
        .expect("a session on disk has its registry");
    let main = std::path::PathBuf::from(database.file_name().expect("the registry has a name"));
    let mut log = main.clone().into_os_string();
    log.push("-wal");
    let log = std::path::PathBuf::from(log);
    mux.shutdown();
    // A commit after the stop and before the release: the owner has the
    // session, and the log holds this commit when the release returns.
    let wrote = {
        let mut registry = mux.workspace_registry.lock().unwrap();
        let (revision, _) = store_state(&registry);
        write_at(&mut registry, "before-the-release", revision)
    };
    let release = mux.release_ownership(&root.join("control.sock"));
    let mut before = files_of(&folder);
    // The drop runs here, on this thread, when this handle is the last one.
    let dropped = Arc::into_inner(mux).is_some();
    let mut after = files_of(&folder);
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let _ = std::fs::remove_dir_all(&root);
    eprintln!("the session folder at the drop: {:?}", changed_files(&before, &after));
    before.retain(|path, _| *path == main || *path == log);
    after.retain(|path, _| *path == main || *path == log);
    let log_bytes = before.get(&log).map_or(0, |file| file.length);
    let changed = changed_files(&before, &after);
    assert!(wrote.is_ok(), "setup: the owner's commit before its release failed: {wrote:?}");
    assert!(
        release == lifecycle::OwnershipRelease::Released,
        "setup: an owner whose threads all ended did not give its session up: its release: \
         {release:?}"
    );
    assert!(
        before.contains_key(&main) && log_bytes > 0,
        "setup: the registry's main file or a commit in its log was not there when the \
         release returned (the log: {log_bytes} bytes)"
    );
    assert!(
        changed.is_empty(),
        "after its release returned, the drop of the owner changed the registry's main file \
         or its log, which the next owner has from then on: {changed:?}"
    );
    assert!(
        dropped,
        "setup: the test's handle of the owner was not the last one, so the owner's drop did \
         not run between the two reads of the session folder"
    );
}

/// The owner's output store holds output of a terminal that is not in its
/// session: the terminal left, and its reader gave a part of its output to
/// the store after that. No write of the store takes those bytes, and the
/// owner after this one has no terminal that reads them. They are not a
/// missing last write: the release gives the session up, and the drop of
/// the owner changes no file of the store.
#[test]
fn output_of_a_terminal_that_is_not_in_the_session_does_not_keep_the_session() {
    let root = std::env::temp_dir().join(format!(
        "cmux-session-release-left-terminal-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let (mux, surface, terminal) = open_owner_with_a_terminal(&root, "release-left-terminal");
    let folder = session_folder(&mux);
    let store = store_folder(&mux);
    print(&mux, &surface, &terminal, format!("a first line\r\n{LAST_LINE}\r\n").as_bytes());
    // Before the owner's last write: bytes of a terminal that is not in the
    // session. Each write of the store finds no terminal for them.
    let gone = restore_terminal_id(0x5f);
    let generation = Arc::from("1000000000004000800000000000005f");
    mux.output_store.append(&gone, &generation, b"a line\r\n", None);
    mux.shutdown();
    let release = mux.release_ownership(&root.join("control.sock"));
    let before = files_of(&store);
    drop(surface);
    // The drop runs here, on this thread, when this handle is the last one.
    let dropped = Arc::into_inner(mux).is_some();
    let changed = changed_files(&before, &files_of(&store));
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        has_a_file_of(&before, &terminal) && !has_a_file_of(&before, &gone),
        "setup: the owner's stop wrote no file of its terminal, or it wrote a file of the \
         terminal that is not in the session"
    );
    assert!(
        release == lifecycle::OwnershipRelease::Released,
        "an owner kept its session for output of a terminal that is not in the session, which \
         no write of its output store takes: its release: {release:?}"
    );
    assert!(
        changed.is_empty(),
        "after its release returned, the drop of the owner changed files of its output \
         store, which the next owner has from then on: {changed:?}"
    );
    assert!(
        dropped,
        "setup: the test's handle of the owner was not the last one, so the owner's drop did \
         not run between the two reads of the store's folder"
    );
}

/// A terminal has a tab in the session and no runtime in the owner (a
/// respawn takes the old runtime out before the new one is there), and the
/// output store holds output of it that no write of the store took. The
/// owner after this one has that terminal, so this is a missing last write:
/// the release keeps the session and names the last pass.
#[test]
fn unwritten_output_of_a_terminal_of_the_session_with_no_runtime_keeps_the_session() {
    let root = std::env::temp_dir().join(format!(
        "cmux-session-release-no-runtime-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let (mux, surface, terminal) = open_owner_with_a_terminal(&root, "release-no-runtime");
    let folder = session_folder(&mux);
    // The runtime leaves the owner. The terminal's tab stays in the session.
    let runtime = mux.remove_terminal_catalog_for_test(&terminal);
    let tabs = mux.with_state(|state| {
        state.placements_of_content(&ContentPublicId::Terminal(terminal.clone())).len()
    });
    // After the runtime left: each write of the store finds no runtime for
    // these bytes, so they are in no file when the owner stops.
    mux.output_store.append(&terminal, &Arc::from(DROP_INCARNATION), b"a line\r\n", None);
    mux.shutdown();
    let release = mux.release_ownership(&root.join("control.sock"));
    let names = kept_names(Some(&release));
    let had_a_runtime = runtime.is_some();
    drop(runtime);
    drop(surface);
    drop(mux);
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        had_a_runtime && tabs > 0,
        "setup: the terminal had no runtime to take out, or it has no tab in the session after \
         that (a runtime: {had_a_runtime}; its tabs: {tabs})"
    );
    assert!(
        names.contains(&LAST_PASS),
        "an owner whose output store holds unwritten output of a terminal of its session gave \
         the session up: its release: {release:?}"
    );
}

/// The owner's output store holds output of a private terminal that is in
/// no file. By design no write of the store takes it: a private terminal
/// stays in memory. So it is not a missing last write: the release gives
/// the session up, and the drop of the owner changes no file of the store.
#[test]
fn unwritten_output_of_a_private_terminal_does_not_keep_the_session() {
    let root = std::env::temp_dir().join(format!(
        "cmux-session-release-private-terminal-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let (mux, surface, terminal) = open_owner_with_a_terminal(&root, "release-private-terminal");
    let folder = session_folder(&mux);
    let store = store_folder(&mux);
    mux.output_store.mark_private(&terminal);
    print(&mux, &surface, &terminal, format!("a first line\r\n{LAST_LINE}\r\n").as_bytes());
    // The terminal's host put a new screen in its place: the store owes a
    // snapshot of the terminal from then on, and no pass writes one of a
    // private terminal.
    mux.output_store.stream_gap(&terminal, &Arc::from(DROP_INCARNATION));
    mux.shutdown();
    let unwritten = mux.output_store.has_unwritten_output_of(&terminal);
    let release = mux.release_ownership(&root.join("control.sock"));
    let before = files_of(&store);
    drop(surface);
    // The drop runs here, on this thread, when this handle is the last one.
    let dropped = Arc::into_inner(mux).is_some();
    let changed = changed_files(&before, &files_of(&store));
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        unwritten && !has_a_file_of(&before, &terminal),
        "setup: after the owner's stop the output store holds no unwritten output of the \
         private terminal, or it has a file of that terminal (unwritten: {unwritten})"
    );
    assert!(
        release == lifecycle::OwnershipRelease::Released,
        "an owner kept its session for output of a private terminal, which no write of its \
         output store takes: its release: {release:?}"
    );
    assert!(
        changed.is_empty(),
        "after its release returned, the drop of the owner changed files of its output \
         store, which the next owner has from then on: {changed:?}"
    );
    assert!(
        dropped,
        "setup: the test's handle of the owner was not the last one, so the owner's drop did \
         not run between the two reads of the store's folder"
    );
}

/// A commit that the registry's log holds when the owner releases the
/// session is not lost at the owner's drop: the owner after it reads that
/// commit, whether the drop wrote the log into the main file or left it.
#[test]
fn the_next_owner_reads_a_commit_that_the_registry_log_held_at_the_release() {
    let root = std::env::temp_dir().join(format!(
        "cmux-session-release-log-commit-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let session = "release-log-commit";
    let mux = open_owner(&root, session);
    let folder = session_folder(&mux);
    let database = mux
        .workspace_registry
        .lock()
        .unwrap()
        .session_journal_database_path()
        .expect("a session on disk has its registry");
    let mut log = database.into_os_string();
    log.push("-wal");
    mux.shutdown();
    // A commit after the stop and before the release, as the owner.
    let (revision, wrote) = {
        let mut registry = mux.workspace_registry.lock().unwrap();
        let (revision, _) = store_state(&registry);
        (revision, write_at(&mut registry, "before-the-release", revision))
    };
    let release = mux.release_ownership(&root.join("control.sock"));
    let log_bytes = std::fs::metadata(&log).map_or(0, |file| file.len());
    // The drop runs here, on this thread, when this handle is the last one.
    let dropped = Arc::into_inner(mux).is_some();
    crate::workspace_registry::owner_release::end_kept_owner_for_test(&folder);
    let next = WorkspaceRegistry::open(&root, session);
    let next_said = next.as_ref().err().map(|error| format!("{error:#}"));
    let read = next.as_ref().ok().map(|next| store_state(next).0);
    drop(next);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        wrote.as_ref().is_ok_and(|wrote| *wrote > revision) && log_bytes > 0,
        "setup: the owner's commit before its release failed or changed no revision, or the \
         registry's log was empty when the release returned (the commit: {wrote:?}, after \
         revision {revision}; the log: {log_bytes} bytes)"
    );
    assert!(
        release == lifecycle::OwnershipRelease::Released && dropped,
        "setup: the owner did not give its session up, or the test's handle of it was not the \
         last one (its release: {release:?}; dropped: {dropped})"
    );
    assert!(
        read == wrote.as_ref().ok().copied(),
        "the owner after one that released its session does not read the commit that the \
         registry's log held at that release: it read revision {read:?}, the commit was \
         {wrote:?} (its error at its open: {next_said:?})"
    );
}

/// A registry database that no owner released closes as before: its last
/// connection writes the log into the main file and removes the log. An
/// open that makes a database beside the registry and then renames its main
/// file into place opens it by this function: a log that stays beside a
/// renamed file is a lost commit.
#[test]
fn a_registry_database_that_no_owner_released_has_no_log_after_its_close() {
    let root = std::env::temp_dir().join(format!(
        "cmux-session-release-plain-close-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    std::fs::create_dir_all(&root).unwrap();
    let database = root.join("beside-the-registry.sqlite3");
    let mut log = database.clone().into_os_string();
    log.push("-wal");
    let connection = crate::workspace_registry::open_registry_database(&database)
        .expect("setup: a new database opens");
    let wrote = connection.execute_batch(
        "PRAGMA journal_mode=WAL;
         CREATE TABLE written(value INTEGER NOT NULL);
         INSERT INTO written(value) VALUES (7);",
    );
    let log_bytes = std::fs::metadata(&log).map_or(0, |file| file.len());
    drop(connection);
    let log_after = std::fs::metadata(&log).ok().map(|file| file.len());
    let read = crate::workspace_registry::open_registry_database_read_only(&database)
        .and_then(|reader| {
            reader
                .query_row("SELECT value FROM written", [], |row| row.get::<_, i64>(0))
                .map_err(anyhow::Error::from)
        })
        .map_err(|error| format!("{error:#}"));
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        wrote.is_ok() && log_bytes > 0,
        "setup: the write failed, or it was not in the database's log before the close (the \
         write: {wrote:?}; the log: {log_bytes} bytes)"
    );
    assert!(
        log_after.is_none(),
        "the close of the last connection of a database that no owner released left its log \
         ({log_after:?} bytes): a rename of the main file then loses the commits of that log"
    );
    assert!(
        read == Ok(7),
        "the main file of a database does not hold the commit after the close of its last \
         connection: {read:?}"
    );
}
