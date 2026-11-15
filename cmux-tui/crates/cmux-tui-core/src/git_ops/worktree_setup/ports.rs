use super::*;
use cmux_file_lock::{FileLock, Kind, LockError};

/// The file lock every session host's allocation for the repository
/// takes, and this process's lock. The drop lets go of the file lock
/// first: it unlocks the file before it closes it (a child another
/// thread forked meanwhile shares it until it execs). Then it lets go
/// of this process's lock.
struct Lock {
    _file: Option<FileLock>,
    _guard: std::sync::MutexGuard<'static, ()>,
}

/// How long an allocation waits for the file lock while another session
/// host's allocation has it.
const WAIT: Duration = Duration::from_millis(500);

/// The time between two tries of the file lock.
const STEP: Duration = Duration::from_millis(10);

/// The locks of an allocation, after at most `wait` for the file lock.
/// With no file lock then, the allocation has this process's lock alone,
/// and a line on stderr says so.
fn lock(path: &Path, wait: Duration) -> Lock {
    static LOCK: Mutex<()> = Mutex::new(());
    // No lock file is made through a link, and none is taken on a file
    // that is not a regular one: the allocation then has this process's
    // lock alone, as when the file cannot be made. A lock file that has a
    // second name is made new.
    let lock_path = path.with_extension("lock");
    // The wait comes before this process's lock: a lock file that stays
    // locked does not hold up the allocation of another repository.
    let waited = open_or_make_own(OpenOptions::new().write(true), &lock_path)
        .map(|file| FileLock::take_within(file, Kind::Exclusive, wait, STEP));
    let guard = LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    // One more try, now with this process's lock: the file lock is free
    // when a thread of this process had it during the wait and is done.
    let taken = waited.map(|waited| match waited {
        Err(LockError::Busy(file)) => FileLock::try_take(file, Kind::Exclusive),
        waited => waited,
    });
    let file = taken.and_then(|taken| {
        taken
            .inspect_err(|error| {
                eprintln!(
                    "cmux-tui: {}: {error}; the ports of this repository's worktrees have \
                     no lock between session hosts now",
                    lock_path.display()
                );
            })
            .ok()
    });
    Lock { _file: file, _guard: guard }
}

/// The repository's port list, in its shared git folder (`git_dir` is a
/// worktree's own, `<common>/worktrees/<name>`), so every session host
/// on the machine reads the same one.
fn path(git_dir: &Path) -> Option<PathBuf> {
    let worktrees = git_dir.parent()?;
    let common = if worktrees.file_name()? == "worktrees" { worktrees.parent()? } else { git_dir };
    Some(common.join("cmux-worktree-ports.json"))
}

/// The ports of each worktree. A ports file above the size limit is not
/// read, and it is not a list with no worktree: a port of a list that
/// starts empty can be the port of another worktree.
fn load(path: &Path) -> Result<BTreeMap<String, u16>, TooLarge> {
    let bytes = read_own(path)?;
    Ok(bytes.and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default())
}

fn save(path: &Path, ports: &BTreeMap<String, u16>) {
    if let Ok(bytes) = serde_json::to_vec_pretty(ports) {
        let _ = write_own(path, &bytes);
    }
}

fn key(root: &Path) -> String {
    root.to_string_lossy().into_owned()
}

#[cfg(all(test, unix))]
mod lock_tests {
    use super::*;

    /// An allocation lets go of the repository's port lock, also while a child the server
    /// forked meanwhile has the descriptor: else every other session host's allocation for
    /// the repository waits for that child.
    #[test]
    fn a_dropped_port_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
        let dir = crate::fork_tests::Scratch::new("worktree_ports");
        let path = dir.path().join("cmux-worktree-ports.json");
        let held = lock(&path, WAIT);
        let keeper = crate::fork_tests::Keeper::fork();
        drop(held);
        let free = crate::fork_tests::free(&path.with_extension("lock"));
        drop(keeper);
        assert!(free, "a dropped port lock stayed held through a forked child's copy");
    }
}

/// The worktree's block, if it has one. The read takes no lock: the
/// ports file is written under a second name that then takes its name,
/// so a read gets a whole file.
pub(super) fn lookup(git_dir: &Path, root: &Path) -> Option<u16> {
    load(&path(git_dir)?).ok()?.get(&key(root)).copied()
}

/// The worktree's block, kept from before or the first free one: none
/// of its ports listens, and no other worktree of the repository has
/// it. A repository starts looking at a block its folder picks, so two
/// repositories rarely start at the same one.
///
/// No port is given, and the file stays, when the ports file is above
/// the size limit.
pub(super) fn allocate(git_dir: &Path, root: &Path) -> Result<Option<u16>, TooLarge> {
    allocate_within(git_dir, root, WAIT)
}

/// [`allocate`], with at most `wait` for the file lock.
pub(super) fn allocate_within(
    git_dir: &Path,
    root: &Path,
    wait: Duration,
) -> Result<Option<u16>, TooLarge> {
    let Some(path) = path(git_dir) else { return Ok(None) };
    let _guard = lock(&path, wait);
    let mut ports = load(&path)?;
    Ok(free_block(&path, &mut ports, root))
}

/// The block of `root` in `ports`, kept from before or the first free
/// one, which is then saved at `path`.
fn free_block(path: &Path, ports: &mut BTreeMap<String, u16>, root: &Path) -> Option<u16> {
    use std::hash::{Hash as _, Hasher as _};
    if let Some(port) = ports.get(&key(root)) {
        return Some(*port);
    }
    ports.retain(|folder, _| Path::new(folder).exists());
    let taken: std::collections::BTreeSet<u16> = ports.values().copied().collect();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut hasher);
    let first = u16::try_from(hasher.finish() % u64::from(PORT_BLOCKS)).unwrap_or(0);
    let port = (0..PORT_BLOCKS)
        .map(|step| FIRST_PORT + ((first + step) % PORT_BLOCKS) * PORT_BLOCK)
        .find(|port| {
            !taken.contains(port)
                && (*port..*port + PORT_BLOCK)
                    .all(|port| TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_ok())
        })?;
    ports.insert(key(root), port);
    save(path, ports);
    Some(port)
}

pub(super) fn free(git_dir: &Path, root: &Path) {
    let Some(path) = path(git_dir) else { return };
    let _guard = lock(&path, WAIT);
    let Ok(mut ports) = load(&path) else { return };
    if ports.remove(&key(root)).is_some() {
        save(&path, &ports);
    }
}
