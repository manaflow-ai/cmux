use super::*;

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("cu-stage-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn slot(root: &Path, name: &str, marker: &str) {
    let s = root.join(name);
    std::fs::create_dir_all(s.join("cmux Remote (dev).app")).unwrap();
    std::fs::write(s.join(".verified"), marker).unwrap();
}

#[test]
fn a_new_build_moves_into_the_one_stable_path_and_old_layouts_go() {
    let root = dir("promote");
    slot(&root, CURRENT, "old");
    slot(&root, NEXT, "new");
    slot(&root, "0123456789abcdef", "older layout");
    let app = root.join(CURRENT).join("cmux Remote (dev).app");
    let staged = Staged {
        executable: app.join("Contents/MacOS/cmux-remote"),
        app: app.clone(),
        digest: "new".into(),
        next: Some(root.join(NEXT)),
    };
    promote(&staged).unwrap();
    assert_eq!(std::fs::read_to_string(root.join(CURRENT).join(".verified")).unwrap(), "new");
    assert!(!root.join(NEXT).exists());
    assert!(!root.join("0123456789abcdef").exists());
    assert!(app.exists(), "the app keeps its path across builds");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn nothing_waiting_keeps_current_and_a_live_staging_folder() {
    let root = dir("keep");
    slot(&root, CURRENT, "same");
    let live = root.join(format!(".staging-{}", std::process::id()));
    std::fs::create_dir_all(&live).unwrap();
    let app = root.join(CURRENT).join("cmux Remote (dev).app");
    let staged = Staged {
        executable: app.join("Contents/MacOS/cmux-remote"),
        app,
        digest: "same".into(),
        next: None,
    };
    promote(&staged).unwrap();
    assert_eq!(std::fs::read_to_string(root.join(CURRENT).join(".verified")).unwrap(), "same");
    assert!(live.exists());
    let _ = std::fs::remove_dir_all(&root);
}
