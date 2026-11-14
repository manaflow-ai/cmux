//! The lock is let go by an unlock, not only by a close (test-only).

use super::*;

/// A child process that keeps a copy of `file`'s open file description as its stdin, the way
/// a child that another thread starts keeps the parent's descriptors until it execs or exits.
/// Dropping this ends and reaps it.
struct Keeper(std::process::Child);

impl Keeper {
    fn keep(file: &std::fs::File) -> Keeper {
        let copy = file.try_clone().unwrap();
        Keeper(std::process::Command::new("sleep").arg("60").stdin(copy).spawn().unwrap())
    }
}

impl Drop for Keeper {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Whether an exclusive lock on a new open of `path` is taken now (and let go at once).
fn free(path: &Path) -> bool {
    let file = std::fs::File::open(path).unwrap();
    let taken = file.try_lock().is_ok();
    if taken {
        let _ = file.unlock();
    }
    taken
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-lock-{name}-{}-{:?}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A journal writer's lock is free once it drops, also while a child another thread started
/// meanwhile keeps its descriptor: else the next writer's `try_lock` reads the journal as
/// held by another writer until that child exits.
#[test]
fn a_dropped_journal_lock_is_free_while_a_child_keeps_its_descriptor() {
    let dir = scratch("journal");
    let path = dir.join("journal.lock");
    let file = std::fs::File::create(&path).unwrap();
    file.try_lock().unwrap();
    let keeper = Keeper::keep(&file);
    drop(FsLock { _file: file });
    let free = free(&path);
    drop(keeper);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(free, "a dropped journal lock stayed held through a child's copy");
}
