use super::*;

fn private_dir() -> PathBuf {
    let mut bytes = [0_u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let suffix: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let directory = std::env::temp_dir().join(format!("cmux-hook-queue-test-{suffix}"));
    let mut builder = std::fs::DirBuilder::new();
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(&directory).unwrap();
    directory
}

/// `reset-state` is the definitive end of a session's hook queues: they
/// are deleted and their events counted; another session's stay.
#[test]
fn reset_drops_and_counts_only_the_sessions_hook_queues() {
    let root = private_dir();
    let socket = root.join("work.sock");
    let spool = hook_spool_dir(&socket).unwrap();
    let queue = |socket: &str, terminal: &str| {
        spool.join(format!(
            "{}.{}.jsonl",
            queue_prefix(&root.join(socket)),
            spool_name_part(terminal)
        ))
    };
    std::fs::write(queue("work.sock", "terminal_a"), "{}\n{}\n").unwrap();
    std::fs::write(queue("work.sock", "terminal_b"), "{}\n").unwrap();
    std::fs::write(queue("other.sock", "terminal_c"), "{}\n").unwrap();
    // A collision of escaped names: it must stay another session's queue.
    std::fs::write(queue("work_sock", "terminal_d"), "{}\n").unwrap();
    assert_eq!(HookQueueSnapshot::beside(&socket).queued_events, 3);

    assert_eq!(drop_session_hook_queues(&socket).unwrap(), 3);

    let mut left: Vec<_> = std::fs::read_dir(&spool)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    let mut kept = vec![
        queue("other.sock", "terminal_c").file_name().unwrap().to_string_lossy().into_owned(),
        queue("work_sock", "terminal_d").file_name().unwrap().to_string_lossy().into_owned(),
        HOOK_SPOOL_DROPPED_EVENTS.to_owned(),
    ];
    kept.sort();
    assert_eq!(left, kept);
    let snapshot = HookQueueSnapshot::beside(&socket);
    assert_eq!((snapshot.queued_events, snapshot.reset_dropped_events), (0, 3));
    assert_eq!(HookQueueSnapshot::beside(&root.join("other.sock")).queued_events, 1);
    std::fs::remove_dir_all(root).unwrap();
}

/// reset-state and server-stats never read or delete in a queue
/// directory that another user could have made or written.
#[test]
fn reset_and_stats_leave_a_shared_directory_alone() {
    use std::os::unix::fs::PermissionsExt as _;
    let root = private_dir();
    let socket = root.join("work.sock");
    let spool = root.join(HOOK_SPOOL_DIR);
    std::fs::create_dir(&spool).unwrap();
    let planted =
        spool.join(format!("{}.{}.jsonl", queue_prefix(&socket), spool_name_part("terminal_a")));
    std::fs::write(&planted, "{}\n").unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o777)).unwrap();

    assert!(drop_session_hook_queues(&socket).is_err());
    assert!(planted.exists(), "reset deleted a file in a shared directory");
    assert_eq!(HookQueueSnapshot::beside(&socket).queued_events, 0);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_shared_directory_gets_no_spool() {
    use std::os::unix::fs::PermissionsExt as _;
    let root = private_dir();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o777)).unwrap();
    assert!(hook_spool_dir(&root.join("s.sock")).is_err());
    assert!(!root.join(HOOK_SPOOL_DIR).exists());
    std::fs::remove_dir_all(root).unwrap();
}
