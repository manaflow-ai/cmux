//! Syscall boundary, staged independently of Linux sandbox activation.
//! Deny and optional notify rules share one program and one installation.
//! The deny-only entry point never requests a listener.

// No production caller until the init helper lands.
#![allow(dead_code)]

use std::io;
use std::os::fd::{FromRawFd, OwnedFd};

pub(crate) fn deny_filter() -> Result<Vec<libc::sock_filter>, String> {
    filter(false)
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
const SECCOMP_DATA_NR: u32 = 0;
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
const SECCOMP_DATA_ARCH: u32 = 4;
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
const SECCOMP_DATA_ARG0_LO: u32 = 16;
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
const SECCOMP_DATA_ARG0_HI: u32 = 20;
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
const SECCOMP_DATA_ARG1_LO: u32 = 24;
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
const SECCOMP_DATA_ARG2_LO: u32 = 32;

#[cfg(target_arch = "x86_64")]
const AUDIT_ARCH: u32 = 0xc000_003e;
#[cfg(target_arch = "aarch64")]
const AUDIT_ARCH: u32 = 0xc000_00b7;

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
#[derive(Clone, Copy)]
struct Label(usize);

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
struct Assembler {
    program: Vec<libc::sock_filter>,
    labels: Vec<Option<usize>>,
    patches: Vec<(usize, Label, bool)>,
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
impl Assembler {
    fn new() -> Self {
        Self { program: Vec::new(), labels: Vec::new(), patches: Vec::new() }
    }

    fn label(&mut self) -> Label {
        let label = Label(self.labels.len());
        self.labels.push(None);
        label
    }

    fn mark(&mut self, label: Label) {
        self.labels[label.0] = Some(self.program.len());
    }

    fn stmt(&mut self, code: u32, k: u32) {
        self.program.push(libc::sock_filter { code: code as u16, jt: 0, jf: 0, k });
    }

    fn jump(&mut self, code: u32, k: u32, jt: u8, jf: u8) {
        self.program.push(libc::sock_filter { code: code as u16, jt, jf, k });
    }

    fn cond(&mut self, code: u32, k: u32, jt: Label, jf: Label) {
        let index = self.program.len();
        self.program.push(libc::sock_filter { code: code as u16, jt: 0, jf: 0, k });
        self.patches.push((index, jt, true));
        self.patches.push((index, jf, false));
    }

    fn finish(mut self) -> Result<Vec<libc::sock_filter>, String> {
        for (index, label, true_branch) in self.patches {
            let target = self.labels[label.0]
                .ok_or_else(|| format!("unresolved seccomp label {}", label.0))?;
            let offset = target
                .checked_sub(index + 1)
                .ok_or_else(|| format!("backward seccomp jump at {index}"))?;
            if offset > u8::MAX as usize {
                return Err(format!("seccomp jump at {index} is too far ({offset})"));
            }
            if true_branch {
                self.program[index].jt = offset as u8;
            } else {
                self.program[index].jf = offset as u8;
            }
        }
        if self.program.len() >= 4096 {
            return Err(format!(
                "seccomp filter has {} instructions (BPF_MAXINSNS is 4096)",
                self.program.len()
            ));
        }
        Ok(self.program)
    }
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn deny_syscalls() -> Vec<u32> {
    let mut numbers = Vec::new();
    #[cfg(target_arch = "x86_64")]
    numbers.push(libc::SYS_link as u32);
    numbers.extend(
        [
            libc::SYS_linkat,
            libc::SYS_mount,
            libc::SYS_umount2,
            libc::SYS_fsopen,
            libc::SYS_fsconfig,
            libc::SYS_fsmount,
            libc::SYS_fspick,
            libc::SYS_move_mount,
            libc::SYS_open_tree,
            libc::SYS_mount_setattr,
            libc::SYS_pivot_root,
            libc::SYS_chroot,
            libc::SYS_setns,
            libc::SYS_unshare,
            libc::SYS_ptrace,
            libc::SYS_process_vm_readv,
            libc::SYS_process_vm_writev,
            libc::SYS_io_uring_setup,
            libc::SYS_io_uring_enter,
            libc::SYS_io_uring_register,
            libc::SYS_keyctl,
            libc::SYS_add_key,
            libc::SYS_request_key,
            libc::SYS_bpf,
            libc::SYS_perf_event_open,
            libc::SYS_userfaultfd,
            libc::SYS_name_to_handle_at,
            libc::SYS_open_by_handle_at,
            libc::SYS_bind,
            libc::SYS_listen,
            libc::SYS_accept,
            libc::SYS_accept4,
            libc::SYS_seccomp,
        ]
        .into_iter()
        .map(|n| n as u32),
    );
    numbers
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
pub(crate) fn filter(notify: bool) -> Result<Vec<libc::sock_filter>, String> {
    use libc::{
        BPF_ABS, BPF_ALU, BPF_AND, BPF_JEQ, BPF_JGE, BPF_JMP, BPF_JSET, BPF_K, BPF_LD, BPF_RET,
        BPF_W, SECCOMP_RET_ALLOW, SECCOMP_RET_ERRNO, SECCOMP_RET_KILL_PROCESS,
    };

    let mut asm = Assembler::new();
    // Reserve stable labels first so the code below can refer to them without
    // embedding instruction indexes. Every branch is forward and bounded.
    let allow = asm.label();
    let deny = asm.label();
    let clone_body = asm.label();
    let socket_body = asm.label();
    let socket_v6 = asm.label();
    let netlink_domain = asm.label();
    let netlink_body = asm.label();
    let socketpair_body = asm.label();
    let socketpair_after = asm.label();
    let socketpair_type = asm.label();
    let prctl_body = asm.label();
    let prctl_after = asm.label();

    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARCH);
    // A mismatched architecture reaches the kill return; a match skips it.
    let kill = asm.label();
    let after_kill = asm.label();
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH, after_kill, kill);
    asm.mark(after_kill);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_NR);
    #[cfg(target_arch = "x86_64")]
    {
        let after_x32 = asm.label();
        asm.cond(BPF_JMP | BPF_JGE | BPF_K, 0x4000_0000, kill, after_x32);
        asm.mark(after_x32);
    }

    let eperm = SECCOMP_RET_ERRNO | libc::EPERM as u32;
    let enosys = SECCOMP_RET_ERRNO | libc::ENOSYS as u32;
    for number in deny_syscalls() {
        let next = asm.label();
        let here = asm.label();
        asm.cond(BPF_JMP | BPF_JEQ | BPF_K, number, here, next);
        asm.mark(here);
        asm.stmt(BPF_RET | BPF_K, eperm);
        asm.mark(next);
    }

    // Keep this filter as the single seccomp installation point. A later
    // equal-precedence filter could otherwise win and answer USER_NOTIF
    // requests with CONTINUE, while NEW_LISTENER could race the supervisor.
    // E's notify rules are therefore added to this same program before its
    // one install; target code cannot install another filter afterward.
    let after_prctl = asm.label();
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::SYS_prctl as u32, prctl_body, after_prctl);
    asm.mark(prctl_body);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARG0_LO);
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::PR_SET_SECCOMP as u32, deny, prctl_after);
    asm.mark(prctl_after);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_NR);
    asm.mark(after_prctl);

    // clone's namespace flags occupy the low 32 bits of arg0 on both arches;
    // the high word is separately rejected so no 64-bit flag can hide there.
    let clone_after = asm.label();
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::SYS_clone as u32, clone_body, clone_after);
    asm.mark(clone_body);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARG0_LO);
    asm.jump(
        BPF_JMP | BPF_JSET | BPF_K,
        (libc::CLONE_NEWNS
            | libc::CLONE_NEWUTS
            | libc::CLONE_NEWIPC
            | libc::CLONE_NEWUSER
            | libc::CLONE_NEWPID
            | libc::CLONE_NEWNET
            | libc::CLONE_NEWCGROUP
            | libc::CLONE_NEWTIME) as u32,
        0,
        1,
    );
    asm.stmt(BPF_RET | BPF_K, eperm);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARG0_HI);
    asm.jump(BPF_JMP | BPF_JGE | BPF_K, 1, 0, 1);
    asm.stmt(BPF_RET | BPF_K, eperm);
    asm.mark(clone_after);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_NR);

    for (number, action) in [(libc::SYS_clone3, enosys), (libc::SYS_openat2, enosys)] {
        let next = asm.label();
        let here = asm.label();
        asm.cond(BPF_JMP | BPF_JEQ | BPF_K, number as u32, here, next);
        asm.mark(here);
        asm.stmt(BPF_RET | BPF_K, action);
        asm.mark(next);
    }

    // socket: INET/INET6 are allowed; NETLINK is allowed only for route.
    let socket_not = asm.label();
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::SYS_socket as u32, socket_body, socket_not);
    asm.mark(socket_body);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARG0_LO);
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::AF_INET as u32, allow, socket_v6);
    asm.mark(socket_v6);
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::AF_INET6 as u32, allow, netlink_domain);
    asm.mark(netlink_domain);
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::AF_NETLINK as u32, netlink_body, deny);
    asm.mark(netlink_body);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARG2_LO);
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::NETLINK_ROUTE as u32, allow, deny);
    asm.mark(socket_not);

    // socketpair: only UNIX stream or seqpacket. Datagram pairs can sendto
    // arbitrary filesystem Unix paths even while connected, so they stay off.
    let socketpair_not = asm.label();
    asm.cond(
        BPF_JMP | BPF_JEQ | BPF_K,
        libc::SYS_socketpair as u32,
        socketpair_body,
        socketpair_not,
    );
    asm.mark(socketpair_body);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARG0_LO);
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::AF_UNIX as u32, socketpair_type, deny);
    asm.mark(socketpair_type);
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARG1_LO);
    asm.stmt(BPF_ALU | BPF_AND | BPF_K, 0xf);
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::SOCK_STREAM as u32, allow, socketpair_after);
    asm.mark(socketpair_after);
    asm.cond(BPF_JMP | BPF_JEQ | BPF_K, libc::SOCK_SEQPACKET as u32, allow, deny);
    asm.mark(socketpair_not);

    if notify {
        // Write opens and every name/metadata mutation follow the deny rules.
        for (nr, argument) in [
            (libc::SYS_openat, SECCOMP_DATA_ARG2_LO),
            #[cfg(target_arch = "x86_64")]
            (libc::SYS_open, SECCOMP_DATA_ARG1_LO),
        ] {
            asm.jump(BPF_JMP | BPF_JEQ | BPF_K, nr as u32, 0, 3);
            asm.stmt(BPF_LD | BPF_W | BPF_ABS, argument);
            asm.jump(
                BPF_JMP | BPF_JSET | BPF_K,
                (libc::O_WRONLY
                    | libc::O_RDWR
                    | libc::O_CREAT
                    | libc::O_TRUNC
                    | libc::O_APPEND
                    | (libc::O_TMPFILE & !libc::O_DIRECTORY)) as u32,
                0,
                1,
            );
            asm.stmt(BPF_RET | BPF_K, libc::SECCOMP_RET_USER_NOTIF);
            asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_NR);
        }
        #[cfg(target_arch = "x86_64")]
        {
            asm.jump(BPF_JMP | BPF_JEQ | BPF_K, libc::SYS_creat as u32, 0, 1);
            asm.stmt(BPF_RET | BPF_K, libc::SECCOMP_RET_USER_NOTIF);
        }
        #[allow(unused_mut)] // The legacy syscall extension exists only on x86_64.
        let mut mutations = vec![
            libc::SYS_mkdirat,
            libc::SYS_mknodat,
            libc::SYS_symlinkat,
            libc::SYS_renameat,
            libc::SYS_renameat2,
            libc::SYS_unlinkat,
            libc::SYS_truncate,
            libc::SYS_fchmodat,
            452, /* fchmodat2 */
            libc::SYS_fchownat,
            libc::SYS_utimensat,
            libc::SYS_setxattr,
            libc::SYS_lsetxattr,
            libc::SYS_removexattr,
            libc::SYS_lremovexattr,
            463,
            466, /* setxattrat, removexattrat */
            libc::SYS_fchmod,
            libc::SYS_fchown,
            libc::SYS_fsetxattr,
            libc::SYS_fremovexattr,
            libc::SYS_ftruncate,
        ];
        #[cfg(target_arch = "x86_64")]
        mutations.extend([
            libc::SYS_mkdir,
            libc::SYS_mknod,
            libc::SYS_symlink,
            libc::SYS_rename,
            libc::SYS_unlink,
            libc::SYS_rmdir,
            libc::SYS_chmod,
            libc::SYS_chown,
            libc::SYS_lchown,
            libc::SYS_utime,
            libc::SYS_utimes,
            libc::SYS_futimesat,
        ]);
        for nr in mutations {
            asm.jump(BPF_JMP | BPF_JEQ | BPF_K, nr as u32, 0, 1);
            asm.stmt(BPF_RET | BPF_K, libc::SECCOMP_RET_USER_NOTIF);
        }
    }

    // Fallthrough for every syscall not handled above is the default allow.
    asm.mark(allow);
    asm.stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    asm.mark(deny);
    asm.stmt(BPF_RET | BPF_K, eperm);
    asm.mark(kill);
    asm.stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
    asm.finish()
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
pub(crate) fn filter(_notify: bool) -> Result<Vec<libc::sock_filter>, String> {
    Err(format!("unsupported Linux seccomp architecture: {}", std::env::consts::ARCH))
}

fn classify_install_result(rc: libc::c_long, errno: i32) -> io::Result<()> {
    if rc < 0 {
        Err(io::Error::from_raw_os_error(errno))
    } else if rc > 0 {
        Err(io::Error::other(format!("thread {rc} not synchronized")))
    } else {
        Ok(())
    }
}

fn install_flags(filter: &[libc::sock_filter], flags: libc::c_ulong) -> io::Result<libc::c_long> {
    if filter.is_empty() || filter.len() >= 4096 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid seccomp filter length"));
    }
    // SAFETY: PR_SET_NO_NEW_PRIVS takes an integer flag and no pointers.
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let program = libc::sock_fprog {
        len: filter.len() as libc::c_ushort,
        filter: filter.as_ptr() as *mut libc::sock_filter,
    };
    // SAFETY: `program` remains live for the raw syscall.
    let rc =
        unsafe { libc::syscall(libc::SYS_seccomp, libc::SECCOMP_SET_MODE_FILTER, flags, &program) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(rc)
}

pub(crate) fn install(filter: &[libc::sock_filter]) -> io::Result<()> {
    let rc = install_flags(filter, libc::SECCOMP_FILTER_FLAG_TSYNC as _)?;
    classify_install_result(rc, 0)
}

/// Install USER_NOTIF and return the kernel-owned listener. The listener is
/// handed to the host before exec; the target filter remains active afterward.
pub(crate) fn install_notify(filter: &[libc::sock_filter]) -> io::Result<OwnedFd> {
    const NEW_LISTENER: libc::c_ulong = 1 << 3;
    const TSYNC_ESRCH: libc::c_ulong = 1 << 4;
    let fd = install_flags(
        filter,
        (libc::SECCOMP_FILTER_FLAG_TSYNC as libc::c_ulong) | NEW_LISTENER | TSYNC_ESRCH,
    )?;
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: seccomp returned a newly owned listener descriptor.
    Ok(unsafe { OwnedFd::from_raw_fd(fd as _) })
}

#[cfg(all(test, not(any(target_arch = "x86_64", target_arch = "aarch64"))))]
mod unsupported_tests {
    #[test]
    fn unsupported_architecture_is_refused() {
        assert!(super::deny_filter().is_err());
    }
}

#[cfg(all(test, any(target_arch = "x86_64", target_arch = "aarch64")))]
mod tests {
    //! Table loops stop at the end of their finite arrays or filter slices.

    use super::*;
    use libc::*;

    // Independent Linux UAPI values: EM_X86_64/EM_AARCH64 | 64BIT | LE.
    #[cfg(target_arch = "x86_64")]
    const ARCH: u32 = 0xc000_003e;
    #[cfg(target_arch = "aarch64")]
    const ARCH: u32 = 0xc000_00b7;
    const EPERM_ACTION: u32 = SECCOMP_RET_ERRNO | EPERM as u32;
    const ENOSYS_ACTION: u32 = SECCOMP_RET_ERRNO | ENOSYS as u32;

    /// Interpreter stops at RET, or fails after at most filter.len() steps.
    fn evaluate(filter: &[sock_filter], arch: u32, nr: u32, args: [u64; 6]) -> u32 {
        let mut data = [0u8; 64]; // struct seccomp_data's stable UAPI layout
        data[..4].copy_from_slice(&nr.to_ne_bytes());
        data[4..8].copy_from_slice(&arch.to_ne_bytes());
        for (i, arg) in args.iter().enumerate() {
            data[16 + i * 8..24 + i * 8].copy_from_slice(&arg.to_ne_bytes());
        }
        let (mut pc, mut a) = (0usize, 0u32);
        for _ in 0..filter.len() {
            let ins = &filter[pc];
            pc += 1;
            match ins.code as u32 {
                c if c == BPF_LD | BPF_W | BPF_ABS => {
                    let offset = ins.k as usize;
                    a = u32::from_ne_bytes(data[offset..offset + 4].try_into().unwrap());
                }
                c if c == BPF_JMP | BPF_JA => pc += ins.k as usize,
                c if c == BPF_JMP | BPF_JEQ | BPF_K => {
                    pc += if a == ins.k { ins.jt } else { ins.jf } as usize;
                }
                c if c == BPF_JMP | BPF_JGE | BPF_K => {
                    pc += if a >= ins.k { ins.jt } else { ins.jf } as usize;
                }
                c if c == BPF_JMP | BPF_JSET | BPF_K => {
                    pc += if a & ins.k != 0 { ins.jt } else { ins.jf } as usize;
                }
                c if c == BPF_ALU | BPF_AND | BPF_K => a &= ins.k,
                c if c == BPF_RET | BPF_K => return ins.k,
                c => panic!("unexpected BPF opcode {c:#x}"),
            }
        }
        panic!("filter did not return");
    }

    #[test]
    fn filter_is_well_formed() {
        let filter = deny_filter().unwrap();
        // BPF_MAXINSNS from linux/bpf_common.h.
        assert!(!filter.is_empty() && filter.len() < 4096);
        assert_eq!(filter.last().unwrap().code as u32, BPF_RET | BPF_K);
        for (pc, ins) in filter.iter().enumerate() {
            if ins.code as u32 & 7 == BPF_JMP {
                let targets = if ins.code as u32 == BPF_JMP | BPF_JA {
                    [ins.k as usize; 2]
                } else {
                    [ins.jt as usize, ins.jf as usize]
                };
                for offset in targets {
                    assert!(pc + 1 + offset < filter.len(), "jump outside filter at {pc}");
                }
            }
            if ins.code as u32 == BPF_RET | BPF_K {
                assert_ne!(ins.k & SECCOMP_RET_ACTION_FULL, SECCOMP_RET_USER_NOTIF);
            }
        }
    }

    #[test]
    fn foreign_architecture_and_x32_are_killed_first() {
        let filter = deny_filter().unwrap();
        for arch in [0, 0x4000_0003, ARCH ^ 1] {
            for nr in [SYS_getpid as u32, SYS_linkat as u32] {
                assert_eq!(evaluate(&filter, arch, nr, [0; 6]), SECCOMP_RET_KILL_PROCESS);
            }
        }
        #[cfg(target_arch = "x86_64")]
        for nr in [0x4000_0000, 0x4000_0000 | SYS_getpid as u32, u32::MAX] {
            assert_eq!(evaluate(&filter, ARCH, nr, [0; 6]), SECCOMP_RET_KILL_PROCESS);
        }
    }

    #[test]
    fn privileged_syscalls_are_denied_and_fallbacks_are_enosys() {
        let filter = deny_filter().unwrap();
        let denied = [
            #[cfg(target_arch = "x86_64")]
            SYS_link,
            SYS_linkat,
            SYS_mount,
            SYS_umount2,
            SYS_fsopen,
            SYS_fsconfig,
            SYS_fsmount,
            SYS_fspick,
            SYS_move_mount,
            SYS_open_tree,
            SYS_mount_setattr,
            SYS_pivot_root,
            SYS_chroot,
            SYS_setns,
            SYS_unshare,
            SYS_ptrace,
            SYS_process_vm_readv,
            SYS_process_vm_writev,
            SYS_io_uring_setup,
            SYS_io_uring_enter,
            SYS_io_uring_register,
            SYS_keyctl,
            SYS_add_key,
            SYS_request_key,
            SYS_bpf,
            SYS_perf_event_open,
            SYS_userfaultfd,
            SYS_name_to_handle_at,
            SYS_open_by_handle_at,
            SYS_bind,
            SYS_listen,
            SYS_accept,
            SYS_accept4,
        ];
        for nr in denied {
            assert_eq!(evaluate(&filter, ARCH, nr as u32, [0; 6]), EPERM_ACTION, "nr {nr}");
        }
        assert_eq!(evaluate(&filter, ARCH, SYS_seccomp as u32, [0; 6]), EPERM_ACTION);
        for nr in [SYS_clone3, SYS_openat2] {
            assert_eq!(evaluate(&filter, ARCH, nr as u32, [0; 6]), ENOSYS_ACTION);
        }
        for nr in [SYS_openat, SYS_write, SYS_getpid, SYS_execve, SYS_close] {
            assert_eq!(evaluate(&filter, ARCH, nr as u32, [0; 6]), SECCOMP_RET_ALLOW);
        }
    }

    #[test]
    fn prctl_set_seccomp_is_denied_but_other_options_are_allowed() {
        let filter = deny_filter().unwrap();
        assert_eq!(
            evaluate(&filter, ARCH, SYS_prctl as u32, [PR_SET_SECCOMP as u64, 0, 0, 0, 0, 0]),
            EPERM_ACTION
        );
        assert_eq!(
            evaluate(&filter, ARCH, SYS_prctl as u32, [PR_SET_NO_NEW_PRIVS as u64, 0, 0, 0, 0, 0]),
            SECCOMP_RET_ALLOW
        );
    }

    #[test]
    fn classify_install_result_rejects_unsynchronized_thread() {
        assert!(classify_install_result(0, 0).is_ok());
        assert_eq!(classify_install_result(-1, EACCES).unwrap_err().raw_os_error(), Some(EACCES));
        let error = classify_install_result(4242, 0).unwrap_err();
        assert!(error.to_string().contains("thread 4242 not synchronized"));
    }

    #[test]
    fn clone_checks_every_namespace_bit_and_high_word() {
        let filter = deny_filter().unwrap();
        for flags in [
            CLONE_NEWNS as u64,
            CLONE_NEWUTS as u64,
            CLONE_NEWIPC as u64,
            CLONE_NEWUSER as u64,
            CLONE_NEWPID as u64,
            CLONE_NEWNET as u64,
            CLONE_NEWCGROUP as u64,
            CLONE_NEWTIME as u64,
            1u64 << 32,
            1u64 << 63,
        ] {
            assert_eq!(
                evaluate(&filter, ARCH, SYS_clone as u32, [flags, 0, 0, 0, 0, 0]),
                EPERM_ACTION
            );
        }
        for flags in [SIGCHLD, CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD] {
            assert_eq!(
                evaluate(&filter, ARCH, SYS_clone as u32, [flags as u64, 0, 0, 0, 0, 0]),
                SECCOMP_RET_ALLOW
            );
        }
    }

    #[test]
    fn supervisor_filter_notifies_write_opens_and_preserves_denials() {
        let program = super::filter(true).unwrap();
        for (nr, flag_arg) in [
            (SYS_openat, 2),
            #[cfg(target_arch = "x86_64")]
            (SYS_open, 1),
        ] {
            for flags in
                [O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, O_APPEND, O_TMPFILE, O_TMPFILE | O_RDWR]
            {
                let mut args = [0; 6];
                args[flag_arg] = flags as u64;
                assert_eq!(evaluate(&program, ARCH, nr as u32, args), SECCOMP_RET_USER_NOTIF);
                assert_eq!(
                    evaluate(&super::filter(false).unwrap(), ARCH, nr as u32, args),
                    SECCOMP_RET_ALLOW
                );
            }
            for flags in [O_RDONLY, O_RDONLY | O_CLOEXEC, O_RDONLY | O_DIRECTORY, O_PATH] {
                let mut args = [0; 6];
                args[flag_arg] = flags as u64;
                assert_eq!(evaluate(&program, ARCH, nr as u32, args), SECCOMP_RET_ALLOW);
            }
        }
        #[cfg(target_arch = "x86_64")]
        assert_eq!(evaluate(&program, ARCH, SYS_creat as u32, [0; 6]), SECCOMP_RET_USER_NOTIF);
        for nr in deny_syscalls() {
            assert_eq!(evaluate(&program, ARCH, nr, [0; 6]), EPERM_ACTION);
        }
        assert_eq!(
            evaluate(&program, ARCH ^ 1, SYS_openat as u32, [0; 6]),
            SECCOMP_RET_KILL_PROCESS
        );
        assert_eq!(evaluate(&program, ARCH, SYS_openat2 as u32, [0; 6]), ENOSYS_ACTION);
        assert_eq!(
            evaluate(&program, ARCH, SYS_prctl as u32, [PR_SET_SECCOMP as u64, 0, 0, 0, 0, 0]),
            EPERM_ACTION
        );
        // Argument checks must restore the syscall accumulator before falling
        // through, even when a prctl option numerically resembles an open.
        assert_eq!(
            evaluate(
                &program,
                ARCH,
                SYS_prctl as u32,
                [SYS_openat as u64, 0, O_WRONLY as u64, 0, 0, 0]
            ),
            SECCOMP_RET_ALLOW
        );
        #[cfg(target_arch = "x86_64")]
        assert_eq!(
            evaluate(
                &program,
                ARCH,
                0x4000_0000 | SYS_openat as u32,
                [0, 0, O_WRONLY as u64, 0, 0, 0]
            ),
            SECCOMP_RET_KILL_PROCESS
        );
    }

    #[test]
    fn review_creators_notify_on_both_architectures() {
        let program = super::filter(true).unwrap();
        #[allow(unused_mut)]
        let mut numbers = vec![SYS_mkdirat, SYS_mknodat, SYS_symlinkat];
        #[cfg(target_arch = "x86_64")]
        numbers.extend([SYS_mkdir, SYS_mknod, SYS_symlink]);
        for nr in numbers {
            assert_eq!(evaluate(&program, ARCH, nr as u32, [0; 6]), SECCOMP_RET_USER_NOTIF);
        }
        assert_eq!(evaluate(&program, ARCH, SYS_linkat as u32, [0; 6]), EPERM_ACTION);
    }

    #[test]
    fn mutation_filter_notifies_every_name_and_metadata_operation() {
        let notify = super::filter(true).unwrap();
        let deny_only = super::filter(false).unwrap();
        // New syscall numbers are shared by x86_64 and aarch64; this libc
        // version does not expose all three constants on both architectures.
        for nr in [
            SYS_renameat,
            SYS_renameat2,
            SYS_unlinkat,
            SYS_truncate,
            SYS_fchmodat,
            452, /* fchmodat2 */
            SYS_fchownat,
            SYS_utimensat,
            SYS_setxattr,
            SYS_lsetxattr,
            SYS_removexattr,
            SYS_lremovexattr,
            463, /* setxattrat */
            466, /* removexattrat */
            SYS_fchmod,
            SYS_fchown,
            SYS_fsetxattr,
            SYS_fremovexattr,
            SYS_ftruncate,
            #[cfg(target_arch = "x86_64")]
            SYS_rename,
            #[cfg(target_arch = "x86_64")]
            SYS_unlink,
            #[cfg(target_arch = "x86_64")]
            SYS_rmdir,
            #[cfg(target_arch = "x86_64")]
            SYS_chmod,
            #[cfg(target_arch = "x86_64")]
            SYS_chown,
            #[cfg(target_arch = "x86_64")]
            SYS_lchown,
            #[cfg(target_arch = "x86_64")]
            SYS_utime,
            #[cfg(target_arch = "x86_64")]
            SYS_utimes,
            #[cfg(target_arch = "x86_64")]
            SYS_futimesat,
        ] {
            assert_eq!(
                evaluate(&notify, ARCH, nr as u32, [0; 6]),
                SECCOMP_RET_USER_NOTIF,
                "nr {nr}"
            );
            assert_eq!(evaluate(&deny_only, ARCH, nr as u32, [0; 6]), SECCOMP_RET_ALLOW, "nr {nr}");
        }
        for nr in [
            SYS_linkat,
            #[cfg(target_arch = "x86_64")]
            SYS_link,
        ] {
            assert_eq!(evaluate(&notify, ARCH, nr as u32, [0; 6]), EPERM_ACTION);
        }
    }

    #[test]
    fn socket_domains_protocols_and_socketpair_types() {
        let filter = deny_filter().unwrap();
        for (domain, protocol, expected) in [
            (AF_INET, 0, SECCOMP_RET_ALLOW),
            (AF_INET6, 0, SECCOMP_RET_ALLOW),
            (AF_NETLINK, NETLINK_ROUTE, SECCOMP_RET_ALLOW),
            (AF_NETLINK, NETLINK_KOBJECT_UEVENT, EPERM_ACTION),
            (AF_UNIX, 0, EPERM_ACTION),
            (AF_PACKET, 0, EPERM_ACTION),
            (AF_VSOCK, 0, EPERM_ACTION),
            (-1, 0, EPERM_ACTION),
        ] {
            for high in [0, 1u64 << 32] {
                assert_eq!(
                    evaluate(
                        &filter,
                        ARCH,
                        SYS_socket as u32,
                        [high | domain as u32 as u64, SOCK_STREAM as u64, protocol as u64, 0, 0, 0]
                    ),
                    expected
                );
            }
        }
        for domain in [AF_UNIX, AF_INET, AF_INET6, AF_NETLINK] {
            for kind in [SOCK_STREAM, SOCK_SEQPACKET, SOCK_DGRAM, SOCK_RAW, 0] {
                for flags in [0, SOCK_CLOEXEC | SOCK_NONBLOCK] {
                    let expected =
                        if domain == AF_UNIX && matches!(kind, SOCK_STREAM | SOCK_SEQPACKET) {
                            SECCOMP_RET_ALLOW
                        } else {
                            EPERM_ACTION
                        };
                    assert_eq!(
                        evaluate(
                            &filter,
                            ARCH,
                            SYS_socketpair as u32,
                            [domain as u64, (kind | flags) as u64, 0, 0, 0, 0]
                        ),
                        expected
                    );
                }
            }
        }
    }

    /// The child uses only raw libc calls after installation, then _exit;
    /// its five-second SIGALRM bounds execution. All tables are finite.
    unsafe fn child_checks() -> i32 {
        // SAFETY: syscall pointer arguments are valid for the indicated calls;
        // rejected calls deliberately use null arguments and must return EPERM
        // before the kernel dereferences them. No Rust allocation or unwinding.
        unsafe {
            macro_rules! require {
                ($condition:expr, $code:expr) => {
                    if !$condition {
                        return $code;
                    }
                };
            }
            require!(socket(AF_UNIX, SOCK_STREAM, 0) == -1 && *__errno_location() == EPERM, 10);
            require!(
                syscall(SYS_seccomp, SECCOMP_GET_ACTION_AVAIL, 0usize, 0usize) == -1
                    && *__errno_location() == EPERM,
                33
            );
            require!(
                syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0usize, 0usize) == -1
                    && *__errno_location() == EPERM,
                35
            );
            require!(
                syscall(SYS_prctl, PR_SET_SECCOMP as c_long, 2, 0usize, 0usize, 0usize) == -1
                    && *__errno_location() == EPERM,
                34
            );
            let inet = socket(AF_INET, SOCK_STREAM, 0);
            require!(inet >= 0, 11);
            let route = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
            require!(route >= 0, 12);
            close(route);
            require!(
                socket(AF_NETLINK, SOCK_RAW, NETLINK_KOBJECT_UEVENT) == -1
                    && *__errno_location() == EPERM,
                13
            );
            let mut pair = [-1; 2];
            for kind in [SOCK_STREAM, SOCK_SEQPACKET | SOCK_CLOEXEC] {
                require!(socketpair(AF_UNIX, kind, 0, pair.as_mut_ptr()) == 0, 14);
                close(pair[0]);
                close(pair[1]);
            }
            require!(
                socketpair(AF_UNIX, SOCK_DGRAM, 0, pair.as_mut_ptr()) == -1
                    && *__errno_location() == EPERM,
                15
            );
            require!(bind(inet, std::ptr::null(), 0) == -1 && *__errno_location() == EPERM, 16);
            require!(listen(inet, 1) == -1 && *__errno_location() == EPERM, 17);
            close(inet);
            for (index, (nr, arg0, errno)) in [
                (SYS_linkat, 0, EPERM),
                (SYS_io_uring_setup, 0, EPERM),
                (SYS_keyctl, 0, EPERM),
                (SYS_ptrace, PTRACE_TRACEME as c_long, EPERM),
                (SYS_unshare, CLONE_NEWUSER as c_long, EPERM),
                (SYS_clone3, 0, ENOSYS),
                (SYS_openat2, 0, ENOSYS),
            ]
            .iter()
            .enumerate()
            {
                require!(
                    syscall(*nr, *arg0, 0usize, 0usize, 0usize, 0usize, 0usize) == -1
                        && *__errno_location() == *errno,
                    20 + index as i32
                );
            }
            let fd = openat(AT_FDCWD, c"/dev/null".as_ptr(), O_WRONLY | O_CLOEXEC);
            require!(fd >= 0, 30);
            require!(write(fd, c"x".as_ptr().cast(), 1) == 1, 31);
            close(fd);
            require!(getpid() > 0, 32);
            0
        }
    }

    /// waitpid retries EINTR until the child exits (bounded by its alarm),
    /// or an unrecoverable wait error occurs; the parent never installs a filter.
    #[test]
    fn installed_filter_enforces_syscalls_in_forked_child() {
        let filter = deny_filter().unwrap();
        // SAFETY: filter allocation precedes fork. The child only calls the
        // syscall-only installer/raw libc checks and _exit, never the test harness.
        let pid = unsafe { fork() };
        assert!(pid >= 0, "fork failed: {}", io::Error::last_os_error());
        if pid == 0 {
            unsafe {
                let mut empty: sigset_t = std::mem::zeroed();
                sigemptyset(&mut empty);
                sigprocmask(SIG_SETMASK, &empty, std::ptr::null_mut());
                signal(SIGALRM, SIG_DFL);
                alarm(5);
                if install(&filter).is_err() {
                    _exit(1);
                }
                _exit(child_checks());
            }
        }
        let mut status = 0;
        loop {
            let result = unsafe { waitpid(pid, &mut status, 0) };
            if result == pid {
                break;
            }
            assert!(
                result == -1 && io::Error::last_os_error().raw_os_error() == Some(EINTR),
                "waitpid failed"
            );
        }
        assert!(WIFEXITED(status), "child terminated by signal: status {status:#x}");
        assert_eq!(WEXITSTATUS(status), 0, "child check failed (1 = install; 10..32 = syscall)");
    }
}
