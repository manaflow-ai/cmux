use std::fs::{create_dir, write};

use super::*;

fn temp_dir(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "cmux-tui-sidebar-files-{name}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn lists_directories_first_and_sorts_each_kind() {
    let temp = temp_dir("sort");
    create_dir(temp.join("z-dir")).unwrap();
    create_dir(temp.join("A-dir")).unwrap();
    write(temp.join("z-file"), "").unwrap();
    write(temp.join("B-file"), "").unwrap();

    let entries = list_directory(&temp, false).unwrap();
    let actual = entries.iter().map(|entry| (entry.name.as_str(), entry.kind)).collect::<Vec<_>>();
    assert_eq!(
        actual,
        vec![
            ("A-dir", EntryKind::Directory),
            ("z-dir", EntryKind::Directory),
            ("B-file", EntryKind::File),
            ("z-file", EntryKind::File),
        ]
    );
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn hides_dotfiles_until_enabled() {
    let temp = temp_dir("hidden");
    create_dir(temp.join(".config")).unwrap();
    write(temp.join(".env"), "").unwrap();
    write(temp.join("visible"), "").unwrap();

    let hidden = list_directory(&temp, false).unwrap();
    assert_eq!(hidden.len(), 1);
    assert_eq!(hidden[0].name, "visible");

    let shown = list_directory(&temp, true).unwrap();
    assert_eq!(shown.len(), 3);
    assert_eq!(shown[0].name, ".config");
    assert_eq!(shown[1].name, ".env");
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn filters_case_insensitively() {
    let entries = vec![
        FileEntry { name: "ReadMe.md".into(), path: "ReadMe.md".into(), kind: EntryKind::File },
        FileEntry { name: "src".into(), path: "src".into(), kind: EntryKind::Directory },
    ];
    assert_eq!(filtered_indices(&entries, "README"), vec![0]);
    assert_eq!(filtered_indices(&entries, "r"), vec![0, 1]);
}
