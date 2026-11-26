//! Native counters for the shared duress benchmark. No shell sampling under load.
use super::*;
use std::mem::{size_of, zeroed};

fn host() -> libc::host_t {
    // Keep one send right for the lifetime of this benchmark, not one per sample.
    static HOST: std::sync::OnceLock<libc::host_t> = std::sync::OnceLock::new();
    *HOST.get_or_init(|| unsafe { libc::mach_host_self() })
}

pub(super) fn cpu_jiffies() -> Option<(u64, u64)> {
    // SAFETY: a correctly sized writable HOST_CPU_LOAD_INFO buffer.
    let mut info: libc::host_cpu_load_info = unsafe { zeroed() };
    let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
    let rc = unsafe {
        libc::host_statistics(
            host(),
            libc::HOST_CPU_LOAD_INFO,
            (&mut info as *mut libc::host_cpu_load_info).cast(),
            &mut count,
        )
    };
    if rc != 0 || count != libc::HOST_CPU_LOAD_INFO_COUNT {
        return None;
    }
    let total = info.cpu_ticks.iter().map(|v| u64::from(*v)).sum::<u64>();
    Some((total - u64::from(info.cpu_ticks[libc::CPU_STATE_IDLE as usize]), total))
}

/// Physical RAM and reclaimable bytes. Unlike Linux MemAvailable, this is free + inactive.
/// Do not add purgeable/speculative counts: those overlap other VM page categories.
pub(super) fn memory() -> Option<(u64, u64)> {
    let mut total = 0u64;
    let mut len = size_of::<u64>();
    // SAFETY: NUL-terminated sysctl key and a writable u64 with its actual size.
    let rc = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&mut total as *mut u64).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 || total == 0 || len != size_of::<u64>() {
        return None;
    }
    // SAFETY: the VM statistics buffer and count agree with the SDK layout.
    let mut vm: libc::vm_statistics64 = unsafe { zeroed() };
    let mut count = libc::HOST_VM_INFO64_COUNT;
    let rc = unsafe {
        libc::host_statistics64(
            host(),
            libc::HOST_VM_INFO64,
            (&mut vm as *mut libc::vm_statistics64).cast(),
            &mut count,
        )
    };
    if rc != 0 {
        return None;
    }
    // SAFETY: sysconf reads the host's page-size constant (16 KiB on Apple Silicon).
    let page = u64::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).ok()?;
    let available = (u64::from(vm.free_count) + u64::from(vm.inactive_count)) * page;
    Some((total, available.min(total)))
}

fn bsd_info(pid: i32) -> Option<libc::proc_bsdinfo> {
    // SAFETY: the flavor and size name exactly this output type.
    let mut info: libc::proc_bsdinfo = unsafe { zeroed() };
    let size = size_of::<libc::proc_bsdinfo>() as i32;
    let got = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    (got == size).then_some(info)
}

pub(super) fn procs() -> Vec<(i32, Vec<String>)> {
    // SAFETY: the first call sizes a subsequent writable pid buffer. A fork storm may grow it.
    let estimated = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    assert!(estimated > 0, "cannot enumerate Mac processes; cleanup cannot be verified");
    let mut pids = vec![0i32; estimated as usize + 1024];
    loop {
        let count = unsafe {
            libc::proc_listallpids(pids.as_mut_ptr().cast(), (pids.len() * size_of::<i32>()) as i32)
        };
        assert!(count > 0, "cannot enumerate Mac processes; cleanup cannot be verified");
        if (count as usize) < pids.len() {
            pids.truncate(count as usize);
            break;
        }
        assert!(pids.len() < 1_000_000, "process enumeration did not converge");
        pids.resize(pids.len() * 2, 0);
    }
    pids.into_iter()
        .filter_map(|pid| {
            let p = bsd_info(pid)?;
            // Shared code consumes only state, ppid and pgrp, in /proc/stat field order.
            // Darwin SZOMB is 5 (sys/proc.h).
            Some((
                pid,
                vec![
                    if p.pbi_status == 5 { "Z" } else { "R" }.into(),
                    p.pbi_ppid.to_string(),
                    p.pbi_pgid.to_string(),
                ],
            ))
        })
        .collect()
}

fn task_info(pid: u32) -> Option<libc::proc_taskinfo> {
    // SAFETY: the flavor and size name exactly this output type.
    let mut info: libc::proc_taskinfo = unsafe { zeroed() };
    let size = size_of::<libc::proc_taskinfo>() as i32;
    let got = unsafe {
        libc::proc_pidinfo(
            pid as i32,
            libc::PROC_PIDTASKINFO,
            0,
            (&mut info as *mut libc::proc_taskinfo).cast(),
            size,
        )
    };
    (got == size).then_some(info)
}

pub(super) fn cpu_secs(pid: u32) -> Option<f64> {
    let p = task_info(pid)?;
    Some((p.pti_total_user + p.pti_total_system) as f64 / 1e9)
}

pub(super) fn rss_kib(pid: u32) -> Option<u64> {
    Some(task_info(pid)?.pti_resident_size / 1024)
}

pub(super) fn harness_in(cwd: &Path) -> Option<i32> {
    use std::os::unix::ffi::OsStrExt;
    let want = std::fs::canonicalize(cwd).ok()?;
    procs().into_iter().map(|(pid, _)| pid).find(|pid| {
        // Match only a Python process in the unique work directory this bench owns.
        let mut executable = [0u8; 4096];
        let n = unsafe {
            libc::proc_pidpath(*pid, executable.as_mut_ptr().cast(), executable.len() as u32)
        };
        if n <= 0 || !String::from_utf8_lossy(&executable).to_ascii_lowercase().contains("python") {
            return false;
        }
        let mut paths: libc::proc_vnodepathinfo = unsafe { zeroed() };
        let size = size_of::<libc::proc_vnodepathinfo>() as i32;
        let got = unsafe {
            libc::proc_pidinfo(
                *pid,
                libc::PROC_PIDVNODEPATHINFO,
                0,
                (&mut paths as *mut libc::proc_vnodepathinfo).cast(),
                size,
            )
        };
        if got != size {
            return false;
        }
        let bytes: Vec<u8> = paths
            .pvi_cdir
            .vip_path
            .iter()
            .flatten()
            .take_while(|c| **c != 0)
            .map(|c| *c as u8)
            .collect();
        want.as_os_str().as_bytes() == bytes
    })
}

#[test]
fn mac_duress_counters_and_owned_process_are_readable() {
    let (total, avail) = memory().expect("Mac VM counters");
    assert!(total > 0 && avail <= total);
    let (busy, total) = cpu_jiffies().expect("Mac CPU counters");
    assert!(total > 0 && busy <= total);
    let own = std::process::id();
    assert!(procs().iter().any(|(pid, _)| *pid == own as i32));
    assert!(rss_kib(own).is_some_and(|v| v > 0));
    assert!(cpu_secs(own).is_some());
}
