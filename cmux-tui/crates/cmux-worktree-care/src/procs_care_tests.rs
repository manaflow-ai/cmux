#[cfg(unix)]
#[test]
fn care_a_program_working_in_a_folder_has_it_open() {
    let folder = std::env::temp_dir().join(format!("care-open-{}", std::process::id()));
    std::fs::create_dir_all(&folder).unwrap();
    let mut child =
        std::process::Command::new("sleep").arg("30").current_dir(&folder).spawn().unwrap();
    let found = open_inside(&folder);
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&folder);
    match found {
        Ok(pid) => assert_eq!(pid, Some(child.id())),
        // No lsof on this machine: the check fails closed, which is
        // what a pass needs; nothing more to test here.
        Err(error) => assert!(error.starts_with("lsof"), "{error}"),
    }
}

use super::*;

#[test]
fn a_process_in_a_subfolder_is_inside_but_a_sibling_prefix_is_not() {
    let processes = vec![
        Process { pid: 1, cwd: PathBuf::from("/w/a-2/src") },
        Process { pid: 2, cwd: PathBuf::from("/w/a/src") },
    ];
    assert_eq!(inside(&processes, Path::new("/w/a")).map(|p| p.pid), Some(2));
    assert_eq!(inside(&processes, Path::new("/w/b")), None);
}

#[test]
fn care_a_running_claude_session_is_found_and_a_stale_one_is_not() {
    let dir = crate::store::care_tests::scratch("claude-registry");
    let sessions = dir.join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let me = std::process::id();
    std::fs::write(
        sessions.join("1.json"),
        format!(r#"{{"pid":{me},"cwd":"/w/a","kind":"interactive"}}"#),
    )
    .unwrap();
    // Far above any pid_max: never running.
    std::fs::write(sessions.join("2.json"), r#"{"pid":2000000000,"cwd":"/w/b"}"#).unwrap();
    std::fs::write(sessions.join("3.json"), "{not json").unwrap();
    let found = claude_sessions(&[dir.clone(), dir.join("absent")]).unwrap();
    assert_eq!(found, vec![Process { pid: me, cwd: PathBuf::from("/w/a") }]);
    // A format change: no record reads, so the pass must not act.
    for name in ["1.json", "2.json"] {
        std::fs::write(sessions.join(name), r#"{"processId":1,"folder":"/w/a"}"#).unwrap();
    }
    assert!(claude_sessions(std::slice::from_ref(&dir)).is_err());
    let _ = std::fs::remove_dir_all(dir);
}
