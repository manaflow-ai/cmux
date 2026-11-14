use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

use notify::event::{
    AccessKind, AccessMode, DataChange, Event, EventKind, Flag, ModifyKind, RemoveKind, RenameMode,
};

use super::{Folders, Wake, fingerprint, next_burst};

const ROOT: &str = "/apps/customize";

/// Whether this queue of events wakes the watch.
fn wakes(events: Vec<notify::Result<Event>>) -> bool {
    let (sender, receiver) = channel();
    for event in events {
        sender.send(Wake::File(event)).unwrap();
    }
    drop(sender);
    next_burst(&receiver, &|path: &Path| path.starts_with(ROOT), &|path: &Path| {
        path == Path::new(ROOT)
    })
    .is_some()
}

fn on(kind: EventKind) -> notify::Result<Event> {
    Ok(Event::new(kind).add_path(PathBuf::from(ROOT).join("cmux-app.v2.json")))
}

/// Reading a local app opens its folder and files, and inotify reports
/// every open: a read that woke the watch made it read again, in a loop
/// that never slept (Linux).
#[test]
fn a_read_does_not_wake_the_watch_and_a_write_does() {
    let read = vec![
        on(EventKind::Access(AccessKind::Open(AccessMode::Any))),
        on(EventKind::Access(AccessKind::Close(AccessMode::Read))),
    ];
    assert!(!wakes(read), "opening and reading a file changes nothing");
    assert!(wakes(vec![on(EventKind::Modify(ModifyKind::Data(DataChange::Any)))]));
    assert!(
        wakes(vec![on(EventKind::Access(AccessKind::Close(AccessMode::Write)))]),
        "a finished write is a change"
    );
}

/// An overflowed inotify queue drops events and says so in one event that
/// names no path; a watch error can lose events too. Both read again.
#[test]
fn a_watch_that_lost_events_reads_again() {
    assert!(wakes(vec![Ok(Event::new(EventKind::Other).set_flag(Flag::Rescan))]));
    assert!(wakes(vec![Err(notify::Error::generic("inotify read failed"))]));
}

/// A folder hint (the folder appeared, vanished or was replaced), or the
/// watched folder itself removed or renamed, arms the folders again, also
/// behind a save in the same burst. A save alone arms nothing.
#[test]
fn a_folder_hint_or_a_removed_folder_arms_the_folders_again() {
    let burst = |wakes: Vec<Wake>| {
        let (sender, receiver) = channel();
        for wake in wakes {
            sender.send(wake).unwrap();
        }
        drop(sender);
        next_burst(&receiver, &|path: &Path| path.starts_with(ROOT), &|path: &Path| {
            path == Path::new(ROOT)
        })
        .map(|burst| burst.folder)
    };
    let write = || Wake::File(on(EventKind::Modify(ModifyKind::Data(DataChange::Any))));
    let folder = |kind| Wake::File(Ok(Event::new(kind).add_path(PathBuf::from(ROOT))));
    assert_eq!(burst(vec![Wake::Folder]), Some(true));
    assert_eq!(burst(vec![write(), Wake::Folder]), Some(true));
    assert_eq!(burst(vec![folder(EventKind::Remove(RemoveKind::Folder))]), Some(true));
    assert_eq!(
        burst(vec![folder(EventKind::Modify(ModifyKind::Name(RenameMode::From)))]),
        Some(true)
    );
    assert_eq!(burst(vec![write()]), Some(false), "a save alone arms nothing");
}

/// Waits (at most 10 s) for a change event naming `want`; panics on one
/// naming a path in `never` first.
fn change_named(events: &Receiver<notify::Result<Event>>, want: &Path, never: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let Ok(event) = events.recv_timeout(left) else {
            panic!("no event for {} in 10 s", want.display())
        };
        let Ok(event) = event else { continue };
        if matches!(event.kind, EventKind::Access(_)) {
            continue;
        }
        assert!(
            !event.paths.iter().any(|path| path == never),
            "the old folder's watch still names {}: {event:?}",
            never.display()
        );
        if event.paths.iter().any(|path| path == want) {
            return;
        }
    }
}

/// A folder deleted and made again at once, or renamed away and made
/// again, is watched once armed again: a save in the new folder is seen,
/// and the old folder's watch reports nothing under the path. Deleted
/// and made at once, the new folder often gets the freed inode number
/// back, so its identity did not say that it had no watch (Linux).
#[test]
fn a_folder_made_again_is_watched_once_armed_again() {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let base = std::env::temp_dir().canonicalize().unwrap();
    let root = base.join(format!("cmux-local-rewatch-{}-{stamp}", std::process::id()));
    let dir = root.join("customize");
    std::fs::create_dir_all(&dir).unwrap();
    let (sender, events) = channel();
    let mut watcher = notify::recommended_watcher(move |event| {
        let _ = sender.send(event);
    })
    .unwrap();
    let dirs = vec![dir.clone()];
    let mut folders = Folders::default();
    folders.arm(&mut watcher, &dirs);
    std::fs::write(dir.join("main.js"), "1").unwrap();
    change_named(&events, &dir.join("main.js"), Path::new("/nothing"));

    // The watch thread arms again once it hears of the removal (a folder
    // hint, or notify's own event for the folder): so does the test.
    std::fs::remove_dir_all(&dir).unwrap();
    change_named(&events, &dir, Path::new("/nothing"));
    std::fs::create_dir(&dir).unwrap();
    folders.arm(&mut watcher, &dirs);
    std::fs::write(dir.join("main.js"), "2").unwrap();
    change_named(&events, &dir.join("main.js"), Path::new("/nothing"));

    let old = root.join("customize.old");
    std::fs::rename(&dir, &old).unwrap();
    std::fs::create_dir(&dir).unwrap();
    folders.arm(&mut watcher, &dirs);
    std::fs::write(old.join("stale.js"), "old").unwrap();
    std::fs::write(dir.join("next.js"), "3").unwrap();
    change_named(&events, &dir.join("next.js"), &dir.join("stale.js"));
    drop(watcher);
    let _ = std::fs::remove_dir_all(&root);
}

/// A coarse file clock (a timer tick on Linux before 6.13, one second on
/// some file systems) gives a same-size save its old modification time.
#[test]
fn a_same_size_save_with_the_old_modification_time_changes_the_fingerprint() {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let dir =
        std::env::temp_dir().join(format!("cmux-local-reload-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let manifest = dir.join("cmux-app.v2.json");
    std::fs::write(&manifest, r#"{"version":"1.0.0"}"#).unwrap();
    let modified = std::fs::metadata(&manifest).unwrap().modified().unwrap();
    let before = fingerprint(&dir);
    std::fs::write(&manifest, r#"{"version":"1.0.1"}"#).unwrap();
    std::fs::File::options().write(true).open(&manifest).unwrap().set_modified(modified).unwrap();
    let after = fingerprint(&dir);
    let _ = std::fs::remove_dir_all(&dir);
    assert_ne!(before, after, "the content changed");
}
