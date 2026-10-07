//! Windows integration tests (hosted `test-windows`, the Windows VM). Each
//! test uses its own directory under the user's temp dir.
#![cfg(windows)]

use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_local_socket::{connect_same_user, listen, peer_pid, win};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cls-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn me() -> String {
    win::current_identity().unwrap().user_sid
}

/// `listen` makes the directory: protected DACL, only our user, owned by us;
/// the socket file is owned by our token user even when elevated.
#[test]
fn listen_makes_an_owner_only_directory_and_owns_the_socket() {
    let dir = scratch("own");
    let path = dir.join("s.sock");
    let _listener = listen(&path).expect("listen");
    assert!(win::directory_is_owner_only(&dir, &me()).unwrap(), "the directory is owner-only");
    assert_eq!(win::owner_of(&dir).unwrap(), me());
    assert_eq!(win::owner_of(&path).unwrap(), me());
    let _ = std::fs::remove_dir_all(&dir);
}

/// An existing directory that grants Everyone access is refused.
#[test]
fn listen_refuses_a_wider_directory() {
    let dir = scratch("wide");
    std::fs::create_dir_all(&dir).unwrap();
    grant_everyone(&dir);
    let err = listen(&dir.join("s.sock")).err().expect("refused");
    assert_eq!(err.kind(), std::io::ErrorKind::PermissionDenied, "{err}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A connection from this process (our user, our integrity) is admitted,
/// and the peer pid is ours on both ends.
#[test]
fn same_user_peer_is_admitted_with_its_pid() {
    let dir = scratch("peer");
    let path = dir.join("s.sock");
    let listener = listen(&path).unwrap();
    let mut client = connect_same_user(&path).expect("connect_same_user");
    let mut server = listener.accept().expect("accept");
    assert_eq!(peer_pid(&server).unwrap(), std::process::id());
    assert_eq!(peer_pid(&client).unwrap(), std::process::id());
    client.write_all(b"x").unwrap();
    let mut byte = [0u8; 1];
    server.read_exact(&mut byte).unwrap();
    assert_eq!(&byte, b"x");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Sockets are not inherited by child processes.
#[test]
fn sockets_are_not_inheritable() {
    let dir = scratch("inherit");
    let path = dir.join("s.sock");
    let listener = listen(&path).unwrap();
    let client = connect_same_user(&path).unwrap();
    let server = listener.accept().unwrap();
    for (name, raw) in [
        ("listener", listener.raw_socket()),
        ("client", std::os::windows::io::AsRawSocket::as_raw_socket(&client)),
        ("server", std::os::windows::io::AsRawSocket::as_raw_socket(&server)),
    ] {
        assert!(!inheritable(raw), "{name} socket is inheritable");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A socket file owned by someone else than our token user is refused by
/// `connect_same_user` (skipped where we cannot set another owner: a
/// non-elevated runner).
#[test]
fn connect_same_user_refuses_a_foreign_owner() {
    let dir = scratch("foreign");
    let path = dir.join("s.sock");
    let _listener = listen(&path).unwrap();
    if !set_owner_administrators(&path) {
        eprintln!("skipped: cannot set the owner to BUILTIN\\Administrators here (not elevated)");
        return;
    }
    let err = connect_same_user(&path).err().expect("refused");
    assert_eq!(err.kind(), std::io::ErrorKind::PermissionDenied, "{err}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A Low-integrity child of the same user (a sandbox, like a Chromium
/// renderer) is refused by `accept`. The child is this test binary started
/// with a Low-integrity copy of our token, running `low_integrity_child`.
#[test]
fn low_integrity_peer_is_refused() {
    let dir = scratch("low");
    let path = dir.join("s.sock");
    let listener = listen(&path).unwrap();
    // Let a Low-integrity process write to the socket file, so the refusal
    // we test is ours, not the OS's no-write-up rule.
    label_low(&path);
    let child = spawn_low_integrity_child(&path);
    listener.set_nonblocking(true).unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let outcome = loop {
        match listener.accept() {
            Ok(_) => break Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() > deadline {
                    break Err("the child never connected".to_string());
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => break Err(e.to_string()),
        }
    };
    let status = wait_child(child);
    eprintln!("child exit {status:#x}; accept: {outcome:?}");
    let err = outcome.expect_err("a Low-integrity peer must be refused");
    assert!(err.contains("integrity"), "refused for its integrity: {err}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The Low-integrity child's body (does nothing in a normal run).
#[test]
fn low_integrity_child() {
    let Ok(path) = std::env::var("CLS_LOW_CHILD_SOCKET") else { return };
    let identity = win::current_identity().unwrap();
    assert!(identity.integrity_rid < cmux_local_socket::MEDIUM_INTEGRITY_RID, "{identity:?}");
    let mut s = cmux_local_socket::connect(std::path::Path::new(&path)).expect("child connect");
    let _ = s.write_all(b"low");
}

// --- helpers ------------------------------------------------------------

use windows_sys::Win32::Foundation::{
    CloseHandle, GetHandleInformation, HANDLE, HANDLE_FLAG_INHERIT, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1, SE_FILE_OBJECT,
    SetNamedSecurityInfoW,
};
use windows_sys::Win32::Security::{
    ACL, CreateWellKnownSid, DACL_SECURITY_INFORMATION, GetSecurityDescriptorDacl,
    GetSecurityDescriptorSacl, LABEL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR, PSID, WinBuiltinAdministratorsSid,
};

fn wide(p: &std::path::Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    p.as_os_str().encode_wide().chain([0]).collect()
}

fn inheritable(raw: u64) -> bool {
    let mut flags = 0u32;
    assert_ne!(unsafe { GetHandleInformation(raw as HANDLE, &mut flags) }, 0);
    flags & HANDLE_FLAG_INHERIT != 0
}

fn sd(sddl: &str) -> PSECURITY_DESCRIPTOR {
    let w: Vec<u16> = sddl.encode_utf16().chain([0]).collect();
    let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    let ok = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            w.as_ptr(),
            SDDL_REVISION_1,
            &mut sd,
            std::ptr::null_mut(),
        )
    };
    assert_ne!(ok, 0, "SDDL {sddl}");
    sd
}

fn grant_everyone(dir: &std::path::Path) {
    let d = sd("D:(A;OICI;FA;;;WD)(A;OICI;FA;;;OW)");
    let (mut present, mut acl, mut defaulted) = (0, std::ptr::null_mut::<ACL>(), 0);
    unsafe { GetSecurityDescriptorDacl(d, &mut present, &mut acl, &mut defaulted) };
    let mut p = wide(dir);
    let r = unsafe {
        SetNamedSecurityInfoW(
            p.as_mut_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            acl,
            std::ptr::null_mut(),
        )
    };
    assert_eq!(r, 0, "grant Everyone");
    unsafe { LocalFree(d as _) };
}

fn set_owner_administrators(path: &std::path::Path) -> bool {
    let mut sid = [0u8; 68];
    let mut size = sid.len() as u32;
    unsafe {
        CreateWellKnownSid(
            WinBuiltinAdministratorsSid,
            std::ptr::null_mut(),
            sid.as_mut_ptr() as PSID,
            &mut size,
        )
    };
    let mut p = wide(path);
    let r = unsafe {
        SetNamedSecurityInfoW(
            p.as_mut_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            sid.as_mut_ptr() as PSID,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    r == 0
}

fn label_low(path: &std::path::Path) {
    let d = sd("S:(ML;;NW;;;LW)");
    let (mut present, mut acl, mut defaulted) = (0, std::ptr::null_mut::<ACL>(), 0);
    unsafe { GetSecurityDescriptorSacl(d, &mut present, &mut acl, &mut defaulted) };
    let mut p = wide(path);
    let r = unsafe {
        SetNamedSecurityInfoW(
            p.as_mut_ptr(),
            SE_FILE_OBJECT,
            LABEL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            acl,
        )
    };
    assert_eq!(r, 0, "label Low");
    unsafe { LocalFree(d as _) };
}

fn spawn_low_integrity_child(path: &std::path::Path) -> HANDLE {
    use windows_sys::Win32::Security::Authorization::ConvertStringSidToSidW;
    use windows_sys::Win32::Security::{
        DuplicateTokenEx, SID_AND_ATTRIBUTES, SecurityImpersonation, SetTokenInformation,
        TOKEN_ALL_ACCESS, TOKEN_MANDATORY_LABEL, TokenIntegrityLevel, TokenPrimary,
    };
    use windows_sys::Win32::System::SystemServices::SE_GROUP_INTEGRITY;
    use windows_sys::Win32::System::Threading::{
        CreateProcessAsUserW, GetCurrentProcess, OpenProcessToken, PROCESS_INFORMATION,
        STARTUPINFOW,
    };
    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        assert_ne!(OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &mut token), 0);
        let mut low: HANDLE = std::ptr::null_mut();
        assert_ne!(
            DuplicateTokenEx(
                token,
                TOKEN_ALL_ACCESS,
                std::ptr::null(),
                SecurityImpersonation,
                TokenPrimary,
                &mut low
            ),
            0
        );
        let sid_text: Vec<u16> = "S-1-16-4096".encode_utf16().chain([0]).collect();
        let mut sid: PSID = std::ptr::null_mut();
        assert_ne!(ConvertStringSidToSidW(sid_text.as_ptr(), &mut sid), 0);
        let label = TOKEN_MANDATORY_LABEL {
            Label: SID_AND_ATTRIBUTES { Sid: sid, Attributes: SE_GROUP_INTEGRITY as u32 },
        };
        assert_ne!(
            SetTokenInformation(
                low,
                TokenIntegrityLevel,
                (&raw const label).cast(),
                size_of::<TOKEN_MANDATORY_LABEL>() as u32
            ),
            0,
            "set Low"
        );
        let exe = std::env::current_exe().unwrap();
        let mut cmd: Vec<u16> = format!(
            "\"{}\" --exact low_integrity_child --nocapture --test-threads 1",
            exe.display()
        )
        .encode_utf16()
        .chain([0])
        .collect();
        // The child reads the socket path from its environment.
        std::env::set_var("CLS_LOW_CHILD_SOCKET", path);
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = size_of::<STARTUPINFOW>() as u32;
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        let ok = CreateProcessAsUserW(
            low,
            std::ptr::null(),
            cmd.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            0,
            std::ptr::null(),
            std::ptr::null(),
            &si,
            &mut pi,
        );
        std::env::remove_var("CLS_LOW_CHILD_SOCKET");
        assert_ne!(ok, 0, "CreateProcessAsUserW: {}", std::io::Error::last_os_error());
        CloseHandle(pi.hThread);
        CloseHandle(low);
        CloseHandle(token);
        LocalFree(sid as _);
        pi.hProcess
    }
}

fn wait_child(process: HANDLE) -> u32 {
    use windows_sys::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject};
    unsafe {
        WaitForSingleObject(process, 30_000);
        let mut code = 0u32;
        GetExitCodeProcess(process, &mut code);
        CloseHandle(process);
        code
    }
}

/// `private_directory` makes an owner-only directory once and accepts it
/// again; `listen_explicit` binds in a directory it does not change.
#[test]
fn private_directory_then_explicit_listen() {
    let dir = scratch("explicit");
    cmux_local_socket::private_directory(&dir).unwrap();
    cmux_local_socket::private_directory(&dir).unwrap();
    assert!(win::directory_is_owner_only(&dir, &me()).unwrap());
    let shared = scratch("shared");
    std::fs::create_dir_all(&shared).unwrap();
    let path = shared.join("s.sock");
    let listener = cmux_local_socket::listen_explicit(&path).unwrap();
    assert!(!win::directory_is_owner_only(&shared, &me()).unwrap(), "left as it was");
    assert_eq!(win::owner_of(&path).unwrap(), me());
    let _client = connect_same_user(&path).unwrap();
    let _server = listener.accept().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&shared);
}
