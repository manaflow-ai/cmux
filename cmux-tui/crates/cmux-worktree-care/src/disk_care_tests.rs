use super::*;
use std::time::Duration;

#[test]
fn a_listed_folder_is_summed_inside_the_total() {
    let root = crate::store::care_tests::scratch("sizes");
    std::fs::create_dir_all(root.join("node_modules/a")).unwrap();
    std::fs::write(root.join("node_modules/a/big"), vec![1u8; 64 * 1024]).unwrap();
    std::fs::write(root.join("small"), b"x").unwrap();
    let part = PathBuf::from("node_modules");
    let sizes = sizes(&root, std::slice::from_ref(&part), Instant::now() + Duration::from_secs(10));
    let modules = sizes.parts.get(&part).copied().unwrap_or(0);
    assert!(modules >= 64 * 1024, "{modules}");
    assert!(sizes.total > modules);
    assert!(!sizes.partial);
}

#[test]
fn the_disk_of_a_folder_has_a_size() {
    let usage = usage(Path::new("/")).unwrap();
    assert!(usage.total > 0 && usage.available <= usage.total);
    assert!((0.0..=1.0).contains(&usage.used_fraction()));
}
