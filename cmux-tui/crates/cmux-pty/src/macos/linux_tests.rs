use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};

use super::{DescriptorCleanup, mark_inherited_descriptors_close_on_exec};

#[test]
fn oversized_descriptor_limit_fails_without_scanning_when_fast_paths_are_unavailable() {
    const CHILD_ENV: &str = "CMUX_PTY_HIGH_FD_FALLBACK_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg(
                    "macos::linux_tests::oversized_descriptor_limit_fails_without_scanning_when_fast_paths_are_unavailable",
                )
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .output()
                .unwrap();
        assert!(
            output.status.success(),
            "PTY fallback scanned an oversized descriptor table:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let source = File::open("/dev/null").unwrap();
    let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
    assert!(descriptor >= 200);
    let _inherited = unsafe { File::from_raw_fd(descriptor) };
    install_close_range_openat_and_fcntl_eperm_filter();

    let mut cleanup = DescriptorCleanup::new(1_048_576);
    let error = mark_inherited_descriptors_close_on_exec(&mut cleanup)
        .expect_err("oversized descriptor table should fail before an individual scan");
    assert_eq!(error.raw_os_error(), Some(libc::EOVERFLOW));
}

#[test]
fn close_range_fallback_enumerates_the_child_descriptor_table() {
    const CHILD_ENV: &str = "CMUX_PTY_CHILD_FD_TABLE_SECCOMP_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("macos::linux_tests::close_range_fallback_enumerates_the_child_descriptor_table")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "PTY fallback inspected the parent's descriptor table:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    install_close_range_eperm_filter();
    let source = File::open("/dev/null").unwrap();
    let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
    assert!(descriptor >= 200);
    let inherited = unsafe { File::from_raw_fd(descriptor) };
    let mut cleanup = DescriptorCleanup::new(unsafe { libc::getdtablesize() });
    let mut child_ready = [-1; 2];
    let mut parent_ready = [-1; 2];
    assert_eq!(unsafe { libc::pipe2(child_ready.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
    assert_eq!(unsafe { libc::pipe2(parent_ready.as_mut_ptr(), libc::O_CLOEXEC) }, 0);

    let child = unsafe { libc::fork() };
    assert!(child >= 0, "fork failed: {}", io::Error::last_os_error());
    if child == 0 {
        unsafe {
            libc::close(child_ready[0]);
            libc::close(parent_ready[1]);
            let marker = [1_u8];
            if libc::write(child_ready[1], marker.as_ptr().cast(), marker.len()) != 1 {
                libc::_exit(2);
            }
            let mut acknowledgement = [0_u8];
            if libc::read(
                parent_ready[0],
                acknowledgement.as_mut_ptr().cast(),
                acknowledgement.len(),
            ) != 1
            {
                libc::_exit(3);
            }
        }
        let marked = mark_inherited_descriptors_close_on_exec(&mut cleanup).is_ok_and(|_| unsafe {
            let flags = libc::fcntl(descriptor, libc::F_GETFD);
            flags != -1 && flags & libc::FD_CLOEXEC != 0
        });
        unsafe { libc::_exit(if marked { 0 } else { 4 }) };
    }

    unsafe {
        libc::close(child_ready[1]);
        libc::close(parent_ready[0]);
    }
    let mut marker = [0_u8];
    assert_eq!(unsafe { libc::read(child_ready[0], marker.as_mut_ptr().cast(), marker.len()) }, 1);
    drop(inherited);
    assert_eq!(unsafe { libc::write(parent_ready[1], marker.as_ptr().cast(), marker.len()) }, 1);
    let mut status = 0;
    assert_eq!(unsafe { libc::waitpid(child, &mut status, 0) }, child);
    assert_eq!(status, 0, "child descriptor cleanup exited with wait status {status}");
}

fn install_close_range_eperm_filter() {
    let mut filter = [
        libc::sock_filter {
            code: (libc::BPF_LD | libc::BPF_W | libc::BPF_ABS) as u16,
            jt: 0,
            jf: 0,
            k: 0,
        },
        libc::sock_filter {
            code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
            jt: 0,
            jf: 1,
            k: libc::SYS_close_range as u32,
        },
        libc::sock_filter {
            code: (libc::BPF_RET | libc::BPF_K) as u16,
            jt: 0,
            jf: 0,
            k: libc::SECCOMP_RET_ERRNO | libc::EPERM as u32,
        },
        libc::sock_filter {
            code: (libc::BPF_RET | libc::BPF_K) as u16,
            jt: 0,
            jf: 0,
            k: libc::SECCOMP_RET_ALLOW,
        },
    ];
    let program = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };

    let no_new_privileges = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    assert_eq!(no_new_privileges, 0, "PR_SET_NO_NEW_PRIVS failed: {}", io::Error::last_os_error());
    let installed = unsafe {
        libc::prctl(
            libc::PR_SET_SECCOMP,
            libc::SECCOMP_MODE_FILTER,
            &program as *const libc::sock_fprog,
        )
    };
    assert_eq!(installed, 0, "seccomp filter installation failed: {}", io::Error::last_os_error());
}

fn install_close_range_openat_and_fcntl_eperm_filter() {
    let mut filter = [
        libc::sock_filter {
            code: (libc::BPF_LD | libc::BPF_W | libc::BPF_ABS) as u16,
            jt: 0,
            jf: 0,
            k: 0,
        },
        libc::sock_filter {
            code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
            jt: 2,
            jf: 0,
            k: libc::SYS_close_range as u32,
        },
        libc::sock_filter {
            code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
            jt: 1,
            jf: 0,
            k: libc::SYS_openat as u32,
        },
        libc::sock_filter {
            code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
            jt: 0,
            jf: 1,
            k: libc::SYS_fcntl as u32,
        },
        libc::sock_filter {
            code: (libc::BPF_RET | libc::BPF_K) as u16,
            jt: 0,
            jf: 0,
            k: libc::SECCOMP_RET_ERRNO | libc::EPERM as u32,
        },
        libc::sock_filter {
            code: (libc::BPF_RET | libc::BPF_K) as u16,
            jt: 0,
            jf: 0,
            k: libc::SECCOMP_RET_ALLOW,
        },
    ];
    let program = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };

    let no_new_privileges = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    assert_eq!(no_new_privileges, 0, "PR_SET_NO_NEW_PRIVS failed: {}", io::Error::last_os_error());
    let installed = unsafe {
        libc::prctl(
            libc::PR_SET_SECCOMP,
            libc::SECCOMP_MODE_FILTER,
            &program as *const libc::sock_fprog,
        )
    };
    assert_eq!(installed, 0, "seccomp filter installation failed: {}", io::Error::last_os_error());
}
