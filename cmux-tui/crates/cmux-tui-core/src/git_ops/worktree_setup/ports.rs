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

/// Why an allocation gives no block of the repository's ports file: the
/// file gives no list of ports, or the list is not written.
#[derive(Clone, Copy, Debug)]
pub(super) enum NoList {
    /// The file is above the size limit.
    TooLarge,
    /// A thing is at the name of the file, and it gives no list: it is not
    /// read as a file (a folder, a link, a file that the read fails for),
    /// or its bytes are not a JSON object of ports (an empty file, a list
    /// that is cut short, a JSON value of a different form).
    NotAList,
    /// The list with the new block is not written to the file, or its
    /// bytes are not flushed before it takes the name of the file: no
    /// later allocation of the repository knows that block.
    NotWritten,
}

/// What a setup's log says when the ports file is above the size limit.
const TOO_LARGE: &str =
    "the file cmux-worktree-ports.json in the repository's git folder is larger than 1 MiB";
/// What a setup's log says when the ports file is not a list of ports.
const NOT_A_LIST: &str =
    "the file cmux-worktree-ports.json in the repository's git folder is not a list of ports";
/// What a setup's log says when the list of ports is not written.
const NOT_WRITTEN: &str =
    "the file cmux-worktree-ports.json in the repository's git folder is not written";

impl NoList {
    /// What a setup's log says of the ports file.
    pub(super) fn text(self) -> &'static str {
        match self {
            Self::TooLarge => TOO_LARGE,
            Self::NotAList => NOT_A_LIST,
            Self::NotWritten => NOT_WRITTEN,
        }
    }
}

/// The ports of each worktree. With no thing at the name of the ports file
/// the list has no worktree. A thing at the name that gives no list
/// ([`NoList`]) is not a list with no worktree: a port of a list that starts
/// empty can be the port of another worktree.
fn load(folder: &OwnFolder) -> Result<BTreeMap<String, u16>, NoList> {
    match folder.read(PORTS_FILE) {
        Ok(Some(bytes)) => serde_json::from_slice(&bytes).map_err(|_| NoList::NotAList),
        // No file was read. The look at the name comes after the read, so a
        // file that came to the name meanwhile is not taken as no file.
        Ok(None) if folder.has(PORTS_FILE) => Err(NoList::NotAList),
        Ok(None) => Ok(BTreeMap::new()),
        Err(TooLarge) => Err(NoList::TooLarge),
    }
}

/// Writes `ports` as the whole of the ports file ([`OwnFolder::write`]),
/// with the error of a write that fails.
fn save(folder: &OwnFolder, ports: &BTreeMap<String, u16>) -> std::io::Result<()> {
    folder.write(PORTS_FILE, &serde_json::to_vec_pretty(ports)?)
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
/// No port is given, and the thing at the name of the ports file stays,
/// when the ports file gives no list ([`NoList`]): the setup of the
/// worktree then does not start, and its log says why when the log can
/// be written. The same holds when the list with the new block is not
/// written or is not flushed ([`NoList::NotWritten`]): a block that no
/// list has can be the block of another worktree later. No port is given
/// either when `folder` is not open ([`OwnFolder::not_opened`]): the
/// blocks that the other worktrees have are not known then, and a line
/// on stderr says why the folder is not open.
pub(super) fn allocate(folder: &OwnFolder, root: &Path) -> Result<Option<u16>, NoList> {
    allocate_within(folder, root, WAIT)
}

/// [`allocate`], with at most `wait` for the file lock.
pub(super) fn allocate_within(
    folder: &OwnFolder,
    root: &Path,
    wait: Duration,
) -> Result<Option<u16>, NoList> {
    if let Some(kind) = folder.not_opened() {
        // No list is read: a block of a list that starts empty can be the
        // block of another worktree.
        eprintln!(
            "cmux-tui: {}: the repository's git folder is not open ({kind}); the worktree {} \
             gets no ports",
            folder.path().display(),
            root.display()
        );
        return Ok(None);
    }
    let _guard = lock(folder, wait);
    let mut ports = load(folder)?;
    free_block(folder, &mut ports, root)
}

/// The block of `root` in `ports`, kept from before or the first free
/// one, which is then saved in `folder`. The first block that a repository
/// looks at comes from the path of its ports file. A new block whose list
/// is not written is not given ([`NoList::NotWritten`]), and a line on
/// stderr has the error of the write.
fn free_block(
    folder: &OwnFolder,
    ports: &mut BTreeMap<String, u16>,
    root: &Path,
) -> Result<Option<u16>, NoList> {
    use std::hash::{Hash as _, Hasher as _};
    if let Some(port) = ports.get(&key(root)) {
        return Ok(Some(*port));
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
        });
    let Some(port) = port else { return Ok(None) };
    ports.insert(key(root), port);
    if let Err(error) = save(folder, ports) {
        eprintln!(
            "cmux-tui: {}: the list of ports is not written ({error}); the worktree {} gets no \
             ports",
            folder.path().join(PORTS_FILE).display(),
            root.display()
        );
        return Err(NoList::NotWritten);
    }
    Ok(Some(port))
}

/// Takes the worktree out of the list, so its block is free. With no file
/// lock the list is not written, and a write that fails is not reported:
/// the block is free at a later allocation, when the worktree's folder is
/// gone ([`free_block`]).
pub(super) fn free(folder: &OwnFolder, root: &Path) {
    let held = lock(folder, WAIT);
    if held.file.is_none() {
        return;
    }
    let Ok(mut ports) = load(folder) else { return };
    if ports.remove(&key(root)).is_some() {
        let _ = save(folder, &ports);
    }
}
