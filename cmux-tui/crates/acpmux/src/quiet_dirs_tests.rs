use super::*;
use std::cell::RefCell;
use std::time::Duration;

thread_local! {
    /// Run once, right after `sync` first looks at which folders exist.
    pub(super) static AFTER_LOOK: RefCell<Option<Box<dyn FnMut()>>> =
        const { RefCell::new(None) };
}

/// The first event naming `path` within five seconds.
fn named(rx: &std::sync::mpsc::Receiver<notify::Result<notify::Event>>, path: &Path) -> bool {
    let end = std::time::Instant::now() + Duration::from_secs(5);
    while let Ok(event) = rx.recv_timeout(end.saturating_duration_since(std::time::Instant::now()))
    {
        if event.is_ok_and(|e| e.paths.iter().any(|p| p == path)) {
            return true;
        }
    }
    false
}

/// A folder standing in for a missing one (watched for its entries) sends nothing for a read
/// or a write of a file in it, and sends a folder made in it; a followed folder sends a
/// write. Dropping the watch ends the thread, which drops its sender.
#[test]
fn an_entries_watch_ignores_opens_and_writes_and_sees_a_folder_made() {
    let base = tempfile::tempdir().unwrap();
    let ancestor = base.path().join("ancestor");
    let changes = base.path().join("changes");
    std::fs::create_dir_all(&ancestor).unwrap();
    std::fs::create_dir_all(&changes).unwrap();
    let file = ancestor.join("busy");
    std::fs::write(&file, "x").unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let targets =
        vec![Target::Dir(ancestor.join("made").join("deeper")), Target::Dir(changes.clone())];
    let dirs = QuietDirs::follow(tx, "quiet-dirs-test", targets).unwrap();
    assert_eq!(dirs.watched(), vec![ancestor.clone(), changes.clone()]);
    for _ in 0..20 {
        let _ = std::fs::read_to_string(&file).unwrap();
        std::fs::write(&file, "y").unwrap();
    }
    let quiet = rx.recv_timeout(Duration::from_millis(300));
    assert!(quiet.is_err(), "an open or a write sent an event: {quiet:?}");
    std::fs::create_dir(ancestor.join("made")).unwrap();
    let made = rx.recv_timeout(Duration::from_secs(5)).expect("a folder made sends");
    assert_eq!(made.unwrap().paths, vec![ancestor.join("made")]);
    std::fs::write(changes.join("profile.toml"), "x").unwrap();
    assert!(named(&rx, &changes.join("profile.toml")), "a write sent nothing");
    drop(dirs);
    // The thread ends: once what it already sent is read, the channel closes.
    let end = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        match rx.recv_timeout(end.saturating_duration_since(std::time::Instant::now())) {
            Ok(_) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            Err(e) => panic!("the reading thread did not end: {e:?}"),
        }
    }
}

/// `~/.config/cmux` made between `sync`'s look (which found only the home) and the home's
/// watch: no event ever names it, so the folder must be watched by that same look, or a
/// later write of a file in it is never seen.
#[test]
fn a_folder_made_while_sync_looks_is_watched_by_that_sync() {
    let base = tempfile::tempdir().unwrap();
    let home = std::fs::canonicalize(base.path()).unwrap();
    let folder = home.join(".config").join("cmux");
    let made = folder.clone();
    AFTER_LOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || std::fs::create_dir_all(&made).unwrap()));
    });
    let (tx, _rx) = std::sync::mpsc::channel();
    let target = Target::File(folder.join("cmux-next.json"));
    let dirs = QuietDirs::follow(tx, "quiet-dirs-race", vec![target]).unwrap();
    assert!(AFTER_LOOK.with(|hook| hook.borrow().is_none()), "the look never ran");
    assert_eq!(dirs.watched(), vec![folder]);
}

/// A followed folder removed between `sync`'s look (which found it) and its watch: the add
/// fails, so that same sync watches its nearest existing ancestor instead, or nothing is
/// watched and the folder made again is never seen (#42594 F1).
#[test]
fn a_folder_removed_while_sync_looks_falls_back_to_its_ancestor() {
    let base = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(base.path()).unwrap();
    let folder = root.join("harnesses");
    std::fs::create_dir_all(&folder).unwrap();
    let removed = folder.clone();
    AFTER_LOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || std::fs::remove_dir(&removed).unwrap()));
    });
    let (tx, rx) = std::sync::mpsc::channel();
    let dirs =
        QuietDirs::follow(tx, "quiet-dirs-vanish", vec![Target::Dir(folder.clone())]).unwrap();
    assert!(AFTER_LOOK.with(|hook| hook.borrow().is_none()), "the look never ran");
    assert_eq!(dirs.watched(), vec![root.clone()]);
    std::fs::create_dir(&folder).unwrap();
    assert!(named(&rx, &folder), "the folder made again was not seen");
    while rx.recv_timeout(Duration::from_millis(300)).is_ok() {}
    std::fs::write(folder.join("x.toml"), "x").unwrap();
    assert!(named(&rx, &folder.join("x.toml")), "a write into the folder sent nothing");
}

/// A followed folder replaced under its name (`mv` away, `mv` another in) is watched again:
/// a write into the new folder is sent, and the kernel holds one watch, not two.
#[test]
fn a_folder_replaced_by_mv_is_watched_again() {
    let base = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(base.path()).unwrap();
    let folder = root.join("harnesses");
    std::fs::create_dir_all(&folder).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let dirs =
        QuietDirs::follow(tx, "quiet-dirs-replace", vec![Target::Dir(folder.clone())]).unwrap();
    assert_eq!(dirs.kernel_watches(), 1);
    let new = root.join("harnesses.new");
    std::fs::create_dir_all(&new).unwrap();
    std::fs::rename(&folder, root.join("harnesses.old")).unwrap();
    std::fs::rename(&new, &folder).unwrap();
    // The move is seen, and the new folder named once it is watched.
    assert!(named(&rx, &folder), "the replacement was not seen");
    while rx.recv_timeout(Duration::from_millis(300)).is_ok() {}
    std::fs::write(folder.join("x.toml"), "x").unwrap();
    assert!(named(&rx, &folder.join("x.toml")), "a write into the new folder sent nothing");
    assert_eq!(dirs.kernel_watches(), 1, "{:?}", dirs.watched());
}

/// A link to a folder not made yet: making the folder watches it, and a file written into it
/// is sent.
#[test]
fn a_link_to_a_folder_made_later_is_followed() {
    let base = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(base.path()).unwrap();
    let link = root.join("config").join("cmux");
    std::fs::create_dir_all(root.join("config")).unwrap();
    let target = root.join("dots").join("cmux");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    assert_eq!(resolve(&link.join("cmux-next.json")).0, target.join("cmux-next.json"));
    let (tx, rx) = std::sync::mpsc::channel();
    let file = link.join("cmux-next.json");
    let dirs = QuietDirs::follow(tx, "quiet-dirs-link", vec![Target::File(file)]).unwrap();
    std::fs::create_dir_all(&target).unwrap();
    // Once the folder behind the link is watched, it is named in an event.
    assert!(named(&rx, &link), "the link's folder was never watched: {:?}", dirs.watched());
    while rx.recv_timeout(Duration::from_millis(300)).is_ok() {}
    std::fs::write(target.join("cmux-next.json"), "{}").unwrap();
    let end = std::time::Instant::now() + Duration::from_secs(5);
    let mut seen = false;
    while let Ok(event) = rx.recv_timeout(end.saturating_duration_since(std::time::Instant::now()))
    {
        if event
            .is_ok_and(|e| e.paths.iter().any(|p| p.file_name() == Some("cmux-next.json".as_ref())))
        {
            seen = true;
            break;
        }
    }
    assert!(seen, "a write behind the link sent nothing");
}
