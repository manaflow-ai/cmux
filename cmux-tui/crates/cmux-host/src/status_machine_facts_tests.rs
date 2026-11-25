use super::*;

#[test]
fn parses_proc_files() {
    assert_eq!(parse_uptime("172800.55 340000.10\n"), Some(172800));
    assert_eq!(parse_mem_total_mib("MemTotal:        3984000 kB\nMemFree: 1 kB\n"), Some(3890));
    assert_eq!(parse_uptime(""), None);
}

#[test]
fn first_read_is_fresh_second_is_reused() {
    let dir = std::env::temp_dir().join(format!("cmux-host-facts-{}", std::process::id()));
    let marker = dir.join("first-agent-start");
    let _ = std::fs::remove_dir_all(&dir);
    let first = MachineFacts::read(&marker, 1000);
    assert!(!first.reused);
    assert_eq!(first.first_agent_start_unix, 1000);
    let second = MachineFacts::read(&marker, 5000);
    assert!(second.reused);
    assert_eq!(second.first_agent_start_unix, 1000);
    assert!(second.vcpus >= 1);
    let _ = std::fs::remove_dir_all(&dir);
}
