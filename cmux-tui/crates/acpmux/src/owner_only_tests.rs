use super::*;

fn grant_everyone(path: &Path) {
    let output = std::process::Command::new("icacls")
        .arg(path)
        .args(["/grant", "*S-1-1-0:(OI)(CI)F"])
        .output()
        .unwrap();
    assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
}

fn grant_everyone_read(path: &Path) {
    let output = std::process::Command::new("icacls")
        .arg(path)
        .args(["/grant", "*S-1-1-0:(OI)(CI)R"])
        .output()
        .unwrap();
    assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
}

fn grant_everyone_add_subdirectory(path: &Path) {
    let output = std::process::Command::new("icacls")
        .arg(path)
        .args(["/grant", "*S-1-1-0:(AD)"])
        .output()
        .unwrap();
    assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
}

fn grant_everyone_add_file(path: &Path) {
    let output = std::process::Command::new("icacls")
        .arg(path)
        .args(["/grant", "*S-1-1-0:(WD)"])
        .output()
        .unwrap();
    assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
}

#[test]
fn private_dir_refuses_an_existing_directory_another_sid_can_change() {
    let root = std::env::temp_dir().join(format!(
        "acpmux-owner-writable-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let checked = root.join("checked");
    std::fs::create_dir_all(&checked).unwrap();
    grant_everyone(&checked);
    private_dir(&checked).expect_err("a directory writable by Everyone was trusted");
    assert!(!only_owner_reads(&checked).unwrap(), "the unsafe DACL was silently erased");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn private_dir_allows_an_ancestor_that_can_only_add_a_sibling() {
    let root = std::env::temp_dir().join(format!(
        "acpmux-owner-add-only-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let checked = root.join("checked");
    private_dir(&root).unwrap();
    private_dir(&checked).unwrap();
    grant_everyone_add_subdirectory(&root);

    private_dir(&checked).expect("add-subdirectory alone could replace an existing child");
    assert!(only_owner_reads(&checked).unwrap());
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn private_dir_refuses_an_ancestor_that_can_be_made_a_reparse_point() {
    let root = std::env::temp_dir().join(format!(
        "acpmux-owner-add-file-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    private_dir(&root).unwrap();
    grant_everyone_add_file(&root);

    private_dir(&root.join("checked"))
        .expect_err("FILE_WRITE_DATA can turn the ancestor into a reparse point");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn private_dir_normalizes_the_opened_directory_not_a_replacement_path() {
    let root = std::env::temp_dir().join(format!(
        "acpmux-owner-handle-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let checked = root.join("checked");
    let moved = root.join("moved");
    std::fs::create_dir_all(&checked).unwrap();
    grant_everyone_read(&checked);

    ensure_safe_parent(&checked).unwrap();
    let opened = open_directory(&checked).unwrap();
    std::fs::rename(&checked, &moved).unwrap();
    std::fs::create_dir(&checked).unwrap();
    grant_everyone(&checked);
    finish_private_dir(&checked, &opened).expect_err("a replacement pathname was accepted");

    assert!(only_owner_reads(&moved).unwrap(), "the checked object stayed wide");
    assert!(!only_owner_reads(&checked).unwrap(), "the replacement path was changed");
    let _ = std::fs::remove_dir_all(&root);
}
