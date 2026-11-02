// Included only inside notification_tests; exercise bounds children by SIGALRM.
macro_rules! creator_test {
    ($name:ident, $case:literal, $path:literal) => {
        #[test]
        fn $name() {
            if let Some((fixture, status)) = exercise($case, &[]) {
                assert_eq!(status, 0, "creator child failed");
                assert!(fs::symlink_metadata(fixture.0.join($path)).is_err());
            }
        }
    };
}
creator_test!(review_mkdir_git_denied, 210, ".git");
creator_test!(review_mkdir_claude_denied, 211, "sub/.claude");
creator_test!(review_mkdirat_hooks_denied, 212, ".git/hooks/x");
creator_test!(review_symlink_claude_denied, 213, "CLAUDE.md");
creator_test!(review_symlinkat_mcp_denied, 214, "sub/.mcp.json");
creator_test!(review_mknod_envrc_denied, 215, ".envrc");
creator_test!(review_mknod_device_denied, 217, "device");

#[test]
fn review_creators_allow_ordinary_names_and_preserve_errno_umask() {
    if let Some((fixture, status)) = exercise(216, &[]) {
        assert_eq!(status, 0);
        assert_eq!(
            fs::metadata(fixture.0.join("directory")).unwrap().permissions().mode() & 0o777,
            0o750
        );
        assert_eq!(
            fs::metadata(fixture.0.join("fifo")).unwrap().permissions().mode() & 0o777,
            0o640
        );
        assert_eq!(fs::read_link(fixture.0.join("alias")).unwrap(), Path::new(".git/config"));
    }
}

#[test]
fn review_truncate_symlink_race_preserves_config() {
    if let Some((fixture, status)) = exercise(218, &[]) {
        assert_eq!(status, 0);
        assert_eq!(fs::read(fixture.0.join(".git/config")).unwrap(), b"protected");
    }
}

/// Bounded syscall sequences; the harness alarm also bounds thread joins.
unsafe fn review_case(case: u8) -> i32 {
    unsafe {
        let at = AT_FDCWD;
        if case == 218 {
            return truncate_race();
        }
        if case == 216 {
            libc::umask(0o027);
            if libc::mkdir(c"directory".as_ptr(), 0o777) != 0
                || libc::symlink(c".git/config".as_ptr(), c"alias".as_ptr()) != 0
                || libc::mknod(c"fifo".as_ptr(), S_IFIFO | 0o666, 0) != 0
            {
                return 130;
            }
            if libc::mkdir(c"directory".as_ptr(), 0o777) != -1
                || *libc::__errno_location() != EEXIST
            {
                return 131;
            }
            if libc::mkdirat(at, c"missing/dir".as_ptr(), 0o777) != -1
                || *libc::__errno_location() != ENOENT
            {
                return 132;
            }
            return 0;
        }
        let rc = match case {
            210 => libc::mkdir(c".git".as_ptr(), 0o755),
            211 => libc::mkdir(c"sub/.claude".as_ptr(), 0o755),
            212 => {
                let dir = libc::open(c".git/hooks".as_ptr(), O_RDONLY | O_DIRECTORY);
                let rc = libc::mkdirat(dir, c"x".as_ptr(), 0o755);
                let saved = *libc::__errno_location();
                libc::close(dir);
                *libc::__errno_location() = saved;
                rc
            }
            213 => libc::symlink(c"ordinary".as_ptr(), c"CLAUDE.md".as_ptr()),
            214 => libc::symlinkat(c"ordinary".as_ptr(), at, c"sub/.mcp.json".as_ptr()),
            215 => libc::mknod(c".envrc".as_ptr(), S_IFIFO | 0o600, 0),
            217 => libc::mknodat(at, c"device".as_ptr(), S_IFCHR | 0o600, libc::makedev(1, 3)),
            _ => return 133,
        };
        let errno = *libc::__errno_location();
        if case == 217 {
            return if rc == -1 && errno == EPERM { 0 } else { 134 };
        }
        if rc == -1 && matches!(errno, EACCES | EPERM) { 0 } else { 135 }
    }
}

struct LeafRace {
    ready: AtomicBool,
    stop: AtomicBool,
}

/// Swaps the missing leaf with a protected symlink until stop or 10k iterations.
extern "C" fn swap_leaf(data: *mut c_void) -> *mut c_void {
    let state = unsafe { &*data.cast::<LeafRace>() };
    for _ in 0..10_000 {
        if state.stop.load(Ordering::Acquire) {
            break;
        }
        unsafe {
            libc::symlinkat(c".git/config".as_ptr(), AT_FDCWD, c"racing".as_ptr());
            state.ready.store(true, Ordering::Release);
            libc::sched_yield();
            libc::unlinkat(AT_FDCWD, c"racing".as_ptr(), 0);
        }
    }
    std::ptr::null_mut()
}

/// One thousand truncates race a sibling; SIGALRM bounds the readiness wait.
unsafe fn truncate_race() -> i32 {
    unsafe {
        if libc::truncate(c"racing".as_ptr(), 0) != -1 || *libc::__errno_location() != ENOENT {
            return 136;
        }
        let state = LeafRace { ready: AtomicBool::new(false), stop: AtomicBool::new(false) };
        let mut thread = std::mem::zeroed();
        if libc::pthread_create(
            &mut thread,
            std::ptr::null(),
            swap_leaf,
            (&state as *const LeafRace).cast_mut().cast(),
        ) != 0
        {
            return 137;
        }
        while !state.ready.load(Ordering::Acquire) {
            libc::sched_yield();
        }
        for _ in 0..1_000 {
            libc::truncate(c"racing".as_ptr(), 0);
        }
        state.stop.store(true, Ordering::Release);
        if libc::pthread_join(thread, std::ptr::null_mut()) != 0 {
            return 138;
        }
        0
    }
}
