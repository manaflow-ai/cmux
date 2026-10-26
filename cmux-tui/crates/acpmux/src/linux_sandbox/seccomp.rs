//! Syscall boundary, staged independently of Linux sandbox activation.
//! Part E will stack a separate USER_NOTIF filter with NEW_LISTENER; D's
//! deny filter must never return USER_NOTIF or request a listener.

// No production caller until the init helper lands.
#![allow(dead_code)]

use std::io;

pub(crate) fn deny_filter() -> Result<Vec<libc::sock_filter>, String> {
    Err("seccomp deny filter not implemented".into())
}

pub(crate) fn install(_filter: &[libc::sock_filter]) -> io::Result<()> {
    Err(io::Error::from_raw_os_error(libc::ENOSYS))
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
        for nr in [SYS_clone3, SYS_openat2] {
            assert_eq!(evaluate(&filter, ARCH, nr as u32, [0; 6]), ENOSYS_ACTION);
        }
        for nr in [SYS_openat, SYS_write, SYS_getpid, SYS_execve, SYS_close] {
            assert_eq!(evaluate(&filter, ARCH, nr as u32, [0; 6]), SECCOMP_RET_ALLOW);
        }
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
