use super::*;

/// A program that only opens and reads a file in a watched folder sends nothing: the shell's
/// folder (`/usr/bin`) and `/etc` are opened by every program that starts, and each open
/// woke the daemon (about 1,300 a second on a busy agent VM). A write still arrives.
#[test]
fn a_read_in_a_watched_folder_sends_nothing_and_a_write_arrives() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("profile");
    std::fs::write(&file, "export A=1\n").unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let source = source(&[dir.path().to_path_buf()], std::slice::from_ref(&file), tx)
        .expect("the folder is watched");
    for _ in 0..20 {
        let _ = std::fs::read_to_string(&file).unwrap();
    }
    let read = rx.recv_timeout(Duration::from_millis(300));
    assert!(read.is_err(), "a read sent an event: {read:?}");
    std::fs::write(&file, "export A=2\n").unwrap();
    let wrote = rx.recv_timeout(Duration::from_secs(5)).expect("a write sends an event");
    assert!(
        touches(&wrote, std::slice::from_ref(&file)),
        "the write did not name the file: {wrote:?}"
    );
    drop(source);
}

/// cmux#42565: a startup file whose folder does not exist when the watch starts
/// (`~/.config/cmux/machine.env` with no `~/.config`) is seen once the folder and the file
/// are made, with no agent spawn: the nearest existing folder stands in and the watch moves
/// down the path as each folder appears.
#[cfg(target_os = "linux")]
#[test]
fn a_startup_file_in_a_folder_made_after_the_start_is_seen() {
    let base = tempfile::tempdir().unwrap();
    let home = std::fs::canonicalize(base.path()).unwrap();
    let folder = home.join(".config").join("cmux");
    let file = folder.join("machine.env");
    let files = watched(vec![home.join(".profile"), file.clone()]);
    let dirs = vec![home.clone(), folder.clone()];
    let (tx, rx) = std::sync::mpsc::channel();
    let source = source(&dirs, &files, tx).expect("the home is watched");
    std::fs::create_dir_all(&folder).unwrap();
    // The folders' arrival counts (a file may be in them before their watch is armed).
    let end = Instant::now() + Duration::from_secs(5);
    loop {
        let left = end.saturating_duration_since(Instant::now());
        let event = rx.recv_timeout(left).expect("making the folder sent no event touching it");
        if touches(&event, &files) {
            break;
        }
    }
    while rx.recv_timeout(Duration::from_millis(300)).is_ok() {}
    std::fs::write(&file, "A=1\n").unwrap();
    let end = Instant::now() + Duration::from_secs(5);
    loop {
        let left = end.saturating_duration_since(Instant::now());
        let event = rx.recv_timeout(left).expect("writing the startup file sent no event");
        if event.as_ref().is_ok_and(|e| e.paths.contains(&file)) {
            break;
        }
    }
    drop(source);
}
