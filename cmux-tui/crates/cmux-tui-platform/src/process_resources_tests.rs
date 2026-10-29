//! The memory footprint `memory-report` reads for the daemon itself.

use super::*;

const STATUS: &str = "Name:\tcmux-tui\nUmask:\t0022\nVmPeak:\t  912340 kB\n\
VmRSS:\t   81920 kB\nRssAnon:\t   61440 kB\nRssFile:\t   20480 kB\nRssShmem:\t       0 kB\n\
VmSwap:\t    2048 kB\nThreads:\t12\n";

#[test]
fn proc_status_footprint_is_anonymous_resident_plus_swap() {
    let footprint = parse_proc_status_footprint(STATUS).unwrap();
    assert_eq!(footprint.private_footprint_bytes, (61_440 + 2_048) * 1024);
    assert_eq!(footprint.resident_bytes, 81_920 * 1024);
}

#[test]
fn proc_status_without_swap_counts_no_swap() {
    let status = STATUS.replace("VmSwap:\t    2048 kB\n", "");
    let footprint = parse_proc_status_footprint(&status).unwrap();
    assert_eq!(footprint.private_footprint_bytes, 61_440 * 1024);
}

#[test]
fn proc_status_of_a_kernel_thread_has_no_footprint() {
    assert_eq!(parse_proc_status_footprint("Name:\tkthreadd\nThreads:\t1\n"), None);
    // `RssAnonymous` is not `RssAnon`.
    assert_eq!(parse_proc_status_footprint("VmRSS:\t1 kB\nRssAnonymous:\t1 kB\n"), None);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn own_footprint_is_read_on_this_platform() {
    let footprint = own_memory_footprint().expect("this platform reports a footprint");
    assert!(footprint.resident_bytes > 0, "{footprint:?}");
    assert!(footprint.private_footprint_bytes > 0, "{footprint:?}");
}
