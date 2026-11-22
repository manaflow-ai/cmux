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

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-lock-{name}-{}-{:?}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A write lets go of the config lock, also while a child another thread started meanwhile
/// keeps its descriptor: else the next writer (another session daemon or the Mac app) waits
/// until that child exits.
#[test]
fn a_dropped_config_lock_is_free_while_a_child_keeps_its_descriptor() {
    let dir = scratch("config");
    let config = dir.join("cmux.json");
    let held = lock_config(&config).expect("a config lock");
    let keeper = Keeper::keep(&held);
    drop(held);
    let free = free(&dir.join(".cmux.json.lock"));
    drop(keeper);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(free, "a dropped config lock stayed held through a child's copy");
}
