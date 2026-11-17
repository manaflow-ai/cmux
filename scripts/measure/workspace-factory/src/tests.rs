use super::*;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::sync::atomic::{AtomicUsize, Ordering};

/// A unique directory under the system temp dir, removed on drop.
struct Tmp(PathBuf);

impl Tmp {
    fn new(tag: &str) -> Tmp {
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let p =
            std::env::temp_dir().join(format!("wsfactory-test-{}-{n}-{tag}", std::process::id()));
        fsx::remove_tree(&p).unwrap();
        fs::create_dir_all(&p).unwrap();
        // Canonical, so it compares equal to the source_path publish records (macOS /tmp is a link).
        Tmp(fs::canonicalize(&p).unwrap())
    }
    fn join(&self, s: &str) -> PathBuf {
        self.0.join(s)
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = fsx::remove_tree(&self.0);
    }
}

fn me() -> i64 {
    std::process::id() as i64
}

/// The pid of a process that has exited and been reaped.
fn dead_pid() -> i64 {
    let mut c = std::process::Command::new("true").spawn().unwrap();
    let pid = c.id() as i64;
    c.wait().unwrap();
    assert!(!fsx::pid_alive(pid));
    pid
}

/// A build tree with the things builds leave: nested dirs, a read-only file in a read-only dir, a symlink.
fn make_build(dir: &Path) {
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::create_dir_all(dir.join("target/debug")).unwrap();
    fs::write(dir.join("src/main.rs"), "fn main() {}\n").unwrap();
    fs::write(dir.join("target/debug/app"), vec![7u8; 20_000]).unwrap();
    std::os::unix::fs::symlink("debug/app", dir.join("target/app-link")).unwrap();
    fs::create_dir_all(dir.join("ro")).unwrap();
    fs::write(dir.join("ro/locked"), "x").unwrap();
    fs::set_permissions(dir.join("ro/locked"), fs::Permissions::from_mode(0o444)).unwrap();
    fs::set_permissions(dir.join("ro"), fs::Permissions::from_mode(0o555)).unwrap();
}

fn is_empty_dir(p: &Path) -> bool {
    fs::read_dir(p)
        .map(|mut d| d.next().is_none())
        .unwrap_or(true)
}

fn publish(t: &Tmp, root: &Path) -> (PathBuf, Obj) {
    let build = t.join("build");
    make_build(&build);
    let rec = seed_publish(root, "s", &build, false).unwrap();
    (build, rec)
}

#[test]
fn round_trip_leaves_nothing() {
    let t = Tmp::new("roundtrip");
    let root = t.join("root");
    let (build, rec) = publish(&t, &root);
    assert_eq!(rec.str("source_path"), Some(build.to_str().unwrap()));
    assert!(fsx::gone(&build).unwrap(), "publish moves the build dir");
    assert_eq!(rec.int("files"), Some(4));

    let c = create(&root, "s", "j1", None, me()).unwrap();
    assert_eq!(
        c.str("path"),
        Some(build.to_str().unwrap()),
        "created at the seed's build path"
    );
    assert_eq!(
        fs::read_to_string(build.join("src/main.rs")).unwrap(),
        "fn main() {}\n"
    );
    assert_eq!(
        fs::read_link(build.join("target/app-link")).unwrap(),
        Path::new("debug/app")
    );
    for k in ["home", "tmp", "cache"] {
        assert!(Path::new(c.str(k).unwrap()).is_dir(), "{k}");
    }
    assert!(lease_path(&root, "j1").is_file());

    let d = destroy(&root, "j1").unwrap();
    assert!(d.int("removed_bytes").unwrap() > 20_000);
    assert!(fsx::gone(&build).unwrap());
    assert!(is_empty_dir(&root.join("jobs")));
    assert!(is_empty_dir(&root.join("leases")));
    assert_eq!(
        seed_verify(&root, "s").unwrap().bool("ok"),
        Some(true),
        "a job's clone leaves the seed alone"
    );

    assert_eq!(seed_remove(&root, "s").unwrap().bool("removed"), Some(true));
    assert!(fsx::gone(&root.join("seeds/s")).unwrap());
}

#[test]
fn destroy_is_idempotent() {
    let t = Tmp::new("idem");
    let root = t.join("root");
    publish(&t, &root);
    create(&root, "s", "j1", None, me()).unwrap();
    assert!(destroy(&root, "j1").unwrap().get("removed_bytes").is_some());
    let again = destroy(&root, "j1").unwrap();
    assert_eq!(again.bool("already"), Some(true));
    assert_eq!(destroy(&root, "never").unwrap().bool("already"), Some(true));
}

#[test]
fn create_refuses_existing_path() {
    let t = Tmp::new("refuse");
    let root = t.join("root");
    let (build, _) = publish(&t, &root);
    create(&root, "s", "j1", None, me()).unwrap();
    // Held by a live job.
    let e = create(&root, "s", "j2", None, me()).unwrap_err();
    assert!(e.contains("in use by job j1"), "{e}");
    assert!(
        fsx::gone(&lease_path(&root, "j2")).unwrap(),
        "a refused create leaves no lease"
    );
    // Same job twice.
    assert!(create(&root, "s", "j1", Some(&t.join("other")), me())
        .unwrap_err()
        .contains("already has a lease"));
    // A directory nobody leased.
    let stray = t.join("stray");
    fs::create_dir(&stray).unwrap();
    let e = create(&root, "s", "j3", Some(&stray), me()).unwrap_err();
    assert!(e.contains("no lease names it"), "{e}");
    assert!(stray.is_dir(), "a refused create leaves the path alone");
    assert!(fsx::gone(&lease_path(&root, "j3")).unwrap());
    assert!(
        build.join("src/main.rs").is_file(),
        "j1's workspace is untouched"
    );
    destroy(&root, "j1").unwrap();
}

#[test]
fn reconcile_reclaims_dead_leases() {
    let t = Tmp::new("reconcile");
    let root = t.join("root");
    let (build, _) = publish(&t, &root);
    create(&root, "s", "dead", None, dead_pid()).unwrap();
    create(&root, "s", "live", Some(&t.join("live")), me()).unwrap();
    let r = reconcile(&root).unwrap();
    assert_eq!(r.arr("reclaimed"), Some(&[Val::Str("dead".into())][..]));
    assert_eq!(r.bool("ok"), Some(true));
    assert!(fsx::gone(&build).unwrap());
    assert!(fsx::gone(&root.join("jobs/dead")).unwrap());
    assert!(
        t.join("live/src/main.rs").is_file(),
        "a live job is left alone"
    );
    destroy(&root, "live").unwrap();
}

#[test]
fn create_reclaims_dead_lease_on_its_path() {
    let t = Tmp::new("reclaim");
    let root = t.join("root");
    let (build, _) = publish(&t, &root);
    create(&root, "s", "old", None, dead_pid()).unwrap();
    fs::write(build.join("leftover"), "from the dead job").unwrap();
    let c = create(&root, "s", "new", None, me()).unwrap();
    assert_eq!(c.arr("reclaimed"), Some(&[Val::Str("old".into())][..]));
    assert!(
        fsx::gone(&build.join("leftover")).unwrap(),
        "nothing a job wrote survives it"
    );
    assert!(fsx::gone(&lease_path(&root, "old")).unwrap());
    destroy(&root, "new").unwrap();
}

#[test]
fn create_reclaims_lease_from_crash_before_clone() {
    // The lease is written before the clone, so a crash can leave a lease and no path.
    let t = Tmp::new("midclone");
    let root = t.join("root");
    let (build, _) = publish(&t, &root);
    create(&root, "s", "old", None, dead_pid()).unwrap();
    fsx::remove_tree(&build).unwrap();
    let c = create(&root, "s", "new", None, me()).unwrap();
    assert_eq!(c.arr("reclaimed").map(<[Val]>::len), Some(1));
    destroy(&root, "new").unwrap();
}

#[test]
fn verify_detects_a_write_into_the_seed() {
    let t = Tmp::new("verify");
    let root = t.join("root");
    publish(&t, &root);
    assert_eq!(seed_verify(&root, "s").unwrap().bool("ok"), Some(true));
    fs::write(root.join("seeds/s/src/extra.rs"), "// a job wrote here\n").unwrap();
    let v = seed_verify(&root, "s").unwrap();
    assert_eq!(v.bool("ok"), Some(false));
    assert!(v
        .arr("mismatch")
        .unwrap()
        .contains(&Val::Str("files".into())));
}

#[test]
fn republish_replaces_the_seed() {
    let t = Tmp::new("republish");
    let root = t.join("root");
    publish(&t, &root);
    let b2 = t.join("build2");
    fs::create_dir(&b2).unwrap();
    fs::write(b2.join("only"), "x").unwrap();
    let rec = seed_publish(&root, "s", &b2, true).unwrap();
    assert_eq!(rec.bool("replaced"), Some(true));
    assert_eq!(rec.int("files"), Some(1));
    assert!(b2.join("only").is_file(), "--clone leaves the source");
    assert_eq!(seed_verify(&root, "s").unwrap().bool("ok"), Some(true));
    let mut left: Vec<String> = fs::read_dir(root.join("seeds"))
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    left.sort();
    assert_eq!(left, ["s", "s.json"], "no tmp or old trees left behind");
}

fn set_mtime(p: &Path, sec: i64, nsec: i64, nofollow: bool) {
    let times = [
        Timespec {
            tv_sec: sec,
            tv_nsec: nsec as _,
        },
        Timespec {
            tv_sec: sec,
            tv_nsec: nsec as _,
        },
    ];
    let c = fsx::cpath(p).unwrap();
    let flags = if nofollow { AT_SYMLINK_NOFOLLOW } else { 0 };
    assert_eq!(
        unsafe { utimensat(AT_FDCWD, c.as_ptr(), times.as_ptr(), flags) },
        0,
        "{}",
        p.display()
    );
}

#[repr(C)]
struct Timespec {
    tv_sec: i64,
    tv_nsec: std::os::raw::c_long,
}
extern "C" {
    fn utimensat(
        dirfd: i32,
        path: *const std::os::raw::c_char,
        times: *const Timespec,
        flags: i32,
    ) -> i32;
}
#[cfg(target_os = "macos")]
const AT_FDCWD: i32 = -2;
#[cfg(target_os = "macos")]
const AT_SYMLINK_NOFOLLOW: i32 = 0x20;
#[cfg(not(target_os = "macos"))]
const AT_FDCWD: i32 = -100;
#[cfg(not(target_os = "macos"))]
const AT_SYMLINK_NOFOLLOW: i32 = 0x100;

/// Gives every entry a distinct nanosecond mtime, children before parents.
fn stamp(dir: &Path) -> Vec<(PathBuf, i64)> {
    let rel = [
        "src/main.rs",
        "target/debug/app",
        "target/app-link",
        "ro/locked",
        "target/debug",
        "target",
        "src",
        "ro",
        "",
    ];
    let mut out = Vec::new();
    for (i, r) in rel.iter().enumerate() {
        let p = if r.is_empty() {
            dir.to_path_buf()
        } else {
            dir.join(r)
        };
        set_mtime(&p, 1_600_000_000 + i as i64, 123_456_789 + i as i64, true);
        out.push((
            PathBuf::from(r),
            1_600_000_000_123_456_789 + i as i64 * 1_000_000_001,
        ));
    }
    out
}

fn assert_times(dir: &Path, want: &[(PathBuf, i64)]) {
    for (r, ns) in want {
        let p = if r.as_os_str().is_empty() {
            dir.to_path_buf()
        } else {
            dir.join(r)
        };
        let m = fs::symlink_metadata(&p).unwrap();
        assert_eq!(fsx::mtime_ns(&m), *ns, "mtime of {}", p.display());
    }
}

#[test]
fn create_preserves_mtimes() {
    let t = Tmp::new("mtimes");
    let root = t.join("root");
    let build = t.join("build");
    make_build(&build);
    let want = stamp(&build);
    seed_publish(&root, "s", &build, false).unwrap();
    assert_times(&root.join("seeds/s"), &want);
    let c = create(&root, "s", "j1", None, me()).unwrap();
    assert_times(&build, &want);
    assert_eq!(
        fs::metadata(build.join("ro")).unwrap().permissions().mode() & 0o777,
        0o555
    );
    assert!(c.str("clone").is_some());
    destroy(&root, "j1").unwrap();
}

#[test]
fn std_copy_preserves_mtimes_modes_links() {
    // The fallback macOS uses off APFS; Linux CI otherwise only exercises cp.
    let t = Tmp::new("stdcopy");
    let src = t.join("src");
    make_build(&src);
    fs::set_permissions(src.join("ro"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::hard_link(src.join("target/debug/app"), src.join("ro/app-hard")).unwrap();
    fs::set_permissions(src.join("ro"), fs::Permissions::from_mode(0o555)).unwrap();
    let want = stamp(&src);
    let dst = t.join("dst");
    fs::create_dir(&dst).unwrap();
    fsx::copy_into(&src, &dst).unwrap();
    assert_times(&dst, &want);
    let a = fs::metadata(dst.join("target/debug/app")).unwrap();
    assert_eq!(
        a.ino(),
        fs::metadata(dst.join("ro/app-hard")).unwrap().ino(),
        "hardlinks stay linked"
    );
    assert_eq!(
        fs::metadata(dst.join("ro/locked"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o444
    );
    assert_eq!(
        fs::read_link(dst.join("target/app-link")).unwrap(),
        Path::new("debug/app")
    );
    assert_eq!(fsx::usage(&src).unwrap(), fsx::usage(&dst).unwrap());
}

#[test]
fn usage_counts_hardlinks_once() {
    let t = Tmp::new("usage");
    let d = t.join("d");
    fs::create_dir(&d).unwrap();
    fs::write(d.join("a"), vec![1u8; 64 * 1024]).unwrap();
    let one = fsx::usage(&d).unwrap();
    fs::hard_link(d.join("a"), d.join("b")).unwrap();
    let two = fsx::usage(&d).unwrap();
    assert_eq!(two.files, 2);
    let dir_blocks = fs::symlink_metadata(&d).unwrap().blocks() * 512;
    let file_blocks = fs::metadata(d.join("a")).unwrap().blocks() * 512;
    assert!(file_blocks >= 64 * 1024);
    assert_eq!(two.bytes, dir_blocks + file_blocks);
    // The directory's own blocks may grow with a name; the file's must not be counted twice.
    assert!(two.bytes - one.bytes < file_blocks);

    let missing = usage(&[t.join("nope")]).unwrap();
    let p = &missing.arr("paths").unwrap()[0];
    assert!(matches!(p, Val::Obj(o) if o.bool("exists") == Some(false)));
}

#[test]
fn statfs_matches_df() {
    let t = Tmp::new("statfs");
    let (free, total) = fsx::statfs(&t.0).unwrap();
    let (_, df_total) = fsx::df(&t.0).unwrap();
    assert!(total > 0 && free <= total, "free {free} total {total}");
    // df rounds to KiB; a wrong struct layout would be far off.
    assert!(
        total.abs_diff(df_total) < 1024 * 1024,
        "statfs {total} df {df_total}"
    );
}

#[test]
fn json_round_trips() {
    let o = Obj::new()
        .with("s", "a\"b\\c\n\u{1}é")
        .with("n", -5i64)
        .with("f", 1.5f64)
        .with("b", true)
        .with("a", vec![Val::Null, Val::Int(1)])
        .with("o", Obj::new().with("k", "v"));
    let back = json::parse_obj(&o.to_string()).unwrap();
    assert_eq!(back.str("s"), o.str("s"));
    assert_eq!(back.int("n"), Some(-5));
    assert_eq!(back.get("f"), Some(&Val::Num(1.5)));
    assert_eq!(back.get("o"), o.get("o"));
    assert_eq!(back.arr("a"), o.arr("a"));
}

#[test]
fn names_cannot_escape() {
    for bad in ["", ".", "..", "../x", "a/b", ".hidden"] {
        assert!(check_name("job id", bad).is_err(), "{bad:?}");
    }
    assert!(check_name("job id", "run-123.4_a").is_ok());
    assert!(check_removable(Path::new("/")).is_err());
    assert!(check_removable(Path::new("/Users")).is_err());
    assert!(check_removable(Path::new("/a/../b")).is_err());
    assert!(check_removable(Path::new("/a/b")).is_ok());
}
