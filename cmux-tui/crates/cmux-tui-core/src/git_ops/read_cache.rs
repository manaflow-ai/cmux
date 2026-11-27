//! The daemon's cache of a repository's slow reads (`cmux-tag-cache`): the
//! names `git ls-files` gives for the whole repository, which `git.files.list`
//! and `git.files.search` fold for each folder and query, and the answers of
//! `git.status` and `git.branches`.
//!
//! Keys and tags:
//!
//! - the listing is keyed by the repository's top folder and tagged with
//!   [`Tag::Index`] of it and [`Tag::All`]. One `ls-files` from the top folder
//!   answers every folder and every query until it is stale: the Files page's
//!   refresh lists the top folder and each expanded one, and they all share it.
//! - a status is keyed by the folder asked about and `github`, the branches by
//!   the folder and `limit`; both are tagged with [`Tag::Refs`] of the top
//!   folder and [`Tag::All`].
//!
//! What makes an entry stale: each read stats the files the value was read
//! from and compares them with the stamp the entry was written with; a moved
//! stamp invalidates the repository's tag, one write whatever is cached
//! (`cmux_tag_cache`). The listing's stamp is the index, HEAD, the top
//! `.gitignore` and `info/exclude`; the refs' stamp is HEAD, the config files,
//! `packed-refs`, the reftable list and every loose ref under `refs/heads` and
//! `refs/remotes` (their files and folders). A commit, push or worktree change
//! the daemon runs itself invalidates [`Tag::All`].
//!
//! What a stale entry does (stale-while-revalidate):
//!
//! - a listing whose index moved, or that is older than [`MAX_FRESH`] (a new
//!   untracked name deep in the tree moves no stamp), answers at once and is
//!   read again behind the answer: the open never waits for `ls-files` when a
//!   listing is cached. A tracked name that is gone is never shown either way:
//!   the caller looks at the disk for each name it shows.
//! - a listing whose asked folder changed after it was read (a name was made
//!   or removed right there, so the cached one is known to be wrong for it) is
//!   read before the answer, once for all the folders that wait for it.
//! - a status or branches whose refs moved is read before the answer: the
//!   view after a commit or a push needs the new head and counts. One that is
//!   only older than [`MAX_FRESH`] answers at once and is read behind.
//!
//! One read runs per key at a time: a read before an answer that finds the
//! key's read running waits for it and takes its result; a read behind an
//! answer starts only when none runs for the key, on a `mux-git-revalidate`
//! thread, at most [`MAX_BEHIND`] in the daemon (past it the entry stays
//! stale, and a later ask starts its read). Each value is written at the
//! cache stamp taken before its read, so an invalidation during the read
//! leaves it stale ([`TagCache::insert_at`]).

use std::collections::HashSet;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use cmux_tag_cache::{Lookup, TagCache};
use serde_json::Value;

use super::Repository;
use crate::resource::ResourceError;

/// How long an entry whose stamp did not move answers with no read behind it.
const MAX_FRESH: Duration = Duration::from_secs(30);
/// Reads behind an answer that run at one time in the daemon.
const MAX_BEHIND: usize = 2;
/// Entries kept: a few repositories' listings and their folders' refs reads.
const CAPACITY: usize = 64;
/// How long a read before an answer waits for the same key's running read.
const FLIGHT_WAIT: Duration = Duration::from_secs(25);
/// Loose refs and their folders the refs stamp looks at; past it the stamp is
/// unknown and each ask reads.
const MAX_REF_FILES: usize = 20_000;
/// A folder changed this close before a listing's read may be missing from
/// it: file times come from a coarse clock.
const CLOCK_SLACK: Duration = Duration::from_millis(20);
/// The same on a file system whose times have whole seconds.
const COARSE_SLACK: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Key {
    Listing(PathBuf),
    Status(PathBuf, bool),
    Branches(PathBuf, Option<u64>),
}

/// What a cached value was read from.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Tag {
    /// A repository's index and the files that hide untracked names.
    Index(PathBuf),
    /// A repository's HEAD, refs and config.
    Refs(PathBuf),
    /// Every entry: a git change the daemon made itself.
    All,
}

/// The names `git ls-files` gave for a whole repository, sorted, with no
/// repeat, relative to its top folder.
pub(super) struct Listing {
    paths: Vec<String>,
    truncated: bool,
    /// Taken before the read: a folder changed after this may be missing.
    started: SystemTime,
    stamp: Option<u64>,
    read_at: Instant,
}

/// A reply read from a repository's refs.
struct Reply {
    value: Value,
    root: PathBuf,
    git_dir: PathBuf,
    stamp: Option<u64>,
    read_at: Instant,
}

enum Cached {
    Listing { root: PathBuf, git_dir: PathBuf, listing: Listing },
    Reply(Reply),
}

/// What an ask does with the entry it found.
enum Verdict {
    Serve,
    ServeAndReadBehind,
    ReadFirst,
}

type Entries = TagCache<Key, Arc<Cached>, Tag>;

struct Cache {
    entries: Mutex<Entries>,
    /// Keys whose read runs.
    flights: Mutex<HashSet<Key>>,
    landed: Condvar,
    behind: AtomicUsize,
}

fn cache() -> &'static Cache {
    static CACHE: OnceLock<Cache> = OnceLock::new();
    CACHE.get_or_init(|| Cache {
        entries: Mutex::new(TagCache::new(CAPACITY)),
        flights: Mutex::new(HashSet::new()),
        landed: Condvar::new(),
        behind: AtomicUsize::new(0),
    })
}

impl Cache {
    fn entries(&self) -> MutexGuard<'_, Entries> {
        self.entries.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn flights(&self) -> MutexGuard<'_, HashSet<Key>> {
        self.flights.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn land(&self, key: &Key) {
        self.flights().remove(key);
        self.landed.notify_all();
    }
}

/// A key's running read: it lands when dropped, also when the read panics, so
/// no ask waits for a read that ended.
struct Flight(Key);

impl Drop for Flight {
    fn drop(&mut self) {
        cache().land(&self.0);
    }
}

/// A read of one key: the value and its tags.
type Read = Arc<dyn Fn() -> Result<(Cached, Vec<Tag>), ResourceError> + Send + Sync>;

/// The value for `key`: the cached one when `judge` says so, else read.
fn answer(
    key: &Key,
    judge: impl Fn(&Cached, bool) -> Verdict,
    read: &Read,
) -> Result<Arc<Cached>, ResourceError> {
    let cache = cache();
    for _ in 0..3 {
        let found = match cache.entries().get(key) {
            Lookup::Fresh(value) => Some((Arc::clone(value), true)),
            Lookup::Stale(value) => Some((Arc::clone(value), false)),
            Lookup::Miss => None,
        };
        // The judge stats files: never under the lock.
        if let Some((value, fresh)) = found {
            match judge(&value, fresh) {
                Verdict::Serve => return Ok(value),
                Verdict::ServeAndReadBehind => {
                    read_behind(key, read);
                    return Ok(value);
                }
                Verdict::ReadFirst => {}
            }
        }
        {
            let mut flights = cache.flights();
            if flights.contains(key) {
                // Its result answers this ask too: wait, then judge it.
                let (_flights, _) = cache
                    .landed
                    .wait_timeout_while(flights, FLIGHT_WAIT, |flights| flights.contains(key))
                    .unwrap_or_else(PoisonError::into_inner);
                continue;
            }
            flights.insert(key.clone());
        }
        let _flight = Flight(key.clone());
        return read_into(key, read);
    }
    // Reads that kept landing stale while the repository changed: one of
    // this ask's own.
    read().map(|(value, _)| Arc::new(value))
}

/// Reads `key` and writes it at the stamp taken before the read.
fn read_into(key: &Key, read: &Read) -> Result<Arc<Cached>, ResourceError> {
    let cache = cache();
    let stamp = cache.entries().stamp();
    let (value, tags) = read()?;
    let value = Arc::new(value);
    cache.entries().insert_at(key.clone(), Arc::clone(&value), tags, stamp);
    Ok(value)
}

/// One read behind an answer: counted out and landed when it ends.
struct Behind(#[allow(dead_code, reason = "lands the key when dropped")] Flight);

impl Drop for Behind {
    fn drop(&mut self) {
        cache().behind.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Reads `key` again behind the answer, unless its read runs or the daemon
/// runs [`MAX_BEHIND`] already.
fn read_behind(key: &Key, read: &Read) {
    let cache = cache();
    {
        let mut flights = cache.flights();
        if flights.contains(key) {
            return;
        }
        if cache.behind.fetch_add(1, Ordering::SeqCst) >= MAX_BEHIND {
            cache.behind.fetch_sub(1, Ordering::SeqCst);
            return;
        }
        flights.insert(key.clone());
    }
    let behind = Behind(Flight(key.clone()));
    let read = Arc::clone(read);
    let key = key.clone();
    // A failed spawn drops `behind` with its closure: the key lands and the
    // entry stays stale, so a later ask reads again.
    let _ = std::thread::Builder::new().name("mux-git-revalidate".into()).spawn(move || {
        let _behind = behind;
        // A failed read leaves the stale entry; the next ask reads again.
        let _ = read_into(&key, &read);
    });
}

/// Marks every cached read stale: the daemon changed a repository itself.
pub(super) fn invalidate_all() {
    cache().entries().invalidate(Tag::All);
}

/// The names under one folder of a repository, from the repository's cached
/// listing.
pub(super) struct Paths {
    source: Source,
    start: usize,
    end: usize,
    /// Bytes of each name before the folder's own part (`below/`).
    strip: usize,
}

enum Source {
    Cached(Arc<Cached>),
    /// A folder listed on its own, and whether that listing was cut.
    Read(Vec<String>, bool),
}

impl Paths {
    fn all(&self) -> &[String] {
        match &self.source {
            Source::Read(paths, _) => paths,
            Source::Cached(cached) => match cached.as_ref() {
                Cached::Listing { listing, .. } => &listing.paths,
                Cached::Reply(_) => &[],
            },
        }
    }

    /// The names, relative to the folder, sorted.
    pub(super) fn iter(&self) -> impl Iterator<Item = &str> {
        let strip = self.strip;
        self.all()
            .get(self.start..self.end)
            .unwrap_or_default()
            .iter()
            .map(move |path| path.get(strip..).unwrap_or(path.as_str()))
    }

    /// Whether the listing was cut.
    pub(super) fn truncated(&self) -> bool {
        match &self.source {
            Source::Read(_, cut) => *cut,
            Source::Cached(cached) => match cached.as_ref() {
                Cached::Listing { listing, .. } => listing.truncated,
                Cached::Reply(_) => false,
            },
        }
    }
}

/// The names git lists under `below` (the result of `files::folder`), from the
/// repository's cached listing: see the module docs for when it is read.
pub(super) fn listed(
    repository: &Repository,
    directory: &Path,
    below: &Path,
    operation: &'static str,
) -> Result<Paths, ResourceError> {
    // The home folder's repository is never listed whole from its top
    // folder, which is the whole home folder (`cmux_git::home`).
    let prefix = below.to_str().filter(|_| repository.lists_untracked());
    let Some(prefix) = prefix else {
        // The asked folder lists on its own, only what is below it, as before
        // the cache: in the home folder's repository, and for a folder whose
        // name is not UTF-8, which has no name in the listing.
        let (paths, cut) = super::files::listed(repository, directory, operation)?;
        let end = paths.len();
        return Ok(Paths { source: Source::Read(paths, cut), start: 0, end, strip: 0 });
    };
    let root = repository.root.clone();
    let folder = root.join(below);
    let key = Key::Listing(root);
    let reader = repository.clone();
    let read: Read = Arc::new(move || {
        let git_dir = reader.git_dir().to_path_buf();
        let stamp = listing_stamp(&reader.root, &git_dir);
        let started = SystemTime::now();
        let (paths, truncated) = super::files::listed(&reader, &reader.root, operation)?;
        let listing = Listing { paths, truncated, started, stamp, read_at: Instant::now() };
        let tags = vec![Tag::Index(reader.root.clone()), Tag::All];
        Ok((Cached::Listing { root: reader.root.clone(), git_dir, listing }, tags))
    });
    let judge = |cached: &Cached, fresh: bool| {
        let Cached::Listing { root, git_dir, listing } = cached else {
            return Verdict::ReadFirst;
        };
        if changed_since(&folder, listing.started) {
            return Verdict::ReadFirst;
        }
        let moved = listing.stamp.is_none() || listing_stamp(root, git_dir) != listing.stamp;
        // Only the first ask to see the move invalidates: once the entry is
        // stale, a read behind it may already run, and a later invalidation
        // would land that read stale too and cost another read.
        if moved && fresh {
            cache().entries().invalidate(Tag::Index(root.clone()));
        }
        if moved || !fresh || listing.read_at.elapsed() > MAX_FRESH {
            Verdict::ServeAndReadBehind
        } else {
            Verdict::Serve
        }
    };
    let cached = answer(&key, judge, &read)?;
    let Cached::Listing { listing, .. } = cached.as_ref() else {
        return Err(mixed_up(operation));
    };
    let (start, end, strip) = if prefix.is_empty() {
        (0, listing.paths.len(), 0)
    } else {
        let prefix = format!("{prefix}/");
        let start = listing.paths.partition_point(|path| path.as_str() < prefix.as_str());
        let count = listing
            .paths
            .get(start..)
            .unwrap_or_default()
            .partition_point(|path| path.starts_with(&prefix));
        (start, start + count, prefix.len())
    };
    Ok(Paths { source: Source::Cached(Arc::clone(&cached)), start, end, strip })
}

/// What a read of the refs found: the reply and where it was read.
pub(super) struct RefsRead {
    pub(super) value: Value,
    pub(super) root: PathBuf,
    pub(super) git_dir: PathBuf,
    /// [`refs_stamp`], taken before the reply's reads.
    pub(super) stamp: Option<u64>,
}

/// `git.status` of `directory`, cached: `read` reads it.
pub(super) fn status(
    directory: &Path,
    github: bool,
    read: impl Fn() -> Result<RefsRead, ResourceError> + Send + Sync + 'static,
) -> Result<Value, ResourceError> {
    refs_reply("git.status", Key::Status(directory.to_path_buf(), github), read)
}

/// `git.branches` of `directory`, cached: `read` reads it.
pub(super) fn branches(
    directory: &Path,
    limit: Option<u64>,
    read: impl Fn() -> Result<RefsRead, ResourceError> + Send + Sync + 'static,
) -> Result<Value, ResourceError> {
    refs_reply("git.branches", Key::Branches(directory.to_path_buf(), limit), read)
}

/// A key that holds another kind of value: no answer from it.
fn mixed_up(operation: &'static str) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        "the cached read is of another kind".to_owned(),
        serde_json::json!({"code": "git_failed"}),
    )
}

fn refs_reply(
    operation: &'static str,
    key: Key,
    read: impl Fn() -> Result<RefsRead, ResourceError> + Send + Sync + 'static,
) -> Result<Value, ResourceError> {
    let read: Read = Arc::new(move || {
        let RefsRead { value, root, git_dir, stamp } = read()?;
        let tags = vec![Tag::Refs(root.clone()), Tag::All];
        Ok((Cached::Reply(Reply { value, root, git_dir, stamp, read_at: Instant::now() }), tags))
    });
    let judge = |cached: &Cached, fresh: bool| {
        let Cached::Reply(reply) = cached else { return Verdict::ReadFirst };
        if reply.stamp.is_none() || refs_stamp(&reply.root, &reply.git_dir) != reply.stamp {
            // The status and the branches of this repository both read again.
            // A stale entry was invalidated already, and a read may run
            // since: invalidating again would land that read stale too.
            if fresh {
                cache().entries().invalidate(Tag::Refs(reply.root.clone()));
            }
            return Verdict::ReadFirst;
        }
        if !fresh {
            Verdict::ReadFirst
        } else if reply.read_at.elapsed() > MAX_FRESH {
            Verdict::ServeAndReadBehind
        } else {
            Verdict::Serve
        }
    };
    let cached = answer(&key, judge, &read)?;
    match cached.as_ref() {
        Cached::Reply(reply) => Ok(reply.value.clone()),
        Cached::Listing { .. } => Err(mixed_up(operation)),
    }
}

/// Whether `folder` changed after `started`, or so close before it that the
/// read may have missed the change.
fn changed_since(folder: &Path, started: SystemTime) -> bool {
    let Ok(modified) = std::fs::metadata(folder).and_then(|meta| meta.modified()) else {
        // Gone or unreadable: the listing cannot say what it holds now.
        return true;
    };
    let whole_seconds =
        modified.duration_since(SystemTime::UNIX_EPOCH).is_ok_and(|at| at.subsec_nanos() == 0);
    let slack = if whole_seconds { COARSE_SLACK } else { CLOCK_SLACK };
    modified + slack >= started
}

/// The stamp of what a listing is read from; `None` when there is none.
fn listing_stamp(root: &Path, git_dir: &Path) -> Option<u64> {
    let common = common_dir(git_dir);
    let mut hasher = DefaultHasher::new();
    for file in [
        git_dir.join("index"),
        git_dir.join("HEAD"),
        root.join(".git"),
        root.join(".gitignore"),
        common.join("info").join("exclude"),
    ] {
        stat_into(&mut hasher, &file);
    }
    Some(hasher.finish())
}

/// The stamp of what a status or the branches are read from: HEAD, the config
/// files, the packed refs and every loose branch and remote-tracking ref.
/// `None` when the loose refs are more than [`MAX_REF_FILES`].
pub(super) fn refs_stamp(root: &Path, git_dir: &Path) -> Option<u64> {
    let common = common_dir(git_dir);
    let mut hasher = DefaultHasher::new();
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let xdg = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| home.as_ref().map(|home| home.join(".config")));
    let mut files = vec![
        root.join(".git"),
        git_dir.join("HEAD"),
        git_dir.join("config.worktree"),
        common.join("config"),
        common.join("packed-refs"),
        common.join("reftable").join("tables.list"),
    ];
    files.extend(home.map(|home| home.join(".gitconfig")));
    files.extend(xdg.map(|xdg| xdg.join("git").join("config")));
    for file in &files {
        stat_into(&mut hasher, file);
    }
    let mut left = MAX_REF_FILES;
    for namespace in ["heads", "remotes"] {
        if !walk_into(&mut hasher, &common.join("refs").join(namespace), &mut left) {
            return None;
        }
    }
    Some(hasher.finish())
}

/// The repository's common git folder: a linked worktree's `commondir`.
fn common_dir(git_dir: &Path) -> PathBuf {
    match std::fs::read_to_string(git_dir.join("commondir")) {
        Ok(text) => git_dir.join(text.trim_end_matches(['\n', '\r'])),
        Err(_) => git_dir.to_path_buf(),
    }
}

/// Hashes what `path` is: its size, change time and file id, or that it is
/// not there.
fn stat_into(hasher: &mut DefaultHasher, path: &Path) {
    path.hash(hasher);
    match std::fs::symlink_metadata(path) {
        Ok(meta) => {
            1_u8.hash(hasher);
            meta.len().hash(hasher);
            meta.modified()
                .ok()
                .and_then(|at| at.duration_since(SystemTime::UNIX_EPOCH).ok())
                .hash(hasher);
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt as _;
                (meta.ino(), meta.ctime(), meta.ctime_nsec()).hash(hasher);
            }
        }
        Err(_) => 0_u8.hash(hasher),
    }
}

/// Hashes every file and folder below `folder`, links not followed; false
/// once more than `left` were seen.
fn walk_into(hasher: &mut DefaultHasher, folder: &Path, left: &mut usize) -> bool {
    stat_into(hasher, folder);
    let Ok(read) = std::fs::read_dir(folder) else { return true };
    let mut children: Vec<(PathBuf, bool)> = read
        .filter_map(Result::ok)
        .map(|entry| (entry.path(), entry.file_type().is_ok_and(|kind| kind.is_dir())))
        .collect();
    // The order a folder gives its names in is not the same each time.
    children.sort();
    for (child, is_folder) in children {
        if *left == 0 {
            return false;
        }
        *left -= 1;
        if is_folder {
            if !walk_into(hasher, &child, left) {
                return false;
            }
        } else {
            stat_into(hasher, &child);
        }
    }
    true
}
