use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

use notify::event::{
    AccessKind, AccessMode, DataChange, Event, EventKind, Flag, ModifyKind, RemoveKind, RenameMode,
};

use super::{Burst, Folders, Scope, Wake, fingerprint, next_burst, package_of};

const ROOT: &str = "/apps/customize";

/// The burst the watch of the customize folder `ROOT` drains from `wakes`.
fn drain(wakes: Vec<Wake>) -> Option<Burst> {
    let (sender, receiver) = channel();
    for wake in wakes {
        sender.send(wake).unwrap();
    }
    drop(sender);
    let roots = [(PathBuf::from(ROOT), PathBuf::from(ROOT))];
    next_burst(
        &receiver,
        &|path: &Path| path.starts_with(ROOT),
        &|path: &Path| path == Path::new(ROOT),
        &|path: &Path| package_of(&roots, Some(Path::new(ROOT)), path),
    )
}

/// Whether this queue of events wakes the watch.
fn wakes(events: Vec<notify::Result<Event>>) -> bool {
    drain(events.into_iter().map(Wake::File).collect()).is_some()
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
    let burst = |wakes: Vec<Wake>| drain(wakes).map(|burst| burst.folder);
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

/// A burst names the package folders its events are in, so the pass
/// reads only those; a lost-events signal, a folder hint or an event on
/// a watched folder itself reads every folder.
#[test]
fn a_save_names_its_package_folder_and_a_lost_event_reads_all() {
    let local = PathBuf::from("/state/apps/local");
    // The folder as watched under a symlink's real path, and as configured.
    let real = PathBuf::from("/private/state/apps/local");
    let roots = [(local.clone(), local.clone()), (real.clone(), local.clone())];
    let scope = |events: Vec<notify::Result<Event>>| {
        let (sender, receiver) = channel();
        for event in events {
            sender.send(Wake::File(event)).unwrap();
        }
        drop(sender);
        let relevant = |path: &Path| roots.iter().any(|(root, _)| path.starts_with(root));
        let root = |path: &Path| roots.iter().any(|(root, _)| path == root);
        let package = |path: &Path| package_of(&roots, None, path);
        match next_burst(&receiver, &relevant, &root, &package).unwrap().scope {
            Scope::All => None,
            Scope::Folders(folders) => {
                let mut folders: Vec<PathBuf> = folders.into_iter().collect();
                folders.sort();
                Some(folders)
            }
        }
    };
    let write = |path: PathBuf| {
        Ok(Event::new(EventKind::Modify(ModifyKind::Data(DataChange::Any))).add_path(path))
    };
    // `ext dev` stages a file and renames it over the old one.
    let staged = Event::new(EventKind::Modify(ModifyKind::Name(RenameMode::Both)))
        .add_path(local.join("s0/dist/.main.js.tmp"))
        .add_path(local.join("s0/dist/main.js"));
    assert_eq!(scope(vec![Ok(staged)]), Some(vec![local.join("s0")]));
    assert_eq!(
        scope(vec![write(real.join("s1/cmux-app.json")), write(local.join("s0/main.js"))]),
        Some(vec![local.join("s0"), local.join("s1")]),
        "the real path names the folder as configured"
    );
    assert_eq!(
        scope(vec![Ok(Event::new(EventKind::Create(notify::event::CreateKind::Folder))
            .add_path(local.join("new")))]),
        Some(vec![local.join("new")]),
        "a new app folder is read on its own"
    );
    assert_eq!(scope(vec![write(local.clone())]), None, "the watched folder itself");
    assert_eq!(
        scope(vec![
            write(local.join("s0/a")),
            Ok(Event::new(EventKind::Other).set_flag(Flag::Rescan))
        ]),
        None,
        "a lost event reads every folder"
    );
    assert_eq!(
        scope(vec![write(local.join("s0/a")), Err(notify::Error::generic("read failed"))]),
        None
    );
    assert!(
        matches!(
            drain(vec![Wake::File(on(EventKind::Modify(ModifyKind::Any))), Wake::Folder])
                .unwrap()
                .scope,
            Scope::All
        ),
        "a folder hint reads every folder"
    );
    assert!(matches!(
        drain(vec![Wake::File(on(EventKind::Modify(ModifyKind::Any)))]).unwrap().scope,
        Scope::Folders(folders) if folders.len() == 1 && folders.contains(Path::new(ROOT))
    ));
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

/// An empty `CMUX_APPS_DIRS` entry (a leading or trailing `:`) and an
/// outer folder watch nothing they do not hold directly: every path
/// starts with "", so a shipped package counted as watched, had no
/// fingerprint from before the read, and restarted on every reload.
#[test]
fn only_direct_subfolders_of_a_named_folder_are_watched() {
    let sources = super::catalog::Sources {
        local: Some(PathBuf::from("/state/apps/local")),
        extra: vec![PathBuf::new(), PathBuf::from("/src/ext")],
        customize: Some(PathBuf::from("/home/me/.config/cmux/customize")),
        ..Default::default()
    };
    let watched = |dir: &str| super::is_watched_dir(&sources, Path::new(dir));
    assert!(watched("/state/apps/local/spy"));
    assert!(watched("/src/ext/fork"));
    assert!(watched("/home/me/.config/cmux/customize"));
    assert!(!watched("/Applications/cmux.app/Contents/Resources/apps/first-party/search"));
    assert!(!watched("/src/ext/fork/nested"));
    assert!(!super::watched_dirs(&sources).iter().any(|d| d.as_os_str().is_empty()));
}
