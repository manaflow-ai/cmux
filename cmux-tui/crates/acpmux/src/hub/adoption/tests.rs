use super::*;
use std::process::Command;

/// A fresh folder for one test, canonical (macOS's temp dir is a symlink).
fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("acpmux-adopt-cwd-remap-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

/// A git checkout at `dir` with a `sub` folder and `remote` as origin.
fn checkout(dir: &Path, remote: &str) {
    std::fs::create_dir_all(dir.join("sub")).unwrap();
    for args in [&["init", "-q"][..], &["remote", "add", "origin", remote]] {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .status()
            .unwrap()
            .success();
        assert!(ok, "git {args:?}");
    }
}

/// Another machine's home, gone here.
const GONE: &str = "/acpmux-gone-host/leo";

fn map_to(root: &Path) -> Vec<(PathBuf, PathBuf)> {
    vec![(PathBuf::from(GONE), root.to_path_buf())]
}

#[test]
fn adopt_cwd_remap_explicit_map_opens_the_mapped_folder() {
    let root = scratch("explicit");
    let given = root.join("Projects");
    std::fs::create_dir_all(&given).unwrap();
    let recorded = PathBuf::from(GONE).join("Projects");
    let got =
        session_cwd(Some(given.clone()), Some(recorded.clone()), "claude", &map_to(&root)).unwrap();
    assert_eq!(got, (given, Some(recorded)));
}

#[test]
fn adopt_cwd_remap_accepts_another_checkout_of_the_same_repo() {
    let root = scratch("same-repo");
    checkout(&root.join("a"), "git@github.com:manaflow-ai/cmux.git");
    checkout(&root.join("b"), "https://GitHub.com/manaflow-ai/cmux/");
    let recorded = PathBuf::from(GONE).join("a/sub");
    let given = root.join("b/sub");
    let got =
        session_cwd(Some(given.clone()), Some(recorded.clone()), "claude", &map_to(&root)).unwrap();
    assert_eq!(got, (given, Some(recorded)));
}

#[test]
fn adopt_cwd_remap_refuses_another_repo() {
    let root = scratch("other-repo");
    checkout(&root.join("a"), "git@github.com:manaflow-ai/cmux.git");
    checkout(&root.join("b"), "git@github.com:manaflow-ai/other.git");
    let recorded = PathBuf::from(GONE).join("a/sub");
    let err = session_cwd(Some(root.join("b/sub")), Some(recorded), "claude", &map_to(&root))
        .unwrap_err();
    assert!(err.message.contains("which is gone"), "{}", err.message);
}

#[test]
fn adopt_cwd_remap_refuses_another_folder_of_the_same_repo() {
    let root = scratch("other-folder");
    checkout(&root.join("a"), "git@github.com:manaflow-ai/cmux.git");
    checkout(&root.join("b"), "git@github.com:manaflow-ai/cmux.git");
    let recorded = PathBuf::from(GONE).join("a/sub");
    let err =
        session_cwd(Some(root.join("b")), Some(recorded), "claude", &map_to(&root)).unwrap_err();
    assert!(err.message.contains("which is gone"), "{}", err.message);
}

#[test]
fn adopt_cwd_remap_home_swap_needs_the_same_repo() {
    let root = scratch("home-swap");
    checkout(&root.join("a"), "git@github.com:manaflow-ai/cmux.git");
    std::fs::create_dir_all(root.join("Projects")).unwrap();
    // Another machine's home maps onto this one's, for a checkout of one repo.
    let swapped = remapped_cwd(&root.join("a/sub"), Path::new("/home/leo/a/sub"), &[], Some(&root));
    assert_eq!(swapped, Ok(()));
    // A folder that is no checkout needs an explicit map.
    let plain =
        remapped_cwd(&root.join("Projects"), Path::new("/home/leo/Projects"), &[], Some(&root));
    assert!(plain.is_err());
    // A folder under no home maps nowhere.
    assert!(remapped_cwd(&root.join("a/sub"), Path::new("/srv/a/sub"), &[], Some(&root)).is_err());
}

#[test]
fn adopt_cwd_remap_gone_folder_without_a_map_is_refused() {
    let root = scratch("no-map");
    let err =
        session_cwd(Some(root.clone()), Some(PathBuf::from("/srv/acpmux-gone/x")), "claude", &[])
            .unwrap_err();
    assert!(err.message.contains("which is gone"), "{}", err.message);
}

#[test]
fn adopt_cwd_remap_reads_the_adopt_cwd_map() {
    let meta = json!({"adopt": {"agentSessionId": "abc", "cwdMap": ["/home/leo=/Users/leoli"]}});
    let adopt = AdoptRequest::from_meta(Some(&meta)).unwrap().unwrap();
    assert_eq!(adopt.cwd_map, vec![(PathBuf::from("/home/leo"), PathBuf::from("/Users/leoli"))]);
    let bad = json!({"adopt": {"agentSessionId": "abc", "cwdMap": ["home=/Users/leoli"]}});
    assert!(AdoptRequest::from_meta(Some(&bad)).is_err());
}
