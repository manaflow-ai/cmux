//! macOS host measurements for the RFD 0050 duress leg.

use super::*;

pub(super) const LEG: &str = "rfd0050";
pub(super) const BROKER_SECS: u64 = 100;
pub(super) const WINDOW_MIN: Duration = Duration::from_secs(BROKER_SECS + 40);
const HOLD_PCT: u64 = 90;
const RAM_HEADROOM: u64 = 512 << 20;

pub(super) fn cpu_loops(cores: usize) -> usize {
    (cores * HOLD_PCT as usize).div_ceil(100).max(1)
}

fn total_memory() -> Option<u64> {
    let mut value = 0u64;
    let mut len = std::mem::size_of::<u64>();
    let name = std::ffi::CString::new("hw.memsize").ok()?;
    // SAFETY: all pointers identify writable buffers for the requested sysctl value.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            &mut value as *mut _ as *mut libc::c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && len == std::mem::size_of::<u64>()).then_some(value)
}

fn vm_stat() -> Option<(u64, u64)> {
    let output = std::process::Command::new("/usr/bin/vm_stat").output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let page_size = text
        .lines()
        .find_map(|line| line.split_whitespace().find_map(|part| part.parse::<u64>().ok()))?;
    let mut used_pages = 0u64;
    let mut free_pages = 0u64;
    for line in text.lines() {
        let pages = line
            .split_once(':')
            .and_then(|(_, value)| value.trim().trim_end_matches('.').parse::<u64>().ok())
            .unwrap_or(0);
        if line.starts_with("Pages free") || line.starts_with("Pages speculative") {
            free_pages += pages;
        } else if line.starts_with("Pages active")
            || line.starts_with("Pages wired")
            || line.starts_with("Pages occupied by compressor")
        {
            used_pages += pages;
        }
    }
    Some((used_pages.saturating_mul(page_size), free_pages.saturating_mul(page_size)))
}

pub(super) fn mem_used_pct() -> Option<f64> {
    let total = total_memory()?;
    let (used, _) = vm_stat()?;
    Some(used as f64 * 100.0 / total.max(1) as f64)
}

pub(super) fn hog_bytes() -> Option<u64> {
    let total = total_memory()?;
    let (used, free) = vm_stat()?;
    let want = (total / 100 * HOLD_PCT).saturating_sub(used);
    Some(want.min(free.saturating_sub(RAM_HEADROOM)))
}

pub(super) fn hog_script(bytes: u64) -> String {
    format!(
        "exec python3 -c 'import time\nchunks=[]\nleft={bytes}\nwhile left>0:\n n=min(left,64<<20)\n b=bytearray(n)\n b[::4096]=b\"\\x01\"*len(range(0,n,4096))\n chunks.append(b)\n left-=n\nwhile True:\n time.sleep(2)\n for b in chunks:\n  b[::4096]=b\"\\x02\"*len(range(0,len(b),4096))\n'"
    )
}

pub(super) fn cpu_jiffies() -> Option<(u64, u64)> {
    let mut count = 0u32;
    let mut info: *mut libc::c_int = std::ptr::null_mut();
    // SAFETY: mach_host_self is valid for this process and the kernel allocates `info`.
    let kr = unsafe {
        libc::host_processor_info(
            libc::mach_host_self(),
            libc::PROCESSOR_CPU_LOAD_INFO,
            &mut count,
            &mut info,
        )
    };
    if kr != libc::KERN_SUCCESS || info.is_null() {
        return None;
    }
    let values =
        unsafe { std::slice::from_raw_parts(info, count as usize * libc::CPU_STATE_MAX as usize) };
    let mut busy = 0u64;
    let mut total = 0u64;
    for cpu in values.chunks_exact(libc::CPU_STATE_MAX as usize) {
        let user = cpu[libc::CPU_STATE_USER as usize] as u64;
        let system = cpu[libc::CPU_STATE_SYSTEM as usize] as u64;
        let nice = cpu[libc::CPU_STATE_NICE as usize] as u64;
        let idle = cpu[libc::CPU_STATE_IDLE as usize] as u64;
        busy += user + system + nice;
        total += user + system + nice + idle;
    }
    // SAFETY: the kernel returned this array and its byte size is count * CPU_STATE_MAX.
    unsafe {
        libc::vm_deallocate(
            libc::mach_task_self(),
            info as libc::vm_address_t,
            (values.len() * std::mem::size_of::<libc::c_int>()) as libc::vm_size_t,
        );
    }
    Some((busy, total))
}

pub(super) fn busy_pct(a: Option<(u64, u64)>, b: Option<(u64, u64)>) -> Option<f64> {
    let ((b0, t0), (b1, t1)) = (a?, b?);
    (t1 > t0).then(|| (b1 - b0) as f64 * 100.0 / (t1 - t0) as f64)
}

pub(super) fn relay_ls_body() -> String {
    format!("#!/bin/sh\nsleep {BROKER_SECS}\necho '{{\"sessions\":[]}}'\n")
}
