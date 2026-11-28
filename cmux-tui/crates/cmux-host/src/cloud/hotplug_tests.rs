use super::hotplug::{Onlined, online_hot_added, parse_cpu_list};
use std::fs;
use std::path::Path;

fn put(root: &Path, rel: &str, text: &str) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, text).unwrap();
}

fn read(root: &Path, rel: &str) -> String {
    fs::read_to_string(root.join(rel)).unwrap()
}

#[test]
fn the_kernel_cpu_list_parses() {
    assert_eq!(parse_cpu_list("2-4,7\n"), vec![2, 3, 4, 7]);
    assert_eq!(parse_cpu_list("\n"), Vec::<u32>::new());
    assert_eq!(parse_cpu_list("5"), vec![5]);
    assert_eq!(parse_cpu_list("x,1-y,3"), vec![3]);
}

/// A grow's hot-added vCPUs and the memory switch: the present offline vCPUs go online, one not
/// present (no directory) is left, and the kernel takes over memory blocks.
#[test]
fn a_grow_comes_online_without_udev() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    put(root, "sys/devices/system/memory/auto_online_blocks", "offline\n");
    put(root, "sys/devices/system/cpu/offline", "2-3,9\n");
    put(root, "sys/devices/system/cpu/cpu2/online", "0\n");
    put(root, "sys/devices/system/cpu/cpu3/online", "0\n");
    let done = online_hot_added(root);
    assert_eq!(done, Onlined { memory_auto_online: true, cpus: vec![2, 3], failed: vec![] });
    assert_eq!(read(root, "sys/devices/system/memory/auto_online_blocks"), "online");
    assert_eq!(read(root, "sys/devices/system/cpu/cpu2/online"), "1");
    assert_eq!(read(root, "sys/devices/system/cpu/cpu3/online"), "1");
}

/// Nothing offline: nothing written, so a steady machine's probe only reads.
#[test]
fn a_steady_machine_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    put(root, "sys/devices/system/memory/auto_online_blocks", "online\n");
    put(root, "sys/devices/system/cpu/offline", "\n");
    put(root, "sys/devices/system/cpu/cpu1/online", "1\n");
    assert_eq!(online_hot_added(root), Onlined::default());
    assert_eq!(read(root, "sys/devices/system/memory/auto_online_blocks"), "online\n");
    assert_eq!(read(root, "sys/devices/system/cpu/cpu1/online"), "1\n");
}

/// A kernel without the files (or not Linux sysfs at all): a pass does nothing.
#[test]
fn missing_files_do_nothing() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(online_hot_added(dir.path()), Onlined::default());
}
