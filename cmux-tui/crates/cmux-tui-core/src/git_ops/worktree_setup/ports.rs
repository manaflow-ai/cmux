use super::*;
use cmux_file_lock::{FileLock, Kind, LockError};

/// The file lock every session host's allocation for the repository
/// takes, and this process's lock. The drop lets go of the file lock
/// first: it unlocks the file before it closes it (a child another
/// thread forked meanwhile shares it until it execs). Then it lets go
/// of this process's lock.
struct Lock {
    file: Option<FileLock>,
    _guard: std::sync::MutexGuard<'static, ()>,
}

/// How long an allocation waits for the file lock while another session
/// host's allocation has it.
const WAIT: Duration = Duration::from_millis(500);

/// The time between two tries of the file lock.
const STEP: Duration = Duration::from_millis(10);

/// The repository's port list, in its shared git folder.
const PORTS_FILE: &str = "cmux-worktree-ports.json";
/// The lock file of the port list, beside it.
const PORTS_LOCK_FILE: &str = "cmux-worktree-ports.lock";

/// The locks of an allocation in the repository's git folder `folder`,
/// after at most `wait` for the file lock. With no file lock then, the
/// allocation has this process's lock alone, and a line on stderr says so.
fn lock(folder: &OwnFolder, wait: Duration) -> Lock {
    static LOCK: Mutex<()> = Mutex::new(());
    // No lock file is made through a link, and none is taken on a file
    // that is not a regular one: the allocation then has this process's
    // lock alone, as when the file cannot be made, and the line on stderr
    // says that the lock file is not opened. A lock file that has a second
    // name is made new.
    // The wait comes before this process's lock: a lock file that stays
    // locked does not hold up the allocation of another repository.
    let waited = folder
        .open_or_make(PORTS_LOCK_FILE, Access::Write)
        .map(|file| FileLock::take_within(file, Kind::Exclusive, wait, STEP));
    let guard = LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    // One more try, now with this process's lock: the file lock is free
    // when a thread of this process had it during the wait and is done.
    let taken = waited.map(|waited| match waited {
        Err(LockError::Busy(file)) => FileLock::try_take(file, Kind::Exclusive),
        waited => waited,
    });
    let (file, why) = match taken {
        Some(Ok(file)) => (Some(file), None),
        Some(Err(error)) => (None, Some(error.to_string())),
        None => (None, Some("the lock file is not opened".to_string())),
    };
    if let Some(why) = why {
        eprintln!(
            "cmux-tui: {}: {why}; the ports of this repository's worktrees have no lock \
             between session hosts now",
            folder.path().join(PORTS_LOCK_FILE).display()
        );
    }
    Lock { file, _guard: guard }
}

/// The ports of each worktree. A ports file above the size limit is not
/// read, and it is not a list with no worktree: a port of a list that
/// starts empty can be the port of another worktree.
fn load(folder: &OwnFolder) -> Result<BTreeMap<String, u16>, TooLarge> {
    let bytes = folder.read(PORTS_FILE)?;
    Ok(bytes.and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default())
}

fn save(folder: &OwnFolder, ports: &BTreeMap<String, u16>) {
    if let Ok(bytes) = serde_json::to_vec_pretty(ports) {
        let _ = folder.write(PORTS_FILE, &bytes);
    }
}

fn key(root: &Path) -> String {
    root.to_string_lossy().into_owned()
}

#[cfg(all(test, unix))]
mod lock_tests {
    use std::fs::OpenOptions;

    use super::*;

    /// An allocation lets go of the repository's port lock, also while a child the server
    /// forked meanwhile has the descriptor: else every other session host's allocation for
    /// the repository waits for that child.
    #[test]
    fn a_dropped_port_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
        let dir = crate::fork_tests::Scratch::new("worktree_ports");
        let path = dir.path().join("cmux-worktree-ports.json");
        let held = lock(&OwnFolder::open(dir.path()), WAIT);
        let keeper = crate::fork_tests::Keeper::fork();
        drop(held);
        let free = crate::fork_tests::free(&path.with_extension("lock"));
        drop(keeper);
        assert!(free, "a dropped port lock stayed held through a forked child's copy");
    }

    /// An allocation has the file lock until its drop: a second open of the lock file cannot
    /// take the lock before that.
    #[test]
    fn a_port_lock_is_held_until_its_drop() {
        let dir = crate::fork_tests::Scratch::new("worktree_ports_held");
        let path = dir.path().join("cmux-worktree-ports.json");
        let held = lock(&OwnFolder::open(dir.path()), Duration::ZERO);
        let free_before = crate::fork_tests::free(&path.with_extension("lock"));
        drop(held);
        let free_after = crate::fork_tests::free(&path.with_extension("lock"));
        assert_eq!((free_before, free_after), (false, true));
    }

    /// An allocation that waits takes the file lock when its holder lets go during the wait.
    /// The 10 s are the most that the wait can take, not a time that the test measures. The
    /// holder keeps the lock for a moment, so the first tries of the allocation find it held;
    /// an allocation that starts later finds it free, and the result is the same.
    #[test]
    fn a_port_lock_that_waits_takes_the_file_lock_that_comes_free() {
        let dir = crate::fork_tests::Scratch::new("worktree_ports_wait");
        let path = dir.path().join("cmux-worktree-ports.json");
        let lock_path = path.with_extension("lock");
        let mut options = OpenOptions::new();
        let file = options.create(true).truncate(false).write(true).open(&lock_path).unwrap();
        let holder = FileLock::try_take(file, Kind::Exclusive).unwrap();
        let held = std::thread::scope(|scope| {
            scope.spawn(move || {
                std::thread::sleep(Duration::from_millis(50));
                drop(holder);
            });
            let second = lock(&OwnFolder::open(dir.path()), Duration::from_secs(10));
            let held = !crate::fork_tests::free(&lock_path);
            drop(second);
            held
        });
        assert!(held, "the allocation has no file lock after its wait");
    }
}

/// The worktree's block, if it has one, from the list in the repository's
/// git folder `folder`. The read takes no lock: a writer that has the file
/// lock writes the ports file to a `.partial` file that then takes its name
/// ([`OwnFolder::write`]), so a read gets a whole file then.
pub(super) fn lookup(folder: &OwnFolder, root: &Path) -> Option<u16> {
    load(folder).ok()?.get(&key(root)).copied()
}

/// The worktree's block, kept from before or the first free one: none
/// of its ports listens, and no other worktree of the repository has
/// it. A repository starts looking at a block its folder picks, so two
/// repositories rarely start at the same one.
///
/// No port is given, and the file stays, when the ports file is above
/// the size limit.
pub(super) fn allocate(folder: &OwnFolder, root: &Path) -> Result<Option<u16>, TooLarge> {
    allocate_within(folder, root, WAIT)
}

/// [`allocate`], with at most `wait` for the file lock.
pub(super) fn allocate_within(
    folder: &OwnFolder,
    root: &Path,
    wait: Duration,
) -> Result<Option<u16>, TooLarge> {
    let _guard = lock(folder, wait);
    let mut ports = load(folder)?;
    Ok(free_block(folder, &mut ports, root))
}

/// The block of `root` in `ports`, kept from before or the first free
/// one, which is then saved in `folder`. The first block that a repository
/// looks at comes from the path of its ports file.
fn free_block(folder: &OwnFolder, ports: &mut BTreeMap<String, u16>, root: &Path) -> Option<u16> {
    use std::hash::{Hash as _, Hasher as _};
    if let Some(port) = ports.get(&key(root)) {
        return Some(*port);
    }
    ports.retain(|folder, _| Path::new(folder).exists());
    let taken: std::collections::BTreeSet<u16> = ports.values().copied().collect();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    folder.path().join(PORTS_FILE).hash(&mut hasher);
    let first = u16::try_from(hasher.finish() % u64::from(PORT_BLOCKS)).unwrap_or(0);
    let port = (0..PORT_BLOCKS)
        .map(|step| FIRST_PORT + ((first + step) % PORT_BLOCKS) * PORT_BLOCK)
        .find(|port| {
            !taken.contains(port)
                && (*port..*port + PORT_BLOCK)
                    .all(|port| TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_ok())
        })?;
    ports.insert(key(root), port);
    save(folder, ports);
    Some(port)
}

/// Takes the worktree out of the list, so its block is free. With no file
/// lock the list is not written: the block is free at a later allocation,
/// when the worktree's folder is gone ([`free_block`]).
pub(super) fn free(folder: &OwnFolder, root: &Path) {
    let held = lock(folder, WAIT);
    if held.file.is_none() {
        return;
    }
    let Ok(mut ports) = load(folder) else { return };
    if ports.remove(&key(root)).is_some() {
        save(folder, &ports);
    }
}
