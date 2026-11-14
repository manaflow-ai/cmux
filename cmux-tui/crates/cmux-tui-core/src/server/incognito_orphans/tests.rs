use super::*;

#[test]
fn only_workspaces_of_a_gone_other_process_are_orphaned() {
    let creators = HashMap::from([
        ("gone".to_string(), "token:1.1".to_string()),
        ("reader".to_string(), "token:2.1".to_string()),
        ("connected".to_string(), "token:3.1".to_string()),
    ]);
    let connected = HashSet::from(["token:2.1".to_string(), "token:3.1".to_string()]);
    let all_gone = |_: &str| true;
    assert_eq!(orphaned(&creators, "token:2.1", &connected, all_gone), vec!["gone".to_string()]);
    // A new process with the old pid (another pid version) is another process.
    assert_eq!(orphaned(&creators, "token:1.2", &connected, all_gone), vec!["gone".to_string()]);
    // A creator whose process still runs keeps its workspaces.
    assert!(orphaned(&creators, "token:2.1", &connected, |_| false).is_empty());
}

#[cfg(unix)]
#[test]
fn a_running_process_is_not_gone() {
    assert!(!process_gone(&format!("token:{}.1", std::process::id())));
    // Above every pid_max (Linux 4194304, macOS 99999).
    assert!(process_gone("token:999999901.1"));
}
