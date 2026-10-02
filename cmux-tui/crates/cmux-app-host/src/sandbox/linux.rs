//! Linux: no_new_privs + Landlock (deny every handled right) + seccomp.

use super::Report;

// Landlock (include/uapi/linux/landlock.h).
const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1;
const FS_RIGHTS_BY_ABI: [u64; 6] = [
    (1 << 13) - 1, // v1: EXECUTE..MAKE_SYM
    (1 << 14) - 1, // v2: + REFER
    (1 << 15) - 1, // v3: + TRUNCATE
    (1 << 15) - 1, // v4: network rights only
    (1 << 16) - 1, // v5: + IOCTL_DEV
    (1 << 16) - 1, // v6: scopes only
];
const NET_RIGHTS: u64 = 0b11; // BIND_TCP | CONNECT_TCP (ABI 4)
const SCOPES: u64 = 0b11; // ABSTRACT_UNIX_SOCKET | SIGNAL (ABI 6)

#[repr(C)]
struct RulesetAttr {
    handled_access_fs: u64,
    handled_access_net: u64,
    scoped: u64,
}

// seccomp / classic BPF (include/uapi/linux/{seccomp,filter,bpf_common}.h).
// BPF_LD | BPF_W | BPF_ABS, BPF_JMP | BPF_JEQ | BPF_K, BPF_RET | BPF_K.
const BPF_LD_W_ABS: u16 = 0x20;
const BPF_JMP_JEQ_K: u16 = 0x15;
const BPF_RET_K: u16 = 0x06;
const SECCOMP_RET_KILL_PROCESS: u32 = 0x8000_0000;
const SECCOMP_RET_ERRNO: u32 = 0x0005_0000;
const SECCOMP_RET_ALLOW: u32 = 0x7fff_0000;
const SECCOMP_MODE_FILTER: libc::c_ulong = 2;
const OFFSET_NR: u32 = 0;
const OFFSET_ARCH: u32 = 4;
#[cfg(target_arch = "x86_64")]
const AUDIT_ARCH: u32 = 0xC000_003E;
#[cfg(target_arch = "aarch64")]
const AUDIT_ARCH: u32 = 0xC000_00B7;

/// Syscalls the host never needs once it runs. Everything the VM does is
/// memory, time, randomness and reads/writes on fds it already holds.
fn denied_syscalls() -> Vec<libc::c_long> {
    let mut list = vec![
        libc::SYS_openat,
        libc::SYS_openat2,
        libc::SYS_open_by_handle_at,
        libc::SYS_name_to_handle_at,
        libc::SYS_socket,
        libc::SYS_socketpair,
        libc::SYS_connect,
        libc::SYS_bind,
        libc::SYS_listen,
        libc::SYS_accept,
        libc::SYS_accept4,
        libc::SYS_execve,
        libc::SYS_execveat,
        libc::SYS_clone,
        libc::SYS_clone3,
        libc::SYS_ptrace,
        libc::SYS_process_vm_readv,
        libc::SYS_process_vm_writev,
        libc::SYS_mount,
        libc::SYS_umount2,
        libc::SYS_pivot_root,
        libc::SYS_chroot,
        libc::SYS_unshare,
        libc::SYS_setns,
        libc::SYS_bpf,
        libc::SYS_perf_event_open,
        libc::SYS_io_uring_setup,
        libc::SYS_io_uring_enter,
        libc::SYS_io_uring_register,
        libc::SYS_keyctl,
        libc::SYS_add_key,
        libc::SYS_request_key,
        libc::SYS_memfd_create,
        libc::SYS_mknodat,
        libc::SYS_mkdirat,
        libc::SYS_unlinkat,
        libc::SYS_renameat,
        libc::SYS_renameat2,
        libc::SYS_linkat,
        libc::SYS_symlinkat,
        libc::SYS_fchmodat,
        libc::SYS_fchownat,
        libc::SYS_truncate,
        libc::SYS_init_module,
        libc::SYS_finit_module,
        libc::SYS_delete_module,
        libc::SYS_kexec_load,
    ];
    #[cfg(target_arch = "x86_64")]
    list.extend([
        libc::SYS_open,
        libc::SYS_creat,
        libc::SYS_fork,
        libc::SYS_vfork,
        libc::SYS_mknod,
        libc::SYS_mkdir,
        libc::SYS_rmdir,
        libc::SYS_unlink,
        libc::SYS_rename,
        libc::SYS_link,
        libc::SYS_symlink,
        libc::SYS_chmod,
        libc::SYS_chown,
        libc::SYS_lchown,
        libc::SYS_uselib,
    ]);
    list
}

pub(super) fn apply() -> Result<Report, String> {
    // SAFETY: plain prctl with integer arguments.
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
        return Err(format!("no_new_privs: {}", std::io::Error::last_os_error()));
    }
    let landlock_abi = landlock()?;
    seccomp()?;
    Ok(Report { mechanism: "seccomp", landlock_abi })
}

/// Restricts the process with every right Landlock knows and no rule, so
/// nothing on the file system (and from ABI 4 no TCP) is reachable. Returns
/// `None` when the kernel has no Landlock; seccomp still refuses opens.
fn landlock() -> Result<Option<u32>, String> {
    // SAFETY: the version query takes a null attribute and size 0.
    let abi = unsafe {
        libc::syscall(
            libc::SYS_landlock_create_ruleset,
            std::ptr::null::<RulesetAttr>(),
            0usize,
            LANDLOCK_CREATE_RULESET_VERSION,
        )
    };
    if abi < 1 {
        return Ok(None);
    }
    let abi = abi as u32;
    let index = (abi as usize).min(FS_RIGHTS_BY_ABI.len()) - 1;
    let attr = RulesetAttr {
        handled_access_fs: FS_RIGHTS_BY_ABI[index],
        handled_access_net: if abi >= 4 { NET_RIGHTS } else { 0 },
        scoped: if abi >= 6 { SCOPES } else { 0 },
    };
    // Older kernels reject fields they do not know, so pass only the known prefix.
    let size = match abi {
        1..=3 => size_of::<u64>(),
        4 | 5 => 2 * size_of::<u64>(),
        _ => size_of::<RulesetAttr>(),
    };
    // SAFETY: `attr` outlives the call and `size` never exceeds it.
    let fd = unsafe {
        libc::syscall(libc::SYS_landlock_create_ruleset, &attr as *const RulesetAttr, size, 0u32)
    };
    if fd < 0 {
        return Err(format!("landlock ruleset: {}", std::io::Error::last_os_error()));
    }
    let fd = fd as libc::c_int;
    // SAFETY: `fd` is the ruleset descriptor created above.
    let restricted = unsafe { libc::syscall(libc::SYS_landlock_restrict_self, fd, 0u32) };
    let error = std::io::Error::last_os_error();
    // SAFETY: closing the descriptor we own.
    unsafe { libc::close(fd) };
    if restricted != 0 {
        return Err(format!("landlock restrict: {error}"));
    }
    Ok(Some(abi))
}

fn seccomp() -> Result<(), String> {
    let stmt = |code: u16, k: u32| libc::sock_filter { code, jt: 0, jf: 0, k };
    let jump = |k: u32, jt: u8, jf: u8| libc::sock_filter { code: BPF_JMP_JEQ_K, jt, jf, k };
    let mut program = vec![
        stmt(BPF_LD_W_ABS, OFFSET_ARCH),
        jump(AUDIT_ARCH, 1, 0),
        stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS),
        stmt(BPF_LD_W_ABS, OFFSET_NR),
    ];
    for nr in denied_syscalls() {
        program.push(jump(nr as u32, 0, 1));
        program.push(stmt(BPF_RET_K, SECCOMP_RET_ERRNO | libc::EPERM as u32));
    }
    program.push(stmt(BPF_RET_K, SECCOMP_RET_ALLOW));
    let fprog = libc::sock_fprog { len: program.len() as u16, filter: program.as_mut_ptr() };
    // SAFETY: `fprog` points at `program`, which lives until the call returns;
    // the kernel copies the filter.
    let rc = unsafe {
        libc::prctl(
            libc::PR_SET_SECCOMP,
            SECCOMP_MODE_FILTER,
            &fprog as *const libc::sock_fprog,
            0,
            0,
        )
    };
    if rc != 0 {
        return Err(format!("seccomp: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}
