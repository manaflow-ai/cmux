//! Process tests exercise the real passwd-rooted authority. They must never
//! overwrite existing user policy. CI runs these in a disposable OS account;
//! each guard owns only the previously absent authority directory it creates.
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};
static SERIAL: Mutex<()> = Mutex::new(());

pub struct ConsentHome {
    pub root: PathBuf,
    _serial: MutexGuard<'static, ()>,
}
impl ConsentHome {
    pub fn isolated() -> Self {
        let serial = SERIAL.lock().unwrap_or_else(|error| error.into_inner());
        let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut result = std::ptr::null_mut();
        let mut buffer = vec![0u8; 65536];
        // SAFETY: live outputs and backing buffer; the lookup uses this uid.
        let code = unsafe {
            libc::getpwuid_r(
                libc::geteuid(),
                entry.as_mut_ptr(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        assert!(code == 0 && !result.is_null());
        // SAFETY: successful getpwuid_r populated a NUL-terminated pw_dir.
        let home = unsafe { std::ffi::CStr::from_ptr((*result).pw_dir) };
        use std::os::unix::ffi::OsStrExt;
        let root = PathBuf::from(std::ffi::OsStr::from_bytes(home.to_bytes()))
            .join(".acpmux/machine-consent");
        let expected = std::env::var_os("ACPMUX_TEST_ACCOUNT_HOME")
            .expect("run ignored consent tests in a disposable OS account with ACPMUX_TEST_ACCOUNT_HOME=passwd home");
        assert_eq!(root, PathBuf::from(expected).join(".acpmux/machine-consent"));
        assert!(
            !root.try_exists().unwrap(),
            "consent tests require a clean isolated OS account; refusing to change existing policy"
        );
        Self { root, _serial: serial }
    }
}
impl Drop for ConsentHome {
    fn drop(&mut self) {
        // This test owns the absent-at-entry directory created by its children.
        if self.root.exists() {
            std::fs::remove_dir_all(&self.root).unwrap();
        }
    }
}

/// A relocated build artifact readable by the disposable UID. This override
/// exists only in test code and never changes production state resolution.
pub fn binary(default: &std::path::Path) -> PathBuf {
    std::env::var_os("ACPMUX_TEST_BINARY").map(PathBuf::from).unwrap_or_else(|| default.to_owned())
}
