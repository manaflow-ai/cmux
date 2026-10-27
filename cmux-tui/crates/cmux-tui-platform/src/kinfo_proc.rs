//! One process's entry in the macOS process table (`struct kinfo_proc`).
//!
//! proc_pidinfo does not answer for a process that runs with another user's
//! credentials, such as login(1) (setuid root) leading a terminal's session
//! (cmux-tui-core `login_shell`). The process table answers for every process.

/// Whether `leader`, a terminal's foreground group, is the shell login(1)
/// started: the terminal's PTY child `pid` is login(1) and `leader` is its
/// child. That shell is the terminal's own shell, not a job it runs.
#[cfg(target_os = "macos")]
pub(crate) fn login_session_shell(pid: u32, leader: u32) -> bool {
    KinfoProc::read(pid).is_some_and(|child| child.command() == Some(b"login".as_slice()))
        && KinfoProc::read(leader).is_some_and(|shell| shell.parent() == pid)
}

/// Only macOS shells start through login(1).
#[cfg(not(target_os = "macos"))]
pub(crate) fn login_session_shell(_pid: u32, _leader: u32) -> bool {
    false
}

/// One process's `struct kinfo_proc` from the process table (sysctl
/// `{CTL_KERN, KERN_PROC, KERN_PROC_PID, pid}`), read at the field offsets of
/// the 64-bit Darwin layout (the same on arm64 and x86_64, from
/// `<sys/sysctl.h>`). A buffer of another size, or for another pid, is not
/// used.
#[cfg(target_os = "macos")]
pub(crate) struct KinfoProc([u8; KinfoProc::SIZE]);

#[cfg(target_os = "macos")]
impl KinfoProc {
    const SIZE: usize = 648;
    /// `kp_proc.p_pid`.
    const P_PID: usize = 40;
    /// `kp_proc.p_comm`: `MAXCOMLEN + 1` bytes, NUL-terminated.
    const P_COMM: usize = 243;
    const P_COMM_LEN: usize = 17;
    /// `kp_eproc.e_ppid`, `e_tdev` and `e_tpgid`.
    const E_PPID: usize = 560;
    const E_TDEV: usize = 572;
    const E_TPGID: usize = 576;

    pub(crate) fn read(pid: u32) -> Option<Self> {
        let pid = libc::c_int::try_from(pid).ok()?;
        let mut mib = [libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PID, pid];
        let mut info = [0u8; Self::SIZE];
        let mut size = info.len();
        // SAFETY: the kernel writes at most `size` bytes into `info`.
        let result = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                4,
                info.as_mut_ptr().cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        let info = Self(info);
        (result == 0 && size == Self::SIZE && info.int(Self::P_PID) == Some(pid)).then_some(info)
    }

    /// The `int` field at `offset` (a field offset above, so always inside the buffer).
    fn int(&self, offset: usize) -> Option<i32> {
        self.0.get(offset..)?.first_chunk::<4>().map(|bytes| i32::from_ne_bytes(*bytes))
    }

    pub(crate) fn parent(&self) -> u32 {
        self.int(Self::E_PPID).and_then(|parent| u32::try_from(parent).ok()).unwrap_or(0)
    }

    /// The process's name: its executable's base name, at most 16 bytes.
    fn command(&self) -> Option<&[u8]> {
        let comm = self.0.get(Self::P_COMM..Self::P_COMM + Self::P_COMM_LEN)?;
        comm.split(|byte| *byte == 0).next()
    }

    /// The process group that owns the process's controlling terminal.
    pub(crate) fn foreground_group(&self) -> Option<u32> {
        // NODEV (all ones) means the process has no controlling terminal.
        if self.int(Self::E_TDEV)? == -1 {
            return None;
        }
        u32::try_from(self.int(Self::E_TPGID)?).ok().filter(|group| *group > 0)
    }
}
