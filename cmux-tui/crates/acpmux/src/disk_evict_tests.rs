use super::*;
use std::cell::Cell;

const GIB: u64 = 1024 * 1024 * 1024;

#[test]
fn low_is_under_four_gib_or_fifteen_percent() {
    assert!(is_low(20 * GIB, 4 * GIB - 1));
    assert!(!is_low(20 * GIB, 4 * GIB));
    assert!(is_low(40 * GIB, 5 * GIB), "15% of 40 GiB is 6 GiB");
    assert!(!is_low(40 * GIB, 7 * GIB));
    assert_eq!(target_free(40 * GIB), 10 * GIB);
    assert_eq!(target_free(8 * GIB), 4 * GIB);
}

#[cfg(unix)]
#[test]
fn candidates_are_package_caches_then_idle_builds_oldest_first() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    for d in [".npm/_cacache", ".cache/bun", "src/a/target", "src/b/target", "src/c/target"] {
        std::fs::create_dir_all(h.join(d)).unwrap();
    }
    // A symlinked cache is never followed.
    std::fs::create_dir_all(h.join("precious")).unwrap();
    std::fs::create_dir_all(h.join(".cache")).unwrap();
    std::os::unix::fs::symlink(h.join("precious"), h.join(".cache/pip")).unwrap();
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
    let ago = |s: u64| now - Duration::from_secs(s);
    let builds =
        vec![h.join("src/a/target"), h.join("src/b/target"), h.join("src/c/target"), "/etc".into()];
    let touched = |p: &Path| {
        Some(if p.ends_with("a/target") {
            ago(3 * 3600)
        } else if p.ends_with("b/target") {
            ago(10 * 3600)
        } else if p.ends_with(".cache/bun") {
            ago(60)
        } else if p.ends_with(".npm/_cacache") {
            ago(3600)
        } else {
            ago(60)
        })
    };
    let got = candidates(h, &builds, now, touched);
    assert_eq!(
        got,
        [h.join(".npm/_cacache"), h.join("src/b/target"), h.join("src/a/target")],
        "a cache or build touched a minute ago stays (in use), a path outside home never comes, \
         nor a symlink"
    );
}

#[test]
fn eviction_stops_at_the_target() {
    let list: [PathBuf; 3] = ["/h/.npm/_cacache".into(), "/h/.cache/bun".into(), "/h/t".into()];
    let free = Cell::new(GIB);
    let got = evict(
        &list,
        3 * GIB,
        || Some(free.get()),
        |_| {
            free.set(free.get() + GIB);
            true
        },
    );
    // Each clears 1 GiB: two reach the target, the build stays.
    assert_eq!(got, list[..2]);
    // A path that will not go is not reported, and the next one is tried.
    let free = Cell::new(GIB);
    let got = evict(
        &list,
        2 * GIB,
        || Some(free.get()),
        |p| {
            let gone = !p.ends_with("_cacache");
            if gone {
                free.set(free.get() + GIB);
            }
            gone
        },
    );
    assert_eq!(got, list[1..2]);
    // Already at the target: nothing goes.
    let none = evict(&list, GIB, || Some(GIB), |_| panic!("nothing goes at the target"));
    assert!(none.is_empty());
}

#[cfg(unix)]
#[test]
fn a_dir_is_touched_by_its_newest_inner_dir() {
    let dir = tempfile::tempdir().unwrap();
    let t = dir.path().join("target");
    std::fs::create_dir_all(t.join("debug/deps")).unwrap();
    let old = filetime_secs(&t, 1_000);
    filetime_secs(&t.join("debug"), 1_000);
    let new = filetime_secs(&t.join("debug/deps"), 5_000);
    assert!(old < new);
    assert_eq!(last_touched(&t), Some(new));
}

/// Sets `path`'s modification time to `secs` after the epoch.
#[cfg(unix)]
fn filetime_secs(path: &Path, secs: u64) -> SystemTime {
    let at = SystemTime::UNIX_EPOCH + Duration::from_secs(secs);
    std::fs::File::open(path).unwrap().set_modified(at).unwrap();
    at
}
