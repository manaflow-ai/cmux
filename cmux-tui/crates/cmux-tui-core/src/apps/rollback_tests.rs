use super::*;

/// A fresh empty folder under the system temp dir, removed on drop.
struct Temp(PathBuf);
impl Temp {
    fn new(tag: &str) -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let dir = std::env::temp_dir()
            .join(format!("cmux-rollback-{tag}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap()
}

#[test]
fn rollback_folder_names_are_unambiguous() {
    let apps = ["local/a~b", "local~a/b", "local/a%2Fb", "local/a/b", "x/é"];
    let names: Vec<String> = apps.map(encode).into();
    let unique: BTreeSet<&String> = names.iter().collect();
    assert_eq!(unique.len(), names.len(), "{names:?}");
    for (app, name) in apps.iter().zip(&names) {
        assert_eq!(decode(name).as_deref(), Some(*app), "{name}");
    }
    assert_eq!(encode("local/spy"), "local%2Fspy");
    // Names encode never makes are not apps.
    for name in ["local~spy", "%2f", "%+1", "%2", "a b"] {
        assert_eq!(decode(name), None, "{name}");
    }
}

#[test]
fn rollback_keeps_two_replaced_versions() {
    let root = Temp::new("rotate");
    let (dir, target) = (root.0.join("app"), root.0.join("kept"));
    write(&target.join("files/dist/main.js"), "good");
    write(&dir.join("dist/main.js"), "broken one");
    restore(&dir, &target).unwrap();
    assert_eq!(read(&dir.join("dist/main.js")), "good");
    write(&dir.join("dist/main.js"), "broken two");
    restore(&dir, &target).unwrap();
    assert_eq!(read(&dir.join("dist/main.js")), "good");
    assert_eq!(read(&target.join("replaced/dist/main.js")), "broken two");
    assert_eq!(read(&target.join("replaced.previous/dist/main.js")), "broken one");
}

#[cfg(unix)]
#[test]
fn rollback_refuses_to_write_through_a_symlink() {
    use std::os::unix::fs::symlink;
    let root = Temp::new("symlink");
    let (dir, target, outside) = (root.0.join("app"), root.0.join("kept"), root.0.join("outside"));
    write(&target.join("files/dist/main.js"), "good");
    write(&target.join("files/cmux-app.json"), "{}");
    write(&outside.join("main.js"), "not yours");
    write(&outside.join("victim.json"), "not yours");
    // A linked directory on the way.
    std::fs::create_dir_all(&dir).unwrap();
    symlink(&outside, dir.join("dist")).unwrap();
    let refused = restore(&dir, &target).unwrap_err();
    assert!(refused.to_string().contains("symbolic link"), "{refused}");
    assert_eq!(read(&outside.join("main.js")), "not yours");
    // Refused before anything changed: nothing was moved to replaced.
    assert!(!target.join("replaced").exists());
    // A linked file.
    std::fs::remove_file(dir.join("dist")).unwrap();
    write(&dir.join("dist/main.js"), "broken");
    symlink(outside.join("victim.json"), dir.join("cmux-app.json")).unwrap();
    let refused = restore(&dir, &target).unwrap_err();
    assert!(refused.to_string().contains("symbolic link"), "{refused}");
    assert_eq!(read(&outside.join("victim.json")), "not yours");
    assert_eq!(read(&dir.join("dist/main.js")), "broken");
    // With the link gone it restores.
    std::fs::remove_file(dir.join("cmux-app.json")).unwrap();
    restore(&dir, &target).unwrap();
    assert_eq!(read(&dir.join("dist/main.js")), "good");
    assert_eq!(read(&outside.join("main.js")), "not yours");
}
