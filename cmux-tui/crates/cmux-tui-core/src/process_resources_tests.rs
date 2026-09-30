//! Unit tests for the pure process-tree walk and the platform readers.

use super::*;

fn index(pairs: &[(u32, u32)]) -> ChildIndex {
    ChildIndex::from_ppid_map(&pairs.iter().copied().collect())
}

fn pids(tree: &ProcessTree) -> Vec<u32> {
    tree.nodes.iter().map(|node| node.pid).collect()
}

#[test]
fn cmux_next_process_tree_lists_root_then_descendants_breadth_first() {
    // 10 -> {11, 12}, 11 -> {13}, 12 -> {14, 15}; 99 is unrelated.
    let children = index(&[(11, 10), (12, 10), (13, 11), (14, 12), (15, 12), (99, 1)]);
    let tree = walk_tree(10, 512, |pid| children.children(pid));
    assert_eq!(pids(&tree), vec![10, 11, 12, 13, 14, 15]);
    assert!(!tree.truncated);
    assert_eq!(tree.nodes[0].parent, None);
    assert_eq!(tree.nodes[3], TreeNode { pid: 13, parent: Some(11) });
    assert_eq!(tree.nodes[5], TreeNode { pid: 15, parent: Some(12) });
}

#[test]
fn cmux_next_process_tree_reports_each_pid_once() {
    // A children function that repeats pids, as a racy platform listing
    // can: 11 is listed twice and 12 is listed under two parents.
    let tree = walk_tree(10, 512, |pid| match pid {
        10 => vec![11, 11, 12],
        11 => vec![12, 13],
        _ => Vec::new(),
    });
    assert_eq!(pids(&tree), vec![10, 11, 12, 13]);
}

#[test]
fn cmux_next_process_tree_survives_pid_cycles() {
    // 10 -> 11 -> 12 -> 10 (a reused pid can close a cycle), and a
    // self-parented pid.
    let children = index(&[(11, 10), (12, 11), (10, 12), (20, 20)]);
    let tree = walk_tree(10, 512, |pid| children.children(pid));
    assert_eq!(pids(&tree), vec![10, 11, 12]);
    assert!(!tree.truncated);
    let tree = walk_tree(20, 512, |pid| children.children(pid));
    assert_eq!(pids(&tree), vec![20]);
}

#[test]
fn cmux_next_process_tree_caps_and_reports_truncation() {
    // Root 1 with 600 children.
    let pairs: Vec<(u32, u32)> = (2..602).map(|pid| (pid, 1)).collect();
    let children = index(&pairs);
    let tree = walk_tree(1, MAX_PROCESSES_PER_TERMINAL, |pid| children.children(pid));
    assert_eq!(tree.nodes.len(), MAX_PROCESSES_PER_TERMINAL);
    assert!(tree.truncated);
    assert_eq!(tree.nodes[0].pid, 1);
    // Exactly at the cap (the root and its 600 children) is not truncated.
    let tree = walk_tree(1, 601, |pid| children.children(pid));
    assert_eq!(tree.nodes.len(), 601);
    assert!(!tree.truncated);
    let tree = walk_tree(1, 0, |pid| children.children(pid));
    assert!(tree.nodes.is_empty());
    assert!(tree.truncated);
}

#[test]
fn cmux_next_process_tree_parses_proc_stat_and_statm() {
    let stat = "4242 (my (odd) cmd) S 4000 4242 4242 34816 4242 4194304 100 0 0 0 \
                250 50 0 0 20 0 1 0 12345 1000000 300 18446744073709551615";
    let parsed = parse_proc_stat(stat).unwrap();
    assert_eq!(parsed, ProcStat { ppid: 4000, name: "my (odd) cmd".to_string(), cpu_ticks: 300 });
    assert_eq!(parse_proc_stat("garbage"), None);
    assert_eq!(parse_statm_resident_pages("2048 512 100 1 0 300 0\n"), Some(512));
    assert_eq!(parse_statm_resident_pages("2048"), None);
    assert_eq!(executable_basename("/usr/bin/sleep"), "sleep");
    assert_eq!(executable_basename("sleep"), "sleep");
}

#[test]
fn cmux_next_process_tree_samples_this_process() {
    let now = monotonic_now_ns();
    assert!(monotonic_now_ns() >= now);
    let sampler = Sampler::new();
    let own = std::process::id();
    if !reads_process_trees() {
        assert_eq!(sampler.sample(own), None);
        return;
    }
    let sample = sampler.sample(own).expect("sample of the test process");
    assert!(!sample.name.is_empty());
    assert!(sample.memory_bytes > 0);
    assert!(sampler.runs_own_executable(own));
    assert!(sampler.parent(own).is_some());
    assert_eq!(sampler.tree(own).nodes[0].pid, own);
}
