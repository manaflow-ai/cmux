use std::fs;

use super::*;

/// A work tree with the file `below.txt` in the folder `real`, and the
/// link `dir` to that folder.
fn tree_with_a_link() -> PathBuf {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let root = std::env::temp_dir().join(format!("cmux-files-second-look-{hex}"));
    fs::create_dir_all(root.join("real")).unwrap();
    fs::write(root.join("real/below.txt"), "below").unwrap();
    std::os::unix::fs::symlink("real", root.join("dir")).unwrap();
    root
}

/// The second look of a search, with no candidate filter before it: the
/// state of a folder that became a link after the look at the candidates.
#[test]
fn the_second_look_of_a_search_gives_no_path_below_a_link() {
    let root = tree_with_a_link();
    let mut folders = Folders { tree: Tree::open(&root), below: PathBuf::new() };
    assert!(folders.tree.is_some(), "the work tree opens");
    assert!(folders.file("real/below.txt"), "a file below a real folder");
    assert!(!folders.file("dir/below.txt"), "a path below a link");
    assert!(folders.file("dir"), "the link itself is a leaf");
    assert!(!folders.file("real"), "a real folder is no file");
    fs::remove_dir_all(root).unwrap();
}

/// The second look gives no path that it cannot look at: a folder above
/// the path is not there, nothing has the path's name, or the work tree
/// did not open.
#[test]
fn the_second_look_of_a_search_gives_no_path_that_it_cannot_reach() {
    let root = tree_with_a_link();
    let mut folders = Folders { tree: Tree::open(&root), below: PathBuf::new() };
    assert!(folders.tree.is_some(), "the work tree opens");
    let below_nothing = folders.file("none/below.txt");
    let no_name = folders.file("real/none.txt");
    let mut no_tree = Folders { tree: None, below: PathBuf::new() };
    let no_work_tree = no_tree.file("real/below.txt");
    fs::remove_dir_all(root).unwrap();
    assert!(!below_nothing, "a path below a folder that is not there");
    assert!(!no_name, "a name that is not there");
    assert!(!no_work_tree, "a work tree that did not open");
}
