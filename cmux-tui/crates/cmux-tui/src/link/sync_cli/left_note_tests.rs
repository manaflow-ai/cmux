use super::*;

#[test]
fn a_long_list_is_summed_past_its_folders_and_names_the_largest_files() {
    let mut left = LeftOnMac::new(true);
    for index in 0..100u64 {
        left.left(&format!("dir{index:03}/a/b.txt"), index * 1000);
    }
    left.left("Downloads/disk.img", 21_000_000_000);
    left.left("cmux/.git/objects/pack/p.pack", 5_000_000);
    left.sent(10);
    let text = left.text(Path::new("/Users/me/Projects"), "/home/u/work/Projects");
    assert!(text.contains("- `Downloads/`: 1 file, 21.0 GB"), "{text}");
    assert!(text.contains("- `cmux/.git/`: 1 file, 5.0 MB, repository history"), "{text}");
    assert!(text.contains("- and 62 more: 62 files,"), "{text}");
    assert!(text.contains("- `Downloads/disk.img`: 21.0 GB"), "{text}");
    assert!(text.contains("cmux link access request /Users/me/Projects/PATH"), "{text}");
    assert!(text.contains("did not reach"), "{text}");
    assert!(text.len() < 8 * 1024, "{} bytes", text.len());
}

#[test]
fn sizes_read_as_finder_shows_them() {
    assert_eq!(human(999), "999 B");
    assert_eq!(human(1_500), "1.5 KB");
    assert_eq!(human(22_548_578_304), "22.5 GB");
    assert_eq!(group("notes.md"), ("notes.md".into(), false));
    assert_eq!(group("work/api/.git/HEAD"), ("work/api/.git/".into(), true));
}
