use super::*;

fn scratch(tag: &str) -> std::path::PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-automations-sys-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

#[test]
fn this_process_is_alive_and_a_reaped_child_is_not() {
    assert!(pid_alive(std::process::id()));
    #[cfg(unix)]
    let mut child = std::process::Command::new("/bin/sh").arg("-c").arg("exit 0").spawn().unwrap();
    #[cfg(windows)]
    let mut child = std::process::Command::new("cmd").args(["/C", "exit 0"]).spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    assert!(!pid_alive(pid));
}

#[test]
fn the_machine_has_a_name() {
    assert!(hostname().is_some_and(|n| !n.is_empty()));
}

#[test]
fn private_folders_and_files_are_made_and_synced() {
    let dir = scratch("private").join("a/b");
    create_private_dir(&dir).unwrap();
    let file = dir.join("f");
    private_file(OpenOptions::new().create(true).write(true)).open(&file).unwrap();
    sync_dir(&dir).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&file), 0o600);
    }
    let _ = fs::remove_dir_all(scratch("private"));
}
