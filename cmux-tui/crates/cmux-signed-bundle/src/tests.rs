use super::*;

/// A fake bundle `<dir>/<name>` whose executable holds `body`.
fn bundle(dir: &Path, name: &str, body: &str) -> PathBuf {
    let app = dir.join(name);
    std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
    std::fs::create_dir_all(app.join("Contents/_CodeSignature")).unwrap();
    std::fs::write(app.join("Contents/MacOS/helper"), body).unwrap();
    std::fs::write(app.join("Contents/_CodeSignature/CodeResources"), "seal").unwrap();
    std::fs::write(app.join("Contents/Info.plist"), "plist").unwrap();
    app
}

fn copy_tree(from: &Path, to: &Path) -> Result<(), String> {
    std::fs::create_dir_all(to).map_err(|e| e.to_string())?;
    for entry in std::fs::read_dir(from).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let target = to.join(entry.file_name());
        if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), target).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[test]
fn the_digest_covers_the_executable_seal_and_plist() {
    let dir = tempfile::tempdir().unwrap();
    let parts = digest_parts("helper");
    let one = digest_of(&bundle(dir.path(), "A.app", "one"), &parts).unwrap();
    let two = digest_of(&bundle(dir.path(), "B.app", "two"), &parts).unwrap();
    assert_eq!(one.len(), 64);
    assert_ne!(one, two);
    assert!(digest_of(&dir.path().join("missing.app"), &parts).is_err());
}

#[test]
fn a_copy_is_staged_once_per_digest_and_old_ones_pruned() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("root");
    let parts = digest_parts("helper");
    let first = bundle(&dir.path().join("v1"), "Helper.app", "one");
    let staged = stage_with(&first, &root, &parts, copy_tree, |_| Ok(())).unwrap();
    assert!(staged.executable("helper").is_file());
    assert!(staged.app.starts_with(&root));
    // Reused: a copier that fails is never asked.
    let again = stage_with(&first, &root, &parts, |_, _| Err("copied".into()), |_| Ok(())).unwrap();
    assert_eq!(again, staged);
    // Two more builds: the oldest copy goes, the two newest stay.
    for (n, body) in [(2, "two"), (3, "three")] {
        std::thread::sleep(std::time::Duration::from_millis(20));
        let next = bundle(&dir.path().join(format!("v{n}")), "Helper.app", body);
        stage_with(&next, &root, &parts, copy_tree, |_| Ok(())).unwrap();
    }
    let slots = std::fs::read_dir(&root).unwrap().count();
    assert_eq!(slots, 2);
    assert!(!staged.app.exists());
}

#[test]
fn a_copy_that_fails_its_check_is_never_kept() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("root");
    let parts = digest_parts("helper");
    let source = bundle(dir.path(), "Helper.app", "one");
    let refused = stage_with(&source, &root, &parts, copy_tree, |_| Err("unsigned".into()));
    assert_eq!(refused, Err("unsigned".into()));
    assert_eq!(std::fs::read_dir(&root).unwrap().count(), 0);
    // A copier that changes the bytes is caught by the digest.
    let tamper = |from: &Path, to: &Path| {
        copy_tree(from, to)?;
        std::fs::write(to.join("Contents/MacOS/helper"), "evil").map_err(|e| e.to_string())
    };
    let refused = stage_with(&source, &root, &parts, tamper, |_| Ok(()));
    assert_eq!(refused, Err("the copy differs from the source bundle".into()));
}

#[cfg(unix)]
#[test]
fn a_symlinked_root_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    assert!(private_dir(&link).is_err());
    assert!(private_dir(&real).is_ok());
}

#[test]
fn requirements_read_and_write_as_codesign_does() {
    assert_eq!(
        team_requirement("com.cmuxterm.app.screen-sharing", "7WLXT3NR37"),
        "identifier \"com.cmuxterm.app.screen-sharing\" and anchor apple generic and certificate leaf[subject.OU] = \"7WLXT3NR37\""
    );
    let printed = "Executable=/x/Helper.app/Contents/MacOS/helper\n# designated => cdhash H\"ab\"\ndesignated => identifier \"a.b\" and anchor apple generic\n";
    assert_eq!(
        parse_designated(printed).as_deref(),
        Some("identifier \"a.b\" and anchor apple generic")
    );
    assert_eq!(parse_designated("Executable=/x\n"), None);
}
