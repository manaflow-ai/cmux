use super::*;
use std::sync::mpsc;
use std::time::Duration;
use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OVERLAPPED;

fn lease_path(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-liveness-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("lease")
}

/// Whether this runs under Wine, whose `NtLockFile` does not implement an asynchronous
/// wait: it answers `STATUS_PENDING` and never finishes the lock, so a waiting lock on an
/// overlapped handle there tests Wine, not this code.
fn under_wine() -> bool {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetModuleHandleA(name: *const u8) -> HANDLE;
        fn GetProcAddress(module: HANDLE, name: *const u8) -> *const std::ffi::c_void;
    }
    // SAFETY: NUL-terminated names; ntdll is loaded in every process.
    unsafe {
        let ntdll = GetModuleHandleA(c"ntdll.dll".as_ptr().cast());
        !ntdll.is_null() && !GetProcAddress(ntdll, c"wine_get_version".as_ptr().cast()).is_null()
    }
}

/// A handle opened with `FILE_FLAG_OVERLAPPED`: `LockFileEx` answers `ERROR_IO_PENDING`
/// while another handle holds the lock and the kernel finishes the call later, writing
/// into its OVERLAPPED. `lock_file` must wait for that, not return with the OVERLAPPED
/// still in the kernel's hands.
#[test]
fn a_waiting_lock_on_an_overlapped_handle_returns_holding_the_lock() {
    if under_wine() {
        eprintln!("skipped under Wine: its NtLockFile cannot wait on an overlapped handle");
        return;
    }
    let path = lease_path("overlapped");
    let holder = acquire(&path, LeaseKind::Exclusive, false).unwrap().expect("first lease");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OVERLAPPED)
        .open(&path)
        .unwrap();
    let (tx, rx) = mpsc::channel();
    let (release, released) = mpsc::channel::<()>();
    let waiter = std::thread::spawn(move || {
        let got = lock_file(&file, LeaseKind::Exclusive, true);
        tx.send(got.map_err(|e| e.to_string())).unwrap();
        // Holds the lock until the test has looked.
        let _ = released.recv();
        unlock_file(&file);
    });
    if let Ok(early) = rx.recv_timeout(Duration::from_millis(300)) {
        panic!("lock_file returned {early:?} while another handle held the lock");
    }
    drop(holder);
    let got = rx.recv_timeout(Duration::from_secs(10)).expect("lock_file returned");
    assert_eq!(got, Ok(true));
    assert_eq!(probe(&path).unwrap(), LeaseProbe::Held);
    release.send(()).unwrap();
    waiter.join().unwrap();
    assert_eq!(probe(&path).unwrap(), LeaseProbe::Free);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());
}

/// The same handle, not waiting: a held lock is a plain `Ok(false)`.
#[test]
fn a_try_lock_on_an_overlapped_handle_sees_a_held_lock() {
    let path = lease_path("overlapped-try");
    let _holder = acquire(&path, LeaseKind::Exclusive, false).unwrap().expect("first lease");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OVERLAPPED)
        .open(&path)
        .unwrap();
    assert_eq!(lock_file(&file, LeaseKind::Exclusive, false).map_err(|e| e.to_string()), Ok(false));
    drop((file, _holder));
    let _ = std::fs::remove_dir_all(path.parent().unwrap());
}
