use super::*;
use std::{
    fs,
    os::unix::fs::symlink,
    sync::atomic::{AtomicUsize, Ordering},
};

struct Fixture(std::path::PathBuf);

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "acpmux-resolver-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(path.join(".git/hooks")).expect("fixture directory");
        fs::create_dir_all(path.join("a/b")).expect("nested fixture directory");
        fs::write(path.join(".git/config"), b"protected").expect("fixture file");
        symlink(".git/config", path.join("link")).expect("fixture symlink");
        Self(fs::canonicalize(path).expect("canonical fixture"))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn task() -> OwnedFd {
    open_at(AT_FDCWD, &format!("/proc/{}", std::process::id()), O_PATH | O_DIRECTORY, 0)
        .expect("proc task")
}

fn nspid() -> String {
    std::fs::read_to_string("/proc/self/status")
        .expect("status")
        .lines()
        .find_map(|line| line.strip_prefix("NSpid:").and_then(|p| p.split_whitespace().last()))
        .expect("NSpid")
        .to_owned()
}

#[test]
fn review_write_open_rejects_unapproved_devices() {
    assert!(reject_write_device(S_IFCHR, makedev(5, 0)).is_err());
    assert!(reject_write_device(S_IFBLK, makedev(8, 0)).is_err());
}

#[test]
fn delivery_object_types_use_device_numbers() {
    for minor in [3, 5, 7, 8, 9] {
        assert_eq!(reject_write_device(S_IFCHR | 0o666, makedev(1, minor)), Ok(()));
    }
    for (kind, device) in
        [(S_IFCHR, makedev(5, 0)), (S_IFCHR, makedev(1, 1)), (S_IFBLK, 0), (S_IFSOCK, 0)]
    {
        assert_eq!(reject_write_device(kind, device), Err(EACCES));
    }
    assert_eq!(reject_write_device(S_IFDIR, 0), Err(EISDIR));
}

#[test]
fn review_id_valid_retries_interrupted_ioctl() {
    assert_eq!(valid_errno(EINTR), Ok(true));
    assert_eq!(valid_errno(ENOENT), Ok(false));
    assert!(valid_errno(EACCES).is_err());
}

// Finite hook-controlled swaps avoid racing test timing or privileged mounts.
#[test]
fn delivery_reopens_the_inspected_inode() {
    let fixture = Fixture::new();
    let leaf = fixture.0.join("leaf");
    fs::write(&leaf, b"original").unwrap();
    let resolved =
        resolve(task().as_raw_fd(), AT_FDCWD, leaf.to_str().unwrap(), O_WRONLY, &nspid()).unwrap();
    let original = fs::File::open(&leaf).unwrap();
    let opened = open_leaf(&resolved, O_WRONLY, 0, || {
        fs::rename(&leaf, fixture.0.join("old")).unwrap();
        fs::write(&leaf, b"replacement").unwrap();
    })
    .unwrap()
    .0;
    assert_eq!(
        stat(opened.as_raw_fd()).unwrap().st_ino,
        stat(original.as_raw_fd()).unwrap().st_ino
    );
}

#[test]
fn delivery_rolls_back_only_its_own_created_inode() {
    let fixture = Fixture::new();
    let leaf = fixture.0.join("new");
    let resolved =
        resolve(task().as_raw_fd(), AT_FDCWD, leaf.to_str().unwrap(), O_CREAT | O_WRONLY, &nspid())
            .unwrap();
    let opened =
        open_at(resolved.parent.as_raw_fd(), &resolved.name, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            .unwrap();
    rollback_created(&resolved, &opened);
    assert!(!leaf.exists());
    fs::write(&leaf, b"replacement").unwrap();
    rollback_created(&resolved, &opened);
    assert_eq!(fs::read(&leaf).unwrap(), b"replacement");
}

#[test]
fn delivery_fifo_swap_never_opens_the_replacement() {
    let fixture = Fixture::new();
    let leaf = fixture.0.join("leaf");
    fs::write(&leaf, b"original").unwrap();
    let fifo = CString::new(fixture.0.join("fifo").to_str().unwrap()).unwrap();
    assert_eq!(unsafe { mkfifo(fifo.as_ptr(), 0o600) }, 0);
    let resolved =
        resolve(task().as_raw_fd(), AT_FDCWD, leaf.to_str().unwrap(), O_WRONLY, &nspid()).unwrap();
    let opened = open_leaf(&resolved, O_WRONLY, 0, || {
        fs::rename(fixture.0.join("fifo"), &leaf).unwrap();
    })
    .unwrap()
    .0;
    assert_eq!(stat(opened.as_raw_fd()).unwrap().st_mode & S_IFMT, S_IFREG);
    assert!(matches!(open_leaf(&resolved, O_WRONLY, 0, || {}), Err(ENXIO)));
}

#[test]
fn delivery_competing_creator_is_reopened_only_without_excl() {
    let fixture = Fixture::new();
    for exclusive in [0, O_EXCL] {
        let leaf = fixture.0.join(format!("created-{exclusive}"));
        let resolved = resolve(
            task().as_raw_fd(),
            AT_FDCWD,
            leaf.to_str().unwrap(),
            O_CREAT | O_WRONLY,
            &nspid(),
        )
        .unwrap();
        let result = open_leaf(&resolved, O_CREAT | O_WRONLY | exclusive, 0o600, || {
            fs::write(&leaf, b"competitor").unwrap();
        });
        if exclusive != 0 {
            assert!(matches!(result, Err(EEXIST)));
        } else {
            assert!(!result.unwrap().1, "must not roll back another creator's name");
        }
        assert_eq!(fs::read(&leaf).unwrap(), b"competitor");
    }
}

#[test]
fn delivery_device_swap_never_opens_the_replacement() {
    let fixture = Fixture::new();
    let device = CString::new(fixture.0.join("device").to_str().unwrap()).unwrap();
    if unsafe { mknod(device.as_ptr(), S_IFCHR | 0o600, makedev(5, 0)) } < 0 {
        let errno = error();
        assert!(matches!(errno, EPERM | EACCES | EOPNOTSUPP));
        eprintln!("skipped: device fixture requires mknod permission: {errno}");
        return;
    }
    let leaf = fixture.0.join("leaf");
    fs::write(&leaf, b"original").unwrap();
    let resolved =
        resolve(task().as_raw_fd(), AT_FDCWD, leaf.to_str().unwrap(), O_WRONLY, &nspid()).unwrap();
    let opened = open_leaf(&resolved, O_WRONLY, 0, || {
        fs::rename(fixture.0.join("device"), &leaf).unwrap();
    })
    .unwrap()
    .0;
    assert_eq!(stat(opened.as_raw_fd()).unwrap().st_mode & S_IFMT, S_IFREG);
    assert!(matches!(open_leaf(&resolved, O_WRONLY, 0, || {}), Err(EACCES)));
}

#[test]
fn review_open_mode_preserves_umask_for_default_acl() {
    assert_eq!(open_mode(0o666, 0o077), 0o666);
}

#[test]
fn review_filesystem_runner_directory_remains_supported() {
    let fixture = Fixture::new();
    let fd = open_at(AT_FDCWD, fixture.0.to_str().unwrap(), O_RDONLY | O_DIRECTORY, 0).unwrap();
    let _ = fd;
    let path = format!("{}/ordinary", fixture.0.display());
    let resolved =
        resolve(task().as_raw_fd(), AT_FDCWD, &path, O_CREAT | O_WRONLY, &nspid()).unwrap();
    assert_eq!(resolved.logical, path);
}

#[test]
fn review_proc_fd_number_requires_canonical_decimal() {
    for (name, number) in [("0", 0), ("3", 3), ("2147483647", 2147483647)] {
        assert_eq!(proc_fd_number(name), Ok(number));
    }
    for name in [
        "03",
        "+3",
        "00",
        "-1",
        "",
        " 3",
        "3 ",
        "3x",
        "٣",
        "2147483648",
        "4294967295",
        "00000000003",
        "99999999999",
    ] {
        assert_eq!(proc_fd_number(name), Err(ENOENT), "noncanonical proc fd: {name:?}");
    }
}

#[test]
fn review_proc_fd_aliases_reject_noncanonical_spelling() {
    let fixture = Fixture::new();
    let file = fs::File::create(fixture.0.join("output")).unwrap();
    let number = file.as_raw_fd();
    // Include the exact review examples, plus aliases of a known live fd.
    for spelling in ["03".to_owned(), "+3".to_owned(), format!("0{number}"), format!("+{number}")] {
        let path = format!("/proc/self/fd/{spelling}");
        assert!(matches!(open_at(AT_FDCWD, &path, O_PATH, 0), Err(ENOENT)));
        assert!(
            matches!(
                resolve(task().as_raw_fd(), AT_FDCWD, &path, O_WRONLY | O_TRUNC, &nspid()),
                Err(ENOENT)
            ),
            "translated invalid alias: {path}"
        );
    }
    assert_eq!(fs::metadata(fixture.0.join("output")).unwrap().len(), 0);
}

#[test]
fn review_casefold_directory_checks_cover_entire_walk() {
    let fixture = Fixture::new();
    let target = format!("{}/a/b/new", fixture.0.display());
    // Every finite case marks a different directory, including root and
    // final parent; the injected reader identifies objects by inode.
    for directory in
        [Path::new("/"), fixture.0.as_path(), &fixture.0.join("a"), &fixture.0.join("a/b")]
    {
        let marked =
            open_at(AT_FDCWD, directory.to_str().unwrap(), O_PATH | O_DIRECTORY, 0).unwrap();
        let marked = stat(marked.as_raw_fd()).unwrap();
        let reader = |fd| {
            let current = stat(fd)?;
            Ok(if (current.st_dev, current.st_ino) == (marked.st_dev, marked.st_ino) {
                0x4000_0000 // FS_CASEFOLD_FL
            } else {
                0
            })
        };
        assert!(
            matches!(
                resolve_with_flags(
                    task().as_raw_fd(),
                    AT_FDCWD,
                    &target,
                    O_CREAT | O_WRONLY,
                    &nspid(),
                    &reader
                ),
                Err(EACCES)
            ),
            "casefold directory: {}",
            directory.display()
        );
    }
    let directory = format!("{}/a/b", fixture.0.display());
    assert!(matches!(
        resolve_with_flags(task().as_raw_fd(), AT_FDCWD, &directory, O_RDONLY, &nspid(), &|_| Ok(
            0x4000_0000
        )),
        Err(EACCES)
    ));
}

#[test]
fn review_casefold_real_directory_refused() {
    let fixture = Fixture::new();
    let directory = fixture.0.join("folded");
    fs::create_dir(&directory).unwrap();
    let fd = open_at(AT_FDCWD, directory.to_str().unwrap(), O_RDONLY | O_DIRECTORY, 0).unwrap();
    let mut flags: c_long = 0;
    if unsafe { ioctl(fd.as_raw_fd(), FS_IOC_GETFLAGS, &mut flags) } < 0 {
        assert!(matches!(error(), EOPNOTSUPP | ENOTTY | EINVAL | EPERM | EACCES));
        eprintln!(
            "skipped: filesystem cannot read directory flags: {}",
            io::Error::last_os_error()
        );
        return;
    }
    flags |= 0x4000_0000;
    if unsafe { ioctl(fd.as_raw_fd(), FS_IOC_SETFLAGS, &flags) } < 0 {
        let errno = error();
        assert!(
            matches!(errno, EOPNOTSUPP | ENOTTY | EINVAL | EPERM | EACCES),
            "unexpected casefold setup errno: {errno}"
        );
        eprintln!(
            "skipped: cannot enable casefold on fixture filesystem: {}",
            io::Error::from_raw_os_error(errno)
        );
        return;
    }
    fs::write(directory.join("CLAUDE.md"), b"protected").unwrap();
    let target = format!("{}/claude.md", directory.display());
    assert!(matches!(
        resolve(task().as_raw_fd(), AT_FDCWD, &target, O_WRONLY | O_TRUNC, &nspid()),
        Err(EACCES)
    ));
}

#[test]
fn review_trailing_slash_regular_file_is_not_write_opened() {
    let fixture = Fixture::new();
    symlink(".git/config/", fixture.0.join("slash-link")).unwrap();
    // The kernel rejects both original and symlink-target trailing slash.
    for suffix in [".git/config/", "slash-link"] {
        let path = format!("{}/{suffix}", fixture.0.display());
        assert!(matches!(open_at(AT_FDCWD, &path, O_WRONLY | O_TRUNC, 0), Err(ENOTDIR)));
        assert!(matches!(
            resolve(task().as_raw_fd(), AT_FDCWD, &path, O_WRONLY | O_TRUNC, &nspid()),
            Err(ENOTDIR)
        ));
    }
    assert_eq!(fs::read(fixture.0.join(".git/config")).unwrap(), b"protected");
}

#[test]
fn review_trailing_slash_requirement_survives_resolution() {
    let fixture = Fixture::new();
    symlink("missing/", fixture.0.join("missing-link")).unwrap();
    symlink("a/b/", fixture.0.join("directory-link")).unwrap();
    for suffix in ["missing/", "missing-link", "a/b/", "directory-link"] {
        let path = format!("{}/{suffix}", fixture.0.display());
        let resolved = resolve(task().as_raw_fd(), AT_FDCWD, &path, 0, &nspid()).unwrap();
        assert!(resolved.directory_required, "lost trailing slash: {suffix}");
    }
}

#[test]
fn review_dirfd_must_be_an_actual_directory() {
    let fixture = Fixture::new();
    symlink("a", fixture.0.join("directory-link")).unwrap();
    for suffix in ["directory-link", ".git/config"] {
        let path = format!("{}/{suffix}", fixture.0.display());
        let fd = open_at(AT_FDCWD, &path, O_PATH | O_NOFOLLOW, 0).unwrap();
        assert!(matches!(open_at(fd.as_raw_fd(), "new", O_CREAT | O_WRONLY, 0o600), Err(ENOTDIR)));
        assert!(matches!(
            resolve(task().as_raw_fd(), fd.as_raw_fd(), "new", O_CREAT | O_WRONLY, &nspid()),
            Err(ENOTDIR)
        ));
    }
    assert!(!fixture.0.join("a/new").exists());
}

#[test]
fn review_cwd_and_dirfd_identity_must_match_rooted_walk() {
    let fixture = Fixture::new();
    let fake = fixture.0.join("task");
    let root = fixture.0.join("root-view");
    fs::create_dir_all(fake.join("fd")).unwrap();
    let actual = fixture.0.join("a/b");
    fs::create_dir_all(root.join(actual.strip_prefix("/").unwrap())).unwrap();
    symlink(&root, fake.join("root")).unwrap();
    symlink(&actual, fake.join("cwd")).unwrap();
    symlink(&actual, fake.join("fd/42")).unwrap();
    let task = open_at(AT_FDCWD, fake.to_str().unwrap(), O_PATH | O_DIRECTORY, 0).unwrap();
    // Both logical start paths exist under root, but address different inodes.
    for dir in [AT_FDCWD, 42] {
        assert!(matches!(
            resolve(task.as_raw_fd(), dir, "new", O_CREAT | O_WRONLY, &nspid()),
            Err(EACCES)
        ));
    }
}

#[test]
fn walks_dotdot_and_symlink_to_a_logical_absolute_path() {
    let fixture = Fixture::new();
    let target = fixture.0.join("a/b/../../link");
    let target = target.to_str().expect("utf8 target");
    let resolved =
        resolve(task().as_raw_fd(), AT_FDCWD, target, O_WRONLY, &nspid()).expect("resolved link");
    assert_eq!(resolved.logical, format!("{}/.git/config", fixture.0.display()));
}

#[test]
fn keeps_missing_final_component_as_parent_and_name() {
    let fixture = Fixture::new();
    let target = format!("{}/new-file", fixture.0.display());
    let resolved = resolve(task().as_raw_fd(), AT_FDCWD, &target, O_CREAT | O_WRONLY, &nspid())
        .expect("resolved missing final component");
    assert_eq!(resolved.name, "new-file");
    assert_eq!(resolved.logical, target);
    assert!(resolved.object.is_none());
}

#[test]
fn refuses_proc_paths_except_fd_aliases() {
    assert!(matches!(
        resolve(task().as_raw_fd(), AT_FDCWD, "/proc/self/mem", O_WRONLY, &nspid()),
        Err(EACCES)
    ));
    // CI stdout may be an anonymous pipe, which the resolver deliberately
    // refuses. Use a named object, as the forked supervisor fixture does,
    // without replacing the test process's shared stdout descriptor.
    let fixture = Fixture::new();
    let target = fixture.0.join("output");
    let output = fs::File::create(&target).expect("named output");
    let number = output.as_raw_fd();
    let pid = nspid();
    // The finite alias table covers the same proc-fd route as /dev/stdout.
    for alias in [
        format!("/proc/self/fd/{number}"),
        format!("/proc/thread-self/fd/{number}"),
        format!("/proc/{pid}/fd/{number}"),
        format!("/dev/fd/{number}"),
    ] {
        let resolved =
            resolve(task().as_raw_fd(), AT_FDCWD, &alias, O_WRONLY, &pid).expect("named fd alias");
        assert_eq!(Path::new(&resolved.logical), target.as_path());
        assert!(resolved.object.is_some());
    }
    let (socket, _peer) = std::os::unix::net::UnixStream::pair().expect("anonymous socket");
    let alias = format!("/proc/self/fd/{}", socket.as_raw_fd());
    assert!(matches!(resolve(task().as_raw_fd(), AT_FDCWD, &alias, O_WRONLY, &pid), Err(EACCES)));
}

/// Claude Code 2.1.322 makes its scratch folders through
/// `/proc/self/fd/<O_PATH dirfd>/<name>`. The prefix resolves to the held
/// directory's walked path, and the rest is walked from there.
#[test]
fn proc_fd_directory_prefix_resolves_through_the_held_directory() {
    let fixture = Fixture::new();
    let held = open_at(AT_FDCWD, fixture.0.join("a").to_str().unwrap(), O_PATH | O_DIRECTORY, 0)
        .expect("held directory");
    let number = held.as_raw_fd();
    let pid = nspid();
    let root = fixture.0.display();
    for prefix in [
        format!("/proc/self/fd/{number}"),
        format!("/proc/thread-self/fd/{number}"),
        format!("/dev/fd/{number}"),
    ] {
        let resolved = resolve(
            task().as_raw_fd(),
            AT_FDCWD,
            &format!("{prefix}/new"),
            O_PATH | O_NOFOLLOW,
            &pid,
        )
        .unwrap_or_else(|e| panic!("{prefix}/new: errno {e}"));
        assert_eq!(resolved.logical, format!("{root}/a/new"));
        assert_eq!(resolved.name, "new");
        assert!(resolved.object.is_none());
        let nested = resolve(
            task().as_raw_fd(),
            AT_FDCWD,
            &format!("{prefix}/b/new"),
            O_CREAT | O_WRONLY,
            &pid,
        )
        .expect("nested name under the held directory");
        assert_eq!(nested.logical, format!("{root}/a/b/new"));
        // `..` leaves the held directory and is checked where it lands.
        let escaped = resolve(
            task().as_raw_fd(),
            AT_FDCWD,
            &format!("{prefix}/../.git/config"),
            O_WRONLY,
            &pid,
        )
        .expect("dotdot from the held directory");
        assert_eq!(escaped.logical, format!("{root}/.git/config"));
    }
    // Only a live, named directory can be a prefix.
    let file = fs::File::open(fixture.0.join(".git/config")).expect("regular file");
    let (socket, _peer) = std::os::unix::net::UnixStream::pair().expect("anonymous socket");
    for fd in [file.as_raw_fd(), socket.as_raw_fd()] {
        assert!(
            resolve(
                task().as_raw_fd(),
                AT_FDCWD,
                &format!("/proc/self/fd/{fd}/new"),
                O_CREAT | O_WRONLY,
                &pid
            )
            .is_err(),
            "non-directory fd {fd} accepted as a prefix"
        );
    }
    // A symlink back into the same prefix is bounded like any symlink loop.
    symlink(format!("/proc/self/fd/{number}/loop"), fixture.0.join("a/loop")).unwrap();
    assert!(matches!(
        resolve(
            task().as_raw_fd(),
            AT_FDCWD,
            &format!("/proc/self/fd/{number}/loop/x"),
            O_CREAT | O_WRONLY,
            &pid
        ),
        Err(ELOOP)
    ));
}

#[test]
fn policy_is_checked_on_the_walked_logical_path() {
    let fixture = Fixture::new();
    let params = [
        ("CWD", fixture.0.clone()),
        ("TMPDIR", fixture.0.join("tmp")),
        ("HOME", fixture.0.join("home")),
        ("CLAUDE_TMP_PROJECT", fixture.0.join("scratch")),
        ("CLAUDE_PROJECT", fixture.0.join("transcript")),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_owned(), value))
    .collect();
    let policy = WritePolicy::from_profile(crate::hub::remote_sandbox::PROFILE, &params)
        .expect("profile policy");
    let resolved = resolve(
        task().as_raw_fd(),
        AT_FDCWD,
        &format!("{}/link", fixture.0.display()),
        O_WRONLY,
        &nspid(),
    )
    .expect("resolved policy path");
    assert!(policy.check(Path::new(&resolved.logical)).is_err());
}
